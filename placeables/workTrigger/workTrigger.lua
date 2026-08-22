-- =========================================================
-- workTrigger.lua
-- FS25 Placeable specialization for the work trigger zone.
-- Contains only a trigger volume (no mesh geometry).
-- =========================================================
-- Pattern: WaterPump.lua from FS25_SeasonalCropStress
-- CRITICAL RULES:
--   - NEVER name i3d root node 'root' (silent load failure)
--   - addTrigger() second arg MUST be a string, not a function
--   - Trigger callback receives (triggerId, otherId, onEnter, onLeave, onStay)
-- =========================================================

WorkTriggerPlaceable = WorkTriggerPlaceable or {}
WorkTriggerPlaceable.MOD_NAME = (WorkplaceTriggersModName or g_currentModName)

local function wtLog(msg)
    print("[WorkplaceTriggers] Placeable: " .. tostring(msg))
end

-- =========================================================
-- SPECIALIZATION REGISTRATION
-- =========================================================
function WorkTriggerPlaceable.prerequisitesPresent(specializations)
    return true
end

function WorkTriggerPlaceable.registerFunctions(placeableType)
    -- Expose public function for trigger data access
    SpecializationUtil.registerFunction(placeableType, "getWorkplaceData", WorkTriggerPlaceable.getWorkplaceData)
    SpecializationUtil.registerFunction(placeableType, "setWorkplaceName", WorkTriggerPlaceable.setWorkplaceName)
    SpecializationUtil.registerFunction(placeableType, "setHourlyWage",    WorkTriggerPlaceable.setHourlyWage)
end

function WorkTriggerPlaceable.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad",   WorkTriggerPlaceable)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", WorkTriggerPlaceable)
end

-- =========================================================
-- LIFECYCLE: onLoad
-- Called by FS25 when the placeable is placed or loaded from save.
-- self.xmlFile is an XMLFile object (OOP API).
-- =========================================================
function WorkTriggerPlaceable.onLoad(self, savegame)
    wtLog("onLoad called for placeable id=" .. tostring(self.id))

    -- Defaults
    self.workplaceName  = "Workplace"
    self.hourlyWage     = 500
    self.triggerNodeId  = nil
    self.playerInside   = false
    self.triggerRadius  = 4.0  -- default trigger radius in meters

    -- Read custom config from the placeable XML
    if self.xmlFile ~= nil then
        local base = "placeable.workTriggerConfig"
        self.workplaceName = self.xmlFile:getString(base .. "#defaultName", self.workplaceName) or self.workplaceName
        self.hourlyWage    = self.xmlFile:getInt(   base .. "#hourlyWage",  self.hourlyWage)    or self.hourlyWage
        self.triggerRadius = self.xmlFile:getFloat( base .. "#triggerRadius", self.triggerRadius) or self.triggerRadius
    end

    -- Register the trigger volume node
    -- i3dMapping id "triggerNode" maps to the TransformGroup node in the i3d
    if self.nodeId ~= nil and self.nodeId ~= 0 then
        local triggerNode = I3DUtil.indexToObject(self.nodeId, "0>0")  -- first child of root
        if triggerNode ~= nil and triggerNode ~= 0 then
            -- CRITICAL: second arg to addTrigger MUST be a string (callback name)
            addTrigger(triggerNode, "onTriggerCallback", self)
            self.triggerNodeId = triggerNode
            wtLog("Trigger volume registered, nodeId=" .. tostring(triggerNode))
        else
            wtLog("WARNING: trigger child node not found under nodeId=" .. tostring(self.nodeId))
        end
    else
        wtLog("WARNING: self.nodeId is nil or 0 - trigger not registered")
    end

    -- Store position for proximity checks (world translation of placeable root)
    if self.nodeId and self.nodeId ~= 0 then
        local ok, x, y, z = pcall(function() return getWorldTranslation(self.nodeId) end)
        if ok and x then
            self.posX = x
            self.posY = y
            self.posZ = z
        end
    end

    -- Scale the bundled ground ring to match triggerRadius
    -- self.nodeId = workTrigger_base (the placeable root).
    -- Children: 0=triggerVolume, 1=testAreaStart, 2=groundRing
    if self.nodeId and self.nodeId ~= 0 then
        local ringNode = getChildAt(self.nodeId, 2)
        if ringNode and ringNode ~= 0 then
            local s = self.triggerRadius  -- mesh is r=1m, scale to triggerRadius
            setScale(ringNode, s, 1.0, s)
            self._groundRingNode = ringNode
            wtLog("Ground ring scaled to radius=" .. tostring(s))
        else
            wtLog("WARNING: groundRing node (child 2) not found")
        end
    end

    -- Build trigger data table for TriggerManager
    local triggerData = {
        id            = tostring(self.id),
        workplaceName = self.workplaceName,
        hourlyWage    = self.hourlyWage,
        triggerRadius = self.triggerRadius,
        posX          = self.posX or 0,
        posY          = self.posY or 0,
        posZ          = self.posZ or 0,
        rotY          = self.rotY or 0,
        playerInside  = false,
        placeableRef  = self,  -- back-reference for future use
    }

    -- Register with system
    if g_WorkplaceSystem and g_WorkplaceSystem.triggerManager then
        if g_WorkplaceSystem.saveLoad then
            -- For saved placeables: restore name/wage/radius by id
            g_WorkplaceSystem.saveLoad:applyPendingRestore(triggerData)
            -- For GUI-spawned placeables (new, no saved id match): pop the create queue
            -- savegame == nil means this is a fresh placement, not a load
            if savegame == nil then
                local pending = g_WorkplaceSystem.saveLoad:popPendingCreate()
                if pending then
                    -- CRITICAL: use the server-assigned stableId as the canonical ID.
                    -- triggerData.id was set to tostring(self.id) above (the engine's
                    -- local node handle), but WorkplaceTrigger.new() reads the same
                    -- pendingCreate via peekPendingCreate() and sets its own id to
                    -- pending.stableId.  Without this assignment the two objects end
                    -- up with different IDs and getTriggerById() never finds the entry,
                    -- so the marker stays "pending" and is never placed on the map.
                    if pending.stableId and pending.stableId ~= "" then
                        triggerData.id = pending.stableId
                    end
                    triggerData.workplaceName = pending.workplaceName
                    triggerData.hourlyWage    = pending.hourlyWage
                    triggerData.triggerRadius = pending.triggerRadius
                    self.workplaceName        = pending.workplaceName
                    self.hourlyWage           = pending.hourlyWage
                    self.triggerRadius        = pending.triggerRadius
                    wtLog(string.format("Applied pending create config: '%s' $%d/hr stableId=%s",
                        pending.workplaceName, pending.hourlyWage, tostring(pending.stableId)))
                end
            end
            -- Re-scale ground ring to match restored radius (was scaled to default before restore)
            if self._groundRingNode and self._groundRingNode ~= 0 then
                local s = triggerData.triggerRadius or self.triggerRadius
                setScale(self._groundRingNode, s, 1.0, s)
            end
        end
        g_WorkplaceSystem.triggerManager:registerTrigger(triggerData)
        -- Keep reference so trigger node callback can update it
        self._triggerData = triggerData
    else
        -- System not loaded yet - store locally, onMissionLoaded will pick it up
        self._triggerData = triggerData
        self._pendingRegistration = true
        wtLog("System not ready yet - pending registration for id=" .. tostring(self.id))
    end

    wtLog(string.format("Loaded: '%s' $%d/hr at (%.1f, %.1f, %.1f)",
        self.workplaceName, self.hourlyWage, self.posX or 0, self.posY or 0, self.posZ or 0))
end

-- =========================================================
-- Trigger Callback (player enters/leaves zone)
-- CRITICAL: callback name must match exactly what was passed to addTrigger()
-- =========================================================
function WorkTriggerPlaceable:onTriggerCallback(triggerId, otherId, onEnter, onLeave, onStay)
    -- Only react to the local player entity
    local playerNode = g_localPlayer and g_localPlayer.rootNode
    if playerNode == nil then
        -- Try mission player
        playerNode = g_currentMission and g_currentMission.player and g_currentMission.player.rootNode
    end

    if otherId ~= playerNode then return end

    if onEnter then
        if self._triggerData then
            self._triggerData.playerInside = true
        end
        wtLog(string.format("Player entered trigger '%s'", self.workplaceName))
    elseif onLeave then
        if self._triggerData then
            self._triggerData.playerInside = false
        end
        wtLog(string.format("Player left trigger '%s'", self.workplaceName))
        -- Grace period and endShiftOnLeave are handled by WorkplaceShiftTracker:updateZoneCheck().
        -- Do NOT call endShift() here - that would bypass the 10-second grace period entirely.
    end
end

-- =========================================================
-- Public API
-- =========================================================
function WorkTriggerPlaceable:getWorkplaceData()
    return self._triggerData
end

function WorkTriggerPlaceable:setWorkplaceName(name)
    self.workplaceName = name
    if self._triggerData then
        self._triggerData.workplaceName = name
    end
end

function WorkTriggerPlaceable:setHourlyWage(wage)
    self.hourlyWage = wage
    if self._triggerData then
        self._triggerData.hourlyWage = wage
    end
end

-- =========================================================
-- LIFECYCLE: onDelete
-- Called when placeable is sold/removed.
-- =========================================================
function WorkTriggerPlaceable.onDelete(self)
    wtLog("onDelete called for id=" .. tostring(self.id))

    -- End any active shift at this trigger before removing
    if g_WorkplaceSystem and g_WorkplaceSystem.shiftTracker then
        local tracker = g_WorkplaceSystem.shiftTracker
        if tracker:isShiftActive() and tracker.activeTriggerId == tostring(self.id) then
            wtLog("Ending active shift because trigger is being removed")
            tracker:endShift()
        end
    end

    -- Remove trigger volume
    if self.triggerNodeId ~= nil and self.triggerNodeId ~= 0 then
        removeTrigger(self.triggerNodeId)
        self.triggerNodeId = nil
    end

    -- Deregister from manager.
    -- Use the stableId stored in _triggerData (set during onLoad) rather than
    -- tostring(self.id), because _triggerData.id was corrected to the
    -- server-assigned stableId when the pendingCreate was applied.
    if g_WorkplaceSystem and g_WorkplaceSystem.triggerManager then
        local deregId = (self._triggerData and self._triggerData.id) or tostring(self.id)
        g_WorkplaceSystem.triggerManager:deregisterTrigger(deregId)
    end

    self._triggerData = nil
end
