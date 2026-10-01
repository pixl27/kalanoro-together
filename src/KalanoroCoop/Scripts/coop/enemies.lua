-- Shared identities for enemies. Replicated enemies have different object names on every machine, so the host
-- numbers each one and tells the clients once; clients bind the number to their copy (the instance of that class
-- nearest to where the host saw it). Afterwards hits, health and animations refer to "#<id>", with
-- "<class>@<x,y,z>" (nearest match) only as a fallback before the binding exists.
local U = require("coop.util")
local Net = require("coop.net")

local Enemies = {}

local nextId = 1
local idByKey = {}    -- host: enemy name -> id
local byId = {}       -- id -> enemy object (host: the real enemy; client: its local copy)
local idByAddr = {}   -- client: object address -> id
local pending = {}    -- client: id -> { cls, loc } announced before our copy of the enemy arrived

local function className(obj)
    return obj:GetClass():GetFName():ToString()
end

local function fmtLoc(l)
    return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z)
end

local function parseLoc(s)
    local x, y, z = (s or ""):match("^(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+)$")
    return { X = tonumber(x) or 0, Y = tonumber(y) or 0, Z = tonumber(z) or 0 }
end

local function nearestOfClass(cls, loc, radius, skipBound)
    local best, bestD = nil, radius * radius
    for _, a in ipairs(FindAllOf(cls) or {}) do
        if a:IsValid() and not a.bActorIsBeingDestroyed and not (skipBound and idByAddr[a:GetAddress()]) then
            local l = a:K2_GetActorLocation()
            local d = (l.X - loc.X) ^ 2 + (l.Y - loc.Y) ^ 2 + (l.Z - loc.Z) ^ 2
            if d < bestD then best, bestD = a, d end
        end
    end
    return best
end

local function alive(obj)
    return obj ~= nil and obj:IsValid() and not obj.bActorIsBeingDestroyed
end

-- Host: the id of an enemy, announcing new ones to the clients.
function Enemies.register(enemy)
    local key = enemy:GetFName():ToString()
    local id = idByKey[key]
    if id then return id end
    id = nextId
    nextId = nextId + 1
    idByKey[key] = id
    byId[id] = enemy
    Net.broadcast(nil, "EID", id, className(enemy), fmtLoc(enemy:K2_GetActorLocation()))
    return id
end

-- How to name `enemy` in a message to the other side.
function Enemies.ref(enemy)
    local id
    if U.isHost() then
        id = Enemies.register(enemy)
    else
        id = idByAddr[enemy:GetAddress()]
    end
    if id then return "#" .. id end
    return className(enemy) .. "@" .. fmtLoc(enemy:K2_GetActorLocation())
end

-- The local object a reference from the other side points at, or nil.
function Enemies.resolve(ref)
    local id = tonumber((ref or ""):match("^#(%d+)$"))
    if id then
        local e = byId[id]
        if alive(e) then return e end
        return nil
    end
    local cls, loc = (ref or ""):match("^(.-)@(.+)$")
    if not cls then return nil end
    return nearestOfClass(cls, parseLoc(loc), 600, false)
end

local function bind(id, cls, loc)
    local e = nearestOfClass(cls, loc, 1500, true)
    if not e then return false end
    byId[id] = e
    idByAddr[e:GetAddress()] = id
    return true
end

local function onEnemyId(fields)
    local id = tonumber(fields[1])
    if not id or alive(byId[id]) then return end
    local loc = parseLoc(fields[3])
    if not bind(id, fields[2], loc) then pending[id] = { cls = fields[2], loc = loc } end
end

-- Client: bind enemies that were announced before they replicated.
function Enemies.tick()
    for id, p in pairs(pending) do
        if alive(byId[id]) or bind(id, p.cls, p.loc) then pending[id] = nil end
    end
end

-- Host: tell a client that just loaded the level about every enemy alive.
function Enemies.sendAll(pc)
    for id, e in pairs(byId) do
        if alive(e) then Net.toClient(pc, "EID", id, className(e), fmtLoc(e:K2_GetActorLocation())) end
    end
end

function Enemies.reset()
    nextId, idByKey, byId, idByAddr, pending = 1, {}, {}, {}, {}
end

function Enemies.init()
    Net.on("EID", onEnemyId)
end

return Enemies
