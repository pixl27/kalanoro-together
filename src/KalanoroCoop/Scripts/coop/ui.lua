-- On-screen messages through the game's own notification HUD (PC_Default.HUDNotification).
local U = require("coop.util")
local Log = require("coop.log")

local UI = {}

function UI.notify(fmt, ...)
    local text = string.format(fmt, ...)
    Log.info("%s", text)
    local pc = U.localPC()
    if not pc then return end
    local ok, hud = pcall(function() return pc.HUDNotification end)
    if ok and U.valid(hud) then
        pcall(function() hud:AddSimpleNotification(FText("Co-op: " .. text)) end)
    end
end

return UI
