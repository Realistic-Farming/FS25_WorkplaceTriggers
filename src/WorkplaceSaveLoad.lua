-- =========================================================
-- WorkplaceSaveLoad.lua
-- Saves/loads all workplace trigger definitions.
-- =========================================================
-- Pattern: SaveLoadHandler.lua from FS25_SeasonalCropStress
-- CRITICAL: Use OOP xmlFile:setInt() etc. NEVER legacy globals.
-- Save layout inside the mod's own standalone file (getSavePath below), NOT the
-- career savegame:
--   <workplaceTriggers>
--     <triggers>
--       <trigger idx="0" id="wt_1" name="Post Office" hourlyWage="500"
--                posX="100.0" posY="0.0" posZ="200.0"/>
--       ...
--     </triggers>
--   </workplaceTriggers>
-- =========================================================

WorkplaceSaveLoad = {}
WorkplaceSaveLoad_mt = Class(WorkplaceSaveLoad)

local ROOT = "careerSavegame.workplaceTriggers"

local function wtLog(msg)
    print("[WorkplaceTriggers] SaveLoad: " .. tostring(msg))
end

-- Helper: safe OOP XML write (falls back to legacy globals if needed)
local function setInt(xmlFile, key, value)
    if xmlFile.setInt then xmlFile:setInt(key, value)
    else setXMLInt(xmlFile, key, value) end
end

local function setFloat(xmlFile, key, value)
    if xmlFile.setFloat then xmlFile:setFloat(key, value)
    else setXMLFloat(xmlFile, key, value) end
end

local function setBool(xmlFile, key, value)
    if xmlFile.setBool then xmlFile:setBool(key, value)
    else setXMLBool(xmlFile, key, value) end
end

local function setString(xmlFile, key, value)
    if xmlFile.setString then xmlFile:setString(key, value)
    else setXMLString(xmlFile, key, value) end
end

-- Helper: safe OOP XML read
local function getInt(xmlFile, key, default)
    local v
    if xmlFile.getInt then v = xmlFile:getInt(key) else v = getXMLInt(xmlFile, key) end
    return v ~= nil and v or default
end

local function getFloat(xmlFile, key, default)
    local v
    if xmlFile.getFloat then v = xmlFile:getFloat(key) else v = getXMLFloat(xmlFile, key) end
    return v ~= nil and v or default
end

local function getString(xmlFile, key, default)
    local v
    if xmlFile.getString then v = xmlFile:getString(key) else v = getXMLString(xmlFile, key) end
    return v ~= nil and v or default
end

-- =========================================================
-- Constructor
-- =========================================================
function WorkplaceSaveLoad.new(system)
    local self = setmetatable({}, WorkplaceSaveLoad_mt)
    self.system = system
    self.isInitialized = false
    return self
end

function WorkplaceSaveLoad:initialize()
    self.isInitialized = true
    wtLog("Initialized")
end


-- =========================================================
-- SAVE
-- Writes to a standalone mod XML file in the savegame directory.
-- =========================================================
function WorkplaceSaveLoad:saveToXMLFile(missionInfo)
    if not self.isInitialized then return end

    local savePath = self:getSavePath(missionInfo)
    if savePath == nil then
        wtLog("saveToXMLFile: could not determine save path - skipping")
        return
    end

    local xmlFile = XMLFile.create("workplaceTriggersSave", savePath, "workplaceTriggers")
    if xmlFile == nil then
        wtLog("saveToXMLFile: XMLFile.create failed for " .. tostring(savePath))
        return
    end

    local triggers = self.system.triggerManager:getAllTriggers()
    local count = 0

    for idx, trigger in ipairs(triggers) do
        local i = idx - 1
        local key = string.format("workplaceTriggers.triggers.trigger(%d)", i)
        xmlFile:setString(key .. "#id",           tostring(trigger.id or ""))
        xmlFile:setString(key .. "#name",         trigger.workplaceName or "Workplace")
        xmlFile:setInt(   key .. "#hourlyWage",   trigger.hourlyWage or 500)
        xmlFile:setFloat( key .. "#triggerRadius",trigger.triggerRadius or 4)
        xmlFile:setFloat( key .. "#posX",         trigger.posX or 0)
        xmlFile:setFloat( key .. "#posY",         trigger.posY or 0)
        xmlFile:setFloat( key .. "#posZ",         trigger.posZ or 0)
        xmlFile:setFloat( key .. "#rotY",         trigger.rotY or 0)
        xmlFile:setString(key .. "#paySchedule",     trigger.paySchedule    or "hourly")
        xmlFile:setInt(   key .. "#timeMultiplier",  trigger.timeMultiplier or 0)
        xmlFile:setBool(  key .. "#endShiftOnLeave", trigger.endShiftOnLeave ~= false)
        xmlFile:setString(key .. "#purpose",         trigger.purpose or "")
        count = count + 1
    end

    xmlFile:setInt("workplaceTriggers.triggers#count", count)

    local hud = self.system.hud
    if hud then
        xmlFile:setFloat("workplaceTriggers.hudLayout#posX",      hud.posX)
        xmlFile:setFloat("workplaceTriggers.hudLayout#posY",      hud.posY)
        xmlFile:setFloat("workplaceTriggers.hudLayout#scale",     hud.scale)
        xmlFile:setFloat("workplaceTriggers.hudLayout#widthMult", hud.widthMult)
        wtLog("Saved HUD layout")
    end

    xmlFile:save()
    xmlFile:delete()

    wtLog(string.format("Saved %d triggers to %s", count, savePath))

    if self.system.settings then
        self.system.settings:saveToXMLFile(missionInfo)
    end
end

-- =========================================================
-- LOAD
-- Reads from the standalone mod XML file in the savegame directory.
-- =========================================================
function WorkplaceSaveLoad:loadFromXMLFile(missionInfo)
    if not self.isInitialized then return end

    local savePath = self:getSavePath(missionInfo)
    if savePath == nil then
        wtLog("loadFromXMLFile: could not determine save path - fresh game")
        return
    end

    local xmlFile = XMLFile.load("workplaceTriggersSave", savePath)
    if xmlFile == nil then
        wtLog("loadFromXMLFile: no save file at " .. tostring(savePath) .. " - fresh game")
        return
    end

    local i = 0

    while true do
        local key = string.format("workplaceTriggers.triggers.trigger(%d)", i)
        local savedId = xmlFile:getString(key .. "#id", nil)
        if savedId == nil or savedId == "" then break end

        local savedName   = xmlFile:getString(key .. "#name",          "Workplace")
        local savedWage   = xmlFile:getInt(   key .. "#hourlyWage",    500)
        local savedRadius = xmlFile:getFloat( key .. "#triggerRadius", 4)
        local savedPosX   = xmlFile:getFloat( key .. "#posX",          0)
        local savedPosY   = xmlFile:getFloat( key .. "#posY",          0)
        local savedPosZ   = xmlFile:getFloat( key .. "#posZ",          0)
        local savedRotY   = xmlFile:getFloat( key .. "#rotY",          0)
        local savedSched           = xmlFile:getString(key .. "#paySchedule",     "hourly")
        local savedTimeMultiplier  = xmlFile:getInt(   key .. "#timeMultiplier",  0)
        local savedEndShiftOnLeave = xmlFile:getBool(  key .. "#endShiftOnLeave", true)
        local savedPurpose         = xmlFile:getString(key .. "#purpose",         "")

        -- Triggers are pure data objects — register directly, no placeable needed
        local triggerData = {
            id              = savedId,
            workplaceName   = savedName,
            hourlyWage      = savedWage,
            triggerRadius   = savedRadius,
            posX            = savedPosX,
            posY            = savedPosY,
            posZ            = savedPosZ,
            rotY            = savedRotY,
            paySchedule     = savedSched,
            timeMultiplier  = savedTimeMultiplier or 0,
            endShiftOnLeave = savedEndShiftOnLeave ~= false,
            purpose         = savedPurpose,
            playerInside    = false,
        }
        self.system.triggerManager:registerTrigger(triggerData)
        wtLog(string.format("Restored trigger '%s' (id=%s)", savedName, savedId))

        i = i + 1
    end

    wtLog(string.format("Loaded %d trigger configs", i))

    local hudPosX      = xmlFile:getFloat("workplaceTriggers.hudLayout#posX",      nil)
    local hudPosY      = xmlFile:getFloat("workplaceTriggers.hudLayout#posY",      nil)
    local hudScale     = xmlFile:getFloat("workplaceTriggers.hudLayout#scale",     nil)
    local hudWidthMult = xmlFile:getFloat("workplaceTriggers.hudLayout#widthMult", nil)
    if hudPosX and self.system.hud then
        self.system.hud:loadFromSettings({
            hudPosX      = hudPosX,
            hudPosY      = hudPosY,
            hudScale     = hudScale,
            hudWidthMult = hudWidthMult,
        })
        wtLog("Loaded HUD layout")
    end

    xmlFile:delete()
end

-- =========================================================
-- Helper: resolve path for mod save file
-- =========================================================
function WorkplaceSaveLoad:getSavePath(missionInfo)
    local mi = missionInfo
        or (g_currentMission and g_currentMission.missionInfo)
    local dir = mi and mi.savegameDirectory
    if dir == nil then return nil end
    return dir .. "/FS25_WorkplaceTriggers.xml"
end

-- =========================================================
-- Immediate HUD Position Save
-- HUD layout is written on the next full game save.
-- =========================================================
function WorkplaceSaveLoad:savePendingHUD()
    wtLog("HUD layout queued for next full save")
end

-- =========================================================
-- Pending Restore (handles load-before-placeable edge case)
-- =========================================================
function WorkplaceSaveLoad:storePendingRestore(id, name, wage, radius, posX, posY, posZ, sched)
    if self.pendingRestores == nil then
        self.pendingRestores = {}
    end
    self.pendingRestores[id] = {
        workplaceName = name,
        hourlyWage    = wage,
        triggerRadius = radius,
        posX          = posX,
        posY          = posY,
        posZ          = posZ,
        paySchedule   = sched or "hourly",
    }
    wtLog(string.format("Stored pending restore for trigger id=%s ('%s')", id, name))
end

-- Called by WorkTriggerPlaceable:onLoad after registering, to pick up any pending restore data
function WorkplaceSaveLoad:applyPendingRestore(trigger)
    if self.pendingRestores == nil then return end
    local pending = self.pendingRestores[tostring(trigger.id)]
    if pending then
        trigger.workplaceName = pending.workplaceName
        trigger.hourlyWage    = pending.hourlyWage
        trigger.triggerRadius = pending.triggerRadius or trigger.triggerRadius
        trigger.paySchedule   = pending.paySchedule or "hourly"
        self.pendingRestores[tostring(trigger.id)] = nil
        wtLog(string.format("Applied pending restore to trigger '%s'", trigger.workplaceName))
    end
end

-- =========================================================
-- Cleanup
-- =========================================================
function WorkplaceSaveLoad:delete()
    self.pendingRestores = nil
    self.isInitialized = false
    wtLog("Deleted")
end
-- =========================================================
-- Pending Create (GUI-spawned placeables pick up name/wage on onLoad)
-- =========================================================
-- When WTEditDialog spawns a new placeable, it queues the desired config here.
-- workTrigger.lua:onLoad() calls popPendingCreate() to claim the first entry.
function WorkplaceSaveLoad:queuePendingCreate(data)
    if self.pendingCreates == nil then self.pendingCreates = {} end
    table.insert(self.pendingCreates, data)
    wtLog(string.format("Queued pending create for '%s' at (%.1f,%.1f,%.1f)",
        data.workplaceName or "?", data.posX or 0, data.posY or 0, data.posZ or 0))
end

-- Called by WorkTriggerPlaceable:onLoad() for newly placed placeables (no saved id).
-- Returns the queued config table and removes it from the queue, or nil if empty.
function WorkplaceSaveLoad:popPendingCreate()
    if self.pendingCreates == nil or #self.pendingCreates == 0 then return nil end
    local data = table.remove(self.pendingCreates, 1)
    wtLog(string.format("Popped pending create for '%s' (stableId=%s)",
        data.workplaceName or "?", tostring(data.stableId)))
    return data
end

-- Non-destructive peek: WorkplaceTrigger.new() uses this to claim the
-- server-assigned stableId during onLoad BEFORE popPendingCreate is called.
-- Returns the first entry or nil without removing it.
function WorkplaceSaveLoad:peekPendingCreate()
    if self.pendingCreates == nil or #self.pendingCreates == 0 then return nil end
    return self.pendingCreates[1]
end
