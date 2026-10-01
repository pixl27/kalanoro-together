-- Message channel built on engine RPCs that already exist in the shipping build:
--   client -> host : APlayerController::ServerExecRPC(FString)   (no-op in shipping, we hook its receipt)
--   host -> client : APlayerController::ClientMessage(FString, FName, float)
-- Messages are "KC1|<kind>|<field>|<field>..." with '%', '|' and newlines percent-escaped.
local U = require("coop.util")
local Log = require("coop.log")

local Net = {}

local PREFIX = "KC1"
local handlers = {}

local function esc(v)
    return (tostring(v):gsub("[%%|\r\n]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function unesc(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function encode(kind, ...)
    local parts = { PREFIX, kind }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = esc(select(i, ...))
    end
    return table.concat(parts, "|")
end

local function decode(msg)
    if msg:sub(1, #PREFIX + 1) ~= PREFIX .. "|" then return nil end
    local fields = {}
    for part in (msg .. "|"):gmatch("(.-)|") do
        fields[#fields + 1] = unesc(part)
    end
    table.remove(fields, 1)
    local kind = table.remove(fields, 1)
    return kind, fields
end

-- handler(fields, senderPC): senderPC is the client's controller when received on the host, nil on clients.
function Net.on(kind, handler)
    handlers[kind] = handler
end

local function dispatch(kind, fields, sender)
    Log.debug("recv %s %s", kind, table.concat(fields, " "))
    local h = handlers[kind]
    if not h then
        Log.debug("no handler for %s", kind)
        return
    end
    local ok, err = pcall(h, fields, sender)
    if not ok then Log.error("handler %s failed: %s", kind, tostring(err)) end
end

function Net.toHost(kind, ...)
    local pc = U.localPC()
    if not pc then return end
    Log.debug("to host %s", kind)
    pc:ServerExecRPC(encode(kind, ...))
end

function Net.toClient(pc, kind, ...)
    if U.valid(pc) then
        pc:ClientMessage(encode(kind, ...), FName("KC"), 0.0)
    end
end

-- Host only: send to every connected client except `except` (a PlayerController or nil).
function Net.broadcast(except, kind, ...)
    local msg = encode(kind, ...)
    Log.debug("broadcast %s", kind)
    for _, pc in ipairs(U.remotePCs()) do
        if except == nil or pc:GetAddress() ~= except:GetAddress() then
            pc:ClientMessage(msg, FName("KC"), 0.0)
        end
    end
end

-- A message received from the network: the host passes it on to everyone except its sender; clients never
-- re-send what they received (the host already delivered it to everybody).
function Net.forward(sender, kind, ...)
    if U.isHost() then Net.broadcast(sender, kind, ...) end
end

-- Send to everyone else in the session, from whichever side we are on.
function Net.toOthers(kind, ...)
    if U.isHost() then
        Net.broadcast(nil, kind, ...)
    elseif U.isClient() then
        Net.toHost(kind, ...)
    end
end

function Net.init()
    RegisterHook("/Script/Engine.PlayerController:ServerExecRPC", function(self, msg)
        local text = msg:get():ToString()
        local kind, fields = decode(text)
        if kind then dispatch(kind, fields, self:get()) end
    end)
    RegisterHook("/Script/Engine.PlayerController:ClientMessage", function(self, s)
        local text = s:get():ToString()
        local kind, fields = decode(text)
        if kind then dispatch(kind, fields, nil) end
    end)
end

return Net
