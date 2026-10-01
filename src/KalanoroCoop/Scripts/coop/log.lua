local Log = {}

local debugEnabled = false
local file = nil

-- With debug enabled, also write to <mod>/logs/coop_<start time>.log (UE4SS.log is shared by every
-- game instance started from the same folder).
function Log.setDebug(enabled, modDir)
    debugEnabled = enabled
    if enabled and modDir and not file then
        os.execute('mkdir "' .. modDir .. '\\logs" 2>nul')
        file = io.open(string.format("%s\\logs\\coop_%s_%d.log", modDir, os.date("%Y%m%d_%H%M%S"), math.random(1000, 9999)), "w")
    end
end

local function write(prefix, fmt, ...)
    local line = string.format(prefix .. fmt, ...)
    print(line .. "\n")
    if file then
        file:write(os.date("%H:%M:%S "), line, "\n")
        file:flush()
    end
end

function Log.info(fmt, ...)
    write("[KalanoroCoop] ", fmt, ...)
end

function Log.debug(fmt, ...)
    if debugEnabled then write("[KalanoroCoop:debug] ", fmt, ...) end
end

function Log.error(fmt, ...)
    write("[KalanoroCoop:ERROR] ", fmt, ...)
end

return Log
