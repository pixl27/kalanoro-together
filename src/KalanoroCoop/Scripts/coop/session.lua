-- Hosting, joining, leaving, and keeping level travel in sync.
local U = require("coop.util")
local Log = require("coop.log")
local Net = require("coop.net")
local UI = require("coop.ui")
local Config = require("coop.config")
local System = require("coop.system")

local Session = {}

local DEFAULT_MAP = "/Game/Levels/StartingScreenLevel"
local MENU_MAPS = {
    ["/Game/Levels/StartingScreenLevel"] = true,
    ["/Game/Levels/MainMenu"] = true,
}
local STEAM_DLL_FROM_MOD = "\\..\\..\\..\\..\\..\\..\\Engine\\Binaries\\ThirdParty\\Steamworks\\Steamv157\\Win64\\steam_api64.dll"

local allowNextTravel = false
local lastMode = nil
local knownClients = {}
local helloWorld = nil
local travelQuietUntil = 0 -- clients reconnect during a server travel; don't announce that as leave/join
local readyListeners = {}
local greeted = {}           -- host: client controllers already announced
local lastJoinAddress = nil -- address of the host we are connected to (for automatic reconnection)
local leavingOnPurpose = false
local reconnect = nil        -- { address, tries, nextAt } while trying to get back into a dropped session
local connected = false      -- client: reached the host's level with a character since the last join
local rejoinAt = nil         -- client: os.clock() of a deliberate reload of the host's level
local REJOIN_SECONDS = 60
local RECONNECT_TRIES = 6
local RECONNECT_INTERVAL = 8

-- fn(pc) runs on the host each time a client has finished loading a level and has a pawn.
function Session.onClientReady(fn)
    readyListeners[#readyListeners + 1] = fn
end

-- The game ships with SteamNetDriver as GameNetDriver; with Steam sockets it cannot open an IP listen
-- socket, so use the plain UDP driver for the game connection.
local function patchNetDriver()
    local engines = { StaticFindObject("/Script/Engine.Default__GameEngine"), FindFirstOf("GameEngine") }
    for _, ge in ipairs(engines) do
        if U.valid(ge) then
            local defs = ge.NetDriverDefinitions
            for i = 1, #defs do
                if defs[i].DefName:ToString() == "GameNetDriver" then
                    defs[i].DriverClassName = FName("/Script/OnlineSubsystemUtils.IpNetDriver")
                    defs[i].DriverClassNameFallback = FName("/Script/OnlineSubsystemUtils.IpNetDriver")
                end
            end
        end
    end
end

-- <game>/Kalanoro/Binaries/Win64/ue4ss/Mods/KalanoroCoop -> <game>/Engine/.../steam_api64.dll
local function steamApiPresent()
    local f = io.open(Config.ModDir .. STEAM_DLL_FROM_MOD, "rb")
    if f then f:close() return true end
    return false
end

local function openLevel(target, options)
    local pc = U.localPC()
    if not pc then return end
    allowNextTravel = true
    U.statics():OpenLevel(pc, FName(target), true, options or "")
end

-- Host only: move the host and every client to `url` (map path plus optional "?options").
local function serverTravel(url)
    local pc = U.localPC()
    if not pc then return end
    Log.info("server travel -> %s", url)
    travelQuietUntil = os.clock() + 45
    U.ksl():ExecuteConsoleCommand(pc, "servertravel " .. url, pc)
end

-- Host: reload the current level for the whole group.
function Session.restartLevel()
    local map = U.currentMap()
    if map then serverTravel(map) end
end

-- Tell the host which address to give their friends, and put it on the clipboard.
function Session.announceAddress()
    local ips = System.localIPs()
    if #ips == 0 then
        UI.notify("hosting on UDP port 7777")
        return
    end
    local best = ips[1]
    System.clipboardSet(best.ip)
    local others = {}
    for i = 2, #ips do others[#others + 1] = ips[i].ip end
    UI.notify("hosting! your IP %s (%s) is copied - send it to your friend", best.ip, best.adapter)
    if #others > 0 then UI.notify("other IPs: %s (internet play: your public IP, UDP 7777 forwarded)", table.concat(others, ", ")) end
end

function Session.host()
    local mode = U.netMode()
    if mode == "host" then UI.notify("already hosting on UDP port 7777") return end
    if mode == "client" then UI.notify("leave the current session before hosting") return end
    local map = U.currentMap()
    if not map or MENU_MAPS[map] then
        UI.notify("load your save first, then press %s to host", Config.HostKey)
        return
    end
    if steamApiPresent() then
        UI.notify("cannot host: Steam API is enabled, run Install-KalanoroCoop.ps1")
        return
    end
    Log.info("hosting %s", map)
    openLevel(map, "listen")
end

function Session.join(address)
    if not address then
        local clip = System.clipboardGet()
        if System.looksLikeAddress(clip) then address = clip else address = Config.JoinAddress end
    end
    local mode = U.netMode()
    if mode == "host" or mode == "client" then UI.notify("leave the current session before joining") return end
    if steamApiPresent() then
        UI.notify("cannot join: Steam API is enabled, run Install-KalanoroCoop.ps1")
        return
    end
    UI.notify("joining %s ...", address)
    lastJoinAddress = address
    leavingOnPurpose = false
    connected = false
    openLevel(address, "")
end

-- Client: load the host's level again (e.g. after switching to the host's save).
function Session.rejoin()
    if not lastJoinAddress then return end
    rejoinAt = os.clock()
    Net.toHost("REJOIN")
    openLevel(lastJoinAddress, "")
end

function Session.isRejoining()
    return rejoinAt ~= nil and os.clock() - rejoinAt < REJOIN_SECONDS
end

function Session.leave()
    local mode = U.netMode()
    leavingOnPurpose = true
    reconnect = nil
    if mode == "client" then
        openLevel(DEFAULT_MAP, "")
    elseif mode == "host" then
        Net.broadcast(nil, "BYE")
        local map = U.currentMap()
        if map then openLevel(map, "") end
    else
        UI.notify("not in a co-op session")
    end
end

function Session.status()
    local mode = U.netMode() or "loading"
    if mode == "host" then
        local names = {}
        for _, pc in ipairs(U.remotePCs()) do names[#names + 1] = U.playerName(pc) end
        UI.notify("hosting, %d client(s): %s", #names, table.concat(names, ", "))
    else
        UI.notify("mode: %s", mode)
    end
end

-- Level changes requested by game scripts. On the host they become a server travel so clients follow;
-- on clients they are cancelled locally and forwarded to the host.
local function onOpenLevel(_, ctx, levelName, _, options)
    if allowNextTravel then
        allowNextTravel = false
        return
    end
    local mode = U.cachedMode
    if mode ~= "host" and mode ~= "client" then return end
    local target = levelName:get():ToString()
    if MENU_MAPS[target] or target == "MainMenu" or target == "StartingScreenLevel" then
        return -- going back to the menus leaves the session
    end
    local opts = options:get():ToString()
    local url = target
    if opts ~= "" then url = target .. "?" .. opts:gsub("^%?", "") end
    ctx:set(nil) -- GetWorldFromContextObject(nullptr) makes OpenLevel return without travelling
    if mode == "host" then
        ExecuteInGameThread(function() serverTravel(url) end)
    elseif Config.ClientsCanChangeLevel then
        Net.toHost("TRAVEL", url)
    else
        UI.notify("the host leads level changes")
    end
end

-- OpenLevelBySoftObjectPtr carries its level as a soft reference, which cannot be read from a hook. Every
-- call site in the game passes a constant, so the destination is known from the calling Blueprint.
local BUS_MAP = "/Game/Levels/Templates/Test2DScroll1"
local TUTO_BUS_MAP = "/Game/Levels/Templates/Level_TutoBus_MilleClement"
-- Pause/inventory menus open either the bus or the main menu; their "bus" branch first looks up the checkpoint
-- save manager (GetActorOfClass), which marks the upcoming level change as a trip to the bus.
local MENU_WIDGETS = { WBP_Pause_C = true, UI_PauseScreen_C = true, UI_Inventory_C = true }
local busMarkedAt = -10

local function softTravelDestination(caller)
    local cls = caller:GetClass():GetFName():ToString()
    if cls == "BPA_ReturnToBus_C" or cls == "BPC_Kalakely_C" or cls == "BP_lemur_stats_C"
        or cls == "UI_YouDiedForReal_C" or cls == "HUD_DEBUG_C" then
        return BUS_MAP
    elseif cls == "BP_NPC_GrandSage_C" or cls == "BP_NPC_RandomTalk_MilleClement_C" then
        local ok, toBus = pcall(function() return caller.GoToBusAfterTalk end)
        return (ok and toBus) and BUS_MAP or TUTO_BUS_MAP
    elseif MENU_WIDGETS[cls] and os.clock() - busMarkedAt < 0.5 then
        busMarkedAt = -10
        return BUS_MAP
    end
    return nil -- main menu / title screen: leaving the session is what the player asked for
end

local function onOpenLevelSoft(_, ctx)
    if allowNextTravel then
        allowNextTravel = false
        return
    end
    local mode = U.cachedMode
    if mode ~= "host" and mode ~= "client" then return end
    local caller = ctx:get()
    if not U.valid(caller) then return end
    local dest = softTravelDestination(caller)
    if not dest then return end
    ctx:set(nil)
    if mode == "host" then
        ExecuteInGameThread(function() serverTravel(dest) end)
    elseif Config.ClientsCanChangeLevel then
        Net.toHost("TRAVEL", dest)
    else
        UI.notify("the host leads level changes")
    end
end

local function onGetActorOfClass(_, ctx, cls)
    local caller = ctx:get()
    if not U.valid(caller) or not MENU_WIDGETS[caller:GetClass():GetFName():ToString()] then return end
    local c = cls:get()
    if U.valid(c) and c:GetFName():ToString() == "BP_CheckpointSaveManager_C" then
        busMarkedAt = os.clock()
    end
end

local function onTravelRequest(fields, sender)
    if not U.isHost() then return end
    local url = fields[1]
    UI.notify("%s is changing level", U.playerName(sender))
    serverTravel(url)
end

local function tick()
    local mode = U.netMode()
    if mode == nil then return end -- between levels
    if mode ~= lastMode then
        if lastMode == "client" and mode == "standalone" then
            -- (a failed reconnection attempt also ends here: keep counting its tries)
            if leavingOnPurpose or not lastJoinAddress then
                UI.notify("left the session")
                reconnect = nil
            elseif not reconnect and not Session.isRejoining() then
                UI.notify("lost the connection to the host - reconnecting...")
                reconnect = { address = lastJoinAddress, tries = 0, nextAt = os.clock() + 3 }
            end
            connected = false
        elseif mode == "host" and lastMode ~= "host" then
            Session.announceAddress()
        end
        if mode ~= "host" then knownClients, greeted = {}, {} end
        lastMode = mode
    end
    if reconnect and mode == "standalone" and os.clock() >= reconnect.nextAt then
        reconnect.tries = reconnect.tries + 1
        if reconnect.tries > RECONNECT_TRIES then
            UI.notify("could not reconnect to %s", reconnect.address)
            reconnect = nil
        else
            reconnect.nextAt = os.clock() + RECONNECT_INTERVAL
            UI.notify("reconnecting to %s (%d/%d)", reconnect.address, reconnect.tries, RECONNECT_TRIES)
            openLevel(reconnect.address, "")
        end
    end
    if mode == "client" and U.localPawn() then
        local world = U.localPC():GetWorld():GetAddress()
        if world ~= helloWorld then
            helloWorld = world
            -- only now is the connection real: the net mode turns "client" while still connecting
            rejoinAt = nil
            if not connected then
                connected = true
                UI.notify(reconnect and "reconnected" or "connected to host")
                reconnect = nil
                if lastJoinAddress and lastJoinAddress ~= Config.JoinAddress then
                    pcall(Config.save, "JoinAddress", lastJoinAddress)
                end
            end
            Net.toHost("HELLO", Config.PlayerName)
        end
    end
    if mode == "host" then
        local seen = {}
        for _, pc in ipairs(U.remotePCs()) do
            local key = pc:GetAddress()
            seen[key] = true
            if not knownClients[key] then
                knownClients[key] = true
            end
        end
        for key in pairs(knownClients) do
            if not seen[key] then
                knownClients[key] = nil
                greeted[key] = nil
                if os.clock() > travelQuietUntil then UI.notify("a player left") end
            end
        end
    end
end

function Session.init()
    patchNetDriver()
    RegisterHook("/Script/Engine.GameplayStatics:OpenLevel", onOpenLevel)
    RegisterHook("/Script/Engine.GameplayStatics:OpenLevelBySoftObjectPtr", onOpenLevelSoft)
    RegisterHook("/Script/Engine.GameplayStatics:GetActorOfClass", onGetActorOfClass)
    Net.on("TRAVEL", onTravelRequest)
    Net.on("REJOIN", function()
        -- a client reloads the level: not worth a "left" / "joined" notice
        if U.isHost() then travelQuietUntil = math.max(travelQuietUntil, os.clock() + 30) end
    end)
    Net.on("BYE", function()
        leavingOnPurpose = true
        reconnect = nil
        UI.notify("the host ended the session")
    end)
    Net.on("HELLO", function(fields, sender)
        if not U.isHost() or not sender then return end
        local key = sender:GetAddress()
        if not greeted[key] then
            greeted[key] = true
            if os.clock() > travelQuietUntil then UI.notify("%s joined", fields[1] or U.playerName(sender)) end
        end
        for _, fn in ipairs(readyListeners) do
            local ok, err = pcall(fn, sender)
            if not ok then Log.error("client ready listener: %s", tostring(err)) end
        end
    end)
    LoopInGameThreadWithDelay(1000, function()
        local ok, err = pcall(tick)
        if not ok then Log.error("session tick: %s", tostring(err)) end
    end)
end

return Session
