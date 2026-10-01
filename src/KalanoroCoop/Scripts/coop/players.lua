-- Player characters: movement authority, camera, and animation-state/montage sync for remote players.
local U = require("coop.util")
local Log = require("coop.log")
local Net = require("coop.net")

local Players = {}

local KALAKELY_CLASS = "/Game/Kalakely/BPC_Kalakely.BPC_Kalakely_C"

-- Character variables read by ABP_KalakelyV4 (or that drive abilities it animates).
local FLAG_VARS = { "isGliding", "isClimbing", "isAiming", "isDashing", "isRolling", "isDashingDown", "IsJumping",
    "IsHairSwinging", "isBuilding", "Winning" }
local NUM_VARS = { "PoseWeight", "Action Value X", "Action Value Y" }

local lastState = nil
local lastMontagePath, lastMontagePos = nil, 0

local function isKalakely(pawn)
    local cls = StaticFindObject(KALAKELY_CLASS)
    return U.valid(pawn) and U.valid(cls) and pawn:IsA(cls)
end

-- BPC_Kalakely renders and animates its "SkeletalMesh" component (ABP_KalakelyV4); the inherited
-- CharacterMesh0 is hidden.
local function animInstance(pawn)
    local mesh = pawn.SkeletalMesh
    if not U.valid(mesh) then return nil end
    local anim = mesh:GetAnimInstance()
    if U.valid(anim) then return anim end
    return nil
end

-- Host: trust client-reported positions. The game's dash/glide/climb/teleport logic runs in Blueprint on the
-- owning machine only, so server-side movement simulation would otherwise snap clients back.
-- Every player stays replicated to everyone however far apart they are (by default a character stops being
-- sent beyond 150 m and disappears from the other machines).
local function applyMovementAuthority()
    local chars = FindAllOf("Character")
    if not chars then return end
    for _, c in ipairs(chars) do
        if c:IsValid() and U.valid(c.PlayerState) and not c.bAlwaysRelevant then
            c.bAlwaysRelevant = true
        end
        if c:IsValid() and U.valid(c.PlayerState) and not c:IsLocallyControlled() then
            local cmc = c.CharacterMovement
            if U.valid(cmc) and not cmc.bServerAcceptClientAuthoritativePosition then
                cmc.bIgnoreClientMovementErrorChecksAndCorrection = true
                cmc.bServerAcceptClientAuthoritativePosition = true
                Log.debug("client-authoritative movement for %s", c:GetFName():ToString())
            end
        end
    end
end

-- Client: the level's single-player setup never points the camera at a pawn possessed over the network.
local function fixClientCamera()
    local pc = U.localPC()
    if not pc or not U.valid(pc.Pawn) then return end
    local pcm = pc.PlayerCameraManager
    if not U.valid(pcm) then return end
    local target = pcm.ViewTarget.Target
    if not U.valid(target) or target:GetAddress() == pc:GetAddress() then
        pc:SetViewTargetWithBlend(pc.Pawn, 0.0, 0, 0.0, false)
    end
end

local MOVE_WALKING, MOVE_FALLING = 1, 3
local remoteGrounded = {} -- player id -> true/false, as reported by that player

local function sampleState(pawn)
    local bits = {}
    for i, name in ipairs(FLAG_VARS) do bits[i] = pawn[name] and "1" or "0" end
    -- ground state last: remote copies don't reliably get the owner's movement mode, and the anim blueprint
    -- plays the in-air pose ("floating") whenever it thinks the character is off the ground
    bits[#bits + 1] = pawn.CharacterMovement:IsMovingOnGround() and "1" or "0"
    local nums = {}
    for i, name in ipairs(NUM_VARS) do nums[i] = string.format("%.2f", pawn[name]) end
    return table.concat(bits), table.concat(nums, ",")
end

local function applyGround(pawn, grounded)
    local cmc = pawn.CharacterMovement
    local mode = cmc.MovementMode
    if grounded and mode ~= MOVE_WALKING then
        cmc:SetMovementMode(MOVE_WALKING, 0)
    elseif not grounded and mode ~= MOVE_FALLING then
        cmc:SetMovementMode(MOVE_FALLING, 0)
    end
end

local function applyState(pawn, bits, nums)
    for i, name in ipairs(FLAG_VARS) do
        pawn[name] = bits:sub(i, i) == "1"
    end
    local grounded = bits:sub(#FLAG_VARS + 1, #FLAG_VARS + 1) ~= "0"
    remoteGrounded[U.pawnId(pawn)] = grounded
    applyGround(pawn, grounded)
    local i = 1
    for v in nums:gmatch("[^,]+") do
        if NUM_VARS[i] then pawn[NUM_VARS[i]] = tonumber(v) or 0 end
        i = i + 1
    end
end

local function sendLocalState()
    local pawn = U.localPawn()
    if not isKalakely(pawn) then return end
    local id = U.pawnId(pawn)
    if not id then return end

    local bits, nums = sampleState(pawn)
    local state = bits .. nums
    if state ~= lastState then
        lastState = state
        Net.toOthers("PS", id, bits, nums)
    end

    local anim = animInstance(pawn)
    if not anim then return end
    local montage = anim:GetCurrentActiveMontage()
    if U.valid(montage) then
        local path = U.path(montage)
        local pos = anim:Montage_GetPosition(montage)
        if path ~= lastMontagePath or pos + 0.05 < lastMontagePos then
            Net.toOthers("AM", id, path, string.format("%.3f", pos))
        end
        lastMontagePath, lastMontagePos = path, pos
    elseif lastMontagePath then
        lastMontagePath, lastMontagePos = nil, 0
    end
end

local function remotePawn(id)
    local pawn = U.findPawnById(tonumber(id))
    if not pawn or pawn:IsLocallyControlled() or not isKalakely(pawn) then return nil end
    return pawn
end

local function onState(fields, sender)
    local id, bits, nums = fields[1], fields[2], fields[3]
    local pawn = remotePawn(id)
    if pawn then applyState(pawn, bits, nums) end
    Net.forward(sender, "PS", id, bits, nums)
end

local function onMontage(fields, sender)
    local id, path, pos = fields[1], fields[2], tonumber(fields[3]) or 0
    local pawn = remotePawn(id)
    if pawn then
        local montage = StaticFindObject(path)
        if not U.valid(montage) then montage = LoadAsset(path) end
        local anim = animInstance(pawn)
        if U.valid(montage) and anim then
            local len = anim:Montage_Play(montage, 1.0, 0, pos, true)
            Log.debug("montage %s on %s -> %s", path, pawn:GetFName():ToString(), tostring(len))
        else
            Log.debug("montage %s: asset %s anim %s", path, tostring(U.valid(montage)), tostring(anim ~= nil))
        end
    else
        Log.debug("montage: no remote pawn for id %s", tostring(id))
    end
    Net.forward(sender, "AM", id, path, fields[3])
end

---------------------------------------------------------------- projectiles fired by players

-- Projectiles the local player fires exist only on its machine; show everyone a copy. Copies have collision off
-- so they never hit anything (the real hits are forwarded by combat.lua / world.lua).
local PLAYER_PROJECTILES = {
    BP_ProjectileHair_C = true, BP_ProjectileElementalV2_C = true, BP_Projectile_Child2_C = true,
    BPA_FurballProjectile_C = true,
}
local spawnByLocalPlayer = false
local spawningCopy = false

local function actsForLocalPlayer(obj)
    local pawn = U.localPawn()
    if not pawn or not U.valid(obj) then return false end
    local addr = pawn:GetAddress()
    if obj:GetAddress() == addr then return true end
    local ok, owner = pcall(function() return obj:GetOwner() end)
    return ok and U.valid(owner) and owner:GetAddress() == addr
end

local function onBeginSpawn(_, ctx)
    if spawningCopy or not U.isOnline() then return end
    spawnByLocalPlayer = actsForLocalPlayer(ctx:get())
end

local function onFinishSpawn(_, actorParam, transformParam)
    if spawningCopy or not spawnByLocalPlayer then return end
    spawnByLocalPlayer = false
    local actor = actorParam:get()
    if not U.valid(actor) or not PLAYER_PROJECTILES[actor:GetClass():GetFName():ToString()] then return end
    -- a deferred actor is only placed when FinishSpawningActor runs: take the spawn transform
    local t = transformParam:get()
    local l = t.Translation
    local r = StaticFindObject("/Script/Engine.Default__KismetMathLibrary"):Quat_Rotator(t.Rotation)
    Net.toOthers("PFX", U.pawnId(U.localPawn()), U.path(actor:GetClass()),
        string.format("%.1f,%.1f,%.1f", l.X, l.Y, l.Z), string.format("%.2f,%.2f,%.2f", r.Pitch, r.Yaw, r.Roll))
end

local function onProjectileCopy(fields, sender)
    Net.forward(sender, "PFX", fields[1], fields[2], fields[3], fields[4])
    local cls = StaticFindObject(fields[2])
    local shooter = U.findPawnById(tonumber(fields[1]))
    local pc = U.localPC()
    if not U.valid(cls) or not pc then return end
    local x, y, z = fields[3]:match("^(.-),(.-),(.-)$")
    local pitch, yaw, roll = fields[4]:match("^(.-),(.-),(.-)$")
    local transform = StaticFindObject("/Script/Engine.Default__KismetMathLibrary"):MakeTransform(
        { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) },
        { Pitch = tonumber(pitch), Yaw = tonumber(yaw), Roll = tonumber(roll) }, { X = 1, Y = 1, Z = 1 })
    spawningCopy = true
    local ok, err = pcall(function()
        local statics = U.statics()
        local copy = statics:BeginDeferredActorSpawnFromClass(pc, cls, transform, 1, U.valid(shooter) and shooter or nil, 0)
        if U.valid(copy) then
            copy:SetActorEnableCollision(false)
            statics:FinishSpawningActor(copy, transform, 0)
            copy:SetActorEnableCollision(false)
            copy:SetLifeSpan(4.0)
        end
    end)
    spawningCopy = false
    if not ok then Log.error("projectile copy: %s", tostring(err)) end
end

function Players.init()
    RegisterHook("/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", onBeginSpawn)
    RegisterHook("/Script/Engine.GameplayStatics:FinishSpawningActor", onFinishSpawn)
    Net.on("PFX", onProjectileCopy)
    Net.on("PS", onState)
    Net.on("AM", onMontage)
    LoopInGameThreadWithDelay(50, function()
        if not U.isOnline() then return end
        local ok, err = pcall(sendLocalState)
        if not ok then Log.error("player sync: %s", tostring(err)) end
    end)
    LoopInGameThreadWithDelay(500, function()
        local mode = U.cachedMode
        if mode == "host" or mode == "client" then
            for _, c in ipairs(FindAllOf("BPC_Kalakely_C") or {}) do
                local id = c:IsValid() and not c:IsLocallyControlled() and U.pawnId(c)
                if id and remoteGrounded[id] ~= nil then pcall(applyGround, c, remoteGrounded[id]) end
            end
        end
        local ok, err = true, nil
        if mode == "host" then
            ok, err = pcall(applyMovementAuthority)
        elseif mode == "client" then
            ok, err = pcall(fixClientCamera)
        end
        if not ok then Log.error("player upkeep: %s", tostring(err)) end
    end)
end

return Players
