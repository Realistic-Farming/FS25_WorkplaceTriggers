-- =========================================================
-- WTSiteListDialog.lua  (WT-8)
-- MessageDialog subclass: the site manager. A SIBLING of WTListDialog that
-- copies its patterns (8 rows, pagination, 3-layer buttons) and none of its
-- wage semantics. Reads only the local site replica (WorkplaceSiteClient),
-- never the world store. Controls gate on the same native right the server
-- enforces (UPDATE_FARM on the own farm, or master user inside an explicit
-- administration context), read through WorkplaceSiteClient:hasCommandRight.
-- =========================================================

WTSiteListDialog = WTSiteListDialog or {}
local WTSiteListDialog_mt = Class(WTSiteListDialog, MessageDialog)

WTSiteListDialog.MAX_ROWS = 8

local function i18n(key, fallback)
    local s = g_i18n ~= nil and g_i18n:getText(key) or nil
    if s == nil or s == "" or s == key then return fallback end
    return s
end

local function isMasterUser()
    if g_currentMission == nil then return false end
    if g_currentMission:getIsServer() then return true end
    return g_currentMission.isMasterUser == true
end

function WTSiteListDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or WTSiteListDialog_mt)
    self.system = nil
    self._page = 1
    self.rowSiteIndex = {}
    self.focusSiteId = nil
    self.adminFarmId = nil     -- display of the administration context (nil = own farm)
    return self
end

function WTSiteListDialog:onCreate()
    local ok, err = pcall(function() WTSiteListDialog:superClass().onCreate(self) end)
    if not ok then print("[WorkplaceTriggers] WTSiteListDialog:onCreate error: " .. tostring(err)) end
end

function WTSiteListDialog:setSystem(system, focusSiteId, clearAdmin)
    self.system = system
    self.focusSiteId = focusSiteId
    if clearAdmin then self:leaveAdministration() end
end

function WTSiteListDialog:onOpen()
    local ok, err = pcall(function() WTSiteListDialog:superClass().onOpen(self) end)
    if not ok then
        print("[WorkplaceTriggers] WTSiteListDialog:onOpen error: " .. tostring(err))
        return
    end
    self._page = 1
    self:refresh()
end

--- The manager reads the administration replica while one is held, else the
--- ordinary own-farm replica (the two never mix).
function WTSiteListDialog:getView()
    local c = self.system and self.system.siteClient
    if c == nil then return nil end
    if c.getManagerView ~= nil then return c:getManagerView() end
    return c.view
end

function WTSiteListDialog:getSites()
    local v = self:getView()
    if v == nil or v.availability ~= "READY" then return {} end
    return v.sites or {}
end

function WTSiteListDialog:canCommand()
    local c = self.system and self.system.siteClient
    if c == nil then return false end
    if c.hasCommandRight ~= nil then return c:hasCommandRight() end
    local v = self:getView()
    return v ~= nil and v.availability == "READY" and v.commandSessionId ~= nil
end

-- =========================================================
-- Refresh
-- =========================================================
function WTSiteListDialog:refresh()
    local sites = self:getSites()
    local total = #sites
    local v = self:getView()

    local maxPage = math.max(1, math.ceil(total / self.MAX_ROWS))
    if self.focusSiteId ~= nil then
        for i, s in ipairs(sites) do
            if s.siteId == self.focusSiteId then self._page = math.ceil(i / self.MAX_ROWS) end
        end
        self.focusSiteId = nil
    end
    if self._page > maxPage then self._page = maxPage end
    if self._page < 1 then self._page = 1 end

    if self.titleText then
        self.titleText:setText(i18n("wt_site_list_title", "Farm Sites"))
    end
    if self.subtitleText then
        local sub
        if v ~= nil and v.administrationTargetFarmId ~= nil then
            sub = string.format(i18n("wt_site_list_admin", "Administering farm %d"), v.administrationTargetFarmId)
        elseif v == nil or v.availability ~= "READY" then
            sub = i18n("wt_site_list_not_ready", "Sites are not available yet")
            if v ~= nil and v.reason == "INVALID_FARM" then sub = i18n("wt_site_list_no_farm", "Join a farm to manage its sites") end
        elseif total == 1 then
            sub = i18n("wt_site_list_subtitle_one", "1 site on your farm")
        else
            sub = string.format(i18n("wt_site_list_subtitle_many", "%d sites on your farm"), total)
        end
        self.subtitleText:setText(sub)
    end

    for i = 1, self.MAX_ROWS do self:clearRow(i) end
    self.rowSiteIndex = {}
    local pageStart = (self._page - 1) * self.MAX_ROWS + 1
    local pageEnd = math.min(total, self._page * self.MAX_ROWS)
    local rowNum = 0
    for i = pageStart, pageEnd do
        rowNum = rowNum + 1
        self.rowSiteIndex[rowNum] = i
        self:fillRow(rowNum, sites[i])
    end

    if self.statusText then
        if total == 0 then
            self.statusText:setText(i18n("wt_site_list_empty", "No sites yet. Click '+ New Site' to name a place on your farm."))
        else
            local showing = (pageStart == pageEnd) and tostring(pageStart) or (tostring(pageStart) .. "-" .. tostring(pageEnd))
            self.statusText:setText(string.format(i18n("wt_dialog_list_showing", "Showing %s of %d"), showing, total))
        end
    end

    self:setPaginationVisible(self._page > 1, self._page < maxPage, maxPage)

    local canNew = self:canCommand()
    for _, id in ipairs({ "newBg", "newTxt", "newBtn" }) do
        local el = self[id]
        if el then el:setVisible(canNew) end
    end
    -- Administration switch: master users only.
    local adminVis = isMasterUser()
    for _, id in ipairs({ "adminBg", "adminTxt", "adminBtn" }) do
        local el = self[id]
        if el then el:setVisible(adminVis) end
    end
    if self.adminTxt and adminVis then
        if v ~= nil and v.administrationTargetFarmId ~= nil then
            self.adminTxt:setText(string.format(i18n("wt_site_admin_next", "Admin: farm %d"), v.administrationTargetFarmId))
        else
            self.adminTxt:setText(i18n("wt_site_admin_own", "Admin: own farm"))
        end
    end
end

function WTSiteListDialog:clearRow(rowNum)
    local p = "r" .. rowNum
    local function hide(id)
        local el = self[id]
        if el then
            if el.setText then el:setText("") end
            el:setVisible(false)
        end
    end
    hide(p .. "bg"); hide(p .. "name"); hide(p .. "purpose"); hide(p .. "state")
    hide(p .. "editbg"); hide(p .. "edittxt"); hide(p .. "edit")
    hide(p .. "delbg"); hide(p .. "deltxt"); hide(p .. "del")
end

function WTSiteListDialog:fillRow(rowNum, site)
    local p = "r" .. rowNum
    local function show(id)
        local el = self[id]
        if el then el:setVisible(true) end
        return el
    end
    show(p .. "bg")
    local nameEl = show(p .. "name")
    if nameEl then
        local name = site.name or "Site"
        if #name > 26 then name = string.sub(name, 1, 23) .. "..." end
        nameEl:setText(name)
    end
    local purposeEl = show(p .. "purpose")
    if purposeEl then
        local label = i18n("wt_site_purpose_none", "none")
        if site.purpose ~= nil and site.purpose ~= "" then
            local spec = WorkplaceSiteRegistry ~= nil and WorkplaceSiteRegistry.getPurpose(site.purpose) or nil
            label = spec and spec.label or site.purpose
        end
        purposeEl:setText(label)
    end
    local stateEl = show(p .. "state")
    if stateEl then
        local radius = string.format("%d m", math.floor((site.radiusMetres or 0) + 0.5))
        if site.state == "UNAVAILABLE" then
            stateEl:setText(radius .. " / " .. i18n("wt_site_state_unavailable", "unavailable") .. (site.reason and (" (" .. site.reason .. ")") or ""))
        else
            stateEl:setText(radius)
        end
    end
    local editTxt = self[p .. "edittxt"]
    if editTxt and editTxt.setText then editTxt:setText(i18n("wt_site_btn_edit", "Edit")) end
    local delTxt = self[p .. "deltxt"]
    if delTxt and delTxt.setText then delTxt:setText(i18n("wt_site_btn_del", "Del")) end
    local can = self:canCommand()
    local v = self:getView()
    local inAdmin = v ~= nil and v.administrationTargetFarmId ~= nil
    -- Edit is the ordinary action; in administration it becomes Transfer for
    -- sites that are not already the administered farm's ACTIVE sites.
    if inAdmin and (site.state == "UNAVAILABLE" or site.ownerFarmId ~= v.administrationTargetFarmId) then
        if editTxt and editTxt.setText then editTxt:setText(i18n("wt_site_btn_transfer", "Move")) end
    end
    for _, id in ipairs({ p .. "editbg", p .. "edittxt", p .. "edit", p .. "delbg", p .. "deltxt", p .. "del" }) do
        local el = self[id]
        if el then el:setVisible(can) end
    end
end

function WTSiteListDialog:setPaginationVisible(showPrev, showNext, maxPage)
    local function setVis(id, vis)
        local el = self[id]
        if el then el:setVisible(vis) end
    end
    setVis("prevBg", showPrev); setVis("prevText", showPrev); setVis("prevBtn", showPrev)
    setVis("nextBg", showNext); setVis("nextText", showNext); setVis("nextBtn", showNext)
    local showInfo = (maxPage and maxPage > 1)
    setVis("pageInfo", showInfo)
    if showInfo and self.pageInfo then self.pageInfo:setText(self._page .. " / " .. maxPage) end
end

-- =========================================================
-- Row actions
-- =========================================================
function WTSiteListDialog:showResult(result)
    if self.statusText == nil or result == nil then return end
    if result.outcome == "APPLIED" then
        self.statusText:setText(i18n("wt_site_result_ok", "Done."))
    else
        local fmt = i18n("wt_site_result_refused", "Refused: %s")
        self.statusText:setText(string.format(fmt, tostring(result.reasonCode)))
    end
end

for i = 1, WTSiteListDialog.MAX_ROWS do
    WTSiteListDialog["onClickEdit" .. i] = function(self)
        if not self:canCommand() then return end
        local idx = self.rowSiteIndex[i]
        local site = idx and self:getSites()[idx] or nil
        if site == nil then return end
        local v = self:getView()
        local inAdmin = v ~= nil and v.administrationTargetFarmId ~= nil
        if inAdmin and (site.state == "UNAVAILABLE" or site.ownerFarmId ~= v.administrationTargetFarmId) then
            -- Transfer to the administered farm.
            local c = self.system.siteClient
            local dialog = self
            c:sendCommand("TRANSFER_SITE", { targetId = site.siteId, expectedRevision = site.revision,
                administrationTargetFarmId = v.administrationTargetFarmId }, function(result)
                dialog:showResult(result)
                dialog:refresh()
            end)
            return
        end
        self:close()
        if WTDialogLoader then WTDialogLoader.showSiteEdit(self.system, site, false) end
    end

    WTSiteListDialog["onClickDel" .. i] = function(self)
        if not self:canCommand() then return end
        local idx = self.rowSiteIndex[i]
        local site = idx and self:getSites()[idx] or nil
        if site == nil then return end
        local c = self.system.siteClient
        local dialog = self
        c:sendCommand("DELETE_SITE", { targetId = site.siteId, expectedRevision = site.revision }, function(result)
            dialog:showResult(result)
            local remaining = #dialog:getSites()
            local maxPage = math.max(1, math.ceil(remaining / dialog.MAX_ROWS))
            if dialog._page > maxPage then dialog._page = maxPage end
            dialog:refresh()
        end)
    end
end

function WTSiteListDialog:onClickNew()
    if not self:canCommand() then return end
    local v = self:getView()
    local adminFarmId = v and v.administrationTargetFarmId or nil
    self:close()
    if WTDialogLoader then WTDialogLoader.showSiteEdit(self.system, nil, true, adminFarmId) end
end

--- Cycle the administration context: own farm, then each existing ordinary farm.
function WTSiteListDialog:onClickAdmin()
    if not isMasterUser() then return end
    local v = self:getView()
    local current = v and v.administrationTargetFarmId or nil
    local maxId = (FarmManager ~= nil and FarmManager.MAX_FARM_ID) or 8
    local start = current or 0
    local nextFarm = nil
    for id = start + 1, maxId do
        if g_farmManager ~= nil and g_farmManager.getFarmById ~= nil and g_farmManager:getFarmById(id) ~= nil then
            nextFarm = id
            break
        end
    end
    self:requestAdministration(nextFarm)
end

function WTSiteListDialog:requestAdministration(farmId)
    local sys = self.system
    if sys == nil then return end
    if g_currentMission ~= nil and g_currentMission:getIsServer() then
        if sys.siteService ~= nil then sys.siteService:setAdministrationContext(nil, farmId) end
    else
        -- A client asks through the command wire with a CREATE-less context switch:
        -- the server binds the context to the connection's session on the next view.
        if sys.siteClient ~= nil and sys.siteClient.requestAdministration ~= nil then
            sys.siteClient:requestAdministration(farmId)
        end
    end
    self.adminFarmId = farmId
    self:refresh()
end

function WTSiteListDialog:leaveAdministration()
    local v = self:getView()
    if v ~= nil and v.administrationTargetFarmId ~= nil then
        self:requestAdministration(nil)
    end
end

function WTSiteListDialog:onClickPrev()
    if self._page > 1 then self._page = self._page - 1 self:refresh() end
end

function WTSiteListDialog:onClickNext()
    local maxPage = math.max(1, math.ceil(#self:getSites() / self.MAX_ROWS))
    if self._page < maxPage then self._page = self._page + 1 self:refresh() end
end

function WTSiteListDialog:onClickClose()
    self:close()
end

function WTSiteListDialog:wtOnClose()
    WTSiteListDialog:superClass().onClose(self)
end

print("[WorkplaceTriggers] WTSiteListDialog loaded")
