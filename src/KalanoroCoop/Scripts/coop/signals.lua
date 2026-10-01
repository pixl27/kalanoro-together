-- Ways to coordinate without voice chat:
--   * ping: the ping key marks the enemy in front of the player (or the player's spot) for everyone, with the
--     pinger's colour, name and the distance to it;
--   * far teammate: a reminder, with the teleport key, when a teammate has been far away for a while;
--   * dialogue: when a teammate talks to an NPC the others are told (conversations follow each player's save).
local U = require("coop.util")
local Log = require("coop.log")
local Net = require("coop.net")
local UI = require("coop.ui")
local Config = require("coop.config")
local Hooks = require("coop.hooks")
local Enemies = require("coop.enemies")
local Combat = require("coop.combat")
local State = require("coop.state")
local Teamplay = require("coop.teamplay")

local Signals = {}

local PING_SECONDS = 10
local PING_ENEMY_RANGE = 2500 -- cm
local PING_ENEMY_CONE = 0.6   -- cosine of the half-angle in front of the character
local MARKER_ABOVE_PLAYER = 160 -- above the name tag (the character location is the middle of its capsule)
local MARKER_ABOVE_ENEMY = 170
local MARKER_SIZE = 30        -- text height (cm) at the distance of the local player from the camera
local FAR_DISTANCE = 8000     -- cm
local FAR_SECONDS = 20        -- far this long before the reminder
local FAR_REPEAT = 180        -- seconds between reminders about the same teammate
local TALK_REPEAT = 30        -- seconds between notices about the same NPC
local NPC_CLASS = "BP_NPC_C"

local markers = {}            -- player id -> { actor, loc, enemy, expires, name }
local farSince, farNotified = {}, {}
local talkNotified = {}       -- npc path -> os.clock()

local function mathLib() return StaticFindObject("/Script/Engine.Default__KismetMathLibrary") end

local function fmtLoc(l) return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end

local function parseLoc(s)
    local x, y, z = (s or ""):match("^(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+)$")
    if not x then return nil end
    return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
end

---------------------------------------------------------------- ping

local function destroyMarker(id)
    local m = markers[id]
    markers[id] = nil
    if m and U.valid(m.actor) and not m.actor.bActorIsBeingDestroyed then m.actor:K2_DestroyActor() end
end

local function spawnMarker(id, name, loc, enemy)
    destroyMarker(id)
    local pc = U.localPC()
    local cls = StaticFindObject("/Script/Engine.TextRenderActor")
    if not pc or not U.valid(cls) then return end
    local transform = mathLib():MakeTransform(loc, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 })
    local statics = U.statics()
    local actor = statics:BeginDeferredActorSpawnFromClass(pc, cls, transform, 1, nil, 0)
    if not U.valid(actor) then return end
    statics:FinishSpawningActor(actor, transform, 0)
    actor:SetActorEnableCollision(false)
    local text = actor.TextRender
    text:SetHorizontalAlignment(1)
    text:SetVerticalAlignment(2)
    text:SetTextRenderColor(U.playerColor(id))
    markers[id] = { actor = actor, loc = loc, enemy = enemy, expires = os.clock() + PING_SECONDS, name = name }
end

-- Keep markers facing the camera, readable at any distance, on their enemy, and gone after a while.
local function updateMarkers()
    local pc = U.localPC()
    local pcm = pc and pc.PlayerCameraManager
    local me = U.localPawn()
    if not U.valid(pcm) or not me then return end
    local cam = pcm:GetCameraLocation()
    local myLoc = me:K2_GetActorLocation()
    local now = os.clock()
    for id, m in pairs(markers) do
        if now > m.expires or not U.valid(m.actor) or (m.enemy and not U.valid(m.enemy)) then
            destroyMarker(id)
        else
            local loc = m.loc
            if m.enemy then
                local l = m.enemy:K2_GetActorLocation()
                loc = { X = l.X, Y = l.Y, Z = l.Z + MARKER_ABOVE_ENEMY }
            end
            m.actor:K2_SetActorLocationAndRotation(loc, U.facing(loc, cam), false, {}, true)
            local text = m.actor.TextRender
            text:SetWorldSize(MARKER_SIZE * math.max(1, U.distance(cam, loc) / math.max(1, U.distance(cam, myLoc))))
            text:K2_SetText(FText(string.format("%s<br>%d m<br>V", m.name, math.floor(U.distance(myLoc, loc) / 100))))
        end
    end
end

local function announcePing(name, loc, enemy)
    local me = U.localPawn()
    local dist = me and math.floor(U.distance(me:K2_GetActorLocation(), loc) / 100) or 0
    UI.notify("%s: %s (%d m)", name, enemy and "enemy!" or "over here", dist)
end

-- The camera looks down at the player, so a ping marks the closest enemy the character is facing, or else the
-- character's own spot ("over here").
local function pingTarget(me)
    local loc = me:K2_GetActorLocation()
    local fwd = me:GetActorForwardVector()
    local best, bestD = nil, PING_ENEMY_RANGE
    for _, c in ipairs(FindAllOf("Character") or {}) do
        if c:IsValid() and not c.bActorIsBeingDestroyed and Combat.isHostile(c) then
            local l = c:K2_GetActorLocation()
            local d = U.distance(l, loc)
            local facing = d < 1 or ((l.X - loc.X) * fwd.X + (l.Y - loc.Y) * fwd.Y) / d >= PING_ENEMY_CONE
            if d < bestD and facing then best, bestD = c, d end
        end
    end
    return best, { X = loc.X, Y = loc.Y, Z = loc.Z + MARKER_ABOVE_PLAYER }
end

function Signals.ping()
    local me = U.localPawn()
    local id = U.pawnId(me)
    if not U.isOnline() or not id then return end
    local enemy, loc = pingTarget(me)
    spawnMarker(id, Config.PlayerName, loc, enemy)
    UI.notify(enemy and "ping: enemy marked" or "ping: your position marked")
    Net.toOthers("PING", id, Config.PlayerName, fmtLoc(loc), enemy and Enemies.ref(enemy) or "")
end

local function onPing(fields, sender)
    Net.forward(sender, "PING", fields[1], fields[2], fields[3], fields[4])
    local id, name, loc = tonumber(fields[1]), fields[2], parseLoc(fields[3])
    if not id or not loc then return end
    local enemy = fields[4] ~= "" and Enemies.resolve(fields[4]) or nil
    spawnMarker(id, name, loc, enemy)
    announcePing(name, enemy and enemy:K2_GetActorLocation() or loc, enemy)
end

---------------------------------------------------------------- far teammate

local function farTick()
    local me = U.localPawn()
    if not me or not State.isStanding(U.pawnId(me)) then return end
    local myLoc = me:K2_GetActorLocation()
    local now = os.clock()
    for _, c in ipairs(FindAllOf("BPC_Kalakely_C") or {}) do
        local id = c:IsValid() and not c:IsLocallyControlled() and U.pawnId(c)
        if id then
            local d = U.distance(c:K2_GetActorLocation(), myLoc)
            if d < FAR_DISTANCE then
                farSince[id] = nil
            else
                farSince[id] = farSince[id] or now
                if now - farSince[id] >= FAR_SECONDS and now - (farNotified[id] or -FAR_REPEAT) >= FAR_REPEAT then
                    farNotified[id] = now
                    UI.notify("%s is %d m away - press %s to join them", Teamplay.nameOf(id), math.floor(d / 100),
                        Config.TeleportKey)
                end
            end
        end
    end
end

---------------------------------------------------------------- dialogue

local function isNpc(actor)
    local cls = actor:GetClass()
    while U.valid(cls) do
        if cls:GetFName():ToString() == NPC_CLASS then return true end
        cls = cls:GetSuperStruct()
    end
    return false
end

local function npcName(npc)
    local ok, name = pcall(function() return npc.NPCName:ToString() end)
    if ok and name and name ~= "" then return name end
    return (npc:GetClass():GetFName():ToString():gsub("^BP_NPC_", ""):gsub("_C$", ""):gsub("_", " "))
end

-- Interact() on an NPC is the local player talking to it (NPCs are not in the replayed interactions).
local function onInteract(self)
    if not U.isOnline() then return end
    local npc = self:get()
    local me = U.localPawn()
    if not U.valid(npc) or not me or not isNpc(npc) then return end
    local path = U.path(npc)
    local now = os.clock()
    if now - (talkNotified[path] or -TALK_REPEAT) < TALK_REPEAT then return end
    talkNotified[path] = now
    Net.toOthers("TALK", Config.PlayerName, npcName(npc))
end

local function onTalk(fields, sender)
    Net.forward(sender, "TALK", fields[1], fields[2])
    UI.notify("%s is talking to %s", fields[1], fields[2])
end

-- NPCs can arrive with streamed sub-levels; Hooks.watch only hooks each class once.
local function watchNpcs()
    for _, a in ipairs(FindAllOf(NPC_CLASS) or {}) do
        if a:IsValid() then Hooks.watch(a, "Interact") end
    end
end

---------------------------------------------------------------- setup

function Signals.onMapChanged()
    for id in pairs(markers) do markers[id] = nil end
    farSince, farNotified, talkNotified = {}, {}, {}
end

function Signals.init()
    Hooks.on("Interact", onInteract)
    Net.on("PING", onPing)
    Net.on("TALK", onTalk)
    LoopInGameThreadWithDelay(50, function()
        if not U.isOnline() or next(markers) == nil then return end
        local ok, err = pcall(updateMarkers)
        if not ok then Log.error("ping markers: %s", tostring(err)) end
    end)
    LoopInGameThreadWithDelay(1000, function()
        if not U.isOnline() then return end
        local ok, err = pcall(function()
            watchNpcs()
            farTick()
        end)
        if not ok then Log.error("signals tick: %s", tostring(err)) end
    end)
end

return Signals
