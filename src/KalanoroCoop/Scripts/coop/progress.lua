-- Story progress follows the host: a client plays the session with the host's save (quests, story flags, unlocked
-- areas, village, inventory...) loaded in memory only. While it is in use the game's own save file is never
-- written, and the client's own progress comes back as soon as the session ends (leaving, lost connection or a
-- crash all leave the client's save untouched).
--
-- The game keeps its whole save as a dictionary in the GameInstance, reloaded from MAIN_KAL_DATA_SLOT_<n>.sav when
-- GI.loadedSlot is reset; level actors read their entries when a level starts. The host has the game write that
-- dictionary to KCOOP_EXPORT.sav and sends it; the client stores it as KCOOP_HOST.sav and points the game's reads
-- of its save slot at that file.
local U = require("coop.util")
local Log = require("coop.log")
local Net = require("coop.net")
local UI = require("coop.ui")
local Config = require("coop.config")
local Session = require("coop.session")

local Progress = {}

local SAVE_DIR = (os.getenv("LOCALAPPDATA") or "") .. "\\Kalanoro\\Saved\\SaveGames\\"
local HOST_SLOT = "KCOOP_HOST"
local EXPORT_SLOT = "KCOOP_EXPORT"
local MAIN_SLOT_PATTERN = "_KAL_DATA_SLOT_%d+$"
local FL_GENERAL = "/Game/FunctionLibraries/FL_General.Default__FL_General_C"
local RESET_UTILITY = "/Script/Kalanoro.Default__GameResetUtility"
local CHUNK = 1500

local following = false -- client: the host's save is in use instead of ours
local appliedHash = nil -- client: version of the host's save in use
local incoming = nil    -- client: { hash, total, count, parts } while the host's save arrives
local sentHash = {}     -- host: client controller address -> version sent
local exporting = false -- host: the game is writing its save for the clients (to EXPORT_SLOT, not its own file)

---------------------------------------------------------------- base64

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64 do B64_INDEX[B64:byte(i)] = i - 1 end

local function b64encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = (a << 16) | ((b or 0) << 8) | (c or 0)
        out[#out + 1] = B64:sub((n >> 18) + 1, (n >> 18) + 1) .. B64:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
            .. (b and B64:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or "=")
            .. (c and B64:sub((n & 63) + 1, (n & 63) + 1) or "=")
    end
    return table.concat(out)
end

local function b64decode(text)
    local out = {}
    for i = 1, #text, 4 do
        local c1, c2, c3, c4 = text:byte(i, i + 3)
        local n = (B64_INDEX[c1] << 18) | (B64_INDEX[c2] << 12) | ((B64_INDEX[c3] or 0) << 6) | (B64_INDEX[c4] or 0)
        out[#out + 1] = string.char(n >> 16)
        if c3 ~= 61 then out[#out + 1] = string.char((n >> 8) & 255) end
        if c4 ~= 61 then out[#out + 1] = string.char(n & 255) end
    end
    return table.concat(out)
end

-- Adler-32 plus length: identifies a version of the save.
local function checksum(data)
    local a, b = 1, 0
    for i = 1, #data do
        a = (a + data:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return string.format("%d-%08x", #data, (b << 16) | a)
end

---------------------------------------------------------------- files

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("a")
    f:close()
    return data
end

local function writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function gameInstance()
    local gi = FindFirstOf("GI_Default_C")
    return U.valid(gi) and gi or nil
end

---------------------------------------------------------------- host

-- The host's current progress, as the game would save it; written to a separate file (the host's own save file is
-- only ever written by the game itself).
local function hostSave()
    local pc = U.localPC()
    if not pc then return nil end
    exporting = true
    local ok, err = pcall(function() StaticFindObject(FL_GENERAL):SaveFullSave(pc) end)
    exporting = false
    if not ok then Log.error("export the host save: %s", tostring(err)) end
    local path = SAVE_DIR .. EXPORT_SLOT .. ".sav"
    local data = readFile(path)
    os.remove(path)
    return data
end

-- Host: runs each time a client has loaded a level; sends the save when it changed since that client last got it.
function Progress.sendTo(pc)
    local data = hostSave()
    if not data or #data == 0 then return end
    local hash = checksum(data)
    local key = pc:GetAddress()
    if sentHash[key] == hash then return end
    sentHash[key] = hash
    local text = b64encode(data)
    local total = math.ceil(#text / CHUNK)
    for i = 1, total do
        Net.toClient(pc, "SAVE", hash, i, total, text:sub((i - 1) * CHUNK + 1, i * CHUNK))
    end
    Log.info("sent the host save (%d bytes) to %s", #data, U.playerName(pc))
end

---------------------------------------------------------------- client

-- Reload the save dictionary from the save slot (redirected to the host's save while following).
local function reloadSaveDictionary(gi, pc)
    gi.loadedSlot = -1
    local fl = StaticFindObject(FL_GENERAL)
    fl["DoesSaveGameExist Multiplatform"](fl, "questsave", pc)
end

local function apply(hash, data)
    local gi, pc = gameInstance(), U.localPC()
    if not gi or not pc then return end
    if not writeFile(SAVE_DIR .. HOST_SLOT .. ".sav", data) then
        Log.error("cannot write %s", SAVE_DIR .. HOST_SLOT .. ".sav")
        return
    end
    local first = not following
    following, appliedHash = true, hash
    if first then
        -- what the main menu does before starting a game from a save...
        local slotIndex = gi.saveSlotIndex
        StaticFindObject(RESET_UTILITY):ResetGameInstanceVariables(gi)
        gi:LoadSettings()
        gi.saveSlotIndex = slotIndex
    end
    reloadSaveDictionary(gi, pc)
    if first then
        gi:InitLoad()
        UI.notify("playing with the host's story progress - your own save is kept for later")
        -- ...then load the level again with it
        Session.rejoin()
    end
end

local function onSave(fields)
    if not U.isClient() or not Config.FollowHostProgress then return end
    local hash, i, total, part = fields[1], tonumber(fields[2]), tonumber(fields[3]), fields[4]
    if not i or not total or hash == appliedHash then return end
    if not incoming or incoming.hash ~= hash then incoming = { hash = hash, total = total, count = 0, parts = {} } end
    if not incoming.parts[i] then
        incoming.parts[i] = part
        incoming.count = incoming.count + 1
    end
    if incoming.count < incoming.total then return end
    local data = b64decode(table.concat(incoming.parts))
    incoming = nil
    if checksum(data) ~= hash then
        Log.error("the host save arrived damaged")
        return
    end
    apply(hash, data)
end

-- The session is over for this client: its own save is what the game loads from now on.
local function restore()
    following, appliedHash, incoming = false, nil, nil
    local gi = gameInstance()
    if gi then gi.loadedSlot = -1 end
    os.remove(SAVE_DIR .. HOST_SLOT .. ".sav")
    UI.notify("your own progress is back")
end

---------------------------------------------------------------- hooks

local function isMainSlot(slot)
    return slot:get():ToString():find(MAIN_SLOT_PATTERN) ~= nil
end

local function onSaveGameToSlot(_, saveObject, slot)
    if not isMainSlot(slot) then return end
    if exporting then
        slot:set(EXPORT_SLOT)
    elseif following then
        Log.debug("kept the game from saving over %s", slot:get():ToString())
        saveObject:set(nil)
    end
end

local function onReadSlot(_, slot)
    if following and isMainSlot(slot) then
        Log.debug("reading the host save instead of %s", slot:get():ToString())
        slot:set(HOST_SLOT)
    end
end

function Progress.onMapChanged()
    sentHash = {} -- clients get new controllers on every level
end

function Progress.init()
    -- left over if the game closed during a session
    os.remove(SAVE_DIR .. HOST_SLOT .. ".sav")
    os.remove(SAVE_DIR .. EXPORT_SLOT .. ".sav")
    RegisterHook("/Script/Engine.GameplayStatics:SaveGameToSlot", onSaveGameToSlot)
    RegisterHook("/Script/Engine.GameplayStatics:LoadGameFromSlot", onReadSlot)
    RegisterHook("/Script/Engine.GameplayStatics:DoesSaveGameExist", onReadSlot)
    Net.on("SAVE", function(fields)
        local ok, err = pcall(onSave, fields)
        if not ok then Log.error("host save: %s", tostring(err)) end
    end)
    LoopInGameThreadWithDelay(1000, function()
        local mode = U.cachedMode
        if following and mode ~= nil and mode ~= "client" and not Session.isRejoining() then
            local ok, err = pcall(restore)
            if not ok then Log.error("restore own save: %s", tostring(err)) end
        end
    end)
end

return Progress
