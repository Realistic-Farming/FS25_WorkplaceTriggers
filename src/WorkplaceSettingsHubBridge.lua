-- =========================================================
-- WorkplaceSettingsHubBridge.lua
-- Optional bridge to FS25_SettingsHub.
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Safe if SettingsHub is not installed (register() just no-ops). Purpose:
-- let the FarmTablet System Settings app list Workplace Triggers' settings.
--
-- g_WorkplaceSystem.settings (a WorkplaceSettings instance, persisted to
-- workplace_triggers_settings.xml on game save) stays the source of truth.
-- This mirrors the 7 settings into SettingsHub for display; the tablet app
-- is read-only for now, so applyChange only sets the value back on that
-- table and re-validates (the next game save persists it). The wage/schedule
-- rules are adminOnly (server-shared); the HUD/notification prefs are
-- player-local (adminOnly = false).
-- =========================================================

WorkplaceSettingsHubBridge = {}

local function wtLog(msg)
    print("[WorkplaceTriggers] SettingsHub: " .. tostring(msg))
end

local function applyChange(key, value)
    local sys = g_WorkplaceSystem
    if sys == nil or sys.settings == nil then return end
    sys.settings[key] = value
    if sys.settings.validate then
        sys.settings:validate()
    end
end

function WorkplaceSettingsHubBridge.register()
    -- The reliable cross-mod handle is g_currentMission.settingsHub (the same one
    -- FarmTablet reads). The bare g_settingsHub global is only visible inside
    -- SettingsHub's own mod environment, so it reads back nil from here.
    local hub = (g_currentMission ~= nil and g_currentMission.settingsHub) or g_settingsHub
    if hub == nil then return end

    local sys = g_WorkplaceSystem
    if sys == nil or sys.settings == nil then return end
    local s = sys.settings

    local defs = {
        { id = "wageMultiplier",    type = "enum", default = s.wageMultiplier, adminOnly = true,  values = WorkplaceSettings.wageMultValues, label = "Wage Multiplier" },
        { id = "endShiftOnLeave",   type = "bool", default = s.endShiftOnLeave,   adminOnly = true,  label = "Auto-End Shift On Leave" },
        { id = "showEarningsInHud", type = "bool", default = s.showEarningsInHud, adminOnly = false, label = "Show Earnings In HUD" },
        { id = "showHud",           type = "bool", default = s.showHud,           adminOnly = false, label = "Show Shift HUD" },
        { id = "hudScale",          type = "enum", default = s.hudScale, adminOnly = false, values = WorkplaceSettings.hudScaleValues, label = "HUD Scale" },
        { id = "showNotifications", type = "bool", default = s.showNotifications, adminOnly = false, label = "Shift Notifications" },
        { id = "debugMode",         type = "bool", default = s.debugMode,         adminOnly = false, label = "Debug Mode" },
    }

    local ok, err = pcall(function()
        hub:registerModule("WorkplaceTriggers", {
            adminSettings = defs,
            onChange      = function(key, value, playerId) applyChange(key, value) end,
            -- We own our persistence (workplace_triggers_settings.xml, loaded in
            -- WorkplaceSystem:onMissionLoaded before this registration runs), so the hub
            -- must mirror for display only: never restore its own stale copy and replay
            -- it back through onChange on load. Without this the hub could push a stale
            -- value over our real one every load (the SoilFertilizer disable-on-load trap).
            selfPersisted = true,
        })
    end)

    if ok then
        wtLog(string.format("Registered with SettingsHub (%d settings)", #defs))
    else
        wtLog("SettingsHub registration failed: " .. tostring(err))
    end
end
