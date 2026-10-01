-- Kalanoro online co-op (UE4SS Lua mod).
local Log = require("coop.log")
local Config = require("coop.config")
local U = require("coop.util")
local Net = require("coop.net")
local Session = require("coop.session")
local Perspective = require("coop.perspective")
local Players = require("coop.players")
local World = require("coop.world")
local Combat = require("coop.combat")
local Teamplay = require("coop.teamplay")
local Signals = require("coop.signals")
local Movers = require("coop.movers")
local Progress = require("coop.progress")

Config.load()
Net.init()
Session.init()
Perspective.init()
Players.init()
World.init()
Combat.init()
Teamplay.init()
Signals.init()
Movers.init()
Progress.init()
Session.onClientReady(World.sendSnapshot)
Session.onClientReady(require("coop.enemies").sendAll)
Session.onClientReady(Movers.sendAll)
Session.onClientReady(Combat.resendState)
Session.onClientReady(Progress.sendTo)

-- A new world instance (also when the same map is reloaded by a restart) resets per-level state.
local lastWorld = nil
LoopInGameThreadWithDelay(250, function()
    local ok, err = pcall(function()
        U.refreshMode()
        local pc = U.localPC()
        local world = pc and pc:GetWorld():GetAddress()
        if world and world ~= lastWorld then
            lastWorld = world
            Combat.onMapChanged()
            Teamplay.onMapChanged()
            Signals.onMapChanged()
            Movers.onMapChanged()
            Progress.onMapChanged()
        end
    end)
    if not ok then Log.error("main tick: %s", tostring(err)) end
end)

local function bindKey(name, fn)
    local key = Key[name]
    if not key then
        Log.error("unknown key '%s' in config.ini", tostring(name))
        return
    end
    RegisterKeyBind(key, function()
        ExecuteInGameThread(fn)
    end)
end

bindKey(Config.HostKey, Session.host)
bindKey(Config.JoinKey, function() Session.join() end)
bindKey(Config.LeaveKey, Session.leave)
bindKey(Config.TeleportKey, Teamplay.teleportToPartner)
bindKey(Config.PingKey, Signals.ping)

-- Console (open with F10 or ~):  coop host | coop join <ip[:port]> | coop leave | coop status | coop tp | coop ping
RegisterConsoleCommandHandler("coop", function(_, params, ar)
    local sub = (params[1] or ""):lower()
    local address = params[2]
    local actions = {
        host = Session.host,
        join = function() Session.join(address) end,
        leave = Session.leave,
        status = Session.status,
        tp = Teamplay.teleportToPartner,
        ping = Signals.ping,
    }
    local action = actions[sub]
    if action then
        -- run after the console handler returns: joining or hosting changes the level, which fires hooks
        ExecuteInGameThread(function()
            local ok, err = pcall(action)
            if not ok then Log.error("coop %s: %s", sub, tostring(err)) end
        end)
    else
        ar:Log("usage: coop host | coop join <ip[:port]> | coop leave | coop status | coop tp | coop ping")
    end
    return true
end)

Log.info("loaded (host %s, join %s, leave %s, teleport %s, ping %s)", Config.HostKey, Config.JoinKey, Config.LeaveKey,
    Config.TeleportKey, Config.PingKey)
