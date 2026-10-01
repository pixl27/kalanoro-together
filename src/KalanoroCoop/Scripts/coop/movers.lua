-- Moving platforms and traps run on every machine, driven by Blueprint chains of timelines and delays that each
-- machine starts when it loads the level: the same platform is at a different point of its cycle for each player
-- (spikes out on the host hurt a client who sees them retracted). The host's movers lead:
--   * each time a mover timeline starts, reverses or stops on the host, clients do the same; a client's own chain
--     is held back (its timeline calls are undone), so it only advances on the host's "finished" events;
--   * once a second the host sends where its moving timelines and rotating parts are, and clients that drifted
--     out of tolerance are corrected.
local U = require("coop.util")
local Log = require("coop.log")
local Net = require("coop.net")

local Movers = {}

-- Level actors whose timelines / rotating movement move things players stand on or must dodge.
local MOVER_PATTERNS = { "Platform", "Mover", "Moving", "Rotating", "Swing", "Elevator", "Flip", "Spike", "Trap",
    "Wheel", "Wooden_Board", "Vynil", "Aponga", "Cylinder", "Flying" }
-- Moved by a player's own ability, which only runs on that player's machine: the host's copy would undo it.
local EXCLUDED_PATTERNS = { "Pull", "Surf" }
local SEND_SECONDS = 1.0
local FULL_REFRESH_SECONDS = 10  -- resend resting movers too, in case a message was missed
local TIME_TOLERANCE = 0.12      -- seconds of timeline
local ANGLE_TOLERANCE = 4        -- degrees
local MAX_MESSAGE = 1400         -- characters per batch message

local TIMELINE_OPS = { "PlayFromStart", "Play", "Reverse", "ReverseFromEnd", "Stop" }

local lastSent = {}    -- host: mover path -> state string
local lastFull = 0
local byPath = {}      -- client: path -> actor (cache)
local compsOf = {}     -- client: actor address -> component name -> timeline / rotating movement (cache)
local ownerOf = {}     -- timeline address -> its mover actor, or false
local applying = false -- client: replaying a host event (not the level's own chain)
local pending = nil    -- client: timeline state before a call made by the level's own chain

local function matchesAny(name, patterns)
    for _, p in ipairs(patterns) do
        if name:find(p, 1, true) then return true end
    end
    return false
end

-- (FindAllOf also returns components of the previous level until they are garbage collected: pass the current
-- world to leave those out.)
local function isMover(actor, world)
    if not U.valid(actor) or actor.bReplicates or actor.bActorIsBeingDestroyed then return false end
    local cls = actor:GetClass():GetFName():ToString()
    if not matchesAny(cls, MOVER_PATTERNS) or matchesAny(cls, EXCLUDED_PATTERNS) then return false end
    if not world then return true end
    local w = actor:GetWorld()
    return U.valid(w) and w:GetAddress() == world
end

local function moverOf(tl)
    local key = tl:GetAddress()
    local owner = ownerOf[key]
    if owner == nil then
        owner = tl:GetOwner()
        if not isMover(owner) then owner = false end
        ownerOf[key] = owner
    end
    return owner
end

-- actor address -> { actor, timelines = {}, rotators = {} } for every mover in the world
local function collect()
    local out = {}
    local pc = U.localPC()
    if not pc then return out end
    local world = pc:GetWorld():GetAddress()
    local function entry(owner)
        local key = owner:GetAddress()
        out[key] = out[key] or { actor = owner, timelines = {}, rotators = {} }
        return out[key]
    end
    for _, tl in ipairs(FindAllOf("TimelineComponent") or {}) do
        local owner = tl:IsValid() and tl:GetOwner()
        if isMover(owner, world) then table.insert(entry(owner).timelines, tl) end
    end
    for _, rm in ipairs(FindAllOf("RotatingMovementComponent") or {}) do
        local owner = rm:IsValid() and rm:GetOwner()
        if isMover(owner, world) and U.valid(rm.UpdatedComponent) then table.insert(entry(owner).rotators, rm) end
    end
    return out
end

---------------------------------------------------------------- host

local function timelineState(tl)
    local flag = "-"
    if tl:IsPlaying() then flag = tl:IsReversing() and "r" or "p" end
    return string.format("%s:%.3f:%s", tl:GetFName():ToString(), tl:GetPlaybackPosition(), flag)
end

local function rotatorState(rm)
    local r = rm.UpdatedComponent.RelativeRotation
    return string.format("%s:%.1f:%.1f:%.1f", rm:GetFName():ToString(), r.Pitch, r.Yaw, r.Roll)
end

local function moverState(m)
    local tls, rots, moving = {}, {}, #m.rotators > 0
    for _, tl in ipairs(m.timelines) do
        tls[#tls + 1] = timelineState(tl)
        if tl:IsPlaying() then moving = true end
    end
    for _, rm in ipairs(m.rotators) do rots[#rots + 1] = rotatorState(rm) end
    return table.concat(tls, ","), table.concat(rots, ","), moving
end

local function sendBatches(send, entries)
    local batch, size = {}, 0
    for _, e in ipairs(entries) do
        batch[#batch + 1], batch[#batch + 2], batch[#batch + 3] = e[1], e[2], e[3]
        size = size + #e[1] + #e[2] + #e[3]
        if size >= MAX_MESSAGE then
            send(batch)
            batch, size = {}, 0
        end
    end
    if #batch > 0 then send(batch) end
end

local function hostTick()
    if #U.remotePCs() == 0 then return end
    local full = os.clock() - lastFull >= FULL_REFRESH_SECONDS
    if full then lastFull = os.clock() end
    local entries = {}
    for _, m in pairs(collect()) do
        local path = U.path(m.actor)
        local tls, rots, moving = moverState(m)
        local state = tls .. "|" .. rots
        if moving or full or lastSent[path] ~= state then
            lastSent[path] = state
            entries[#entries + 1] = { path, tls, rots }
        end
    end
    sendBatches(function(batch) Net.broadcast(nil, "MV", table.unpack(batch)) end, entries)
end

-- Host: a mover timeline started, reversed or stopped.
local function onHostTimelineOp(tl, op)
    local owner = moverOf(tl)
    if not owner or #U.remotePCs() == 0 then return end
    Net.broadcast(nil, "MVE", U.path(owner), tl:GetFName():ToString(), op)
end

-- Host: the state of every mover for a client that just loaded the level.
function Movers.sendAll(pc)
    local entries = {}
    for _, m in pairs(collect()) do
        local tls, rots = moverState(m)
        entries[#entries + 1] = { U.path(m.actor), tls, rots }
    end
    sendBatches(function(batch) Net.toClient(pc, "MV", table.unpack(batch)) end, entries)
end

---------------------------------------------------------------- client

-- Half the round trip: how old the host's numbers are when they arrive.
local function latency()
    local pc = U.localPC()
    local ok, ms = pcall(function() return pc.PlayerState:GetPingInMilliseconds() end)
    if ok and type(ms) == "number" then return ms / 2000 end
    return 0
end

local function components(actor)
    local key = actor:GetAddress()
    if compsOf[key] then return compsOf[key] end
    local out = {}
    for _, cls in ipairs({ "/Script/Engine.TimelineComponent", "/Script/Engine.RotatingMovementComponent" }) do
        local ok, list = pcall(function() return actor:K2_GetComponentsByClass(StaticFindObject(cls)) end)
        if ok and list then
            for i = 1, #list do
                local c = list[i]
                if c and c.get then c = c:get() end
                if U.valid(c) then out[c:GetFName():ToString()] = c end
            end
        end
    end
    compsOf[key] = out
    return out
end

-- Starting and stopping come as events; this only corrects where a timeline is, when both machines agree on
-- what it is doing.
local function applyTimeline(tl, pos, flag, lag)
    local playing, reversing = flag ~= "-", flag == "r"
    if playing ~= tl:IsPlaying() or (playing and reversing ~= tl:IsReversing()) then return end
    local dir = reversing and -1 or 1
    if playing then pos = pos + lag * tl:GetPlayRate() * dir end
    local len = tl:GetTimelineLength()
    local looping = tl:IsLooping() and len > 0
    if looping then pos = pos % len end
    local current = tl:GetPlaybackPosition()
    local diff = math.abs(current - pos)
    if looping then diff = math.min(diff, len - diff) end
    if diff > TIME_TOLERANCE then
        Log.debug("mover %s.%s off by %.2fs", tl:GetOwner():GetFName():ToString(), tl:GetFName():ToString(), diff)
        -- jumping ahead passes over event keys (e.g. a trap's damage switching on): fire them
        tl:SetPlaybackPosition(pos, playing and not looping and (pos - current) * dir > 0, true)
    end
end

local function angleDiff(a, b)
    return math.abs((a - b + 180) % 360 - 180)
end

local function applyRotator(rm, pitch, yaw, roll, lag)
    local rate = rm.RotationRate
    local target = { Pitch = pitch + rate.Pitch * lag, Yaw = yaw + rate.Yaw * lag, Roll = roll + rate.Roll * lag }
    local comp = rm.UpdatedComponent
    local r = comp.RelativeRotation
    if angleDiff(r.Pitch, target.Pitch) > ANGLE_TOLERANCE or angleDiff(r.Yaw, target.Yaw) > ANGLE_TOLERANCE
        or angleDiff(r.Roll, target.Roll) > ANGLE_TOLERANCE then
        Log.debug("rotator %s off by %.0f deg", rm:GetOwner():GetFName():ToString(), angleDiff(r.Yaw, target.Yaw))
        comp:K2_SetRelativeRotation(target, false, {}, true)
    end
end

local function findActor(path)
    local actor = byPath[path]
    if not U.valid(actor) then
        actor = StaticFindObject(path)
        if not U.valid(actor) then return nil end
        byPath[path] = actor
    end
    return actor
end

local function applyMover(path, tls, rots, lag)
    local actor = findActor(path)
    if not actor then return end
    local comps = components(actor)
    for name, pos, flag in tls:gmatch("([^:,]+):(-?[%d%.]+):([%-pr])") do
        local tl = comps[name]
        if tl then applyTimeline(tl, tonumber(pos), flag, lag) end
    end
    for name, p, y, r in rots:gmatch("([^:,]+):(-?[%d%.]+):(-?[%d%.]+):(-?[%d%.]+)") do
        local rm = comps[name]
        if rm and U.valid(rm.UpdatedComponent) then applyRotator(rm, tonumber(p), tonumber(y), tonumber(r), lag) end
    end
end

-- Client: the host's mover timeline started, reversed or stopped.
local function onTimelineEvent(fields)
    if not U.isClient() then return end
    local actor = findActor(fields[1])
    local tl = actor and components(actor)[fields[2]]
    local op = fields[3]
    if not tl or not tl[op] then return end
    applying = true
    local ok, err = pcall(function()
        tl[op](tl)
        if op ~= "Stop" then
            local lag = latency() * tl:GetPlayRate() * (tl:IsReversing() and -1 or 1)
            if lag ~= 0 then tl:SetPlaybackPosition(tl:GetPlaybackPosition() + lag, false, true) end
        end
    end)
    applying = false
    if not ok then Log.error("mover event %s.%s: %s", fields[1], op, tostring(err)) end
end

-- Client: a timeline call made by the level's own chain on a mover is undone (the timeline keeps doing what the
-- host told it), which holds the chain until the host's timeline finishes.
local function beforeTimelineOp(tl)
    if applying or not moverOf(tl) then return end
    pending = { key = tl:GetAddress(), pos = tl:GetPlaybackPosition(), playing = tl:IsPlaying(),
        reversing = tl:IsReversing() }
end

local function undoTimelineOp(tl)
    local before = pending
    pending = nil
    if not before or before.key ~= tl:GetAddress() then return end
    applying = true
    pcall(function()
        tl:SetPlaybackPosition(before.pos, false, true)
        if not before.playing then
            tl:Stop()
        elseif before.reversing then
            tl:Reverse()
        else
            tl:Play()
        end
    end)
    applying = false
end

local function hookTimelineOps()
    for _, op in ipairs(TIMELINE_OPS) do
        RegisterHook("/Script/Engine.TimelineComponent:" .. op, function(self)
            if not U.isClient() then return end
            local ok, err = pcall(beforeTimelineOp, self:get())
            if not ok then Log.error("timeline %s: %s", op, tostring(err)) end
        end, function(self)
            local mode = U.cachedMode
            if mode ~= "host" and mode ~= "client" then return end
            local ok, err = pcall(function()
                local tl = self:get()
                if mode == "host" then onHostTimelineOp(tl, op) else undoTimelineOp(tl) end
            end)
            if not ok then Log.error("timeline %s: %s", op, tostring(err)) end
        end)
    end
end

local function onMovers(fields)
    if not U.isClient() then return end
    local lag = latency()
    for i = 1, #fields - 2, 3 do
        local ok, err = pcall(applyMover, fields[i], fields[i + 1], fields[i + 2], lag)
        if not ok then Log.error("mover %s: %s", fields[i], tostring(err)) end
    end
end

---------------------------------------------------------------- setup

function Movers.onMapChanged()
    lastSent, byPath, compsOf, ownerOf, lastFull, pending = {}, {}, {}, {}, 0, nil
end

function Movers.init()
    Net.on("MV", onMovers)
    Net.on("MVE", onTimelineEvent)
    hookTimelineOps()
    LoopInGameThreadWithDelay(math.floor(SEND_SECONDS * 1000), function()
        if not U.isHost() then return end
        local ok, err = pcall(hostTick)
        if not ok then Log.error("movers tick: %s", tostring(err)) end
    end)
end

return Movers
