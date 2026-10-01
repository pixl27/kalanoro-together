-- Blueprint functions such as DMGMelee or Interact are implemented separately by many actor classes, and a
-- hook can only be registered once the class is loaded. This registry hooks each implementation the first time
-- an actor of that class is seen and fans the call out to every listener for that function name.
local U = require("coop.util")
local Log = require("coop.log")

local Hooks = {}

local listeners = {}   -- function name -> { fn(self, ...) }
local hooked = {}      -- UFunction path -> true
local seenClasses = {} -- class address .. function name -> true

function Hooks.on(fnName, listener)
    listeners[fnName] = listeners[fnName] or {}
    table.insert(listeners[fnName], listener)
end

local function findFunction(cls, fnName)
    while U.valid(cls) do
        local found
        cls:ForEachFunction(function(fn)
            if not found and fn:GetFName():ToString() == fnName then found = fn end
        end)
        if found then return found end
        cls = cls:GetSuperStruct()
    end
    return nil
end

-- Make sure every listener registered for fnName receives calls made on `actor`'s class.
function Hooks.watch(actor, fnName)
    local cls = actor:GetClass()
    local key = tostring(cls:GetAddress()) .. fnName
    if seenClasses[key] then return end
    seenClasses[key] = true
    local fn = findFunction(cls, fnName)
    if not fn then return end
    local path = U.path(fn)
    if hooked[path] then return end
    hooked[path] = true
    RegisterHook(path, function(self, ...)
        for _, l in ipairs(listeners[fnName] or {}) do
            local ok, err = pcall(l, self, ...)
            if not ok then Log.error("%s listener: %s", fnName, tostring(err)) end
        end
    end)
    Log.debug("hooked %s", path)
end

return Hooks
