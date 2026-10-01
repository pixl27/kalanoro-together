local U = {}

local ksl, gameplayStatics

function U.ksl()
    if not ksl or not ksl:IsValid() then
        ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    end
    return ksl
end

function U.statics()
    if not gameplayStatics or not gameplayStatics:IsValid() then
        gameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end
    return gameplayStatics
end

function U.valid(obj)
    return obj ~= nil and obj.IsValid ~= nil and obj:IsValid()
end

-- The locally controlled player controller of the current world, or nil.
function U.localPC()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in ipairs(pcs) do
        if pc:IsValid() and pc:IsLocalController() and U.valid(pc.Player) then
            return pc
        end
    end
    return nil
end

function U.localPawn()
    local pc = U.localPC()
    if pc and U.valid(pc.Pawn) then return pc.Pawn end
    return nil
end

-- "standalone" | "host" | "client" | nil (no world yet)
function U.netMode()
    local pc = U.localPC()
    if not pc then return nil end
    local k = U.ksl()
    if k:IsStandalone(pc) then return "standalone" end
    if k:IsServer(pc) then return "host" end
    return "client"
end

-- Net mode refreshed a few times per second (U.refreshMode from main.lua), cheap to read from hot hooks.
U.cachedMode = nil

function U.refreshMode()
    U.cachedMode = U.netMode()
    return U.cachedMode
end

function U.isHost() return U.cachedMode == "host" end
function U.isClient() return U.cachedMode == "client" end
function U.isOnline()
    return U.cachedMode == "host" or U.cachedMode == "client"
end

-- Object path without the class prefix, e.g. "/Game/Map.Map:PersistentLevel.BPA_Gem8".
function U.path(obj)
    local full = obj:GetFullName()
    return full:match("^%S+%s+(.+)$") or full
end

-- Package path of the current map, e.g. "/Game/Levels/World1_AlaCoast/PrologueHabillage_Current".
function U.currentMap()
    local pc = U.localPC()
    if not pc then return nil end
    local worldPath = U.path(pc:GetWorld())
    return worldPath:match("^([^%.]+)")
end

-- Stable network id for a player pawn (its PlayerState.PlayerId), or nil.
function U.pawnId(pawn)
    if not U.valid(pawn) then return nil end
    local ps = pawn.PlayerState
    if not U.valid(ps) then return nil end
    return ps.PlayerId
end

function U.findPawnById(id)
    local chars = FindAllOf("Character")
    if not chars then return nil end
    for _, c in ipairs(chars) do
        if c:IsValid() and U.pawnId(c) == id then return c end
    end
    return nil
end

-- Player controllers of connected clients (server side only; excludes the host's own controller).
function U.remotePCs()
    local out = {}
    local pcs = FindAllOf("PlayerController")
    if not pcs then return out end
    for _, pc in ipairs(pcs) do
        if pc:IsValid() and not pc:IsLocalController() and U.valid(pc.Player) then
            out[#out + 1] = pc
        end
    end
    return out
end

-- Is `origin` (an attacker/instigator) the local player's character or something it owns (a projectile...)?
function U.fromLocalPlayer(origin)
    local pawn = U.localPawn()
    if not pawn or not U.valid(origin) then return false end
    local addr = pawn:GetAddress()
    if origin:GetAddress() == addr then return true end
    local owner = origin:GetOwner()
    if U.valid(owner) and owner:GetAddress() == addr then return true end
    local inst = origin.Instigator
    return U.valid(inst) and inst:GetAddress() == addr
end

function U.playerName(pc)
    local ps = U.valid(pc) and pc.PlayerState
    if U.valid(ps) then
        local ok, name = pcall(function() return ps:GetPlayerName():ToString() end)
        if ok and name and name ~= "" then return name end
        return "Player " .. tostring(ps.PlayerId)
    end
    return "Player"
end

-- A colour per player, the same on every machine (PlayerIds are replicated), for name tags and pings.
local PLAYER_COLORS = { -- (the game's text material brightens colours: these read as gold, blue, pink, green)
    { R = 255, G = 120, B = 0, A = 255 },
    { R = 0, G = 95, B = 255, A = 255 },
    { R = 255, G = 25, B = 115, A = 255 },
    { R = 45, G = 200, B = 20, A = 255 },
}

function U.playerColor(id)
    return PLAYER_COLORS[(tonumber(id) or 0) % #PLAYER_COLORS + 1]
end

-- Rotation that turns text at `from` to face a camera at `to` (the game's camera looks down steeply: turning
-- only around the vertical axis leaves the text foreshortened, as if lying on the ground).
function U.facing(from, to)
    local dx, dy, dz = to.X - from.X, to.Y - from.Y, to.Z - from.Z
    return { Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }
end

function U.distance(a, b)
    return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2)
end

return U
