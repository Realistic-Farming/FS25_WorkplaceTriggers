-- =========================================================
-- FS25 Workplace Triggers (v0.1.0.0)
-- Placeable Off-Farm Work System
-- =========================================================
-- Author: TisonK
-- License: CC BY-NC-ND 4.0
-- =========================================================
-- CRITICAL REMINDERS (read before editing):
--   1. NEVER name i3d root node 'root' - silent load failure
--   2. addTrigger() second arg MUST be a string, not a function
--   3. No unicode in Lua files - FS25 Lua 5.1 parser rejects it
--   4. XML save: use OOP xmlFile:setInt() etc. (not legacy globals)
--   5. HUD Y=0 at BOTTOM, increases UP
--   6. No os.time() - use g_currentMission.time
--   7. No goto, no continue (Lua 5.1)
-- =========================================================

local modDirectory = g_currentModDirectory
local modName      = g_currentModName

local modItem    = g_modManager:getModByName(modName)
local modVersion = modItem and modItem.version or "0.1.0.0"

print("[WorkplaceTriggers] Starting mod initialization...")

-- Load all source files in dependency order
if modDirectory then
    print("[WorkplaceTriggers] Loading source files...")

    source(modDirectory .. "src/WTMapHotspot.lua")
    source(modDirectory .. "src/WorkplaceTriggerManager.lua")
    source(modDirectory .. "src/WorkplaceShiftTracker.lua")
    source(modDirectory .. "src/WorkplaceFinanceIntegration.lua")
    source(modDirectory .. "src/WorkplaceHUD.lua")
    source(modDirectory .. "src/WTDialogLoader.lua")
    source(modDirectory .. "src/WTListDialog.lua")
    source(modDirectory .. "src/WTEditDialog.lua")
    source(modDirectory .. "src/WorkplaceGUI.lua")
    source(modDirectory .. "src/WorkplaceInputHandler.lua")
    source(modDirectory .. "src/WorkplaceSaveLoad.lua")
    source(modDirectory .. "src/WorkplaceSettings.lua")
    source(modDirectory .. "src/WorkplaceSettingsIntegration.lua")
    source(modDirectory .. "src/integrations/WTNetworkSyncBridge.lua")
    source(modDirectory .. "src/NPCFavorIntegration.lua")
    source(modDirectory .. "src/WorkerCostsIntegration.lua")
    source(modDirectory .. "src/WorkplaceSystem.lua")
    source(modDirectory .. "src/WorkplaceStateLedgerBridge.lua")
    source(modDirectory .. "src/WorkplaceSettingsHubBridge.lua")
    source(modDirectory .. "src/WorkplaceMasterHUDBridge.lua")

    print("[WorkplaceTriggers] All source files loaded")
    -- Init dialog loader with mod path
    WTDialogLoader.init(modDirectory)
else
    print("[WorkplaceTriggers] ERROR - Could not find mod directory!")
    return
end

-- Module-level system reference
local workplaceSystem = nil

local function isMissionValid(mission)
    return mission ~= nil and not mission.cancelLoading
end

-- =========================================================
-- Mission Load
-- =========================================================
local function load(mission)
    print("[WorkplaceTriggers] load() called")
    if not isMissionValid(mission) then
        print("[WorkplaceTriggers] Mission not valid, skipping")
        return
    end
    if workplaceSystem ~= nil then
        print("[WorkplaceTriggers] Already initialized")
        return
    end

    print("[WorkplaceTriggers] Creating WorkplaceSystem v" .. modVersion)
    workplaceSystem = WorkplaceSystem.new(mission, modDirectory, modName)
    if workplaceSystem then
        getfenv(0)["g_WorkplaceSystem"] = workplaceSystem
        -- Cross-mod bridge via g_currentMission (true shared global)
        mission.workplaceTriggers = workplaceSystem
        print("[WorkplaceTriggers] WorkplaceSystem created successfully")
    else
        print("[WorkplaceTriggers] ERROR - Failed to create WorkplaceSystem")
    end
end

-- =========================================================
-- Mission Load Finished
-- =========================================================
local function loadedMission(mission, node)
    print("[WorkplaceTriggers] loadedMission() called")
    if not isMissionValid(mission) then return end
    if workplaceSystem == nil then
        print("[WorkplaceTriggers] workplaceSystem nil in loadedMission, attempting late init")
        load(mission)
    end
    if workplaceSystem then
        workplaceSystem:onMissionLoaded()
        -- Install map dot hook after mission is fully loaded
        if workplaceSystem.triggerManager then
            workplaceSystem.triggerManager:installMapHook()
        end
        -- Startup banner (client only — server has no HUD)
        if workplaceSystem.hud and g_currentMission and g_currentMission:getIsClient() then
            workplaceSystem.hud:showFlash(
                "Workplace Triggers v" .. modVersion .. " loaded",
                {0.3, 0.85, 1, 1},
                5.0
            )
        end
    end
end

-- =========================================================
-- Unload
-- =========================================================
local function unload()
    print("[WorkplaceTriggers] unload() called")
    if workplaceSystem ~= nil then
        workplaceSystem:delete()
        workplaceSystem = nil
        getfenv(0)["g_WorkplaceSystem"] = nil
        print("[WorkplaceTriggers] Unloaded successfully")
    end
end

-- =========================================================
-- FS25 Game Hooks
-- =========================================================
print("[WorkplaceTriggers] Setting up game hooks...")

if Mission00 and Mission00.load then
    Mission00.load = Utils.prependedFunction(Mission00.load, load)
elseif g_currentMission and g_currentMission.load then
    g_currentMission.load = Utils.prependedFunction(g_currentMission.load, load)
end

if Mission00 and Mission00.loadMission00Finished then
    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, loadedMission)
end

if FSBaseMission and FSBaseMission.delete then
    FSBaseMission.delete = Utils.appendedFunction(FSBaseMission.delete, unload)
end

-- Update hook
if FSBaseMission and FSBaseMission.update then
    FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(mission, dt)
        -- Lazy-init fallback: Mission00.loadMission00Finished does not fire in MP (listen-server)
        -- mode. Detect on the first update frame and initialize then.
        if workplaceSystem and not workplaceSystem.isInitialized then
            print("[WorkplaceTriggers] Lazy-init triggered from update hook")
            workplaceSystem:onMissionLoaded()
            if workplaceSystem.triggerManager then
                workplaceSystem.triggerManager:installMapHook()
            end
            if workplaceSystem.hud and g_currentMission and g_currentMission:getIsClient() then
                workplaceSystem.hud:showFlash(
                    "Workplace Triggers v" .. modVersion .. " loaded",
                    {0.3, 0.85, 1, 1},
                    5.0
                )
            end
        end
        if workplaceSystem then
            workplaceSystem:update(dt)
        end
    end)
end

-- Draw hook (HUD rendering MUST be in draw callbacks)
if FSBaseMission and FSBaseMission.draw then
    FSBaseMission.draw = Utils.appendedFunction(FSBaseMission.draw, function(mission)
        -- When MasterHUD is present it owns the single draw loop (our draw was
        -- registered as a self-draw via the bridge); stand down so the HUD never
        -- draws twice. Absent MasterHUD, this hook runs the draw as before.
        if WorkplaceMasterHUDBridge ~= nil and WorkplaceMasterHUDBridge.active then return end
        if workplaceSystem then
            workplaceSystem:draw()
        end
    end)
end

-- =========================================================
-- F4 / WT_MENU Input Binding (open/close GUI)
-- =========================================================
local wtMenuActionEventId  = nil
local wtMenuOriginalFunc   = nil

local function wtMenuActionCallback(self, actionName, inputValue, callbackState, isAnalog)
    if inputValue <= 0 then return end
    if not workplaceSystem then return end
    workplaceSystem:onMenuPressed()
end

local function hookWTMenuInput()
    if wtMenuOriginalFunc ~= nil then return end
    if PlayerInputComponent == nil or PlayerInputComponent.registerActionEvents == nil then return end

    wtMenuOriginalFunc = PlayerInputComponent.registerActionEvents

    PlayerInputComponent.registerActionEvents = function(inputComponent, ...)
        wtMenuOriginalFunc(inputComponent, ...)

        if inputComponent.player ~= nil and inputComponent.player.isOwner then
            g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

            local actionId = InputAction.WT_MENU
            if actionId ~= nil then
                local success, eventId = g_inputBinding:registerActionEvent(
                    actionId,
                    WorkplaceSystem,
                    wtMenuActionCallback,
                    false, true, false, true, nil, true
                )
                if success and eventId ~= nil then
                    wtMenuActionEventId = eventId
                    g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_NORMAL)
                    g_inputBinding:setActionEventText(eventId,
                        g_i18n:getText("wt_input_open_menu") or "[F4] Workplace Manager")
                end
            end

            g_inputBinding:endActionEventsModification()
        end
    end
end

hookWTMenuInput()

-- =========================================================
-- E-Key Input Binding (RVB pattern from NPCFavor)
-- =========================================================
local wtInteractActionEventId    = nil
local wtInteractOriginalFunc     = nil

local function wtInteractActionCallback(self, actionName, inputValue, callbackState, isAnalog)
    if inputValue <= 0 then return end
    if not workplaceSystem then return end
    if g_gui:getIsDialogVisible() then return end
    workplaceSystem:onInteractPressed()
end

local function hookWTInteractInput()
    if wtInteractOriginalFunc ~= nil then return end
    if PlayerInputComponent == nil or PlayerInputComponent.registerActionEvents == nil then
        print("[WorkplaceTriggers] PlayerInputComponent.registerActionEvents not available")
        return
    end

    wtInteractOriginalFunc = PlayerInputComponent.registerActionEvents

    PlayerInputComponent.registerActionEvents = function(inputComponent, ...)
        wtInteractOriginalFunc(inputComponent, ...)

        if inputComponent.player ~= nil and inputComponent.player.isOwner then
            g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

            local actionId = InputAction.WT_INTERACT
            if actionId ~= nil then
                local success, eventId = g_inputBinding:registerActionEvent(
                    actionId,
                    WorkplaceSystem,         -- class table, not instance (required by FS25)
                    wtInteractActionCallback,
                    false,   -- triggerUp
                    true,    -- triggerDown
                    false,   -- triggerAlways
                    false,   -- startActive (MUST be false - shown dynamically)
                    nil,
                    true     -- disableConflictingBindings
                )
                if success and eventId ~= nil then
                    wtInteractActionEventId = eventId
                end
            end

            g_inputBinding:endActionEventsModification()
        end
    end
end

hookWTInteractInput()

-- =========================================================
-- Shift Key Input Binding (WT_HUD_EDIT) - toggle HUD edit mode
-- =========================================================
local wtHudEditActionEventId = nil
local wtHudEditOriginalFunc  = nil

local function wtHudEditActionCallback(self, actionName, inputValue, callbackState, isAnalog)
    if inputValue <= 0 then return end
    if not workplaceSystem then return end
    if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then return end
    if workplaceSystem.hud then
        workplaceSystem.hud:toggleEditMode()
    end
end

local function hookWTHudEditInput()
    if wtHudEditOriginalFunc ~= nil then return end
    if PlayerInputComponent == nil or PlayerInputComponent.registerActionEvents == nil then return end

    wtHudEditOriginalFunc = PlayerInputComponent.registerActionEvents

    PlayerInputComponent.registerActionEvents = function(inputComponent, ...)
        wtHudEditOriginalFunc(inputComponent, ...)

        if inputComponent.player ~= nil and inputComponent.player.isOwner then
            g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

            local actionId = InputAction.WT_HUD_EDIT
            if actionId ~= nil then
                local success, eventId = g_inputBinding:registerActionEvent(
                    actionId,
                    WorkplaceSystem,
                    wtHudEditActionCallback,
                    false, true, false, true, nil, true
                )
                if success and eventId ~= nil then
                    wtHudEditActionEventId = eventId
                    g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_NORMAL)
                    g_inputBinding:setActionEventText(eventId,
                        g_i18n:getText("wt_input_hud_edit") or "[Shift] HUD Edit Mode")
                end
            end

            g_inputBinding:endActionEventsModification()
        end
    end
end

hookWTHudEditInput()


-- Update loop: control E-key prompt visibility based on trigger proximity
if FSBaseMission and FSBaseMission.update then
    FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(mission, dt)
        if g_inputBinding == nil or not workplaceSystem then return end
        if wtInteractActionEventId == nil then return end

        local shouldShow = false
        local promptText = g_i18n:getText("wt_input_interact") or "Start Shift"
        local isDialogOpen = g_gui:getIsDialogVisible()

        if not isDialogOpen and workplaceSystem.triggerManager then
            local nearbyTrigger = workplaceSystem.triggerManager:getNearestPlayerTrigger()
            if nearbyTrigger then
                local st = workplaceSystem.shiftTracker
                -- Only show "End Shift" when THIS player's farm owns the active shift.
                -- shiftOwnerIsLocal=false means another farm is working — show nothing
                -- near their trigger so the player can't accidentally interfere.
                local ownShiftActive = st and st:isShiftActive() and st.shiftOwnerIsLocal ~= false
                shouldShow = true
                if ownShiftActive then
                    local activeName = st:getActiveWorkplaceName()
                    promptText = string.format(
                        g_i18n:getText("wt_input_end_shift") or "End Shift at %s",
                        activeName or "Workplace"
                    )
                else
                    local name = nearbyTrigger.workplaceName or "Workplace"
                    promptText = string.format(
                        g_i18n:getText("wt_input_start_shift") or "Start Shift at %s",
                        name
                    )
                end
            end
        end

        g_inputBinding:setActionEventTextPriority(wtInteractActionEventId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(wtInteractActionEventId, shouldShow)
        g_inputBinding:setActionEventActive(wtInteractActionEventId, shouldShow)
        if shouldShow then
            g_inputBinding:setActionEventText(wtInteractActionEventId, promptText)
        end
    end)
end

-- =========================================================
-- Save / Load Persistence
-- =========================================================
if FSCareerMissionInfo and FSCareerMissionInfo.saveToXMLFile then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
        FSCareerMissionInfo.saveToXMLFile,
        function(missionInfo)
            -- Only save on the authoritative server (listen-server or dedicated server process).
            -- On a dedicated-server CLIENT, FSCareerMissionInfo.saveToXMLFile also fires for
            -- local client data, but our trigger table is server-authoritative and the client
            -- may not have received all TYPE_TRIGGER_CREATED events yet — skipping avoids
            -- misleading "Saved 0 triggers" log entries from the client side.
            if g_currentMission and not g_currentMission:getIsServer() then return end
            if workplaceSystem and workplaceSystem.isInitialized then
                workplaceSystem:saveToXMLFile(missionInfo)
            end
        end
    )
end

-- =========================================================
-- Mod Event Listener
-- =========================================================
addModEventListener({
    onLoad = function()
        print("[WorkplaceTriggers] Mod event listener: onLoad")
    end,
    onUnload = function()
        unload()
    end,
    onSavegameLoaded = function()
        print("[WorkplaceTriggers] onSavegameLoaded")
        if workplaceSystem then
            workplaceSystem:onMissionLoaded()
        end
    end,
    -- Mouse event hook for HUD drag/resize in edit mode.
    -- addModEventListener is the correct pattern (mirrors NPCFavor): the engine
    -- calls mouseEvent on all registered listeners with normalized 0-1 coords.
    -- The old FSBaseMission.mouseEvent = Utils.appendedFunction(...) approach
    -- silently no-ops when FSBaseMission.mouseEvent is nil at load time, which
    -- is why drag and resize never worked.
    mouseEvent = function(self, posX, posY, isDown, isUp, button)
        local isGuiOpen = g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible())
        if workplaceSystem and workplaceSystem.hud and workplaceSystem.hud.editMode and not isGuiOpen then
            workplaceSystem.hud:mouseEvent(posX, posY, isDown, isUp, button)
        end
    end
})

-- Late join: already in a mission
if g_currentMission and not workplaceSystem then
    print("[WorkplaceTriggers] Already in mission - late init")
    load(g_currentMission)
    if g_currentMission.placeables and workplaceSystem then
        workplaceSystem:onMissionLoaded()
    end
end

print("==============================================")
print("  FS25 Workplace Triggers v" .. modVersion .. " LOADED")
print("  Turn any location into a workplace!")
print("  Pay schedules: Hourly / Flat / Daily")
print("  Type 'wtHelp' for console commands")
print("==============================================")