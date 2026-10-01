-- "Whose player is this?" The game's Blueprints find the player with GetPlayerCharacter/Controller(0),
-- GetPlayerCameraManager(0) and GetGameInstance(), which always mean the local player. In co-op that is wrong
-- in two places, fixed here by rewriting the call's inputs in pre-hooks:
--   * code running for another player's character (its components, anim instance, ...) must not touch the local
--     player's controller, HUD, camera or save data (GameInstance) -> those lookups return nothing, and
--     GetPlayerCharacter/Pawn returns that character itself where it can (host) or nothing (clients);
--   * enemy AI on the host must fight every player, not just the host -> GetPlayerCharacter/Pawn called by an
--     AI pawn, its controller, behaviour-tree nodes or components returns the nearest standing player.
local U = require("coop.util")
local State = require("coop.state")

local Perspective = {}

local classes = {}
local function class(path)
    local c = classes[path]
    if not c or not c:IsValid() then
        c = StaticFindObject(path)
        classes[path] = c
    end
    return c
end

local function isA(obj, path)
    local c = class(path)
    return U.valid(c) and obj:IsA(c)
end

local KALAKELY = "/Game/Kalakely/BPC_Kalakely.BPC_Kalakely_C"

-- Arena managers hand out attack tokens and start fights based on "the player"; for them that is the nearest
-- player too.
local MANAGERS = {
    BPA_EnemyManager_C = true, BPA_EnemyManager_Child_TIE_C = true, BPA_CombatManager_C = true,
    BPA_CombatManger_Test_01_C = true, BPA_SurviveCombatManger_Test_C = true,
}

local cache = {}      -- ctx address -> { kind, pawn, expires }
local pcIndex = {}    -- host: controller address -> index in the world's player controller list
local players = {}    -- player pawns in the current world
local refreshedAt = -1
local reentrant = false

local function isPlayerPawn(pawn)
    return isA(pawn, KALAKELY) and U.valid(pawn.PlayerState)
end

-- Resolve an arbitrary Blueprint context object to the pawn it acts for.
local function pawnOf(obj)
    local actor
    if isA(obj, "/Script/Engine.Actor") then
        actor = obj
    elseif isA(obj, "/Script/Engine.ActorComponent") then
        actor = obj:GetOwner()
    elseif isA(obj, "/Script/Engine.AnimInstance") then
        actor = obj:TryGetPawnOwner()
    elseif isA(obj, "/Script/AIModule.BTNode") then
        local ok, owner = pcall(function() return obj.AIOwner end)
        if ok and U.valid(owner) then actor = owner end
    end
    if not U.valid(actor) then return nil end
    if isA(actor, "/Script/Engine.Controller") then
        actor = actor.Pawn
    elseif not isA(actor, "/Script/Engine.Pawn") then
        -- spawned actors (projectiles, hazards) act for their owner or instigator
        local owner = actor:GetOwner()
        if U.valid(owner) and isA(owner, "/Script/Engine.Controller") then owner = owner.Pawn end
        if not (U.valid(owner) and isA(owner, "/Script/Engine.Pawn")) then owner = actor.Instigator end
        if U.valid(owner) and isA(owner, "/Script/Engine.Pawn") then actor = owner else return nil end
    end
    if U.valid(actor) then return actor end
    return nil
end

-- "remote" (another player's character), "ai" (AI-controlled pawn or arena manager, host only) or nil (leave
-- the call alone). For "ai" the second value is the actor whose position picks the nearest player.
local function classify(obj)
    local key = obj:GetAddress()
    local now = os.clock()
    local hit = cache[key]
    if hit and hit.expires > now then return hit.kind, hit.pawn end
    local kind, pawn = nil, pawnOf(obj)
    if not pawn and U.cachedMode == "host" and MANAGERS[obj:GetClass():GetFName():ToString()] then
        kind, pawn = "ai", obj
    elseif not pawn and U.cachedMode == "host" and isA(obj, "/Script/AIModule.EnvQueryContext") then
        kind = "eqs"
    elseif pawn then
        if isPlayerPawn(pawn) then
            if not pawn:IsLocallyControlled() then kind = "remote" end
        elseif U.cachedMode == "host" and U.valid(pawn.Controller) and isA(pawn.Controller, "/Script/AIModule.AIController") then
            kind = "ai"
        end
    end
    cache[key] = { kind = kind, pawn = pawn, expires = now + 2.0 }
    return kind, pawn
end

local function refresh()
    local now = os.clock()
    if now - refreshedAt < 0.5 then return end
    refreshedAt = now
    cache = {}
    players = {}
    local chars = FindAllOf("BPC_Kalakely_C")
    if chars then
        for _, c in ipairs(chars) do
            if c:IsValid() and U.valid(c.PlayerState) and not c.bActorIsBeingDestroyed then players[#players + 1] = c end
        end
    end
    pcIndex = {}
    if U.cachedMode == "host" then
        local pc = U.localPC()
        if pc then
            reentrant = true
            for i = 0, 15 do
                local p = U.statics():GetPlayerController(pc, i)
                if not U.valid(p) then break end
                pcIndex[p:GetAddress()] = i
            end
            reentrant = false
        end
    end
end

local function indexOfPawn(pawn)
    local ctrl = pawn.Controller
    if not U.valid(ctrl) then return nil end
    return pcIndex[ctrl:GetAddress()]
end

local function nearestPlayerIndex(fromPawn)
    local from = fromPawn:K2_GetActorLocation()
    local best, bestDist, fallback = nil, math.huge, nil
    for _, p in ipairs(players) do
        if p:IsValid() then
            local idx = indexOfPawn(p)
            if idx then
                fallback = fallback or idx
                if State.isStanding(U.pawnId(p)) then
                    local l = p:K2_GetActorLocation()
                    local d = (l.X - from.X) ^ 2 + (l.Y - from.Y) ^ 2 + (l.Z - from.Z) ^ 2
                    if d < bestDist then best, bestDist = idx, d end
                end
            end
        end
    end
    return best or fallback
end

local function nearestPlayerIndexToEnemies()
    local sx, sy, sz, n = 0, 0, 0, 0
    for _, c in ipairs(FindAllOf("Character") or {}) do
        if c:IsValid() and not isPlayerPawn(c) and U.valid(c.Controller)
            and isA(c.Controller, "/Script/AIModule.AIController") then
            local l = c:K2_GetActorLocation()
            sx, sy, sz, n = sx + l.X, sy + l.Y, sz + l.Z, n + 1
        end
    end
    if n == 0 then return nil end
    local best, bestDist
    for _, p in ipairs(players) do
        local idx = p:IsValid() and indexOfPawn(p)
        if idx and State.isStanding(U.pawnId(p)) then
            local l = p:K2_GetActorLocation()
            local d = (l.X - sx / n) ^ 2 + (l.Y - sy / n) ^ 2 + (l.Z - sz / n) ^ 2
            if not bestDist or d < bestDist then best, bestDist = idx, d end
        end
    end
    return best
end

local NO_PLAYER = 99

-- wantsPawn: GetPlayerCharacter/GetPlayerPawn (true) vs GetPlayerController/GetPlayerCameraManager (false)
local function redirectIndex(ctx, idx, wantsPawn)
    if reentrant or (U.cachedMode ~= "host" and U.cachedMode ~= "client") then return end
    -- some native call paths hand the hook a shifted parameter list; only touch a real PlayerIndex
    local current = idx:get()
    if type(current) ~= "number" or current ~= 0 then return end
    local obj = ctx:get()
    if not U.valid(obj) then return end
    refresh()
    local kind, pawn = classify(obj)
    if kind == "remote" then
        local own = wantsPawn and U.cachedMode == "host" and indexOfPawn(pawn)
        idx:set(own or NO_PLAYER)
    elseif kind == "ai" and wantsPawn then
        local target = nearestPlayerIndex(pawn)
        if target then idx:set(target) end
    elseif kind == "eqs" and wantsPawn then
        -- EQS contexts run on their class default object and cannot tell which enemy is asking: use the player
        -- closest to where the enemies are.
        local target = nearestPlayerIndexToEnemies()
        if target then idx:set(target) end
    end
end

-- A local controller only ever views its own character, never a teammate's (game code that pairs
-- GetPlayerController(0) with the nearest player would otherwise swap cameras).
local function keepOwnViewTarget(self, target)
    if U.cachedMode ~= "host" and U.cachedMode ~= "client" then return end
    local pc, t = self:get(), target:get()
    if not U.valid(pc) or not U.valid(t) or not pc:IsLocalController() then return end
    if isPlayerPawn(t) and U.valid(pc.Pawn) and t:GetAddress() ~= pc.Pawn:GetAddress() then
        target:set(pc.Pawn)
    end
end

function Perspective.init()
    local G = "/Script/Engine.GameplayStatics:"
    RegisterHook("/Script/Engine.PlayerController:SetViewTargetWithBlend", keepOwnViewTarget)
    RegisterHook(G .. "GetPlayerCharacter", function(_, ctx, idx) redirectIndex(ctx, idx, true) end)
    RegisterHook(G .. "GetPlayerPawn", function(_, ctx, idx) redirectIndex(ctx, idx, true) end)
    RegisterHook(G .. "GetPlayerController", function(_, ctx, idx) redirectIndex(ctx, idx, false) end)
    RegisterHook(G .. "GetPlayerCameraManager", function(_, ctx, idx) redirectIndex(ctx, idx, false) end)
    RegisterHook(G .. "GetGameInstance", function(_, ctx)
        if reentrant or (U.cachedMode ~= "host" and U.cachedMode ~= "client") then return end
        local obj = ctx:get()
        if not U.valid(obj) then return end
        refresh()
        if classify(obj) == "remote" then ctx:set(nil) end
    end)
end

-- Other modules use this to decide whether an object acts for another player's character.
function Perspective.isRemotePlayerContext(obj)
    if not U.valid(obj) then return false end
    return classify(obj) == "remote"
end

Perspective.isPlayerPawn = isPlayerPawn

return Perspective
