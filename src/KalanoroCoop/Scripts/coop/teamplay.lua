-- The co-op layer on top of the synced world:
--   * downed & revive: reaching 0 HP while a teammate is standing puts you down instead of the death screen;
--     a teammate standing next to you for a few seconds brings you back. Bleeding out, or nobody left standing,
--     hands over to the game's own death screen.
--   * shared loot: gems placed in the level reward every player, not just the one who grabbed them.
--   * name tags in each player's colour with health (and distance when far) above teammates, and a key to
--     teleport to your partner.
--   * no pausing the shared world, and "Restart level" from the death screen restarts for the whole group.
local U = require("coop.util")
local Log = require("coop.log")
local Net = require("coop.net")
local UI = require("coop.ui")
local State = require("coop.state")
local Session = require("coop.session")
local Config = require("coop.config")

local Teamplay = {}

local FL_GENERAL = "/Game/FunctionLibraries/FL_General.Default__FL_General_C"
local DEATH_UI = "/Game/UI/CommonUIData/Widgets/UI_YouDiedKindOf.UI_YouDiedKindOf_C"
local HIT_MONTAGE = "/Game/Kalakely/3DAssets/V4/KALAKELY_Hit_Montage.KALAKELY_Hit_Montage"
local HP_FIELD = "HPCurrent_10_F6DDA7314095D7E4A9BBB8ACDD51A9D6"
local HP_MAX_FIELD = "HPMaxCurrent_11_F225A185485D6518F01299B182945861"

local REVIVE_RANGE = 260      -- cm
local REVIVE_SECONDS = 2.5
local BLEED_OUT_SECONDS = 60
local REVIVE_HP_FRACTION = 0.5
local TAG_SIZE = 24            -- name tag text height (cm) at your own distance from the camera
local TAG_SHADOW_OFFSET = 0.1  -- drop shadow offset, as a fraction of the text height
local TAG_HEIGHT = 75          -- name tag anchor above the character's centre (cm)
local TAG_MAX_SCALE = 10
local TAG_DISTANCE_FROM = 2500 -- teammates at least this far get their distance on the tag

local downedAt = nil          -- os.clock() when the local player went down
local deathScreenAllowed = false -- set while the game's own death screen is legitimately shown (player is out)
local lastHp = nil
local reviveProgress = {}     -- downed player id -> seconds the local player has spent reviving them
local teamHp = {}             -- player id -> "hp/max"
local styledTags = {}         -- text render address -> true
local lastHpSent = -10
local names = {}              -- player id -> display name
local applyingLoot = false
local freshLevel = false

local function fl() return StaticFindObject(FL_GENERAL) end

local function localHp()
    local gi = FindFirstOf("GI_Default_C")
    if not U.valid(gi) then return nil end
    local ok, hp, max = pcall(function()
        local s = gi.PlayerHealthStats
        return s[HP_FIELD], s[HP_MAX_FIELD]
    end)
    if ok then return hp, max end
    return nil
end

local function teammates()
    local out = {}
    local me = U.localPawn()
    for _, c in ipairs(FindAllOf("BPC_Kalakely_C") or {}) do
        if c:IsValid() and U.valid(c.PlayerState) and (not me or c:GetAddress() ~= me:GetAddress()) then
            out[#out + 1] = c
        end
    end
    return out
end

local function nameOf(id)
    return names[id] or ("Player " .. tostring(id))
end
Teamplay.nameOf = nameOf


---------------------------------------------------------------- downed / revive

local function closeDeathScreen()
    for _, w in ipairs(FindAllOf("UI_YouDiedKindOf_C") or {}) do
        if w:IsValid() then pcall(function() w:DeactivateWidget() end) end
    end
    local pc = U.localPC()
    if pc then
        pc.bShowMouseCursor = false
        pcall(function()
            StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameOnly(pc, true)
        end)
    end
end

local function closeDeathScreenIfShown()
    for _, w in ipairs(FindAllOf("UI_YouDiedKindOf_C") or {}) do
        if w:IsValid() and w:IsActivated() then
            closeDeathScreen()
            return
        end
    end
end

-- While down or out, the player must not take hits: in co-op the world keeps running (no pause), and every hit
-- at 0 HP makes the game push its death screen again. GodMod also sends "unavoidable" hits through the
-- bCanBeDamaged check in BPC_Kalakely's damage handler.
local savedGodMod = nil
local function setInvulnerable(on)
    local pawn = U.localPawn()
    local gi = FindFirstOf("GI_Default_C")
    if pawn then pawn.bCanBeDamaged = not on end
    if not U.valid(gi) then return end
    if on then
        if savedGodMod == nil then savedGodMod = gi.GodMod end
        gi.GodMod = true
    elseif savedGodMod ~= nil then
        gi.GodMod = savedGodMod
        savedGodMod = nil
    end
end

local function setControls(enabled)
    local pc, pawn = U.localPC(), U.localPawn()
    if not pc or not pawn then return end
    if enabled then
        pawn:EnableInput(pc)
        pc:ResetIgnoreMoveInput()
    else
        pawn:DisableInput(pc)
        pc:SetIgnoreMoveInput(true)
    end
end

local function playDownedPose(pawn, down)
    local anim = U.valid(pawn) and pawn.SkeletalMesh:GetAnimInstance()
    if not U.valid(anim) then return end
    local montage = StaticFindObject(HIT_MONTAGE)
    if not U.valid(montage) then montage = LoadAsset(HIT_MONTAGE) end
    if not U.valid(montage) then return end
    if down then
        local len = anim:Montage_Play(montage, 1.0, 0, 0.0, true)
        if len and len > 0 then anim:Montage_SetPosition(montage, len * 0.8) end
        anim:Montage_Pause(montage)
    else
        anim:Montage_Stop(0.25, montage)
    end
end

-- The game's death stops the character's movement, and its checkpoint respawn is what restarts it: a player who
-- goes down or gets revived instead needs it back, or hangs in the air where they were hit.
local function restoreMovement(pawn)
    if not U.valid(pawn) then return end
    pcall(function()
        pawn.CharacterMovement:SetMovementMode(3, 0) -- falling: drops to the ground and walks from there
        pawn.canDash = true
        pawn.JumpIndex = 0
    end)
end

local function otherIds()
    local ids = {}
    for _, c in ipairs(teammates()) do ids[#ids + 1] = c.PlayerState.PlayerId end
    return ids
end

local function goDown()
    local pawn = U.localPawn()
    downedAt = os.clock()
    closeDeathScreen()
    setInvulnerable(true)
    setControls(false)
    playDownedPose(pawn, true)
    -- (after the game's own death handling of this frame)
    ExecuteInGameThreadWithDelay(300, function()
        if downedAt then restoreMovement(U.localPawn()) end
    end)
    local id = U.pawnId(pawn)
    State.set(id, "down")
    Net.toOthers("DOWN", id)
    UI.notify("you are down - a teammate can revive you")
end

local function getUp(reviverName)
    local pawn = U.localPawn()
    downedAt = nil
    local _, max = localHp()
    local restore = math.max(1, math.floor((max or 12) * REVIVE_HP_FRACTION))
    pcall(function() fl():UpdatePlayerCurrentHealth(restore, pawn) end)
    setInvulnerable(false)
    setControls(true)
    playDownedPose(pawn, false)
    restoreMovement(pawn)
    local id = U.pawnId(pawn)
    State.set(id, nil)
    Net.toOthers("UP", id)
    UI.notify(reviverName and ("revived by " .. reviverName) or "back on your feet")
end

-- Out of the fight (bled out, or nobody left standing to revive you): the game's own death screen takes over
-- (respawn at the checkpoint, or "Restart level" for the whole group).
local function goOut(reason)
    local pawn = U.localPawn()
    local wasDown = downedAt ~= nil
    downedAt = nil
    deathScreenAllowed = true
    setInvulnerable(true)
    setControls(true)
    playDownedPose(pawn, false)
    local id = U.pawnId(pawn)
    State.set(id, "out")
    Net.toOthers("OUT", id)
    if reason then UI.notify(reason) end
    if wasDown then
        local pc = U.localPC()
        local cls = StaticFindObject(DEATH_UI)
        if pc and U.valid(cls) then pcall(function() pc:PushUi(cls) end) end
    end
end

local function checkLocalHealth()
    local hp, max = localHp()
    if hp == nil or not U.localPawn() then return end
    local id = U.pawnId(U.localPawn())
    if freshLevel then
        -- a new level (e.g. the group restarted after everyone went down) starts everyone on their feet
        freshLevel = false
        if hp <= 0 then
            pcall(function() fl():UpdatePlayerCurrentHealth(max or 12, U.localPawn()) end)
            return
        end
    end
    if hp ~= lastHp or os.clock() - lastHpSent > 5 then
        lastHp = hp
        lastHpSent = os.clock()
        if id then Net.toOthers("HP", id, hp, max or 0, Config.PlayerName) end
    end
    if hp > 0 then
        -- alive: back from the death screen (checkpoint respawn / restart), or never went down
        deathScreenAllowed = false
        if id and not downedAt and not State.isStanding(id) then
            State.set(id, nil)
            setInvulnerable(false)
            Net.toOthers("UP", id)
        end
        closeDeathScreenIfShown()
        return
    end
    if downedAt then
        closeDeathScreenIfShown()
        if not State.anyStanding(otherIds()) then
            goOut("nobody left standing")
        elseif os.clock() - downedAt > BLEED_OUT_SECONDS then
            goOut("bled out")
        end
    elseif not deathScreenAllowed then
        if State.anyStanding(otherIds()) then goDown() else goOut(nil) end
    end
end

local function reviveTick(dt)
    local me = U.localPawn()
    if not me or downedAt or not State.isStanding(U.pawnId(me)) then return end
    local myLoc = me:K2_GetActorLocation()
    for _, c in ipairs(teammates()) do
        local id = c.PlayerState.PlayerId
        if State.isDowned(id) then
            local l = c:K2_GetActorLocation()
            local d = math.sqrt((l.X - myLoc.X) ^ 2 + (l.Y - myLoc.Y) ^ 2 + (l.Z - myLoc.Z) ^ 2)
            if d <= REVIVE_RANGE then
                local before = reviveProgress[id] or 0
                local now = before + dt
                reviveProgress[id] = now
                if before == 0 then UI.notify("reviving %s...", nameOf(id)) end
                if now >= REVIVE_SECONDS then
                    reviveProgress[id] = 0
                    Net.toOthers("REVIVE", id, Config.PlayerName)
                end
            else
                reviveProgress[id] = 0
            end
        end
    end
end

-- DOWN / OUT / UP from another player.
local function onStatus(value)
    return function(fields, sender)
        local id = tonumber(fields[1])
        State.set(id, value)
        playDownedPose(U.findPawnById(id), value == "down")
        if value == "down" then
            UI.notify("%s is down! Stand next to them to revive", nameOf(id))
        elseif value == "out" then
            UI.notify("%s is out", nameOf(id))
        end
        Net.forward(sender, value and value:upper() or "UP", fields[1])
    end
end

local function onRevive(fields, sender)
    local id = tonumber(fields[1])
    if U.pawnId(U.localPawn()) == id and downedAt then
        getUp(fields[2])
    end
    Net.forward(sender, "REVIVE", fields[1], fields[2])
end

---------------------------------------------------------------- health / names of teammates

local function onHp(fields, sender)
    local id = tonumber(fields[1])
    teamHp[id] = fields[2] .. "/" .. fields[3]
    names[id] = fields[4]
    Net.forward(sender, "HP", fields[1], fields[2], fields[3], fields[4])
end

local function addTagShadow(character)
    local ok, shadow = pcall(function()
        return character:AddComponentByClass(StaticFindObject("/Script/Engine.TextRenderComponent"), false,
            { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 },
              Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    end)
    if not ok or not U.valid(shadow) then return false end
    shadow:SetHorizontalAlignment(1)
    shadow:SetVerticalAlignment(2)
    shadow:SetTextRenderColor({ R = 15, G = 12, B = 25, A = 255 })
    return shadow
end

local function updateNameTags()
    local pc = U.localPC()
    local pcm = pc and pc.PlayerCameraManager
    if not U.valid(pcm) then return end
    local cam = pcm:GetCameraLocation()
    local me = U.localPawn()
    local myLoc = me and me:K2_GetActorLocation()
    for _, c in ipairs(teammates()) do
        local tag = c.TextRender
        if U.valid(tag) then
            local id = c.PlayerState.PlayerId
            -- name, then health / status (and distance when far) on a second line
            local detail = teamHp[id] or ""
            local status = State.get(id)
            if status == "down" then
                detail = "- DOWN -"
            elseif status == "out" then
                detail = "- OUT -"
            end
            local far = myLoc and U.distance(myLoc, c:K2_GetActorLocation()) or 0
            if far >= TAG_DISTANCE_FROM then
                detail = detail .. string.format("   %d m", math.floor(far / 100))
            end
            local label = FText(nameOf(id) .. "<br>" .. detail)
            tag:K2_SetText(label)
            local key = tag:GetAddress()
            local shadow = styledTags[key]
            if shadow == nil then
                shadow = addTagShadow(c)
                styledTags[key] = shadow
                tag:SetHiddenInGame(false, false)
                tag:SetVisibility(true, false)
                tag:SetHorizontalAlignment(1)
                tag:SetVerticalAlignment(2) -- bottom of the text on the anchor: it stacks upward, above the head
                tag:SetTextRenderColor(U.playerColor(id))
                tag:K2_SetRelativeLocation({ X = 0, Y = 0, Z = TAG_HEIGHT }, false, {}, true)
            end
            local l = tag:K2_GetComponentLocation()
            -- a teammate further from the camera than you gets a bigger tag, so it stays readable (and shows
            -- where they are)
            local scale = myLoc and U.distance(cam, l) / math.max(1, U.distance(cam, myLoc)) or 1
            local size = TAG_SIZE * math.min(TAG_MAX_SCALE, math.max(1, scale))
            local rot = U.facing(l, cam)
            tag:SetWorldSize(size)
            tag:K2_SetWorldRotation(rot, false, {}, true)
            if shadow and U.valid(shadow) then
                -- a dark copy just behind and below the text keeps it readable on bright ground
                local mathLib = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
                local f, r, u = mathLib:GetForwardVector(rot), mathLib:GetRightVector(rot), mathLib:GetUpVector(rot)
                local o = size * TAG_SHADOW_OFFSET
                local function at(axis) return l[axis] - f[axis] * 2 - u[axis] * o - r[axis] * o * 0.6 end
                shadow:SetWorldSize(size)
                shadow:K2_SetText(label)
                shadow:K2_SetWorldLocationAndRotation({ X = at("X"), Y = at("Y"), Z = at("Z") }, rot, false, {}, true)
            end
        end
    end
end

---------------------------------------------------------------- shared loot

-- FL_General.UpdateBlueGem(Operation, Amount, WorldContext) is how gems are granted; share gems picked up from
-- the level (drops from crates/enemies already exist separately for each player).
local function onGemGranted(_, op, amount, ctx)
    if applyingLoot or not U.isOnline() or op:get() ~= 0 then return end
    local source = ctx:get()
    if not U.valid(source) then return end
    local cls = source:GetClass():GetFName():ToString()
    if cls ~= "BPA_Gem_C" and cls ~= "BPA_SplineGem_C" then return end
    Net.toOthers("LOOT", amount:get())
end

local function onLoot(fields, sender)
    local pawn = U.localPawn()
    if pawn then
        applyingLoot = true
        pcall(function() fl():UpdateBlueGem(0, tonumber(fields[1]) or 1, pawn) end)
        applyingLoot = false
    end
    Net.forward(sender, "LOOT", fields[1])
end

---------------------------------------------------------------- pause / restart / teleport

-- The shared world never pauses, except when nobody is left standing: then the death screen may pause it, as in
-- single player (otherwise enemies keep hitting the fallen players).
local function onSetPaused(_, _, paused)
    if not U.isOnline() or not paused:get() then return end
    local ids = otherIds()
    ids[#ids + 1] = U.pawnId(U.localPawn())
    if State.anyStanding(ids) then paused:set(false) end
end

local function onConsoleCommand(_, ctx, cmd, player)
    if not U.isOnline() then return end
    if cmd:get():ToString():lower() ~= "restartlevel" then return end
    ctx:set(nil)
    player:set(nil)
    ExecuteInGameThread(function()
        if U.isHost() then
            Session.restartLevel()
        elseif not State.anyStanding(otherIds()) then
            Net.toHost("RESTART")
        else
            Teamplay.teleportToPartner()
            local _, max = localHp()
            pcall(function() fl():UpdatePlayerCurrentHealth(max or 12, U.localPawn()) end)
            closeDeathScreen()
        end
    end)
end

function Teamplay.teleportToPartner()
    local me = U.localPawn()
    if not me or not U.isOnline() then return end
    local myLoc = me:K2_GetActorLocation()
    local best, bestD
    for _, c in ipairs(teammates()) do
        local l = c:K2_GetActorLocation()
        local d = (l.X - myLoc.X) ^ 2 + (l.Y - myLoc.Y) ^ 2
        if not bestD or d < bestD then best, bestD = c, d end
    end
    if not best then UI.notify("no teammate to teleport to") return end
    local l = best:K2_GetActorLocation()
    local back = best:GetActorForwardVector()
    me:K2_SetActorLocation({ X = l.X - back.X * 150, Y = l.Y - back.Y * 150, Z = l.Z + 30 }, false, {}, true)
    UI.notify("teleported to %s", nameOf(best.PlayerState.PlayerId))
end

---------------------------------------------------------------- setup

-- Hits taken at 0 HP make the game push its death screen again; while down (or while a teammate can still
-- revive you) close it in the same frame it opens instead of letting it flash.
local function onPushUi(_, widgetClass)
    if not U.isOnline() or deathScreenAllowed then return end
    local cls = widgetClass:get()
    if not U.valid(cls) or cls:GetFName():ToString() ~= "UI_YouDiedKindOf_C" then return end
    if downedAt then
        closeDeathScreen()
    elseif State.anyStanding(otherIds()) then
        goDown()
    end
end

local LATE_HOOKS = {
    ["/Game/FunctionLibraries/FL_General.FL_General_C:UpdateBlueGem"] = onGemGranted,
    ["/Game/System/PC_Default.PC_Default_C:PushUi"] = onPushUi,
}
local lateHooked = {}
local function lateHooks()
    for path, fn in pairs(LATE_HOOKS) do
        if not lateHooked[path] and U.valid(StaticFindObject(path)) then
            RegisterHook(path, fn)
            lateHooked[path] = true
        end
    end
end

function Teamplay.onMapChanged()
    State.reset()
    reviveProgress, downedAt, lastHp, styledTags, deathScreenAllowed = {}, nil, nil, {}, false
    freshLevel = true
    setInvulnerable(false) -- the GameInstance (GodMod) outlives the level
end

function Teamplay.init()
    Net.on("DOWN", onStatus("down"))
    Net.on("OUT", onStatus("out"))
    Net.on("UP", onStatus(nil))
    Net.on("REVIVE", onRevive)
    Net.on("RESTART", function() if U.isHost() then Session.restartLevel() end end)
    Net.on("HP", onHp)
    Net.on("LOOT", onLoot)
    RegisterHook("/Script/Engine.GameplayStatics:SetGamePaused", onSetPaused)
    RegisterHook("/Script/Engine.KismetSystemLibrary:ExecuteConsoleCommand", onConsoleCommand)
    LoopInGameThreadWithDelay(100, function()
        if not U.isOnline() then return end
        local ok, err = pcall(function()
            lateHooks()
            checkLocalHealth()
            reviveTick(0.1)
        end)
        if not ok then Log.error("teamplay tick: %s", tostring(err)) end
    end)
    LoopInGameThreadWithDelay(50, function()
        if U.isOnline() then pcall(updateNameTags) end
    end)
end

return Teamplay
