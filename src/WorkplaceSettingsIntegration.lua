-- =========================================================
-- WorkplaceSettingsIntegration.lua
-- Adds Workplace Triggers settings to
-- ESC > Settings > General Settings
-- =========================================================
-- Pattern: NPCSettingsIntegration.lua from FS25_NPCFavor
-- Hooks InGameMenuSettingsFrame.onFrameOpen to inject
-- controls using standard FS25 GUI profiles.
--
-- Controls added (under "Workplace Triggers" section header):
--   Show HUD              (BinaryOption)
--   HUD Scale             (MultiTextOption)
--   Show Notifications    (BinaryOption)
--   Wage Multiplier       (MultiTextOption)
--   Show Earnings in HUD  (BinaryOption)
--   Debug Mode            (BinaryOption)
-- =========================================================

WorkplaceSettingsIntegration = {}
WorkplaceSettingsIntegration_mt = Class(WorkplaceSettingsIntegration)

local function wtLog(msg)
    print("[WorkplaceTriggers] SettingsIntegration: " .. tostring(msg))
end

-- Constructor (created by WorkplaceSystem)
function WorkplaceSettingsIntegration.new(system)
    local self = setmetatable({}, WorkplaceSettingsIntegration_mt)
    self.system = system
    return self
end

function WorkplaceSettingsIntegration:initialize()
    -- Hooks installed at file-load time (see bottom)
end

function WorkplaceSettingsIntegration:update(dt) end
function WorkplaceSettingsIntegration:delete() end

-- =========================================================
-- onFrameOpen  (appended to InGameMenuSettingsFrame)
-- 'self' here IS the InGameMenuSettingsFrame instance
-- =========================================================
function WorkplaceSettingsIntegration:onFrameOpen()
    if self.wt_initDone then
        -- Already added - just refresh values
        WorkplaceSettingsIntegration:updateSettingsUI(self)
        return
    end

    WorkplaceSettingsIntegration:addSettingsElements(self)

    self.generalSettingsLayout:invalidateLayout()

    if self.updateAlternatingElements then
        self:updateAlternatingElements(self.generalSettingsLayout)
    end
    if self.updateGeneralSettings then
        self:updateGeneralSettings(self.generalSettingsLayout)
    end

    self.wt_initDone = true
    wtLog("Injected controls into General Settings")

    WorkplaceSettingsIntegration:updateSettingsUI(self)
end

-- =========================================================
-- addSettingsElements - 1 header + 7 controls
-- =========================================================
function WorkplaceSettingsIntegration:addSettingsElements(frame)
    -- Section header so the mod is easy to find
    WorkplaceSettingsIntegration:addSectionHeader(
        frame,
        g_i18n:getText("wt_settings_section") or "Workplace Triggers"
    )

    -- HUD
    frame.wt_showHudToggle = WorkplaceSettingsIntegration:addBinaryOption(
        frame, "onShowHudChanged",
        g_i18n:getText("wt_settings_show_hud_short")  or "Show Shift HUD",
        g_i18n:getText("wt_settings_show_hud_long")   or "Display the shift info panel while on shift"
    )

    frame.wt_hudScale = WorkplaceSettingsIntegration:addMultiTextOption(
        frame, "onHudScaleChanged",
        WorkplaceSettings.hudScaleOptions,
        g_i18n:getText("wt_settings_hud_scale_short") or "HUD Scale",
        g_i18n:getText("wt_settings_hud_scale_long")  or "Size of the shift HUD panel"
    )

    -- Notifications
    frame.wt_showNotifToggle = WorkplaceSettingsIntegration:addBinaryOption(
        frame, "onShowNotificationsChanged",
        g_i18n:getText("wt_settings_show_notif_short") or "Show Notifications",
        g_i18n:getText("wt_settings_show_notif_long")  or "Show flash messages when a shift starts or ends"
    )

    -- Gameplay
    frame.wt_wageMult = WorkplaceSettingsIntegration:addMultiTextOption(
        frame, "onWageMultChanged",
        WorkplaceSettings.wageMultOptions,
        g_i18n:getText("wt_settings_wage_mult_short") or "Wage Multiplier",
        g_i18n:getText("wt_settings_wage_mult_long")  or "Global multiplier applied to all hourly wages"
    )

    frame.wt_showEarningsToggle = WorkplaceSettingsIntegration:addBinaryOption(
        frame, "onShowEarningsChanged",
        g_i18n:getText("wt_settings_show_earnings_short") or "Show Earnings in HUD",
        g_i18n:getText("wt_settings_show_earnings_long")  or "Show current earnings row in the shift HUD panel"
    )

    -- Debug
    frame.wt_debugToggle = WorkplaceSettingsIntegration:addBinaryOption(
        frame, "onDebugModeChanged",
        g_i18n:getText("wt_settings_debug_short") or "Debug Mode",
        g_i18n:getText("wt_settings_debug_long")  or "Show extra debug logging in the console"
    )
end

-- =========================================================
-- GUI Element Builders (FS25 profile-based)
-- =========================================================
function WorkplaceSettingsIntegration:addSectionHeader(frame, text)
    local el = TextElement.new()
    el.name = "sectionHeader"
    el:loadProfile(g_gui:getProfile("fs25_settingsSectionHeader"), true)
    el:setText(text)
    frame.generalSettingsLayout:addElement(el)
    el:onGuiSetupFinished()
end

function WorkplaceSettingsIntegration:addBinaryOption(frame, callbackName, title, tooltip)
    local container = BitmapElement.new()
    container:loadProfile(g_gui:getProfile("fs25_multiTextOptionContainer"), true)

    local option = BinaryOptionElement.new()
    option.useYesNoTexts = true
    option:loadProfile(g_gui:getProfile("fs25_settingsBinaryOption"), true)
    option.target = WorkplaceSettingsIntegration
    option:setCallback("onClickCallback", callbackName)

    local titleEl = TextElement.new()
    titleEl:loadProfile(g_gui:getProfile("fs25_settingsMultiTextOptionTitle"), true)
    titleEl:setText(title)

    local tooltipEl = TextElement.new()
    tooltipEl.name = "ignore"
    tooltipEl:loadProfile(g_gui:getProfile("fs25_multiTextOptionTooltip"), true)
    tooltipEl:setText(tooltip)

    option:addElement(tooltipEl)
    container:addElement(option)
    container:addElement(titleEl)

    option:onGuiSetupFinished()
    titleEl:onGuiSetupFinished()
    tooltipEl:onGuiSetupFinished()

    frame.generalSettingsLayout:addElement(container)
    container:onGuiSetupFinished()

    return option
end

function WorkplaceSettingsIntegration:addMultiTextOption(frame, callbackName, texts, title, tooltip)
    local container = BitmapElement.new()
    container:loadProfile(g_gui:getProfile("fs25_multiTextOptionContainer"), true)

    local option = MultiTextOptionElement.new()
    option:loadProfile(g_gui:getProfile("fs25_settingsMultiTextOption"), true)
    option.target = WorkplaceSettingsIntegration
    option:setCallback("onClickCallback", callbackName)
    option:setTexts(texts)

    local titleEl = TextElement.new()
    titleEl:loadProfile(g_gui:getProfile("fs25_settingsMultiTextOptionTitle"), true)
    titleEl:setText(title)

    local tooltipEl = TextElement.new()
    tooltipEl.name = "ignore"
    tooltipEl:loadProfile(g_gui:getProfile("fs25_multiTextOptionTooltip"), true)
    tooltipEl:setText(tooltip)

    option:addElement(tooltipEl)
    container:addElement(option)
    container:addElement(titleEl)

    option:onGuiSetupFinished()
    titleEl:onGuiSetupFinished()
    tooltipEl:onGuiSetupFinished()

    frame.generalSettingsLayout:addElement(container)
    container:onGuiSetupFinished()

    return option
end

-- =========================================================
-- Sync UI controls <-> current settings values
-- =========================================================
local function findIndex(values, target)
    for i, v in ipairs(values) do
        if v == target then return i end
    end
    return 1
end

function WorkplaceSettingsIntegration:updateSettingsUI(frame)
    if not frame.wt_initDone then return end
    local s = g_WorkplaceSystem and g_WorkplaceSystem.settings
    if not s then return end

    if frame.wt_showHudToggle then
        frame.wt_showHudToggle:setIsChecked(s.showHud == true, false, false)
    end
    if frame.wt_hudScale then
        frame.wt_hudScale:setState(findIndex(WorkplaceSettings.hudScaleValues, s.hudScale))
    end
    if frame.wt_showNotifToggle then
        frame.wt_showNotifToggle:setIsChecked(s.showNotifications == true, false, false)
    end
    if frame.wt_wageMult then
        frame.wt_wageMult:setState(findIndex(WorkplaceSettings.wageMultValues, s.wageMultiplier))
    end
    if frame.wt_showEarningsToggle then
        frame.wt_showEarningsToggle:setIsChecked(s.showEarningsInHud == true, false, false)
    end
    if frame.wt_debugToggle then
        frame.wt_debugToggle:setIsChecked(s.debugMode == true, false, false)
    end
end

-- Called when updateGameSettings fires (live refresh on settings page re-open)
function WorkplaceSettingsIntegration:updateGameSettings()
    WorkplaceSettingsIntegration:updateSettingsUI(self)
end

-- =========================================================
-- Callback Handlers
-- =========================================================
local function getSettings()
    return g_WorkplaceSystem and g_WorkplaceSystem.settings
end

-- globalSetting=true means this key is a gameplay setting that must be synced to all
-- clients so non-admin players use the same value as the admin.
local function apply(key, value, msg, globalSetting)
    local s = getSettings()
    if not s then return end
    s[key] = value
    if msg then wtLog(msg) end
    -- Write immediately so changes survive a restart without an explicit game save.
    -- Only the server has a valid savegame directory in MP, so the write is a no-op
    -- on clients (harmless). Clients get the authoritative value via TYPE_SYNC_SETTINGS.
    local mi = g_currentMission and g_currentMission.missionInfo
    if mi then s:saveToXMLFile(mi) end
    -- Broadcast global settings to all connected clients so they take effect immediately.
    if globalSetting and g_currentMission and g_currentMission:getIsServer() then
        WTNetworkSyncBridge.sendSyncSettings()
    end
end

function WorkplaceSettingsIntegration:onShowHudChanged(state)
    local v = (state == BinaryOptionElement.STATE_RIGHT)
    apply("showHud", v, "Show HUD: " .. tostring(v))
end

function WorkplaceSettingsIntegration:onHudScaleChanged(state)
    local v = WorkplaceSettings.hudScaleValues[state] or 1.0
    apply("hudScale", v, "HUD scale: " .. v)
    -- Apply to live HUD immediately
    if g_WorkplaceSystem and g_WorkplaceSystem.hud then
        g_WorkplaceSystem.hud.scale = v
        g_WorkplaceSystem.hud:clampPosition()
    end
end

function WorkplaceSettingsIntegration:onShowNotificationsChanged(state)
    local v = (state == BinaryOptionElement.STATE_RIGHT)
    apply("showNotifications", v)
end

function WorkplaceSettingsIntegration:onWageMultChanged(state)
    local v = WorkplaceSettings.wageMultValues[state] or 1.0
    apply("wageMultiplier", v, "Wage multiplier: " .. v, true)
end

function WorkplaceSettingsIntegration:onShowEarningsChanged(state)
    local v = (state == BinaryOptionElement.STATE_RIGHT)
    apply("showEarningsInHud", v)
end

function WorkplaceSettingsIntegration:onDebugModeChanged(state)
    local v = (state == BinaryOptionElement.STATE_RIGHT)
    apply("debugMode", v, "Debug mode: " .. tostring(v))
    if g_WorkplaceSystem then
        g_WorkplaceSystem.debugMode = v
    end
end

-- =========================================================
-- Install hooks at file-load time (same as NPCFavor pattern)
-- =========================================================
local function initHooks()
    if not InGameMenuSettingsFrame then return end

    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
        InGameMenuSettingsFrame.onFrameOpen,
        WorkplaceSettingsIntegration.onFrameOpen
    )

    if InGameMenuSettingsFrame.updateGameSettings then
        InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(
            InGameMenuSettingsFrame.updateGameSettings,
            WorkplaceSettingsIntegration.updateGameSettings
        )
    end

    wtLog("Hooks installed on InGameMenuSettingsFrame")
end

initHooks()
