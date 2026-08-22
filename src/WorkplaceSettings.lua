-- =========================================================
-- WorkplaceSettings.lua
-- Settings data class. Holds all mod settings with defaults,
-- and handles save/load from a per-savegame XML file.
-- =========================================================
-- Pattern: NPCSettings.lua from FS25_NPCFavor
-- Save location: <savegameDir>/workplace_triggers_settings.xml
-- =========================================================

WorkplaceSettings = WorkplaceSettings or {}
local WorkplaceSettings_mt = Class(WorkplaceSettings)

local function wtLog(msg)
    print("[WorkplaceTriggers] Settings: " .. tostring(msg))
end

-- Wage multiplier dropdown options
WorkplaceSettings.wageMultOptions = {"0.5x", "0.75x", "1.0x", "1.25x", "1.5x", "2.0x"}
WorkplaceSettings.wageMultValues  = {0.5, 0.75, 1.0, 1.25, 1.5, 2.0}

-- HUD scale dropdown options
WorkplaceSettings.hudScaleOptions = {"0.75x", "1.0x", "1.25x", "1.5x", "2.0x"}
WorkplaceSettings.hudScaleValues  = {0.75, 1.0, 1.25, 1.5, 2.0}

function WorkplaceSettings.new()
    local self = setmetatable({}, WorkplaceSettings_mt)
    self:resetToDefaults()
    return self
end

-- =========================================================
-- Defaults
-- =========================================================
function WorkplaceSettings:resetToDefaults()
    -- Gameplay
    self.wageMultiplier      = 1.0    -- applied on top of per-trigger hourly wage
    self.endShiftOnLeave     = true   -- auto-end shift when player leaves trigger zone
    self.showEarningsInHud   = true   -- show current earnings row in HUD

    -- HUD display
    self.showHud             = true   -- show shift HUD panel at all
    self.hudScale            = 1.0

    -- Notifications
    self.showNotifications   = true   -- show flash notifications on shift start/end

    -- Debug
    self.debugMode           = false
end

-- =========================================================
-- XML file path (per-savegame)
-- =========================================================
function WorkplaceSettings:getSavegameXmlPath()
    if not (g_currentMission
            and g_currentMission.missionInfo
            and g_currentMission.missionInfo.savegameDirectory) then
        return nil
    end
    return g_currentMission.missionInfo.savegameDirectory
           .. "/workplace_triggers_settings.xml"
end

-- =========================================================
-- Load from disk
-- =========================================================
function WorkplaceSettings:load()
    local xmlPath = self:getSavegameXmlPath()
    if not xmlPath then
        wtLog("No savegame path - using defaults")
        return
    end

    local xml = XMLFile.loadIfExists("wt_settings", xmlPath, "WorkplaceSettings")
    if not xml then
        wtLog("No settings file found (new game) - using defaults")
        return
    end

    local function getBool(k, d)  return xml:getBool( "WorkplaceSettings." .. k, d) end
    local function getFloat(k, d) return xml:getFloat("WorkplaceSettings." .. k, d) end

    self.wageMultiplier    = getFloat("wageMultiplier",    self.wageMultiplier)
    self.endShiftOnLeave   = getBool( "endShiftOnLeave",   self.endShiftOnLeave)
    self.showEarningsInHud = getBool( "showEarningsInHud", self.showEarningsInHud)
    self.showHud           = getBool( "showHud",           self.showHud)
    self.hudScale          = getFloat("hudScale",          self.hudScale)
    self.showNotifications = getBool( "showNotifications", self.showNotifications)
    self.debugMode         = getBool( "debugMode",         self.debugMode)

    xml:delete()
    self:validate()
    wtLog(string.format("Loaded (wageMult=%.2f showHud=%s debug=%s)",
        self.wageMultiplier, tostring(self.showHud), tostring(self.debugMode)))
end

-- =========================================================
-- Save to disk
-- =========================================================
function WorkplaceSettings:saveToXMLFile(missionInfo)
    local dir = missionInfo and missionInfo.savegameDirectory
    if not dir then return end

    local xmlPath = dir .. "/workplace_triggers_settings.xml"
    local xml = XMLFile.create("wt_settings", xmlPath, "WorkplaceSettings")
    if not xml then return end

    local function setBool(k, v)  xml:setBool( "WorkplaceSettings." .. k, v) end
    local function setFloat(k, v) xml:setFloat("WorkplaceSettings." .. k, v) end

    setFloat("wageMultiplier",    self.wageMultiplier)
    setBool( "endShiftOnLeave",   self.endShiftOnLeave)
    setBool( "showEarningsInHud", self.showEarningsInHud)
    setBool( "showHud",           self.showHud)
    setFloat("hudScale",          self.hudScale)
    setBool( "showNotifications", self.showNotifications)
    setBool( "debugMode",         self.debugMode)

    xml:save()
    xml:delete()
    wtLog("Saved to disk")
end

-- =========================================================
-- Validate / clamp
-- =========================================================
function WorkplaceSettings:validate()
    self.wageMultiplier    = math.max(0.1, math.min(5.0, self.wageMultiplier))
    self.hudScale          = math.max(0.5, math.min(2.5, self.hudScale))
    self.endShiftOnLeave   = not not self.endShiftOnLeave
    self.showEarningsInHud = not not self.showEarningsInHud
    self.showHud           = not not self.showHud
    self.showNotifications = not not self.showNotifications
    self.debugMode         = not not self.debugMode
end
