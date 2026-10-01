-- Loads <mod>/config.ini (simple key = value lines, ';' or '#' comments).
local Log = require("coop.log")

local Config = {
    JoinAddress = "127.0.0.1",
    PlayerName = "",
    HostKey = "F5",
    JoinKey = "F6",
    LeaveKey = "F7",
    TeleportKey = "F8",
    PingKey = "MIDDLE_MOUSE_BUTTON",
    ClientsCanChangeLevel = false,
    FollowHostProgress = true,
    Debug = false,
}

local function modDir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return (src:gsub("[/\\]Scripts[/\\]coop[/\\]config%.lua$", ""))
end

local function coerce(old, raw)
    if type(old) == "number" then
        return tonumber(raw) or old
    elseif type(old) == "boolean" then
        local l = raw:lower()
        if l == "true" or l == "1" or l == "yes" then return true end
        if l == "false" or l == "0" or l == "no" then return false end
        return old
    end
    return raw
end

function Config.load()
    Config.ModDir = modDir()
    local path = Config.ModDir .. "\\config.ini"
    local f = io.open(path, "r")
    if not f then
        Log.info("no config.ini at %s, using defaults", path)
        Config.PlayerName = os.getenv("USERNAME") or "Player"
        return
    end
    for line in f:lines() do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key and not line:match("^%s*[;#]") and Config[key] ~= nil and type(Config[key]) ~= "function" then
            Config[key] = coerce(Config[key], value)
        end
    end
    f:close()
    if Config.PlayerName == "" then Config.PlayerName = os.getenv("USERNAME") or "Player" end
    Log.setDebug(Config.Debug, Config.ModDir)
    Log.info("config loaded: JoinAddress=%s", Config.JoinAddress)
end

-- Rewrite one "key = value" line of config.ini (e.g. to remember the last address joined).
function Config.save(key, value)
    Config[key] = value
    local path = Config.ModDir .. "\\config.ini"
    local f = io.open(path, "r")
    if not f then return end
    local lines, found = {}, false
    for line in f:lines() do
        if line:match("^%s*" .. key .. "%s*=") then
            line = key .. " = " .. tostring(value)
            found = true
        end
        lines[#lines + 1] = line
    end
    f:close()
    if not found then lines[#lines + 1] = key .. " = " .. tostring(value) end
    f = io.open(path, "w")
    if f then
        f:write(table.concat(lines, "\n"), "\n")
        f:close()
    end
end

return Config
