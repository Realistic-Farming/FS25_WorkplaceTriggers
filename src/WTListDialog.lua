-- =========================================================
-- WTListDialog.lua
-- MessageDialog subclass - Workplace Trigger list manager.
-- Shows up to 8 triggers per page with Edit and Delete per row.
-- Pattern: NPCListDialog.lua from FS25_NPCFavor
-- =========================================================
-- RULES:
--   - No unicode
--   - Dialog callbacks NEVER named onClose or onOpen
--   - g_gui:loadGui() arg 3 = class table, not instance
-- =========================================================

WTListDialog = {}
local WTListDialog_mt = Class(WTListDialog, MessageDialog)

WTListDialog.MAX_ROWS = 8

-- =========================================================
-- Admin helper
-- =========================================================
local function isAdmin()
    if WorkplaceSystem and WorkplaceSystem.isLocalPlayerAdmin then
        return WorkplaceSystem.isLocalPlayerAdmin()
    end
    return g_currentMission ~= nil and g_currentMission:getIsServer()
end

-- =========================================================
-- Schedule display helpers
-- =========================================================
local function getSchedSuffix(paySchedule)
    if paySchedule == WorkplaceShiftTracker.PAY_FLAT then
        return " flat"
    elseif paySchedule == WorkplaceShiftTracker.PAY_DAILY then
        return "/day"
    end
    return "/hr"
end

local function getSchedLabel(paySchedule)
    if paySchedule == WorkplaceShiftTracker.PAY_FLAT then
        return "Flat"
    elseif paySchedule == WorkplaceShiftTracker.PAY_DAILY then
        return "Daily"
    end
    return "Hourly"
end

function WTListDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or WTListDialog_mt)
    self.system      = nil
    self._page       = 1
    self.rowTriggerIndex = {}   -- rowNum (1-8) -> trigger list index
    return self
end

function WTListDialog:onCreate()
    local ok, err = pcall(function()
        WTListDialog:superClass().onCreate(self)
    end)
    if not ok then
        print("[WorkplaceTriggers] WTListDialog:onCreate error: " .. tostring(err))
    end
end

function WTListDialog:setSystem(system)
    self.system = system
end

function WTListDialog:onOpen()
    local ok, err = pcall(function()
        WTListDialog:superClass().onOpen(self)
    end)
    if not ok then
        print("[WorkplaceTriggers] WTListDialog:onOpen error: " .. tostring(err))
        return
    end
    self._page = 1
    self:refresh()
end

-- =========================================================
-- Refresh display
-- =========================================================
function WTListDialog:refresh()
    local triggers = self:getTriggers()
    local total    = #triggers

    -- Clamp page to valid range
    local maxPage = math.max(1, math.ceil(total / self.MAX_ROWS))
    if self._page > maxPage then self._page = maxPage end
    if self._page < 1       then self._page = 1       end

    -- Title
    if self.titleText then
        local titleStr = g_i18n:getText("wt_dialog_list_title")
        self.titleText:setText((titleStr and titleStr ~= "") and titleStr or "Workplace Triggers")
    end
    if self.subtitleText then
        local sub
        if total == 1 then
            local s = g_i18n:getText("wt_dialog_list_subtitle_one")
            sub = (s and s ~= "") and s or "1 trigger placed"
        else
            local fmt = g_i18n:getText("wt_dialog_list_subtitle_many")
            fmt = (fmt and fmt ~= "") and fmt or "%d triggers placed"
            sub = string.format(fmt, total)
        end
        self.subtitleText:setText(sub)
    end

    -- Clear all rows
    for i = 1, self.MAX_ROWS do
        self:clearRow(i)
    end
    self.rowTriggerIndex = {}

    -- Fill visible rows for current page
    local pageStart = (self._page - 1) * self.MAX_ROWS + 1
    local pageEnd   = math.min(total, self._page * self.MAX_ROWS)
    local rowNum    = 0

    for i = pageStart, pageEnd do
        rowNum = rowNum + 1
        self.rowTriggerIndex[rowNum] = i
        self:fillRow(rowNum, triggers[i])
    end

    -- Status / empty-state text
    if self.statusText then
        if total == 0 then
            local emptyStr = g_i18n:getText("wt_dialog_list_empty")
            self.statusText:setText((emptyStr and emptyStr ~= "") and emptyStr or "No triggers placed. Click '+ New Trigger' to add one.")
        else
            local showing = (pageStart == pageEnd) and tostring(pageStart)
                or (tostring(pageStart) .. "-" .. tostring(pageEnd))
            local fmt = g_i18n:getText("wt_dialog_list_showing")
            fmt = (fmt and fmt ~= "") and fmt or "Showing %s of %d"
            self.statusText:setText(string.format(fmt, showing, total))
        end
    end

    -- Pagination
    self:setPaginationVisible(self._page > 1, self._page < maxPage, maxPage)

    -- "New Trigger" button: admin only
    local adminVis = isAdmin()
    local function setNewVis(id)
        local el = self[id]
        if el then el:setVisible(adminVis) end
    end
    setNewVis("newBg")
    setNewVis("newTxt")
    setNewVis("newBtn")
end

function WTListDialog:getTriggers()
    if self.system and self.system.triggerManager then
        return self.system.triggerManager:getAllTriggers()
    end
    return {}
end

-- =========================================================
-- Row rendering
-- =========================================================
function WTListDialog:clearRow(rowNum)
    local p = "r" .. rowNum
    local function hide(id)
        local el = self[id]
        if el then
            if el.setText then el:setText("") end
            el:setVisible(false)
        end
    end
    hide(p .. "bg")
    hide(p .. "name")
    hide(p .. "wage")
    hide(p .. "pos")
    hide(p .. "editbg")
    hide(p .. "edittxt")
    hide(p .. "edit")
    hide(p .. "delbg")
    hide(p .. "deltxt")
    hide(p .. "del")
end

function WTListDialog:fillRow(rowNum, trigger)
    local p = "r" .. rowNum

    local function show(id)
        local el = self[id]
        if el then el:setVisible(true) end
        return el
    end

    show(p .. "bg")

    -- Name (truncate at 26 chars)
    local nameEl = show(p .. "name")
    if nameEl then
        local name = trigger.workplaceName or "Workplace"
        if #name > 26 then name = string.sub(name, 1, 23) .. "..." end
        nameEl:setText(name)
    end

    -- Wage with schedule-correct suffix
    local wageEl = show(p .. "wage")
    if wageEl then
        local suffix = getSchedSuffix(trigger.paySchedule)
        wageEl:setText("$" .. tostring(trigger.hourlyWage or 0) .. suffix)
    end

    -- Schedule type + radius (replaces raw position coords)
    local posEl = show(p .. "pos")
    if posEl then
        local schedLabel = getSchedLabel(trigger.paySchedule)
        local radius     = tostring(trigger.triggerRadius or 0)
        posEl:setText(schedLabel .. " / " .. radius .. "m")
    end

    -- Edit and Delete buttons: admin only.
    -- clearRow() calls setText("") on all Text elements including button labels,
    -- so we must restore the static text here before making them visible.
    local editTxtEl = self[p .. "edittxt"]
    if editTxtEl and editTxtEl.setText then editTxtEl:setText("Edit") end
    local delTxtEl = self[p .. "deltxt"]
    if delTxtEl and delTxtEl.setText then delTxtEl:setText("Del") end

    local adminVis = isAdmin()
    local function setAdminVis(id)
        local el = self[id]
        if el then el:setVisible(adminVis) end
    end
    setAdminVis(p .. "editbg")
    setAdminVis(p .. "edittxt")
    setAdminVis(p .. "edit")
    setAdminVis(p .. "delbg")
    setAdminVis(p .. "deltxt")
    setAdminVis(p .. "del")
end

function WTListDialog:setPaginationVisible(showPrev, showNext, maxPage)
    local function setVis(id, vis)
        local el = self[id]
        if el then el:setVisible(vis) end
    end
    setVis("prevBg",   showPrev)
    setVis("prevText", showPrev)
    setVis("prevBtn",  showPrev)
    setVis("nextBg",   showNext)
    setVis("nextText", showNext)
    setVis("nextBtn",  showNext)

    -- Page info always visible when there is more than one page
    local showInfo = (maxPage and maxPage > 1)
    setVis("pageInfo", showInfo)
    if showInfo and self.pageInfo then
        self.pageInfo:setText(self._page .. " / " .. maxPage)
    end
end

-- =========================================================
-- Row click handlers (generated for rows 1-8)
-- =========================================================
for i = 1, WTListDialog.MAX_ROWS do
    WTListDialog["onClickEdit" .. i] = function(self)
        if not isAdmin() then return end
        local idx = self.rowTriggerIndex[i]
        if not idx then return end
        local triggers = self:getTriggers()
        local t = triggers[idx]
        if not t then return end
        self:close()
        if WTDialogLoader then
            WTDialogLoader.showEdit(self.system, t, false)
        end
    end

    WTListDialog["onClickDel" .. i] = function(self)
        if not isAdmin() then return end
        local idx = self.rowTriggerIndex[i]
        if not idx then return end
        local triggers = self:getTriggers()
        local t = triggers[idx]
        if not t then return end
        -- Route through MP event so all machines sync
        WTNetworkSyncBridge.sendDeleteTrigger(t.id)
        -- Clamp page after deletion
        local remaining = #self:getTriggers()
        local maxPage = math.max(1, math.ceil(remaining / self.MAX_ROWS))
        if self._page > maxPage then self._page = maxPage end
        self:refresh()
    end
end

-- =========================================================
-- Other button handlers
-- =========================================================
function WTListDialog:onClickNew()
    if not isAdmin() then return end
    self:close()
    if WTDialogLoader then
        WTDialogLoader.showEdit(self.system, nil, true)
    end
end

function WTListDialog:onClickPrev()
    if self._page > 1 then
        self._page = self._page - 1
        self:refresh()
    end
end

function WTListDialog:onClickNext()
    local total   = #self:getTriggers()
    local maxPage = math.max(1, math.ceil(total / self.MAX_ROWS))
    if self._page < maxPage then
        self._page = self._page + 1
        self:refresh()
    end
end

function WTListDialog:onClickClose()
    self:close()
end

function WTListDialog:wtOnClose()
    WTListDialog:superClass().onClose(self)
end

print("[WorkplaceTriggers] WTListDialog loaded")
