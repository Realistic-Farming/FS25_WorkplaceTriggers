-- =========================================================
-- WTSiteEditDialog.lua  (WT-8)
-- MessageDialog subclass: create or edit one site. A SIBLING of WTEditDialog
-- copying its input patterns (name input, +/- buttons, snap-to-player) with
-- the site field set only: name, radius (default 100 m, 1 m to the terrain
-- diagonal), purpose (none, registered FARM tokens, a preserved unknown
-- token), centre from the player's position or the current centre. No wage,
-- schedule or shift field exists. Save sends a command; nothing is inserted
-- locally; the next view replaces the replica.
-- =========================================================

WTSiteEditDialog = WTSiteEditDialog or {}
local WTSiteEditDialog_mt = Class(WTSiteEditDialog, MessageDialog)

WTSiteEditDialog.RADIUS_MIN = 1
WTSiteEditDialog.RADIUS_DEFAULT = 100
WTSiteEditDialog.RADIUS_STEPS = { 1, 10, 50 }

local function i18n(key, fallback)
    local s = g_i18n ~= nil and g_i18n:getText(key) or nil
    if s == nil or s == "" or s == key then return fallback end
    return s
end

function WTSiteEditDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or WTSiteEditDialog_mt)
    self.system = nil
    self.site = nil
    self.isNew = false
    self.radius = WTSiteEditDialog.RADIUS_DEFAULT
    self.radiusStep = 10
    self.purposeIndex = 1
    self.purposeOptions = { { token = "", label = "none" } }
    self.centreX = 0
    self.centreZ = 0
    self.adminFarmId = nil     -- CREATE inside an administration context names its owner explicitly
    return self
end

function WTSiteEditDialog:onCreate()
    local ok, err = pcall(function() WTSiteEditDialog:superClass().onCreate(self) end)
    if not ok then print("[WorkplaceTriggers] WTSiteEditDialog:onCreate error: " .. tostring(err)) end
end

function WTSiteEditDialog:radiusMax()
    local size = (type(g_terrainSize) == "number" and g_terrainSize > 0) and g_terrainSize or 2048
    return math.floor(size * math.sqrt(2))
end

--- Purpose options: none, registered FARM tokens, plus the site's own token
--- when it is not registered (preserved, never rejected).
function WTSiteEditDialog:buildPurposeOptions(current)
    local opts = { { token = "", label = i18n("wt_site_purpose_none", "none") } }
    local seen = { [""] = true }
    if WorkplaceSiteRegistry ~= nil then
        for _, p in ipairs(WorkplaceSiteRegistry.getPurposes(WorkplaceSiteRegistry.CLASS_FARM)) do
            opts[#opts + 1] = { token = p.token, label = p.label }
            seen[p.token] = true
        end
    end
    if current ~= nil and current ~= "" and not seen[current] then
        opts[#opts + 1] = { token = current, label = current }
    end
    self.purposeOptions = opts
    self.purposeIndex = 1
    for i, o in ipairs(opts) do
        if o.token == (current or "") then self.purposeIndex = i end
    end
end

function WTSiteEditDialog:setData(system, site, isNew, adminFarmId)
    self.system = system
    self.isNew = isNew
    self.adminFarmId = isNew and adminFarmId or nil
    if isNew or site == nil then
        self.site = nil
        self.radius = WTSiteEditDialog.RADIUS_DEFAULT
        self.radiusStep = 10
        self:buildPurposeOptions("")
        self:snapToPlayer()
    else
        self.site = site
        self.radius = math.floor((site.radiusMetres or WTSiteEditDialog.RADIUS_DEFAULT) + 0.5)
        self.radiusStep = 10
        self.centreX = site.centreX or 0
        self.centreZ = site.centreZ or 0
        self:buildPurposeOptions(site.purpose or "")
    end
end

function WTSiteEditDialog:snapToPlayer()
    if self.system and self.system.triggerManager then
        local pp = self.system.triggerManager:getPlayerPosition()
        if pp then
            self.centreX = pp.x
            self.centreZ = pp.z
            return
        end
    end
    self.centreX = 0
    self.centreZ = 0
end

function WTSiteEditDialog:onOpen()
    local ok, err = pcall(function() WTSiteEditDialog:superClass().onOpen(self) end)
    if not ok then
        print("[WorkplaceTriggers] WTSiteEditDialog:onOpen error: " .. tostring(err))
        return
    end
    if self.titleText then
        self.titleText:setText(self.isNew and i18n("wt_site_edit_title_new", "New Site") or i18n("wt_site_edit_title_edit", "Edit Site"))
    end
    if self.nameInput then
        local name = (self.site and self.site.name) or i18n("wt_site_edit_name_default", "Main Yard")
        self.nameInput:setText(name)
    end
    if self.statusText then self.statusText:setText("") end
    self:updateRadiusDisplay()
    self:updateStepDisplay()
    self:updatePurposeDisplay()
    self:updatePosDisplay()
end

-- =========================================================
-- Display
-- =========================================================
function WTSiteEditDialog:updateRadiusDisplay()
    if self.radText then self.radText:setText(tostring(self.radius) .. " m") end
end

function WTSiteEditDialog:updateStepDisplay()
    for _, s in ipairs(WTSiteEditDialog.RADIUS_STEPS) do
        local bg = self["step" .. s .. "bg"]
        if bg then
            if s == self.radiusStep then bg:setImageColor(0.18, 0.30, 0.55, 1) else bg:setImageColor(0.10, 0.15, 0.28, 0.9) end
        end
        local txt = self["step" .. s .. "txt"]
        if txt then
            if s == self.radiusStep then txt:setTextColor(1, 1, 1, 1) else txt:setTextColor(0.65, 0.75, 0.9, 1) end
        end
    end
end

function WTSiteEditDialog:updatePurposeDisplay()
    local o = self.purposeOptions[self.purposeIndex] or self.purposeOptions[1]
    if self.purposeText then self.purposeText:setText(o and o.label or "none") end
end

function WTSiteEditDialog:updatePosDisplay()
    if self.posText then
        self.posText:setText(string.format(i18n("wt_site_edit_centre", "Centre: X=%.1f  Z=%.1f"), self.centreX, self.centreZ))
    end
end

-- =========================================================
-- Inputs
-- =========================================================
function WTSiteEditDialog:onClickRadDec()
    self.radius = math.max(WTSiteEditDialog.RADIUS_MIN, self.radius - self.radiusStep)
    self:updateRadiusDisplay()
end

function WTSiteEditDialog:onClickRadInc()
    self.radius = math.min(self:radiusMax(), self.radius + self.radiusStep)
    self:updateRadiusDisplay()
end

function WTSiteEditDialog:onClickStep1()  self.radiusStep = 1  self:updateStepDisplay() end
function WTSiteEditDialog:onClickStep10() self.radiusStep = 10 self:updateStepDisplay() end
function WTSiteEditDialog:onClickStep50() self.radiusStep = 50 self:updateStepDisplay() end

function WTSiteEditDialog:onClickPurposePrev()
    self.purposeIndex = self.purposeIndex - 1
    if self.purposeIndex < 1 then self.purposeIndex = #self.purposeOptions end
    self:updatePurposeDisplay()
end

function WTSiteEditDialog:onClickPurposeNext()
    self.purposeIndex = self.purposeIndex + 1
    if self.purposeIndex > #self.purposeOptions then self.purposeIndex = 1 end
    self:updatePurposeDisplay()
end

function WTSiteEditDialog:onClickSnap()
    self:snapToPlayer()
    self:updatePosDisplay()
    if self.statusText then self.statusText:setText(i18n("wt_dialog_snap_done", "Position snapped to player location.")) end
end

-- =========================================================
-- Save / Cancel
-- =========================================================
function WTSiteEditDialog:onClickSave()
    local c = self.system and self.system.siteClient
    if c == nil then self:close() return end
    local name = ""
    if self.nameInput then name = self.nameInput:getText() or "" end
    name = name:match("^%s*(.-)%s*$")
    if name == "" then
        if self.statusText then self.statusText:setText(i18n("wt_site_edit_name_required", "A site needs a name.")) end
        return
    end
    local o = self.purposeOptions[self.purposeIndex] or self.purposeOptions[1]
    local fields = {
        name = name,
        purpose = o and o.token or "",
        centreX = self.centreX,
        centreZ = self.centreZ,
        radiusMetres = self.radius,
    }
    local action = "CREATE_SITE"
    if not self.isNew and self.site ~= nil then
        action = "UPDATE_SITE"
        fields.targetId = self.site.siteId
        fields.expectedRevision = self.site.revision
    elseif self.adminFarmId ~= nil then
        -- The owner rides the wire; the server checks it against the session.
        fields.administrationTargetFarmId = self.adminFarmId
    end
    local dialog = self
    c:sendCommand(action, fields, function(result)
        if result ~= nil and result.outcome == "APPLIED" then
            dialog:close()
            if WTDialogLoader then WTDialogLoader.showSiteList(dialog.system, result.currentTarget and result.currentTarget.siteId or nil) end
        else
            local reason = result and result.reasonCode or "NOT_READY"
            if dialog.statusText then
                dialog.statusText:setText(string.format(i18n("wt_site_result_refused", "Refused: %s"), tostring(reason)))
            end
            if reason == "STALE_REVISION" and result.currentTarget ~= nil then
                -- Show the current definition; the next Save edits against it.
                dialog.site = result.currentTarget
                dialog.radius = math.floor((result.currentTarget.radiusMetres or dialog.radius) + 0.5)
                dialog.centreX = result.currentTarget.centreX or dialog.centreX
                dialog.centreZ = result.currentTarget.centreZ or dialog.centreZ
                dialog:updateRadiusDisplay()
                dialog:updatePosDisplay()
                if dialog.nameInput then dialog.nameInput:setText(result.currentTarget.name or name) end
            end
        end
    end)
end

function WTSiteEditDialog:onClickCancel()
    self:close()
    if WTDialogLoader then WTDialogLoader.showSiteList(self.system) end
end

function WTSiteEditDialog:wtOnClose()
    WTSiteEditDialog:superClass().onClose(self)
end

print("[WorkplaceTriggers] WTSiteEditDialog loaded")
