-- =========================================================
-- WorkplaceSystem.lua
-- Central coordinator - owns all subsystems.
-- Global reference: g_WorkplaceSystem
-- =========================================================
-- Pattern: NPCSystem.lua from FS25_NPCFavor
-- =========================================================

WorkplaceSystem = {}
WorkplaceSystem_mt = Class(WorkplaceSystem)

local LOG_PREFIX = "[WorkplaceTriggers] "

local function wtLog(msg)
    print(LOG_PREFIX .. tostring(msg))
end

-- =========================================================
-- Constructor
-- =========================================================
function WorkplaceSystem.new(mission, modDirectory, modName)
    local self = setmetatable({}, WorkplaceSystem_mt)

    self.mission      = mission
    self.modDirectory = modDirectory
    self.modName      = modName
    self.isInitialized = false

    -- Settings data (created immediately - needed before any subsystem)
    self.settings            = WorkplaceSettings.new()

    -- Subsystems (created here, initialized in onMissionLoaded)
    self.triggerManager      = WorkplaceTriggerManager.new(self)
    self.shiftTracker        = WorkplaceShiftTracker.new(self)
    self.financeIntegration  = WorkplaceFinanceIntegration.new(self)
    self.hud                 = WorkplaceHUD.new(self)
    self.gui                 = WorkplaceGUI.new(self)
    self.inputHandler        = WorkplaceInputHandler.new(self)
    self.saveLoad            = WorkplaceSaveLoad.new(self)
    self.settingsIntegration = WorkplaceSettingsIntegration.new(self)
    self.npcFavorIntegration = NPCFavorIntegration.new(self)
    self.workerCostsInteg    = WorkerCostsIntegration.new(self)

    wtLog("WorkplaceSystem created")
    return self
end

-- =========================================================
-- Mission Loaded
-- Called from main.lua after Mission00.loadMission00Finished
-- =========================================================
function WorkplaceSystem:onMissionLoaded()
    if self.isInitialized then
        wtLog("onMissionLoaded called but already initialized")
        return
    end

    wtLog("onMissionLoaded - initializing subsystems")

    -- Load settings first (other subsystems may read them at init)
    self.settings:load()

    self.triggerManager:initialize()
    self.shiftTracker:initialize()
    self.financeIntegration:initialize()
    self.hud:initialize()
    self.gui:initialize()
    self.inputHandler:initialize()
    self.saveLoad:initialize()
    self.settingsIntegration:initialize()
    self.npcFavorIntegration:initialize()
    self.workerCostsInteg:initialize()

    self.isInitialized = true

    wtLog("All subsystems initialized - mod ready")
    self:registerConsoleCommands()

    -- Server: load trigger data from the mod save file.
    -- This must happen AFTER all subsystems are initialized (saveLoad.isInitialized = true).
    -- Client: schedule a deferred sync request instead of sending immediately.
    -- Sending REQUEST_SYNC during onMissionLoaded() is too early — the server's
    -- broadcast back may not reach the client while the stream is still opening.
    -- The update() loop sends it after a short warm-up delay.
    if g_currentMission then
        if g_currentMission:getIsServer() then
            self:loadFromXMLFile(g_currentMission.missionInfo)
        else
            -- Arm the deferred sync. update() will fire it after SYNC_DELAY_SEC.
            self.syncPending      = true
            self.syncDelayTimer   = 0
            self.syncAttempts     = 0
            wtLog("Client: deferred trigger sync armed")
        end
    end

    -- Bedrock bridges (delegate-when-present; each no-ops if its bedrock mod is
    -- absent). Handles (g_currentMission.settingsHub / .masterHUD) are published by
    -- the bedrock mods at Mission00.load, so they are ready by now. Registration is
    -- guarded once by the isInitialized check at the top of this function.
    if WorkplaceSettingsHubBridge ~= nil then WorkplaceSettingsHubBridge.register() end
    if WorkplaceMasterHUDBridge  ~= nil then WorkplaceMasterHUDBridge.register()  end
end

-- =========================================================
-- Update (dt in milliseconds from FS25)
-- =========================================================
-- Seconds to wait before first REQUEST_SYNC attempt on client.
-- Gives the server stream time to fully open before we expect a broadcast back.
WorkplaceSystem.SYNC_DELAY_SEC   = 2.0
WorkplaceSystem.SYNC_RETRY_SEC   = 8.0
WorkplaceSystem.SYNC_MAX_ATTEMPTS = 5

function WorkplaceSystem:update(dt)
    if not self.isInitialized then return end

    -- Convert ms to seconds for subsystem use
    local dtSec = dt / 1000.0

    -- Deferred client sync: send REQUEST_SYNC after warm-up, retry until triggers arrive
    if self.syncPending and g_currentMission and not g_currentMission:getIsServer() then
        self.syncDelayTimer = (self.syncDelayTimer or 0) + dtSec
        local threshold = (self.syncAttempts == 0)
            and WorkplaceSystem.SYNC_DELAY_SEC
            or  WorkplaceSystem.SYNC_RETRY_SEC
        if self.syncDelayTimer >= threshold then
            self.syncDelayTimer = 0
            self.syncAttempts   = (self.syncAttempts or 0) + 1
            local triggerCount  = #self.triggerManager:getAllTriggers()
            wtLog(string.format("Client: sync attempt %d (have %d triggers)",
                self.syncAttempts, triggerCount))
            if triggerCount > 0 then
                -- We have triggers — sync succeeded (or we're the host)
                self.syncPending = false
                wtLog("Client: sync complete — triggers received")
            elseif self.syncAttempts <= WorkplaceSystem.SYNC_MAX_ATTEMPTS then
                WorkplaceMultiplayerEvent.sendRequestSync()
            else
                self.syncPending = false
                wtLog("Client: sync gave up after " .. WorkplaceSystem.SYNC_MAX_ATTEMPTS .. " attempts")
            end
        end
    end

    self.triggerManager:update(dtSec)
    self.shiftTracker:update(dtSec)
    self.hud:update(dtSec)
    self.gui:update(dtSec)
end

-- =========================================================
-- Draw (HUD rendering - ONLY valid in draw callbacks)
-- =========================================================
function WorkplaceSystem:draw()
    if not self.isInitialized then return end
    self.hud:draw()
    self.gui:draw()
end

-- =========================================================
-- GUI controls
-- =========================================================
function WorkplaceSystem:onMenuPressed()
    if not self.isInitialized then return end
    if self.gui then
        self.gui:toggle()
    end
end

-- =========================================================
-- Interact (E key pressed)
-- Called from main.lua input callback
-- =========================================================
function WorkplaceSystem:onInteractPressed()
    if not self.isInitialized then return end
    -- Do not process shift interactions while the manager GUI is open
    if self.gui and self.gui:isOpen() then return end

    if self.shiftTracker:isShiftActive() then
        -- Only allow ending the shift if it belongs to this local player's farm.
        -- shiftOwnerIsLocal=false means a different farm started it (listen-server case)
        -- — pressing E must not accidentally end someone else's shift.
        if self.shiftTracker.shiftOwnerIsLocal ~= false then
            WorkplaceMultiplayerEvent.sendShiftEnd()
        end
    else
        -- Start shift at nearest trigger
        local trigger = self.triggerManager:getNearestPlayerTrigger()
        if trigger then
            WorkplaceMultiplayerEvent.sendShiftStart(tostring(trigger.id))
        end
    end
end

-- =========================================================
-- Save / Load (delegated to WorkplaceSaveLoad)
-- =========================================================
function WorkplaceSystem:saveToXMLFile(missionInfo)
    if self.saveLoad then
        self.saveLoad:saveToXMLFile(missionInfo)
    end
end

function WorkplaceSystem:loadFromXMLFile(missionInfo)
    if self.saveLoad then
        self.saveLoad:loadFromXMLFile(missionInfo)
    end
end

-- =========================================================
-- =========================================================
-- Admin helper
-- Returns true if the local player has admin rights.
-- On a dedicated server, clients must authenticate with the
-- server admin password; the flag is stored in isMasterUser.
-- SP and listen-server hosts are always admin.
-- =========================================================
function WorkplaceSystem.isLocalPlayerAdmin()
    if g_currentMission == nil then return false end
    -- SP / listen-server host: always admin
    if g_currentMission:getIsServer() then return true end
    -- Dedicated server client: check isMasterUser flag
    if g_currentMission.isMasterUser ~= nil then
        return g_currentMission.isMasterUser == true
    end
    return false
end

-- =========================================================
-- Console Commands
-- Pattern: NPCFavor console command approach
-- =========================================================
function WorkplaceSystem:registerConsoleCommands()
    addConsoleCommand("wtHelp",   "Workplace Triggers - show available commands", "consoleWTHelp",   self)
    addConsoleCommand("wtStatus", "Workplace Triggers - show current shift status", "consoleWTStatus", self)
    addConsoleCommand("wtList",   "Workplace Triggers - list all placed triggers",   "consoleWTList",   self)
    addConsoleCommand("wtDebug",  "Workplace Triggers - toggle debug logging",        "consoleWTDebug",  self)
    addConsoleCommand("wtGui",    "Workplace Triggers - toggle the GUI manager",      "consoleWTGui",    self)
    wtLog("Console commands registered")
end

function WorkplaceSystem:consoleWTGui()
    if not self.isInitialized then return "System not initialized" end
    self:onMenuPressed()
    return "GUI " .. (self.gui:isOpen() and "opened" or "closed")
end

function WorkplaceSystem:consoleWTHelp()
    print("=== Workplace Triggers Commands ===")
    print("  wtHelp   - Show this help")
    print("  wtStatus - Show current shift status")
    print("  wtList   - List all placed workplace triggers")
    print("  wtDebug  - Toggle debug mode")
    return "Commands listed above"
end

function WorkplaceSystem:consoleWTStatus()
    if not self.isInitialized then return "System not initialized" end
    if self.shiftTracker:isShiftActive() then
        local name     = self.shiftTracker:getActiveWorkplaceName()
        local elapsed  = self.shiftTracker:getElapsedHours()
        local earned   = self.shiftTracker:getCurrentEarnings()
        return string.format("ON SHIFT at '%s' | %.2f hrs | $%d earned", name, elapsed, earned)
    else
        return "No active shift"
    end
end

function WorkplaceSystem:consoleWTList()
    if not self.isInitialized then return "System not initialized" end
    local triggers = self.triggerManager:getAllTriggers()
    if #triggers == 0 then
        return "No workplace triggers placed"
    end
    print(string.format("=== Workplace Triggers (%d placed) ===", #triggers))
    for i, t in ipairs(triggers) do
        print(string.format("  %d. '%s' | $%d/hr | pos: %.1f, %.1f, %.1f",
            i, t.workplaceName, t.hourlyWage, t.posX or 0, t.posY or 0, t.posZ or 0))
    end
    return string.format("%d triggers listed", #triggers)
end

function WorkplaceSystem:consoleWTDebug()
    self.debugMode = not (self.debugMode or false)
    wtLog("Debug mode: " .. tostring(self.debugMode))
    return "Debug mode: " .. tostring(self.debugMode)
end

-- =========================================================
-- Cleanup
-- =========================================================
function WorkplaceSystem:delete()
    wtLog("delete() called")

    if self.shiftTracker and self.shiftTracker:isShiftActive() then
        wtLog("Auto-ending active shift on unload")
        self.shiftTracker:endShift()
    end

    if self.hud         then self.hud:delete()                end
    if self.gui         then self.gui:delete()                end
    if self.inputHandler then self.inputHandler:delete()      end
    if self.triggerManager then self.triggerManager:delete()  end
    if self.shiftTracker   then self.shiftTracker:delete()    end
    if self.financeIntegration then self.financeIntegration:delete() end
    if self.saveLoad       then self.saveLoad:delete()        end
    if self.settingsIntegration then self.settingsIntegration:delete() end
    if self.npcFavorIntegration then self.npcFavorIntegration:delete() end
    if self.workerCostsInteg    then self.workerCostsInteg:delete()    end

    removeConsoleCommand("wtHelp")
    removeConsoleCommand("wtStatus")
    removeConsoleCommand("wtList")
    removeConsoleCommand("wtDebug")
    removeConsoleCommand("wtGui")

    self.isInitialized = false
    wtLog("WorkplaceSystem deleted")
end