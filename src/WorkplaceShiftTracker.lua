-- =========================================================
-- WorkplaceShiftTracker.lua
-- Tracks the active shift: start/stop, elapsed game time,
-- and earnings calculation.
-- =========================================================
-- Uses g_currentMission.time (milliseconds since mission start)
-- Never use os.time() - forbidden in FS25 Lua 5.1 sandbox.
-- =========================================================

WorkplaceShiftTracker = {}
WorkplaceShiftTracker_mt = Class(WorkplaceShiftTracker)

-- Pay schedule types
WorkplaceShiftTracker.PAY_HOURLY = "hourly"   -- wage * in-game hours elapsed
WorkplaceShiftTracker.PAY_FLAT   = "flat"     -- fixed amount paid at end of shift
WorkplaceShiftTracker.PAY_DAILY  = "daily"    -- wage paid once per in-game day worked

-- In-game time multiplier: FS25 default is 120x (1 real second = 2 in-game minutes).
-- g_currentMission.missionInfo.timeScale stores the speed factor.
-- We calculate real elapsed ms and convert to in-game hours:
--   inGameHours = (elapsedRealMs * timeScale) / (1000 * 60 * 60)
-- where timeScale is e.g. 120 for the FS25 default 120x speed.

local function wtLog(msg)
    print("[WorkplaceTriggers] ShiftTracker: " .. tostring(msg))
end

function WorkplaceShiftTracker.new(system)
    local self = setmetatable({}, WorkplaceShiftTracker_mt)
    self.system = system

    self.activeTriggerId    = nil
    self.activeWorkplaceName = nil
    self.activeHourlyWage   = 0
    self.activePaySchedule  = WorkplaceShiftTracker.PAY_HOURLY
    self.activeTimeMultiplier = 0     -- 0=Auto, 1=x1(real), 3=x3, 5=x5, 10=x10
    self.activeFarmId       = 1     -- farm to pay when shift ends (set from shift-start event)
    self.shiftStartTime     = nil   -- g_currentMission.time at shift start (ms)
    self.shiftElapsedMs     = 0     -- kept for reset/compat; not accumulated during play
    self.shiftOwnerIsLocal  = true  -- false when shift belongs to a remote MP client
    self.totalEarned        = 0     -- lifetime earnings this session

    -- -------------------------------------------------------
    -- Per-farm shift table (SERVER ONLY).
    -- Keyed by farmId (integer).  Each entry mirrors the single-
    -- slot fields above so multiple farms can have concurrent
    -- active shifts without clobbering each other.
    -- Structure per entry:
    --   { triggerId, workplaceName, hourlyWage, paySchedule,
    --     timeMultiplier, shiftStartTime }
    -- -------------------------------------------------------
    self._farmShifts = {}

    -- Shift history log (capped at 50 entries)
    self.shiftHistory      = {}
    self.MAX_HISTORY       = 50

    self.isInitialized = false
    return self
end

function WorkplaceShiftTracker:initialize()
    self.isInitialized = true
    wtLog("Initialized")
end

-- =========================================================
-- Per-farm shift helpers (SERVER ONLY)
-- These allow multiple farms to have concurrent active shifts
-- without the single-slot fields interfering with each other.
-- =========================================================

function WorkplaceShiftTracker:startShiftForFarm(farmId, trigger)
    if trigger == nil then
        wtLog("startShiftForFarm: nil trigger for farm " .. tostring(farmId))
        return
    end
    local fid = farmId or 1
    -- End any previously active shift for this same farm first
    if self._farmShifts[fid] then
        wtLog("startShiftForFarm: farm " .. tostring(fid) .. " already has a shift — ending it first")
        self:endShiftForFarm(fid)
    end
    self._farmShifts[fid] = {
        triggerId      = trigger.id,
        workplaceName  = trigger.workplaceName  or "Workplace",
        hourlyWage     = trigger.hourlyWage     or 500,
        paySchedule    = trigger.paySchedule    or WorkplaceShiftTracker.PAY_HOURLY,
        timeMultiplier = trigger.timeMultiplier or 0,
        shiftStartTime = self:getCurrentMissionTime(),
    }
    wtLog(string.format("startShiftForFarm: farm=%d trigger='%s' $%d/hr",
        fid, trigger.workplaceName or "?", trigger.hourlyWage or 500))
end

function WorkplaceShiftTracker:isShiftActiveForFarm(farmId)
    return self._farmShifts[farmId or 1] ~= nil
end

-- Returns current earnings for a specific farm's active shift (server-side).
function WorkplaceShiftTracker:getCurrentEarningsForFarm(farmId)
    local fid    = farmId or 1
    local entry  = self._farmShifts[fid]
    if entry == nil then return 0 end

    local mult   = (self.system and self.system.settings and self.system.settings.wageMultiplier) or 1.0
    local sched  = entry.paySchedule or WorkplaceShiftTracker.PAY_HOURLY

    -- Compute elapsed hours for this specific farm's shift
    local realElapsedMs = self:getCurrentMissionTime() - (entry.shiftStartTime or 0)
    if realElapsedMs < 0 then realElapsedMs = 0 end
    local timeScale
    if (entry.timeMultiplier or 0) == 0 then
        timeScale = self:getMissionTimeScale()
    else
        timeScale = entry.timeMultiplier
    end
    local hours = (realElapsedMs * timeScale) / (1000.0 * 60.0 * 60.0)

    if sched == WorkplaceShiftTracker.PAY_FLAT then
        return math.floor(entry.hourlyWage * mult)
    elseif sched == WorkplaceShiftTracker.PAY_DAILY then
        return math.floor(entry.hourlyWage * (hours / 24.0) * mult)
    else
        return math.floor(entry.hourlyWage * hours * mult)
    end
end

-- Ends a specific farm's shift, pays them, and returns the amount earned.
-- Does NOT touch the single-slot fields used by client-side logic.
function WorkplaceShiftTracker:endShiftForFarm(farmId)
    local fid   = farmId or 1
    local entry = self._farmShifts[fid]
    if entry == nil then
        wtLog("endShiftForFarm: no active shift for farm " .. tostring(fid))
        return 0
    end

    local earnings     = self:getCurrentEarningsForFarm(fid)
    local realElapsedMs = self:getCurrentMissionTime() - (entry.shiftStartTime or 0)
    if realElapsedMs < 0 then realElapsedMs = 0 end
    local timeScale    = ((entry.timeMultiplier or 0) == 0)
                         and self:getMissionTimeScale() or entry.timeMultiplier
    local elapsedHours = (realElapsedMs * timeScale) / (1000.0 * 60.0 * 60.0)

    wtLog(string.format("endShiftForFarm: farm=%d '%s' %.2f hrs $%d",
        fid, entry.workplaceName or "?", elapsedHours, earnings))

    -- Record in history
    self:recordHistory(entry.workplaceName, elapsedHours, earnings, entry.paySchedule)

    -- Pay the farm
    if earnings > 0 then
        self.system.financeIntegration:addMoney(earnings, entry.workplaceName, fid)
    end
    self.totalEarned = self.totalEarned + earnings

    -- Integration hooks
    local activeTrigger = self.system.triggerManager
        and self.system.triggerManager:getTriggerById(entry.triggerId)
    if self.system.npcFavorIntegration then
        self.system.npcFavorIntegration:onShiftCompleted(activeTrigger, elapsedHours)
    end
    if self.system.workerCostsInteg then
        self.system.workerCostsInteg:onShiftCompleted(activeTrigger, earnings)
    end

    -- Remove from table
    local workplaceName = entry.workplaceName
    self._farmShifts[fid] = nil
    return earnings, workplaceName
end

-- Penalty variant: pays 20% and clears the slot.
function WorkplaceShiftTracker:endShiftPenaltyForFarm(farmId)
    local fid   = farmId or 1
    local entry = self._farmShifts[fid]
    if entry == nil then
        wtLog("endShiftPenaltyForFarm: no active shift for farm " .. tostring(fid))
        return 0
    end

    local fullEarnings = self:getCurrentEarningsForFarm(fid)
    local penaltyPay   = math.floor(fullEarnings * WorkplaceShiftTracker.ABANDON_PAY_FRACTION)

    local realElapsedMs = self:getCurrentMissionTime() - (entry.shiftStartTime or 0)
    if realElapsedMs < 0 then realElapsedMs = 0 end
    local timeScale    = ((entry.timeMultiplier or 0) == 0)
                         and self:getMissionTimeScale() or entry.timeMultiplier
    local elapsedHours = (realElapsedMs * timeScale) / (1000.0 * 60.0 * 60.0)

    wtLog(string.format("endShiftPenaltyForFarm: farm=%d '%s' %.2f hrs full=$%d penalty=$%d",
        fid, entry.workplaceName or "?", elapsedHours, fullEarnings, penaltyPay))

    self:recordHistory(entry.workplaceName, elapsedHours, penaltyPay, entry.paySchedule)

    if penaltyPay > 0 then
        self.system.financeIntegration:addMoney(penaltyPay, entry.workplaceName, fid)
    end
    self.totalEarned = self.totalEarned + penaltyPay

    local activeTrigger = self.system.triggerManager
        and self.system.triggerManager:getTriggerById(entry.triggerId)
    if self.system.npcFavorIntegration then
        self.system.npcFavorIntegration:onShiftCompleted(activeTrigger, elapsedHours)
    end
    if self.system.workerCostsInteg then
        self.system.workerCostsInteg:onShiftCompleted(activeTrigger, penaltyPay)
    end

    local workplaceName = entry.workplaceName
    self._farmShifts[fid] = nil
    return penaltyPay, workplaceName
end

-- =========================================================
-- Shift Control
-- =========================================================
-- silentStart=true suppresses the HUD notification (used by the server on a listen-server
-- so the host player doesn't see a shift-started popup for a remote farm's shift; the owning
-- client gets its HUD update via the TYPE_SHIFT_CONFIRM broadcast instead).
function WorkplaceShiftTracker:startShift(trigger, silentStart)
    if trigger == nil then
        wtLog("startShift: nil trigger")
        return
    end

    if self:isShiftActive() then
        wtLog("startShift: shift already active, ending first")
        self:endShift()
    end

    self.activeTriggerId     = trigger.id
    self.activeWorkplaceName = trigger.workplaceName or "Workplace"
    self.activeHourlyWage    = trigger.hourlyWage or 500
    self.activePaySchedule   = trigger.paySchedule or WorkplaceShiftTracker.PAY_HOURLY
    self.activeTimeMultiplier = trigger.timeMultiplier or 0
    self.shiftStartTime      = self:getCurrentMissionTime()
    self.shiftElapsedMs      = 0
    self.shiftOwnerIsLocal   = true  -- caller sets false for remote-client shifts

    wtLog(string.format("Shift started at '%s' | $%d/hr", self.activeWorkplaceName, self.activeHourlyWage))

    -- Notify HUD (client-only: dedicated server has no g_i18n / rendering context)
    -- Suppressed when silentStart=true (listen-server serving a remote farm's shift)
    if not silentStart and self.system.hud and g_currentMission and g_currentMission:getIsClient() then
        self.system.hud:onShiftStarted(self.activeWorkplaceName, self.activeHourlyWage)
    end
end

function WorkplaceShiftTracker:endShift()
    if not self:isShiftActive() then
        wtLog("endShift: no active shift")
        return
    end

    local earnings = self:getCurrentEarnings()
    local elapsedHours = self:getElapsedHours()

    wtLog(string.format("Shift ended at '%s' | %.2f hrs | $%d earned",
        self.activeWorkplaceName, elapsedHours, earnings))

    -- Record in history
    self:recordHistory(self.activeWorkplaceName, elapsedHours, earnings, self.activePaySchedule)

    -- Pay the farm (use activeFarmId set at shift start from the client's event)
    if earnings > 0 then
        self.system.financeIntegration:addMoney(earnings, self.activeWorkplaceName, self.activeFarmId)
    end

    self.totalEarned = self.totalEarned + earnings

    -- Notify HUD (client-only: dedicated server has no g_i18n / rendering context)
    if self.system.hud and g_currentMission and g_currentMission:getIsClient() then
        self.system.hud:onShiftEnded(self.activeWorkplaceName, earnings)
    end

    -- Notify integrations
    local activeTrigger = self.system.triggerManager
        and self.system.triggerManager:getTriggerById(self.activeTriggerId)
    if self.system.npcFavorIntegration then
        self.system.npcFavorIntegration:onShiftCompleted(activeTrigger, elapsedHours)
    end
    if self.system.workerCostsInteg then
        self.system.workerCostsInteg:onShiftCompleted(activeTrigger, earnings)
    end

    -- Reset state
    self.activeTriggerId     = nil
    self.activeWorkplaceName = nil
    self.activeHourlyWage    = 0
    self.activePaySchedule    = WorkplaceShiftTracker.PAY_HOURLY
    self.activeTimeMultiplier = 0
    self.activeFarmId         = 1
    self.shiftStartTime      = nil
    self.shiftElapsedMs      = 0
    self.shiftOwnerIsLocal   = true
end

-- =========================================================
-- Penalty End (player abandoned zone during countdown)
-- Pays 20% of what would have been earned and notifies player
-- =========================================================
WorkplaceShiftTracker.ABANDON_PAY_FRACTION = 0.20  -- 20% payout on abandon

function WorkplaceShiftTracker:endShiftPenalty()
    if not self:isShiftActive() then
        wtLog("endShiftPenalty: no active shift")
        return
    end

    local fullEarnings = self:getCurrentEarnings()
    local penaltyPay   = math.floor(fullEarnings * self.ABANDON_PAY_FRACTION)
    local elapsedHours = self:getElapsedHours()

    wtLog(string.format(
        "Shift ABANDONED at '%s' | %.2f hrs | full=$%d | penalty pay=$%d (20%%)",
        self.activeWorkplaceName, elapsedHours, fullEarnings, penaltyPay))

    -- Record in history with the reduced amount
    self:recordHistory(self.activeWorkplaceName, elapsedHours, penaltyPay, self.activePaySchedule)

    -- Pay only the penalty fraction
    if penaltyPay > 0 then
        self.system.financeIntegration:addMoney(penaltyPay, self.activeWorkplaceName, self.activeFarmId)
    end

    self.totalEarned = self.totalEarned + penaltyPay

    -- Notify HUD with the penalty message (client-only)
    if self.system.hud and g_currentMission and g_currentMission:getIsClient() then
        self.system.hud:onShiftAbandonedPenalty(self.activeWorkplaceName, penaltyPay, fullEarnings)
    end

    -- Notify integrations (pass reduced earnings)
    local activeTrigger = self.system.triggerManager
        and self.system.triggerManager:getTriggerById(self.activeTriggerId)
    if self.system.npcFavorIntegration then
        self.system.npcFavorIntegration:onShiftCompleted(activeTrigger, elapsedHours)
    end
    if self.system.workerCostsInteg then
        self.system.workerCostsInteg:onShiftCompleted(activeTrigger, penaltyPay)
    end

    -- Reset state
    self.activeTriggerId     = nil
    self.activeWorkplaceName = nil
    self.activeHourlyWage    = 0
    self.activePaySchedule    = WorkplaceShiftTracker.PAY_HOURLY
    self.activeTimeMultiplier = 0
    self.activeFarmId         = 1
    self.shiftStartTime      = nil
    self.shiftElapsedMs      = 0
    self.shiftOwnerIsLocal   = true
end

-- =========================================================
-- Update
-- =========================================================
-- Grace period before shift is auto-cancelled when player leaves zone
WorkplaceShiftTracker.WARN_GRACE_SECONDS = 10.0   -- seconds to return before cancel
WorkplaceShiftTracker.WARN_EXTRA_RADIUS  = 8.0    -- metres beyond trigger radius before countdown starts

function WorkplaceShiftTracker:update(dtSec)
    if not self.isInitialized then return end
    if not self:isShiftActive() then return end

    -- Elapsed time is computed on-the-fly from shiftStartTime in getElapsedHours(),
    -- so both server and client stay in sync with the shared game clock.
    self:updateZoneCheck(dtSec)
end

function WorkplaceShiftTracker:updateZoneCheck(dtSec)
    -- Zone tracking must run on the player's own client machine only.
    -- On a headless dedicated server there is no local player at all.
    -- On a listen-server (getIsServer() AND getIsClient()), the host's local player
    -- would be used for zone checks, but the active shift may belong to a remote client
    -- (Dafke, etc.) — using the host's position for their zone would cause false
    -- penalties and prevent them from stopping the shift with the E key.
    -- Remote clients track their own zone and send TYPE_SHIFT_END when needed.
    if not g_currentMission:getIsClient() then return end
    if self.shiftOwnerIsLocal == false then return end

    local tm = self.system.triggerManager
    if not tm then return end

    local activeTrigger = tm:getTriggerById(self.activeTriggerId)

    -- Respect the endShiftOnLeave setting on the active trigger.
    -- Falls back to the global setting for triggers created before this field existed.
    local endOnLeave = true
    if activeTrigger and activeTrigger.endShiftOnLeave ~= nil then
        endOnLeave = activeTrigger.endShiftOnLeave ~= false
    else
        local settings = self.system and self.system.settings
        if settings and settings.endShiftOnLeave == false then
            endOnLeave = false
        end
    end
    if not endOnLeave then
        if self.leaveWarnActive then
            self.leaveWarnActive = false
            self.leaveWarnTimer  = 0
            if self.system.hud then self.system.hud:hideLeaveWarning() end
        end
        return
    end
    if not activeTrigger then return end

    local playerPos = tm:getPlayerPosition()
    if not playerPos then return end

    local dx   = (activeTrigger.posX or 0) - playerPos.x
    local dz   = (activeTrigger.posZ or 0) - playerPos.z
    local dist = math.sqrt(dx * dx + dz * dz)
    local radius = activeTrigger.triggerRadius or 4.0

    if dist <= radius then
        -- Back inside zone - cancel warning and reset timer
        if self.leaveWarnActive then
            self.leaveWarnActive = false
            self.leaveWarnTimer  = 0
            if self.system.hud then self.system.hud:hideLeaveWarning() end
        end
    else
        -- Outside zone - countdown starts immediately on leaving the radius
        if not self.leaveWarnActive then
            self.leaveWarnActive = true
            self.leaveWarnTimer  = 0
        end
        self.leaveWarnTimer = (self.leaveWarnTimer or 0) + dtSec
        if self.system.hud then
            self.system.hud:showLeaveWarning(self.WARN_GRACE_SECONDS - self.leaveWarnTimer)
        end
        if self.leaveWarnTimer >= self.WARN_GRACE_SECONDS then
            wtLog("Player left zone too long - auto-ending shift with penalty")
            self.leaveWarnActive = false
            self.leaveWarnTimer  = 0
            if self.system.hud then self.system.hud:hideLeaveWarning() end
            -- Clear activeTriggerId immediately so zone check stops while the
            -- penalty event travels to the server and SHIFT_CONFIRM comes back.
            self.activeTriggerId = nil
            WTNetworkSyncBridge.sendShiftEnd(true)
        end
    end
end

-- =========================================================
-- Queries
-- =========================================================
function WorkplaceShiftTracker:isShiftActive()
    return self.activeTriggerId ~= nil
end

function WorkplaceShiftTracker:getActiveWorkplaceName()
    return self.activeWorkplaceName
end

function WorkplaceShiftTracker:getElapsedHours()
    if not self:isShiftActive() then return 0 end
    if not self.shiftStartTime then return 0 end
    -- Compute elapsed from the game clock so server and client stay in sync.
    -- g_currentMission.time is the authoritative real-ms counter on all machines.
    local realElapsedMs = self:getCurrentMissionTime() - self.shiftStartTime
    if realElapsedMs < 0 then realElapsedMs = 0 end
    -- timeMultiplier: 0=Auto (server game speed), 1=real time, 3/5/10=fixed multipliers.
    local timeScale
    if self.activeTimeMultiplier == 0 then
        timeScale = self:getMissionTimeScale()
    else
        timeScale = self.activeTimeMultiplier
    end
    return (realElapsedMs * timeScale) / (1000.0 * 60.0 * 60.0)
end

function WorkplaceShiftTracker:getElapsedMinutes()
    return self:getElapsedHours() * 60.0
end

-- Returns current shift earnings based on pay schedule
function WorkplaceShiftTracker:getCurrentEarnings()
    if not self:isShiftActive() then return 0 end
    local mult  = (self.system and self.system.settings and self.system.settings.wageMultiplier) or 1.0
    local sched = self.activePaySchedule or WorkplaceShiftTracker.PAY_HOURLY

    if sched == WorkplaceShiftTracker.PAY_FLAT then
        -- Flat rate: the wage IS the payout, paid in full at end of shift
        return math.floor(self.activeHourlyWage * mult)

    elseif sched == WorkplaceShiftTracker.PAY_DAILY then
        -- Daily rate: wage per in-game day (24 in-game hours)
        local hours = self:getElapsedHours()
        local days  = hours / 24.0
        return math.floor(self.activeHourlyWage * days * mult)

    else
        -- Hourly (default)
        local hours = self:getElapsedHours()
        return math.floor(self.activeHourlyWage * hours * mult)
    end
end

-- =========================================================
-- Shift History
-- =========================================================
function WorkplaceShiftTracker:recordHistory(name, hours, earned, schedule)
    local entry = {
        workplaceName = name or "Workplace",
        elapsedHours  = hours or 0,
        earned        = earned or 0,
        paySchedule   = schedule or WorkplaceShiftTracker.PAY_HOURLY,
        gameDay       = (g_currentMission and g_currentMission.environment
                         and g_currentMission.environment.currentDay) or 0,
    }
    table.insert(self.shiftHistory, 1, entry)   -- newest first
    if #self.shiftHistory > self.MAX_HISTORY then
        table.remove(self.shiftHistory)
    end
end

function WorkplaceShiftTracker:getHistory()
    return self.shiftHistory
end

function WorkplaceShiftTracker:clearHistory()
    self.shiftHistory = {}
end

function WorkplaceShiftTracker:getActiveHourlyWage()
    return self.activeHourlyWage
end

-- =========================================================
-- Utility
-- =========================================================
function WorkplaceShiftTracker:getCurrentMissionTime()
    if g_currentMission and g_currentMission.time then
        return g_currentMission.time
    end
    return 0
end

-- FS25 time scale: g_currentMission.missionInfo.timeScale is the raw multiplier.
-- e.g. 120 means 120 in-game seconds pass per real second.
-- Returns the raw multiplier; getElapsedHours() handles the /3600 conversion.
function WorkplaceShiftTracker:getMissionTimeScale()
    -- BUG FIX (issue #17): environment.timeScale does NOT exist in FS25.
    -- The correct authoritative field is missionInfo.timeScale.
    -- Using the wrong field returned nil, so the fallback of 120 was
    -- always used regardless of the server actual time setting, causing
    -- earnings to be miscalculated on servers running at non-120x speed.
    if g_currentMission and g_currentMission.missionInfo
       and g_currentMission.missionInfo.timeScale then
        return g_currentMission.missionInfo.timeScale
    end
    -- Fallback: FS25 default is 120x speed
    return 120.0
end

-- =========================================================
-- Cleanup
-- =========================================================
function WorkplaceShiftTracker:delete()
    if self:isShiftActive() then
        wtLog("delete: ending active shift")
        self:endShift()
    end
    self.isInitialized = false
    wtLog("Deleted")
end
