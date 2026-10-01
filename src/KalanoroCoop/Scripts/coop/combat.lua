-- Combat in a shared world. Enemies are replicated characters whose AI runs on the host, so:
--   * a client's hit on an enemy is also applied on the host (who owns enemy health and death);
--   * an enemy hit on a client's character (resolved on the host) is applied by that client to itself;
--   * enemy health scales with the number of players and is kept in sync on clients;
--   * enemy attack animations played on the host are shown on clients;
--   * clients never spawn enemies themselves, and any player entering an arena starts the host's fight.
local U = require("coop.util")
local Log = require("coop.log")
local Net = require("coop.net")
local Perspective = require("coop.perspective")
local Hooks = require("coop.hooks")
local State = require("coop.state")
local Enemies = require("coop.enemies")

local Combat = {}

local KALAKELY_DMG = "/Game/Kalakely/BPC_Kalakely.BPC_Kalakely_C:DmgMeleeKalakely"
local ENEMY_MANAGER = "/Game/CombatSystems/BPA_EnemyManager.BPA_EnemyManager_C"
local MANAGER_TRIGGER_EVENT = "BndEvt__BPA_EnemyManager_TriggerBox_K2Node_ComponentBoundEvent_1_ComponentBeginOverlapSignature__DelegateSignature"
local HEALTH_SCALE_PER_EXTRA_PLAYER = 0.6

local playerHookDone = false
local lastLocalHurt = -10
local applyingRemoteHit = false
local scaled = {}           -- host: enemy name -> true once its health is scaled to the player count
local lastHealth = {}       -- host: enemy name -> last broadcast health state
local lastEnemyMontage = {} -- host: enemy name -> { path, at } of the montage last sent
local MONTAGE_RESEND_SECONDS = 1
local MONTAGE_TOLERANCE = 0.3
local startedManagers = {}  -- host: manager path -> true
local simulated = {}        -- host: enemy name -> true once it simulates off-screen

local function fmtLoc(l)
    return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z)
end

local function parseLoc(s)
    local x, y, z = s:match("^(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+)$")
    return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
end

local function isEnemy(actor)
    return U.valid(actor) and actor.bReplicates and not Perspective.isPlayerPawn(actor)
        and actor:IsA(StaticFindObject("/Script/Engine.Pawn"))
end

local function playerCount()
    local n = 0
    local chars = FindAllOf("BPC_Kalakely_C")
    for _, c in ipairs(chars or {}) do
        if c:IsValid() and U.valid(c.PlayerState) then n = n + 1 end
    end
    return math.max(n, 1)
end

---------------------------------------------------------------- client hits enemy

local function onEnemyDamaged(self, dmg, _, isWeapon, isHeavy, pushBack, origin)
    if applyingRemoteHit or not U.isClient() then return end
    local enemy = self:get()
    if not isEnemy(enemy) then return end
    -- the hair projectile passes no attacker; on a client nothing else hits enemies without one
    local src = origin:get()
    if U.valid(src) and not U.fromLocalPlayer(src) then return end
    Net.toHost("HIT", Enemies.ref(enemy), dmg:get(),
        isWeapon:get() and 1 or 0, isHeavy:get() and 1 or 0, pushBack:get() and 1 or 0)
end

local function onHit(fields, sender)
    if not U.isHost() or not sender then return end
    local enemy, dmg = Enemies.resolve(fields[1]), tonumber(fields[2]) or 0
    local attacker = sender.Pawn
    if not enemy or not U.valid(attacker) then return end
    applyingRemoteHit = true
    local ok, err = pcall(function()
        enemy:DMGMelee(dmg, nil, fields[3] == "1", fields[4] == "1", fields[5] == "1", attacker, {})
    end)
    applyingRemoteHit = false
    if not ok then Log.error("remote hit on %s: %s", fields[1], tostring(err)) end
end

-- Player abilities reach enemies through these interface calls (elemental shots, electric pulse, stuns, blind,
-- dash); all their parameters are numbers or booleans. On a client they only ever come from the local player.
local ABILITY_CALLS = { "ApplyDmgElemental", "ElectricPulseDamage", "Electrocute", "MiniStun", "Stun", "Blind", "DmgDash" }

local function encodeArgs(params)
    local out = {}
    for i, p in ipairs(params) do
        local v = p:get()
        if type(v) == "boolean" then out[i] = v and "b1" or "b0" else out[i] = tostring(tonumber(v) or 0) end
    end
    return table.concat(out, ",")
end

local function decodeArgs(s)
    local out = {}
    for v in (s or ""):gmatch("[^,]+") do
        if v == "b1" then out[#out + 1] = true elseif v == "b0" then out[#out + 1] = false else out[#out + 1] = tonumber(v) end
    end
    return out
end

local function abilityListener(fnName)
    return function(self, ...)
        if applyingRemoteHit or not U.isClient() then return end
        local enemy = self:get()
        if not isEnemy(enemy) then return end
        Net.toHost("EABL", fnName, Enemies.ref(enemy), encodeArgs({ ... }))
    end
end

local function onAbility(fields, sender)
    if not U.isHost() or not sender then return end
    local fnName = fields[1]
    local enemy = Enemies.resolve(fields[2])
    if not enemy then return end
    local args = decodeArgs(fields[3])
    applyingRemoteHit = true
    local ok, err = pcall(function() enemy[fnName](enemy, table.unpack(args)) end)
    applyingRemoteHit = false
    if not ok then Log.error("remote %s on %s: %s", fnName, fields[2], tostring(err)) end
end

---------------------------------------------------------------- enemy hits client

local function onPlayerDamaged(self, dmg, vec, impulse, unavoidable)
    local pawn = self:get()
    if not U.valid(pawn) or not U.isOnline() then return end
    if pawn:IsLocallyControlled() then
        lastLocalHurt = os.clock()
        return
    end
    -- On the host this ran against a client's character; Perspective kept it away from the host's own
    -- health/HUD, so hand the hit to the player who owns that character.
    if U.isHost() and U.valid(pawn.Controller) and not State.isDowned(U.pawnId(pawn)) then
        local v = vec:get()
        Net.toClient(pawn.Controller, "HURT", dmg:get(), fmtLoc(v), impulse:get() and 1 or 0, unavoidable:get() and 1 or 0)
    end
end

local function onHurt(fields)
    -- Hazards the client touched were already applied locally by its own copy of the level.
    if os.clock() - lastLocalHurt < 0.4 then return end
    local pawn = U.localPawn()
    if not pawn or State.isDowned(U.pawnId(pawn)) then return end
    pawn:DmgMeleeKalakely(tonumber(fields[1]) or 0, parseLoc(fields[2]), fields[3] == "1", fields[4] == "1")
end

---------------------------------------------------------------- spawns and arenas

-- Projectiles and shockwaves fired by enemies exist only on the host unless replicated; clients would get hit by
-- invisible shots. (Turret shots are not listed: every machine runs its own copy of level-placed turrets.)
local ENEMY_PROJECTILES = {
    BP_Projectile_Child_C = true, BP_Projectile_Child1_C = true, BPA_ProjectileLaunchSpline1_C = true,
    BPA_ShockWave_C = true, BPA_ProjectileMarajiGun_C = true, BPA_DiskProjectile_C = true,
    BPA_ProjectileRapeto_C = true, BPA_ProjectileRapetoFast_C = true, BPA_FaraWave_C = true,
}
local spawnByAI = false

local function isAIPawn(obj)
    return U.valid(obj) and obj:IsA(StaticFindObject("/Script/Engine.Pawn")) and U.valid(obj.Controller)
        and obj.Controller:IsA(StaticFindObject("/Script/AIModule.AIController"))
end

local function onFinishSpawning(_, actorParam)
    if not U.isHost() or not spawnByAI then return end
    spawnByAI = false
    local actor = actorParam:get()
    if U.valid(actor) and ENEMY_PROJECTILES[actor:GetClass():GetFName():ToString()] then
        actor:SetReplicates(true)
        actor:SetReplicateMovement(true)
    end
end

-- Clients: enemies (replicated pawns) come from the host; a client-side spawn would be a local-only duplicate.
local function blockClientPawnSpawn(_, ctx, cls)
    if U.isHost() then
        spawnByAI = isAIPawn(ctx:get())
        return
    end
    if not U.isClient() then return end
    local c = cls:get()
    if not U.valid(c) then return end
    local cdo = c:GetCDO()
    if U.valid(cdo) and cdo.bReplicates and cdo:IsA(StaticFindObject("/Script/Engine.Pawn")) then
        ctx:set(nil)
    end
end

-- Arena triggers only react to GetPlayerCharacter(0), i.e. the host on the host. A client entering an arena
-- asks the host to start that fight.
local function onManagerTriggered(self, _, other)
    if not U.isClient() then return end
    local pawn = U.localPawn()
    local actor = other:get()
    if pawn and U.valid(actor) and actor:GetAddress() == pawn:GetAddress() then
        Net.toHost("FIGHT", U.path(self:get()))
    end
end

local function onFightRequest(fields)
    if not U.isHost() then return end
    local path = fields[1]
    if startedManagers[path] then return end
    -- The host's own trigger may already have started it (arena managers target the nearest player).
    ExecuteInGameThreadWithDelay(400, function()
        local manager = StaticFindObject(path)
        if startedManagers[path] or not U.valid(manager) or manager.Disable then return end
        if U.valid(manager.Plane) and manager.Plane:IsVisible() then return end
        -- Replay the trigger's overlap event with the pawn the manager itself considers "the player", so its
        -- player check passes and the fight starts exactly as in single player.
        local player = U.statics():GetPlayerCharacter(manager, 0)
        if not U.valid(player) then return end
        startedManagers[path] = true
        manager[MANAGER_TRIGGER_EVENT](manager, manager.TriggerBox, player, player.CapsuleComponent, 0, false, {})
    end)
end

-- Arena walls are the manager's Plane components; mirror their state from the host.
local WALLS = { "Plane", "Plane1", "Plane2", "Plane3" }
local wallState = {}

local function syncArenas()
    local managers = FindAllOf("BPA_EnemyManager_C")
    if not managers then return end
    for _, m in ipairs(managers) do
        if m:IsValid() then
            local path = U.path(m)
            local visible = U.valid(m.Plane) and m.Plane:IsVisible()
            if wallState[path] ~= visible then
                wallState[path] = visible
                if visible then startedManagers[path] = true end
                Net.broadcast(nil, "ARENA", path, visible and 1 or 0)
            end
        end
    end
end

local function onArena(fields)
    local manager = StaticFindObject(fields[1])
    if not U.valid(manager) then return end
    local up = fields[2] == "1"
    for _, name in ipairs(WALLS) do
        local wall = manager[name]
        if U.valid(wall) then
            wall:SetVisibility(up, false)
            wall:SetCollisionResponseToAllChannels(up and 2 or 1)
        end
    end
end

---------------------------------------------------------------- host upkeep

-- Where enemies keep their health (bosses differ). With a current and a maximum it scales with the player count.
local HEALTH_FIELDS = {
    { "Health", "HealthMax", scale = true },                  -- regular enemies
    { "HP", "Hp Max", scale = true },                         -- Raneny
    { "HP", "HpMax", scale = true },                          -- Maraji
    { "HitNb" },                                              -- Fara: hits taken, with fixed phase thresholds
    { "PhaseCurrent", "Phase1PartCurrent", "Phase1PartMax" }, -- Rapeto (his hit counter is BPA_RapetoMaster's)
}
local healthFieldsByClass = {} -- class name -> entry of HEALTH_FIELDS, or false
local RAPETO_MASTER = "BPA_RapetoMaster_C"
local scaledMasters = {}       -- host: master path -> true
local lastMasterHealth = {}    -- host: master path -> "current/max" sent
local bossBars = {}            -- client: enemy ref -> boss health widget on screen
local lastBar = {}             -- host: enemy name -> class of the boss bar announced
local BOSS_BAR_PROPERTIES = { "HpWidget", "HealthHudRef" }

local function propertyWidget(obj, name)
    local ok, w = pcall(function() return obj[name] end)
    if ok and U.valid(w) then return w end
    return nil
end

-- The boss health bar drawn on screen (regular enemies have theirs above their head), and the property holding it.
local function bossBarOf(enemy)
    for _, name in ipairs(BOSS_BAR_PROPERTIES) do
        local w = propertyWidget(enemy, name)
        if w then return w, name end
    end
    return nil
end

-- Clients: show the values that arrived from the host the way the enemy's own damage code would.
local function refreshHealthDisplay(ref, enemy, fields)
    local cur, max = enemy[fields[1]], fields[2] and enemy[fields[2]] or nil
    local overhead = propertyWidget(enemy, "As HUD Enemy Health")
    if overhead and max then
        overhead:UpdateRedOnly(cur, max)
        overhead:UpdateWhiteOnly(cur, max)
    end
    local hpWidget = propertyWidget(enemy, "HpWidget")
    if hpWidget and max then hpWidget:UpdateHpWidget(cur, max) end
    local hitsWidget = propertyWidget(enemy, "HealthHudRef")
    if hitsWidget then hitsWidget:SetHits(cur) end
    local bar = hpWidget or hitsWidget
    if bar then bossBars[ref] = bar end
end

local function healthFieldsOf(enemy)
    local cls = enemy:GetClass():GetFName():ToString()
    local found = healthFieldsByClass[cls]
    if found == nil then
        found = false
        for _, fields in ipairs(HEALTH_FIELDS) do
            local ok, all = pcall(function()
                for _, name in ipairs(fields) do
                    if type(enemy[name]) ~= "number" then return false end
                end
                return true
            end)
            if ok and all then
                found = fields
                break
            end
        end
        healthFieldsByClass[cls] = found
    end
    return found or nil
end

-- Rapeto's hit counter lives in a level actor (BPA_RapetoMaster). The host scales it and sends it; clients replay
-- the counter's own decrement, which also updates their boss HUD and runs the defeat when it reaches zero.
local function hostMasterTick(factor)
    for _, m in ipairs(FindAllOf(RAPETO_MASTER) or {}) do
        if m:IsValid() and not m.bActorIsBeingDestroyed then
            local path = U.path(m)
            if not scaledMasters[path] and factor > 1 and m.HealthMax > 0 then
                scaledMasters[path] = true
                local max = math.floor(m.HealthMax * factor + 0.5)
                m.HealthCurrent = math.floor(m.HealthCurrent * factor + 0.5)
                m.HealthMax = max
                pcall(function() m.RapetoHUD:UpdateHealth(m.HealthCurrent, max) end)
            end
            local state = m.HealthCurrent .. "/" .. m.HealthMax
            if lastMasterHealth[path] ~= state then
                lastMasterHealth[path] = state
                Net.broadcast(nil, "BM", path, m.HealthCurrent, m.HealthMax)
            end
        end
    end
end

local function hostTick()
    local chars = FindAllOf("Character")
    if not chars then return end
    local factor = 1 + HEALTH_SCALE_PER_EXTRA_PLAYER * (playerCount() - 1)
    for _, c in ipairs(chars) do
        if c:IsValid() and isEnemy(c) and not c.bActorIsBeingDestroyed then
            local key = c:GetFName():ToString()
            local ref = Enemies.ref(c)
            -- Enemies only move and animate while the local player can see them (a single-player optimisation);
            -- on the host they must also fight players the host is not looking at. They also stay replicated at
            -- any distance: an enemy culled on a client comes back as a new object without its shared id.
            if not simulated[key] then
                simulated[key] = true
                pcall(function()
                    c.bAlwaysRelevant = true
                    c.CharacterMovement.bUpdateOnlyIfRendered = false
                    c.Mesh.VisibilityBasedAnimTickOption = 0
                    c.Mesh.bEnableUpdateRateOptimizations = false
                end)
            end
            local fields = healthFieldsOf(c)
            if fields then
                if fields.scale and not scaled[key] and factor > 1 then
                    local cur, max = fields[1], fields[2]
                    if c[max] > 0 then
                        scaled[key] = true
                        c[max] = math.floor(c[max] * factor + 0.5)
                        c[cur] = math.floor(c[cur] * factor + 0.5)
                    end
                end
                local state = {}
                for _, name in ipairs(fields) do state[#state + 1] = name .. "=" .. tostring(c[name]) end
                local bar, barProperty = bossBarOf(c)
                if bar then
                    local shown = bar:IsInViewport()
                    state[#state + 1] = "ui=" .. (shown and 1 or 0)
                    -- the boss code creates its bar only where the fight started: on the host
                    local cls = U.path(bar:GetClass())
                    if shown and lastBar[key] ~= cls then
                        lastBar[key] = cls
                        Net.broadcast(nil, "EBAR", ref, cls, barProperty)
                    end
                end
                state = table.concat(state, ";")
                if lastHealth[key] ~= state then
                    lastHealth[key] = state
                    Net.broadcast(nil, "EH", ref, state)
                end
            end
            local mesh = c.Mesh
            local anim = U.valid(mesh) and mesh:GetAnimInstance()
            if U.valid(anim) then
                -- sent again while it plays: a client that missed the start (or finished early) would stand in the
                -- rest pose, and bosses such as Fara animate almost only through montages
                local m = anim:GetCurrentActiveMontage()
                local path = U.valid(m) and U.path(m) or nil
                local last = lastEnemyMontage[key]
                local now = os.clock()
                if path ~= (last and last.path) or (path and now - last.at >= MONTAGE_RESEND_SECONDS) then
                    lastEnemyMontage[key] = { path = path, at = now }
                    if path then
                        Net.broadcast(nil, "EM", ref, path, string.format("%.2f", anim:Montage_GetPosition(m)))
                    end
                end
            end
        end
    end
    hostMasterTick(factor)
    syncArenas()
end

local function onEnemyHealth(fields)
    local enemy = Enemies.resolve(fields[1])
    if not enemy then return end
    local barShown = nil
    for name, value in (fields[2] or ""):gmatch("([^=;]+)=(-?%d+)") do
        if name == "ui" then
            barShown = value == "1"
        else
            pcall(function() enemy[name] = tonumber(value) end)
        end
    end
    local healthFields = healthFieldsOf(enemy)
    if healthFields then pcall(refreshHealthDisplay, fields[1], enemy, healthFields) end
    -- the boss code that takes its bar off the screen only runs on the host
    local bar = bossBarOf(enemy)
    if bar and barShown == false and bar:IsInViewport() then bar:RemoveFromParent() end
end

-- Clients: put up the boss bar the host has on screen.
local function onBossBar(fields)
    local enemy = Enemies.resolve(fields[1])
    local pc = U.localPC()
    if not enemy or not pc or propertyWidget(enemy, fields[3]) then return end
    local cls = StaticFindObject(fields[2])
    if not U.valid(cls) then cls = LoadAsset(fields[2]) end
    if not U.valid(cls) then return end
    local bar = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
    if not U.valid(bar) then return end
    enemy[fields[3]] = bar
    bar:AddToViewport(0)
    local healthFields = healthFieldsOf(enemy)
    if healthFields then pcall(refreshHealthDisplay, fields[1], enemy, healthFields) end
end

-- Clients: boss bars of bosses that are gone.
local function clearBossBars()
    for ref, bar in pairs(bossBars) do
        if not Enemies.resolve(ref) then
            if U.valid(bar) and bar:IsInViewport() then bar:RemoveFromParent() end
            bossBars[ref] = nil
        end
    end
end

local function onMasterHealth(fields)
    if not U.isClient() then return end
    local m = StaticFindObject(fields[1])
    local cur, max = tonumber(fields[2]), tonumber(fields[3])
    if not U.valid(m) or not cur or not max then return end
    m.HealthMax = max
    if cur < m.HealthCurrent then
        m.HealthCurrent = cur + 1
        m:DecrementHealth()
    else
        m.HealthCurrent = cur
        pcall(function() m.RapetoHUD:UpdateHealth(cur, max) end)
    end
end

local function onEnemyMontage(fields)
    local enemy = Enemies.resolve(fields[1])
    if not enemy then return end
    local montage = StaticFindObject(fields[2])
    if not U.valid(montage) then montage = LoadAsset(fields[2]) end
    local anim = U.valid(enemy.Mesh) and enemy.Mesh:GetAnimInstance()
    if not U.valid(montage) or not U.valid(anim) then return end
    local position = tonumber(fields[3]) or 0
    local current = anim:GetCurrentActiveMontage()
    if not U.valid(current) or current:GetAddress() ~= montage:GetAddress() then
        anim:Montage_Play(montage, 1.0, 0, position, true)
    elseif math.abs(anim:Montage_GetPosition(montage) - position) > MONTAGE_TOLERANCE then
        anim:Montage_SetPosition(montage, position)
    end
end

-- Class-dependent hooks can only be registered once the class is loaded; retry until they are.
local managerHookDone = false
local function lateHooks()
    if not playerHookDone and U.valid(StaticFindObject(KALAKELY_DMG)) then
        RegisterHook(KALAKELY_DMG, onPlayerDamaged)
        playerHookDone = true
    end
    local trigger = ENEMY_MANAGER .. ":" .. MANAGER_TRIGGER_EVENT
    if not managerHookDone and U.valid(StaticFindObject(trigger)) then
        RegisterHook(trigger, onManagerTriggered)
        managerHookDone = true
    end
    local chars = FindAllOf("Character")
    for _, c in ipairs(chars or {}) do
        if c:IsValid() and isEnemy(c) then
            Hooks.watch(c, "DMGMelee")
            for _, fn in ipairs(ABILITY_CALLS) do Hooks.watch(c, fn) end
        end
    end
end

Combat.isEnemy = isEnemy

-- An enemy that fights (villagers, spectators and AI helper pawns are replicated pawns too).
local ENEMY_COMBAT_INTERFACE = "/Game/BlueprintInterfaces/BPI_EnemyCombat.BPI_EnemyCombat_C"
function Combat.isHostile(actor)
    if not isEnemy(actor) then return false end
    local iface = StaticFindObject(ENEMY_COMBAT_INTERFACE)
    return U.valid(iface) and U.ksl():DoesImplementInterface(actor, iface)
end

-- Host: a client (re)loaded the level; its copies start from the level's values, so send every state again.
function Combat.resendState()
    lastHealth, lastMasterHealth, lastBar, lastEnemyMontage = {}, {}, {}, {}
end

function Combat.onMapChanged()
    scaled, lastHealth, lastEnemyMontage, startedManagers, wallState, simulated = {}, {}, {}, {}, {}, {}
    scaledMasters, lastMasterHealth, bossBars, lastBar = {}, {}, {}, {}
    Enemies.reset()
end

function Combat.init()
    Net.on("HIT", onHit)
    Net.on("HURT", onHurt)
    Net.on("FIGHT", onFightRequest)
    Net.on("ARENA", onArena)
    Net.on("EH", onEnemyHealth)
    Net.on("BM", onMasterHealth)
    Net.on("EBAR", onBossBar)
    Net.on("EM", onEnemyMontage)
    Hooks.on("DMGMelee", onEnemyDamaged)
    for _, fn in ipairs(ABILITY_CALLS) do Hooks.on(fn, abilityListener(fn)) end
    Net.on("EABL", onAbility)
    RegisterHook("/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass", blockClientPawnSpawn)
    RegisterHook("/Script/AIModule.AIBlueprintHelperLibrary:SpawnAIFromClass", blockClientPawnSpawn)
    RegisterHook("/Script/Engine.GameplayStatics:FinishSpawningActor", onFinishSpawning)
    Enemies.init()
    LoopInGameThreadWithDelay(1000, function()
        if not U.isOnline() then return end
        if U.isClient() then
            pcall(Enemies.tick)
            pcall(clearBossBars)
        end
        local ok, err = pcall(lateHooks)
        if not ok then Log.error("combat hooks: %s", tostring(err)) end
    end)
    LoopInGameThreadWithDelay(250, function()
        if not U.isHost() then return end
        local ok, err = pcall(hostTick)
        if not ok then Log.error("combat host tick: %s", tostring(err)) end
    end)
end

return Combat
