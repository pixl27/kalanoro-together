-- Co-op state shared between modules: whether each player (by PlayerId) is up, down (revivable) or out
-- (bled out / on the death screen).
local State = {}

local status = {} -- PlayerId -> "down" | "out"; absent = up

function State.set(id, value)
    if id ~= nil then status[id] = value end
end

function State.get(id)
    return id ~= nil and status[id] or nil
end

function State.isDowned(id)
    return id ~= nil and status[id] == "down"
end

function State.isStanding(id)
    return id ~= nil and status[id] == nil
end

function State.anyStanding(ids)
    for _, id in ipairs(ids) do
        if status[id] == nil then return true end
    end
    return false
end

function State.reset()
    status = {}
end

return State
