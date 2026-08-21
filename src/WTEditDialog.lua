-- =========================================================
-- WTEditDialog.lua
-- MessageDialog subclass for creating and editing triggers.
-- Uses TextInput for name, +/- buttons for wage and radius.
-- Pattern: NPCAdminEditDialog.lua from FS25_NPCFavor
-- =========================================================

-- =========================================================
-- Admin helper
-- =========================================================
local function isAdmin()
    if WorkplaceSystem and WorkplaceSystem.isLocalPlayerAdmin then
        return WorkplaceSystem.isLocalPlayerAdmin()
    end
    return g_currentMission ~= nil and g_currentMission:getIsServer()
end

WTEditDialog = {}
local WTEditDialog_mt = Class(WTEditDialog, MessageDialog)

WTEditDialog.WAGE_STEPS   = {1, 10, 100}
WTEditDialog.WAGE_MIN     = 0
WTEditDialog.WAGE_MAX     = 99999
WTEditDialog.RADIUS_MIN   = 1
WTEditDialog.RADIUS_MAX   = 300
WTEditDialog.RADIUS_STEP  = 5

function WTEditDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or WTEditDialog_mt)
    self.system      = nil
    self.trigger     = nil    -- existing trigger being edited, or nil for new
    self.isNew       = false
    self.wage        = 500
    self.radius      = 4
    self.wageStep    = 10     -- current wage adjustment step
    self.paySchedule      = WorkplaceShiftTracker.PAY_HOURLY
    self.timeMultiplier   = 0  -- 0=Auto, 1=x1(real time), 3=x3, 5=x5, 10=x10
    self.endShiftOnLeave  = true
    self.posX        = 0
    self.posY        = 0
    self.posZ        = 0
    return self
end

function WTEditDialog:onCreate()
    local ok, err = pcall(function()
        WTEditDialog:superClass().onCreate(self)
    end)
    if not ok then
        print("[WorkplaceTriggers] WTEditDialog:onCreate error: " .. tostring(err))
    end
end

function WTEditDialog:setData(system, trigger, isNew)
    self.system  = system
    self.isNew   = isNew

    if isNew or trigger == nil then
        -- Defaults for new trigger
        self.trigger        = nil
        self.wage           = 500
        self.radius         = 5
        self.wageStep       = 10
        self.paySchedule     = WorkplaceShiftTracker.PAY_HOURLY
        self.timeMultiplier  = 0
        self.endShiftOnLeave = true
        -- Snap position to player immediately
        self:snapToPlayer()
    else
        self.trigger     = trigger
        self.wage        = trigger.hourlyWage    or 500
        self.radius      = trigger.triggerRadius or 5
        self.posX        = trigger.posX or 0
        self.posY        = trigger.posY or 0
        self.posZ        = trigger.posZ or 0
        self.wageStep       = 10
        self.paySchedule     = trigger.paySchedule or WorkplaceShiftTracker.PAY_HOURLY
        self.timeMultiplier  = trigger.timeMultiplier or 0
        self.endShiftOnLeave = trigger.endShiftOnLeave ~= false  -- default true
    end
end

function WTEditDialog:snapToPlayer()
    if self.system and self.system.triggerManager then
        local pp = self.system.triggerManager:getPlayerPosition()
        if pp then
            self.posX = pp.x
            self.posY = pp.y
            self.posZ = pp.z
            return
        end
    end
    self.posX = 0
    self.posY = 0
    self.posZ = 0
end

function WTEditDialog:onOpen()
    local ok, err = pcall(function()
        WTEditDialog:superClass().onOpen(self)
    end)
    if not ok then
        print("[WorkplaceTriggers] WTEditDialog:onOpen error: " .. tostring(err))
        return
    end

    -- Set title
    if self.titleText then
        local titleKey = self.isNew and "wt_dialog_edit_title_new" or "wt_dialog_edit_title_edit"
        local titleFallback = self.isNew and "New Workplace Trigger" or "Edit Trigger"
        local titleStr = g_i18n:getText(titleKey)
        self.titleText:setText((titleStr and titleStr ~= "") and titleStr or titleFallback)
    end

    -- Populate name input
    if self.nameInput then
        local defaultName = g_i18n:getText("wt_dialog_edit_name_default")
        defaultName = (defaultName and defaultName ~= "") and defaultName or "New Workplace"
        local name = (self.trigger and self.trigger.workplaceName) or defaultName
        self.nameInput:setText(name)
    end

    -- Clear status
    if self.statusText then
        self.statusText:setText("")
    end

    -- Normalise wageStep in case it was left dirty from a previous open
    if self.wageStep ~= 1 and self.wageStep ~= 10 and self.wageStep ~= 100 then
        self.wageStep = 10
    end

    -- Set schedule button labels from translations (XML has English defaults)
    if self.schedHourlyTxt then self.schedHourlyTxt:setText(g_i18n:getText("wt_sched_hourly") or "Hourly")    end
    if self.schedFlatTxt   then self.schedFlatTxt:setText(g_i18n:getText("wt_sched_flat")     or "Flat Rate") end
    if self.schedDailyTxt  then self.schedDailyTxt:setText(g_i18n:getText("wt_sched_daily")   or "Daily")     end

    self:updateWageDisplay()
    self:updateRadiusDisplay()
    self:updatePosDisplay()
    self:updateStepDisplay()
    self:updateSchedDisplay()
    self:updateTimeModeDisplay()
    self:updateLeaveDisplay()
end

-- =========================================================
-- Display helpers
-- =========================================================
function WTEditDialog:updateWageDisplay()
    if self.wageText then
        local sched = self.paySchedule or WorkplaceShiftTracker.PAY_HOURLY
        local suffix = "/hr"
        if sched == WorkplaceShiftTracker.PAY_FLAT then
            suffix = " flat"
        elseif sched == WorkplaceShiftTracker.PAY_DAILY then
            suffix = "/day"
        end
        self.wageText:setText("$" .. tostring(self.wage) .. suffix)
    end
end

function WTEditDialog:updateRadiusDisplay()
    if self.radText then
        self.radText:setText(tostring(self.radius) .. " m")
    end
end

function WTEditDialog:updatePosDisplay()
    if self.posText then
        self.posText:setText(string.format("Position: X=%.1f  Z=%.1f", self.posX, self.posZ))
    end
end

function WTEditDialog:updateStepDisplay()
    -- Highlight the active step button
    local stepIds = {1, 10, 100}
    for _, s in ipairs(stepIds) do
        local bg = self["step" .. s .. "bg"]
        if bg then
            if s == self.wageStep then
                bg:setImageColor(0.18, 0.30, 0.55, 1)
            else
                bg:setImageColor(0.10, 0.15, 0.28, 0.9)
            end
        end
        local txt = self["step" .. s .. "txt"]
        if txt then
            if s == self.wageStep then
                txt:setTextColor(1, 1, 1, 1)
            else
                txt:setTextColor(0.65, 0.75, 0.9, 1)
            end
        end
    end
end

-- =========================================================
-- Pay schedule display + click handlers
-- =========================================================
local function getSchedHint(sched)
    if sched == WorkplaceShiftTracker.PAY_FLAT then
        return g_i18n:getText("wt_sched_hint_flat")   or "Fixed payout at end of shift"
    elseif sched == WorkplaceShiftTracker.PAY_DAILY then
        return g_i18n:getText("wt_sched_hint_daily")  or "Earns wage x in-game days worked"
    end
    return g_i18n:getText("wt_sched_hint_hourly") or "Earns wage x hours worked"
end

local SCHED_IDS = {
    WorkplaceShiftTracker.PAY_HOURLY,
    WorkplaceShiftTracker.PAY_FLAT,
    WorkplaceShiftTracker.PAY_DAILY,
}

local SCHED_KEYS = {
    [WorkplaceShiftTracker.PAY_HOURLY] = "sched",
    [WorkplaceShiftTracker.PAY_FLAT]   = "schedFlat",
    [WorkplaceShiftTracker.PAY_DAILY]  = "schedDaily",
}

function WTEditDialog:updateSchedDisplay()
    local active = self.paySchedule or WorkplaceShiftTracker.PAY_HOURLY

    local schedBgIds = {
        [WorkplaceShiftTracker.PAY_HOURLY] = "schedHourlyBg",
        [WorkplaceShiftTracker.PAY_FLAT]   = "schedFlatBg",
        [WorkplaceShiftTracker.PAY_DAILY]  = "schedDailyBg",
    }
    local schedTxtIds = {
        [WorkplaceShiftTracker.PAY_HOURLY] = "schedHourlyTxt",
        [WorkplaceShiftTracker.PAY_FLAT]   = "schedFlatTxt",
        [WorkplaceShiftTracker.PAY_DAILY]  = "schedDailyTxt",
    }

    for _, s in ipairs(SCHED_IDS) do
        local bg  = self[schedBgIds[s]]
        local txt = self[schedTxtIds[s]]
        if bg then
            if s == active then
                bg:setImageColor(0.18, 0.30, 0.55, 1)
            else
                bg:setImageColor(0.10, 0.14, 0.28, 0.9)
            end
        end
        if txt then
            if s == active then
                txt:setTextColor(1, 1, 1, 1)
            else
                txt:setTextColor(0.65, 0.75, 0.9, 1)
            end
        end
    end

    -- Update wage label to reflect schedule
    if self.wageLabel then
        local labels = {
            [WorkplaceShiftTracker.PAY_HOURLY] = g_i18n:getText("wt_wage_label_hourly") or "Hourly Wage",
            [WorkplaceShiftTracker.PAY_FLAT]   = g_i18n:getText("wt_wage_label_flat")   or "Flat Rate (per shift)",
            [WorkplaceShiftTracker.PAY_DAILY]  = g_i18n:getText("wt_wage_label_daily")  or "Daily Rate",
        }
        self.wageLabel:setText(labels[active] or g_i18n:getText("wt_wage_label_hourly") or "Hourly Wage")
    end

    if self.schedHintText then
        self.schedHintText:setText(getSchedHint(active))
    end
end

function WTEditDialog:onClickSchedHourly()
    self.paySchedule = WorkplaceShiftTracker.PAY_HOURLY
    self:updateSchedDisplay()
    self:updateWageDisplay()
end

function WTEditDialog:onClickSchedFlat()
    self.paySchedule = WorkplaceShiftTracker.PAY_FLAT
    self:updateSchedDisplay()
    self:updateWageDisplay()
end

function WTEditDialog:onClickSchedDaily()
    self.paySchedule = WorkplaceShiftTracker.PAY_DAILY
    self:updateSchedDisplay()
    self:updateWageDisplay()
end

-- =========================================================
-- Time multiplier display + click handlers
-- =========================================================
local TIME_MULT_IDS = {0, 1, 3, 5, 10}
local TIME_MULT_BG  = {[0]="timeMult0Bg",  [1]="timeMult1Bg",  [3]="timeMult3Bg",  [5]="timeMult5Bg",  [10]="timeMult10Bg"}
local TIME_MULT_TXT = {[0]="timeMult0Txt", [1]="timeMult1Txt", [3]="timeMult3Txt", [5]="timeMult5Txt", [10]="timeMult10Txt"}
local TIME_MULT_HINT_KEYS = {
    [0]  = "wt_time_hint_auto",
    [1]  = "wt_time_hint_x1",
    [3]  = "wt_time_hint_x3",
    [5]  = "wt_time_hint_x5",
    [10] = "wt_time_hint_x10",
}
local TIME_MULT_HINT_FALLBACK = {
    [0]  = "Wage scales with server game speed (automatic)",
    [1]  = "Wage per real hour (ignores game speed)",
    [3]  = "Wage at 3x real-time rate",
    [5]  = "Wage at 5x real-time rate",
    [10] = "Wage at 10x real-time rate",
}

function WTEditDialog:updateTimeModeDisplay()
    local active = self.timeMultiplier or 0

    for _, m in ipairs(TIME_MULT_IDS) do
        local bg  = self[TIME_MULT_BG[m]]
        local txt = self[TIME_MULT_TXT[m]]
        local isActive = (m == active)
        if bg  then bg:setImageColor(isActive and 0.18 or 0.10, isActive and 0.30 or 0.14, isActive and 0.55 or 0.28, 1) end
        if txt then txt:setTextColor(isActive and 1 or 0.65, isActive and 1 or 0.75, isActive and 1 or 0.9, 1) end
    end

    if self.timeModeHint then
        local key      = TIME_MULT_HINT_KEYS[active]    or "wt_time_hint_auto"
        local fallback = TIME_MULT_HINT_FALLBACK[active] or ""
        local str = key and g_i18n:getText(key)
        self.timeModeHint:setText((str and str ~= "") and str or fallback)
    end
end

function WTEditDialog:onClickTimeMultAuto()
    self.timeMultiplier = 0
    self:updateTimeModeDisplay()
end

function WTEditDialog:onClickTimeMult1()
    self.timeMultiplier = 1
    self:updateTimeModeDisplay()
end

function WTEditDialog:onClickTimeMult3()
    self.timeMultiplier = 3
    self:updateTimeModeDisplay()
end

function WTEditDialog:onClickTimeMult5()
    self.timeMultiplier = 5
    self:updateTimeModeDisplay()
end

function WTEditDialog:onClickTimeMult10()
    self.timeMultiplier = 10
    self:updateTimeModeDisplay()
end

-- =========================================================
-- Leave zone toggle
-- =========================================================
function WTEditDialog:updateLeaveDisplay()
    local yes = self.endShiftOnLeave ~= false
    local ACTIVE_R, ACTIVE_G, ACTIVE_B = 0.18, 0.30, 0.55
    local DIM_R,    DIM_G,    DIM_B    = 0.10, 0.14, 0.28
    if self.leaveYesBg then self.leaveYesBg:setImageColor(yes and ACTIVE_R or DIM_R, yes and ACTIVE_G or DIM_G, yes and ACTIVE_B or DIM_B, 1) end
    if self.leaveNoBg  then self.leaveNoBg: setImageColor(yes and DIM_R or ACTIVE_R, yes and DIM_G or ACTIVE_G, yes and DIM_B or ACTIVE_B, 1) end
    if self.leaveYesTxt then self.leaveYesTxt:setTextColor(yes and 1 or 0.65, yes and 1 or 0.75, 1, 1) end
    if self.leaveNoTxt  then self.leaveNoTxt: setTextColor(yes and 0.65 or 1, yes and 0.75 or 1, 1, 1) end
end

function WTEditDialog:onClickLeaveYes()
    self.endShiftOnLeave = true
    self:updateLeaveDisplay()
end

function WTEditDialog:onClickLeaveNo()
    self.endShiftOnLeave = false
    self:updateLeaveDisplay()
end

-- =========================================================
-- Wage adjustment
-- =========================================================
function WTEditDialog:onClickWageDec()
    self.wage = math.max(self.WAGE_MIN, self.wage - self.wageStep)
    self:updateWageDisplay()
end

function WTEditDialog:onClickWageInc()
    self.wage = math.min(self.WAGE_MAX, self.wage + self.wageStep)
    self:updateWageDisplay()
end

function WTEditDialog:onClickStep1()
    self.wageStep = 1
    self:updateStepDisplay()
end

function WTEditDialog:onClickStep10()
    self.wageStep = 10
    self:updateStepDisplay()
end

function WTEditDialog:onClickStep100()
    self.wageStep = 100
    self:updateStepDisplay()
end

-- =========================================================
-- Radius adjustment
-- =========================================================
function WTEditDialog:onClickRadDec()
    self.radius = math.max(self.RADIUS_MIN, self.radius - self.RADIUS_STEP)
    self:updateRadiusDisplay()
end

function WTEditDialog:onClickRadInc()
    self.radius = math.min(self.RADIUS_MAX, self.radius + self.RADIUS_STEP)
    self:updateRadiusDisplay()
end

-- =========================================================
-- Snap position
-- =========================================================
function WTEditDialog:onClickSnap()
    self:snapToPlayer()
    self:updatePosDisplay()
    if self.statusText then
        local snapMsg = g_i18n:getText("wt_dialog_snap_done")
        self.statusText:setText((snapMsg and snapMsg ~= "") and snapMsg or "Position snapped to player location.")
    end
end

-- =========================================================
-- Save
-- =========================================================
function WTEditDialog:onClickSave()
    -- ADMIN GUARD: belt-and-suspenders — UI already hides this dialog from
    -- non-admins, but block here too in case of crafted input.
    if not isAdmin() then
        print("[WorkplaceTriggers] WTEditDialog: save blocked - player is not admin")
        self:close()
        return
    end

    local name = ""
    if self.nameInput then
        name = self.nameInput:getText() or ""
    end
    name = name:match("^%s*(.-)%s*$")  -- trim whitespace
    if name == "" then name = "Workplace" end
    if self.isNew then
        local farmId = g_currentMission and g_currentMission:getFarmId() or 1
        -- BUILD 10:17 (Sam DESIGN 09:56): SAVE now has two honest outcomes instead of
        -- one optimistic close. sendCreateTrigger's result travels up from the actual
        -- registerTrigger on the synchronous listen-host path (an explicit false means
        -- the server-side create refused or errored; false also means the bridge is
        -- inactive and nothing was created at all). A hard fail keeps the form open
        -- with the player's input intact and raises the standard blinking warning;
        -- only a success closes the form and reopens the Manager list, which reads
        -- live from the triggerManager the create just wrote, so the new row is there
        -- immediately. No success click ships: the Manager has no click-sound
        -- convention today and inventing one is Sam's call, not mine.
        local sent = false
        local ok, err = pcall(function()
            sent = WTNetworkSyncBridge.sendCreateTrigger({
                workplaceName  = name,
                hourlyWage     = self.wage,
                triggerRadius  = self.radius,
                paySchedule    = self.paySchedule,
                timeMultiplier = self.timeMultiplier or 0,
                endShiftOnLeave = self.endShiftOnLeave ~= false,
                posX           = self.posX or 0,
                posY           = self.posY or 0,
                posZ           = self.posZ or 0,
                farmId         = farmId,
            })
        end)
        if not ok or sent == false then
            print("[WorkplaceTriggers] onClickSave FAILED"
                .. (ok and " (bridge refused)" or (": " .. tostring(err))))
            if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
                local msg = (g_i18n ~= nil and g_i18n:getText("wt_save_failed")) or nil
                if msg == nil or msg == "" or msg == "wt_save_failed" then
                    msg = "Save failed: Invalid trigger parameters."
                end
                g_currentMission:showBlinkingWarning(msg, 3000)
            end
            return
        end
        print("[WorkplaceTriggers] Requested trigger creation: " .. name)
    else
        -- FIX: route edits through the MP event layer as well, so every client
        -- sees the updated name/wage/radius without a rejoin.
        local t = self.trigger
        if t then
            WTNetworkSyncBridge.sendUpdateTrigger(tostring(t.id), {
                workplaceName   = name,
                hourlyWage      = self.wage,
                triggerRadius   = self.radius,
                paySchedule     = self.paySchedule,
                timeMultiplier  = self.timeMultiplier or 0,
                endShiftOnLeave = self.endShiftOnLeave ~= false,
            })
        end
        print("[WorkplaceTriggers] Requested trigger update: " .. name)
    end

    self:close()
    -- Reopen list
    if WTDialogLoader then
        WTDialogLoader.showList(self.system)
    end
end

-- =========================================================
-- Cancel
-- =========================================================
function WTEditDialog:onClickCancel()
    self:close()
    if WTDialogLoader then
        WTDialogLoader.showList(self.system)
    end
end

function WTEditDialog:wtOnClose()
    WTEditDialog:superClass().onClose(self)
end

print("[WorkplaceTriggers] WTEditDialog loaded")
