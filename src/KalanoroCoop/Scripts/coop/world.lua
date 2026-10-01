-- Shared world state for level-placed actors that the game does not replicate (gems, crates, levers, doors,
-- bridges, platforms, chests...). Each machine runs its own copy of the level; what a player does to one of
-- these actors is replayed on everyone else's copy:
--   * destruction (collected gems, broken crates) is mirrored,
--   * hits (levers, breakable walls, crates, generators) are replayed, so mechanisms move for everyone and
--     breakables drop their loot for every player,
--   * "Interact" on world mechanisms (doors, bridges, platforms, chests, lockers) is replayed,
--   * objects a player moves around (push/pull blocks, pull platforms, weapons lying in the level) follow the
--     machine of the player moving them.
local U = require("coop.util")
local Log = require("coop.log")
local Net = require("coop.net")
local Hooks = require("coop.hooks")

local World = {}

-- Classes whose Interact() only drives the mechanism itself (no dialogue, menus, cutscenes or per-player save).
local SHARED_INTERACT = {
    BPA_AreaBlocker_Child_TIE_C = true, BPA_AutoClosing_DoorPowered_C = true, BPA_Bridge_Child_TIE_C = true,
    BPA_ClusterCase_C = true, BPA_FlyingContainer_C = true, BPA_FlyingContainer_Persistent_C = true,
    BPA_FlyingWeightPlatform_C = true, BPA_ImpactMoving_Platform_C = true, BPA_Impact_TriggerInteractEvent_C = true,
    BPA_InteractDoorDouble_C = true, BPA_InteractGemSpawner_C = true, BPA_Interact_DoorPowered_C = true,
    BPA_Locking_Generator_C = true, BPA_Locking_Generator_Child_TIE_C = true, BPA_OneTimeMovingPlatform_C = true,
    BPA_Retriggerable_Many_InteractEvent_C = true, BPA_SplineMovingPlatform_C = true, BPA_TriggerInteractEvent_C = true,
    BPA_Trigger_Many_InteractEvent_C = true, BPA_RewardChest_C = true, BP_LockerOpener_C = true,
    BP_LockerOpener_Child_TIE_C = true, BP_PathLocker_C = true, BP_ChoochooCart_C = true, BP_Canon_3x1_PamsTrap_C = true,
}

local applyingRemote = false
local destroyed = {}      -- host: ordered list of destroyed actor paths in the current map
local destroyedSet = {}
local currentWorld = nil  -- world instance the lists above belong to (a restart reloads the same map)
local scanned = false
local facing = nil        -- address of the interactable the local player is facing

-- Runtime-spawned objects get names counting down from INT32_MAX; level-placed actors keep their editor names,
-- which are identical on every machine and therefore addressable by path.
local function isLevelPlaced(actor)
    local n = tonumber(actor:GetFName():ToString():match("_(%d+)$"))
    if n and n > 2000000000 then return false end
    local level = actor:GetOuter()
    return U.valid(level) and level:GetClass():GetFName():ToString() == "Level"
end

local function shared(actor)
    return U.valid(actor) and not actor.bReplicates and isLevelPlaced(actor)
end

local function remote(fn)
    applyingRemote = true
    local ok, err = pcall(fn)
    applyingRemote = false
    if not ok then Log.error("world replay: %s", tostring(err)) end
end


---------------------------------------------------------------- destruction

local function record(path)
    if not destroyedSet[path] then
        destroyedSet[path] = true
        destroyed[#destroyed + 1] = path
    end
end

local function onLocalDestroy(self)
    if applyingRemote or not U.isOnline() then return end
    local actor = self:get()
    if not shared(actor) then return end
    local path = U.path(actor)
    if U.isHost() then record(path) end
    Net.toOthers("WD", path)
end

-- Actors that clean up after themselves before they go (a boss HUD on screen...): on the other machines they go
-- the same way instead of just disappearing.
local REMOTE_END = {
    -- Rapeto's hit counter: reaching zero removes the boss HUD, shows "cleared" and runs the defeat
    BPA_RapetoMaster_C = function(master)
        master.HealthCurrent = 1
        master:DecrementHealth()
    end,
}

local function onRemoteDestroy(fields, sender)
    local path = fields[1]
    local actor = StaticFindObject(path)
    if U.valid(actor) and not actor.bActorIsBeingDestroyed then
        local finish = REMOTE_END[actor:GetClass():GetFName():ToString()]
        remote(function()
            if finish then finish(actor) else actor:K2_DestroyActor() end
        end)
    end
    if U.isHost() then record(path) end
    Net.forward(sender, "WD", path)
end

---------------------------------------------------------------- hits

local function onLocalHit(self, dmg, _, isWeapon, isHeavy, pushBack, origin)
    if applyingRemote or not U.isOnline() then return end
    local actor = self:get()
    local src = origin:get()
    -- the hair projectile hits with no attacker; count it as the local player's
    if not shared(actor) or (U.valid(src) and not U.fromLocalPlayer(src)) then return end
    Net.toOthers("WH", U.path(actor), dmg:get(), isWeapon:get() and 1 or 0, isHeavy:get() and 1 or 0, pushBack:get() and 1 or 0)
end

local function onRemoteHit(fields, sender)
    local actor = StaticFindObject(fields[1])
    local pawn = U.localPawn()
    if U.valid(actor) and not actor.bActorIsBeingDestroyed and pawn then
        remote(function()
            actor:DMGMelee(tonumber(fields[2]) or 0, nil, fields[3] == "1", fields[4] == "1", fields[5] == "1", pawn, {})
        end)
    end
    Net.forward(sender, "WH", fields[1], fields[2], fields[3], fields[4], fields[5])
end

---------------------------------------------------------------- interactions

local function trackFacing()
    local pawn = U.localPawn()
    facing = nil
    if not pawn then return end
    local ok, list = pcall(function() return pawn.Interactable end)
    if ok and list and #list > 0 then
        local target = list[#list]
        if U.valid(target) then facing = target:GetAddress() end
    end
end

-- Only the actor the player is facing: trigger actors call Interact() on their targets too, and those chained
-- calls are replayed by the trigger itself on every machine.
local function onLocalInteract(self)
    if applyingRemote or not U.isOnline() then return end
    local actor = self:get()
    if not shared(actor) or not SHARED_INTERACT[actor:GetClass():GetFName():ToString()] then return end
    if actor:GetAddress() ~= facing then return end
    Net.toOthers("WI", U.path(actor))
end

local function onRemoteInteract(fields, sender)
    local actor = StaticFindObject(fields[1])
    if U.valid(actor) and not actor.bActorIsBeingDestroyed then
        remote(function() actor:Interact() end)
    end
    Net.forward(sender, "WI", fields[1])
end

---------------------------------------------------------------- objects players move around

-- These move on the machine of the player handling them (attached to their character, or driven by their hair
-- ability); that machine sends where they are while they move and the others put their copy there.
local CARRIED_CLASSES = { "BP_PushPullObject_C", "BP_PushPullObject_V2_Hold_C", "BPA_PullPlatform_C",
    "BPA_PullPlatform_ContainerChild_C", "BPA_GrabableWeapon_C" }
local MOVE_THRESHOLD = 3   -- cm
local TURN_THRESHOLD = 2   -- degrees
local APPLY_QUIET = 1.0    -- seconds an object stays unreported after a remote update (its own physics settling)
local objectState = {}     -- path -> transform last sent or applied
local objectStart = {}     -- host: path -> transform when first seen in this level
local appliedAt = {}       -- path -> os.clock() of the last remote update applied

local function readTransform(actor)
    local l, r = actor:K2_GetActorLocation(), actor:K2_GetActorRotation()
    local t = { l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll }
    -- pull platforms move a part of themselves rather than the whole actor
    local ok, part = pcall(function() return actor.StaticMesh end)
    if ok and U.valid(part) and part:GetAddress() ~= actor:K2_GetRootComponent():GetAddress() then
        local pl, pr = part:K2_GetComponentLocation(), part:K2_GetComponentRotation()
        for _, v in ipairs({ pl.X, pl.Y, pl.Z, pr.Pitch, pr.Yaw, pr.Roll }) do t[#t + 1] = v end
    end
    return t
end

local function angleDiff(a, b)
    return math.abs((a - b + 180) % 360 - 180)
end

local function moved(a, b)
    if #a ~= #b then return true end
    for i = 1, #a, 6 do
        if math.abs(a[i] - b[i]) > MOVE_THRESHOLD or math.abs(a[i + 1] - b[i + 1]) > MOVE_THRESHOLD
            or math.abs(a[i + 2] - b[i + 2]) > MOVE_THRESHOLD then return true end
        for j = i + 3, i + 5 do
            if angleDiff(a[j], b[j]) > TURN_THRESHOLD then return true end
        end
    end
    return false
end

local function encodeTransform(t)
    local parts = {}
    for i, v in ipairs(t) do parts[i] = string.format("%.1f", v) end
    return table.concat(parts, ",")
end

local function simulatesPhysics(actor)
    local ok, sim = pcall(function() return actor:K2_GetRootComponent():IsSimulatingPhysics(FName("None")) end)
    return ok and sim == true
end

local function heldLocally(actor)
    local me = U.localPawn()
    local ok, parent = pcall(function() return actor:GetAttachParentActor() end)
    return me ~= nil and ok and U.valid(parent) and parent:GetAddress() == me:GetAddress()
end

-- Who reports an object's moves: whoever holds it; a loose physics object only the host (every machine simulates
-- its own copy, and two machines correcting each other would never settle).
local function reportsMoves(actor, path)
    if heldLocally(actor) then return true end
    if os.clock() - (appliedAt[path] or -10) < APPLY_QUIET then return false end
    return U.isHost() or not simulatesPhysics(actor)
end

local function trackObjects()
    -- (the state belongs to the level the 1 s tick last saw; wait for it after a level change)
    local pc = U.localPC()
    if not pc or pc:GetWorld():GetAddress() ~= currentWorld then return end
    for _, cls in ipairs(CARRIED_CLASSES) do
        for _, a in ipairs(FindAllOf(cls) or {}) do
            if a:IsValid() and not a.bActorIsBeingDestroyed and shared(a) then
                local path = U.path(a)
                local t = readTransform(a)
                if not objectState[path] then
                    objectState[path] = t
                    if U.isHost() then objectStart[path] = t end
                elseif moved(t, objectState[path]) then
                    objectState[path] = t
                    if reportsMoves(a, path) then Net.toOthers("PO", path, encodeTransform(t)) end
                end
            end
        end
    end
end

local function onRemoteObject(fields, sender)
    Net.forward(sender, "PO", fields[1], fields[2])
    local actor = StaticFindObject(fields[1])
    if not U.valid(actor) or actor.bActorIsBeingDestroyed then return end
    local t = {}
    for v in (fields[2] or ""):gmatch("[^,]+") do t[#t + 1] = tonumber(v) end
    if #t < 6 then return end
    remote(function()
        actor:K2_SetActorLocationAndRotation({ X = t[1], Y = t[2], Z = t[3] },
            { Pitch = t[4], Yaw = t[5], Roll = t[6] }, false, {}, true)
        if #t >= 12 then
            actor.StaticMesh:K2_SetWorldLocationAndRotation({ X = t[7], Y = t[8], Z = t[9] },
                { Pitch = t[10], Yaw = t[11], Roll = t[12] }, false, {}, true)
        end
    end)
    objectState[fields[1]] = readTransform(actor)
    appliedAt[fields[1]] = os.clock()
end

---------------------------------------------------------------- per-map setup

local function scanLevel()
    local actors = FindAllOf("Actor")
    if not actors then return end
    for _, a in ipairs(actors) do
        if a:IsValid() and shared(a) then
            Hooks.watch(a, "DMGMelee")
            if SHARED_INTERACT[a:GetClass():GetFName():ToString()] then
                Hooks.watch(a, "Interact")
            end
        end
    end
end

local function tick()
    local pc = U.localPC()
    local world = pc and pc:GetWorld():GetAddress()
    if world ~= currentWorld then
        currentWorld = world
        destroyed, destroyedSet, scanned, objectState, objectStart, appliedAt = {}, {}, false, {}, {}, {}
    end
    if world and not scanned and U.localPawn() then
        scanned = true
        scanLevel()
    end
end

-- Sent by the host to a client that just finished loading the level.
function World.sendSnapshot(pc)
    for _, path in ipairs(destroyed) do
        Net.toClient(pc, "WD", path)
    end
    for path, t in pairs(objectState) do
        if objectStart[path] and moved(t, objectStart[path]) then Net.toClient(pc, "PO", path, encodeTransform(t)) end
    end
end

function World.init()
    RegisterHook("/Script/Engine.Actor:K2_DestroyActor", onLocalDestroy)
    Hooks.on("DMGMelee", onLocalHit)
    Hooks.on("Interact", onLocalInteract)
    Net.on("WD", onRemoteDestroy)
    Net.on("WH", onRemoteHit)
    Net.on("WI", onRemoteInteract)
    Net.on("PO", onRemoteObject)
    LoopInGameThreadWithDelay(100, function()
        if not U.isOnline() or currentWorld == nil then return end
        pcall(trackFacing)
        local ok, err = pcall(trackObjects)
        if not ok then Log.error("world objects: %s", tostring(err)) end
    end)
    LoopInGameThreadWithDelay(1000, function()
        if not U.isOnline() then return end
        local ok, err = pcall(tick)
        if not ok then Log.error("world tick: %s", tostring(err)) end
    end)
end

return World
