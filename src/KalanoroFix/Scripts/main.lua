-- Kalanoro Fix: graphics options the game lacks (VSync, frame cap, HDR, TSR upscaling, performance mode) and
-- fixes for known keyboard/mouse issues (settings menu arrows, menu cursor, stuck controls).

local Config = {
    VSync = true,
    FrameRateLimit = 0,
    HDR = false,
    HDRNits = 1000,
    AntiAliasing = "Game",
    ResolutionScale = 100,
    MotionBlur = true,
    PerformanceMode = false,
    FixSettingsMenuMouse = true,
    FixMenuCursor = true,
    FixQualitySetting = true,
    UnstuckKey = "F11",
}

local function log(fmt, ...)
    print(string.format("[KalanoroFix] " .. fmt .. "\n", ...))
end

local function loadConfig()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    local dir = src:gsub("[/\\]Scripts[/\\]main%.lua$", "")
    local f = io.open(dir .. "\\config.ini", "r")
    if not f then return end
    for line in f:lines() do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key and not line:match("^%s*[;#]") and Config[key] ~= nil then
            local old = Config[key]
            if type(old) == "number" then
                Config[key] = tonumber(value) or old
            elseif type(old) == "boolean" then
                local l = value:lower()
                Config[key] = (l == "true" or l == "1" or l == "yes")
            else
                Config[key] = value
            end
        end
    end
    f:close()
end

local function valid(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end

local function localPC()
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if pc:IsValid() and pc:IsLocalController() and valid(pc.Player) then return pc end
    end
    return nil
end

local function notify(fmt, ...)
    local text = string.format(fmt, ...)
    log("%s", text)
    local pc = localPC()
    local ok, hud = pcall(function() return pc.HUDNotification end)
    if ok and valid(hud) then pcall(function() hud:AddSimpleNotification(FText(text)) end) end
end

local function userSettings()
    return StaticFindObject("/Script/Engine.Default__GameUserSettings"):GetGameUserSettings()
end

local function console(pc, cmd)
    StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(pc, cmd, pc)
end

---------------------------------------------------------------- graphics

local AA_METHODS = { off = 0, fxaa = 1, taa = 2, tsr = 4 }
local applying = false

local function applyCvars(pc)
    local aa = Config.AntiAliasing:lower()
    local scale = math.max(50, math.min(100, Config.ResolutionScale))
    local motionBlur = Config.MotionBlur
    if Config.PerformanceMode then
        aa, scale, motionBlur = "tsr", 67, false
    end
    if AA_METHODS[aa] then console(pc, "r.AntiAliasingMethod " .. AA_METHODS[aa]) end
    console(pc, "r.ScreenPercentage " .. scale)
    if not motionBlur then console(pc, "r.MotionBlurQuality 0") end
end

local function applyDisplay()
    local gus = userSettings()
    if not valid(gus) then return end
    gus:SetVSyncEnabled(Config.VSync)
    gus:SetFrameRateLimit(Config.FrameRateLimit)
    if Config.HDR then
        if gus:SupportsHDRDisplayOutput() then
            gus:EnableHDRDisplayOutput(true, Config.HDRNits)
        else
            notify("HDR is not supported on this display")
        end
    elseif gus:IsHDREnabled() then
        gus:EnableHDRDisplayOutput(false, Config.HDRNits)
    end
    gus:ApplyNonResolutionSettings()
    gus:SaveSettings()
end

-- The settings menu's Quality option only understands overall levels 0-3; with a mixed ("custom", -1) or
-- Cinematic (4) scalability it shows nothing and its arrows do nothing. Snap to the nearest standard level.
local function normalizeQuality()
    local gus = userSettings()
    local level = gus:GetOverallScalabilityLevel()
    if level >= 0 and level <= 3 then return end
    local groups = { gus:GetViewDistanceQuality(), gus:GetShadowQuality(), gus:GetAntiAliasingQuality(),
        gus:GetTextureQuality(), gus:GetVisualEffectQuality(), gus:GetPostProcessingQuality(),
        gus:GetFoliageQuality(), gus:GetShadingQuality() }
    local sum = 0
    for _, v in ipairs(groups) do sum = sum + math.max(0, math.min(3, v)) end
    local target = math.floor(sum / #groups + 0.5)
    gus:SetOverallScalabilityLevel(target)
    gus:ApplyNonResolutionSettings()
    gus:SaveSettings()
    log("quality normalized from %d to %d", level, target)
end

local function applyAll()
    local pc = localPC()
    if not pc or applying then return end
    applying = true
    local ok, err = pcall(function()
        if Config.PerformanceMode then
            local gus = userSettings()
            if gus:GetOverallScalabilityLevel() ~= 0 then
                gus:SetOverallScalabilityLevel(0)
                gus:ApplyNonResolutionSettings()
            end
        elseif Config.FixQualitySetting then
            normalizeQuality()
        end
        applyDisplay()
        applyCvars(pc)
    end)
    applying = false
    if not ok then log("apply failed: %s", tostring(err)) end
end

-- The game's own settings menu re-applies scalability (which resets render scale etc.); re-apply ours after it.
local function onSettingsApplied()
    if applying then return end
    ExecuteInGameThreadWithDelay(100, applyAll)
end

---------------------------------------------------------------- menus

local function menuStack(pc)
    local ok, stack = pcall(function() return pc.BaseInventoryUI.MenuStack end)
    if ok and valid(stack) then return stack end
    return nil
end

local function activeMenu(pc)
    local stack = menuStack(pc)
    if not stack then return nil end
    local w = stack:GetActiveWidget()
    if valid(w) then return w end
    return nil
end

local function usingGamepad(pc)
    local ok, gamepad = pcall(function() return pc.bIsGamepad end)
    return ok and gamepad == true
end

-- Option rows (screen mode, quality, language) change value with left/right arrow buttons inside ArrowBox.
local OPTION_ROW = "WBP_TemplateOptionSetting_C"
local forcedCursor = false

local function menuTick()
    local pc = localPC()
    if not pc or usingGamepad(pc) then return end

    -- Option rows only reveal their left/right arrow buttons on keyboard/gamepad focus; with a mouse they stay
    -- hidden and the options cannot be changed.
    if Config.FixSettingsMenuMouse then
        local settings = FindFirstOf("UI_Settings_C")
        if valid(settings) and settings:IsVisible() then
            for _, row in ipairs(FindAllOf(OPTION_ROW) or {}) do
                local arrows = row:IsValid() and row.ArrowBox
                if valid(arrows) and arrows:GetVisibility() ~= 0 then arrows:SetVisibility(0) end
            end
        end
    end

    -- Menus pushed while CommonUI still believes a gamepad is in use leave the mouse cursor hidden.
    if Config.FixMenuCursor then
        if activeMenu(pc) then
            if not pc.bShowMouseCursor then
                pc.bShowMouseCursor = true
                forcedCursor = true
            end
        elseif forcedCursor then
            pc.bShowMouseCursor = false
            forcedCursor = false
        end
    end
end

local function unstuck()
    local pc = localPC()
    if not pc then return end
    local menu = activeMenu(pc)
    if menu then pcall(function() menu:DeactivateWidget() end) end
    StaticFindObject("/Script/Engine.Default__GameplayStatics"):SetGamePaused(pc, false)
    StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameOnly(pc, true)
    pc.bShowMouseCursor = false
    forcedCursor = false
    pc:ResetIgnoreMoveInput()
    pc:ResetIgnoreLookInput()
    if valid(pc.Pawn) then pc.Pawn:EnableInput(pc) end
    notify("controls restored")
end

---------------------------------------------------------------- setup

loadConfig()

RegisterHook("/Script/Engine.GameUserSettings:ApplySettings", function() end, onSettingsApplied)
RegisterHook("/Script/Engine.GameUserSettings:ApplyNonResolutionSettings", function() end, onSettingsApplied)

local lastWorld = nil
LoopInGameThreadWithDelay(1000, function()
    local pc = localPC()
    local world = pc and pc:GetWorld():GetAddress()
    if world and world ~= lastWorld then
        lastWorld = world
        applyAll()
    end
end)

LoopInGameThreadWithDelay(200, function()
    local ok, err = pcall(menuTick)
    if not ok then log("menu tick: %s", tostring(err)) end
end)

local key = Key[Config.UnstuckKey]
if key then
    RegisterKeyBind(key, function() ExecuteInGameThread(unstuck) end)
end

log("loaded (VSync=%s, FrameRateLimit=%s, AntiAliasing=%s, ResolutionScale=%s, PerformanceMode=%s)",
    tostring(Config.VSync), tostring(Config.FrameRateLimit), Config.AntiAliasing, tostring(Config.ResolutionScale),
    tostring(Config.PerformanceMode))
