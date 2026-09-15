-- =========================================================
-- WorkplaceSiteClient.lua  (WT-8)
-- The site view replica held by every presentation context: a pure client
-- (fed by WTSiteViewStateEvent) and the listen host / singleplayer player
-- (fed in process by the service's local publication). The map draw and the
-- site manager read only this replica, never the world store.
-- =========================================================

WorkplaceSiteClient = WorkplaceSiteClient or {}
WorkplaceSiteClient_mt = Class(WorkplaceSiteClient)

WorkplaceSiteClient.REQUEST_INTERVAL_SEC = 2.0
WorkplaceSiteClient.REQUEST_MAX = 5

local function wtLog(msg)
    print("[WorkplaceTriggers] SiteClient: " .. tostring(msg))
end

function WorkplaceSiteClient.new(system)
    local self = setmetatable({}, WorkplaceSiteClient_mt)
    self.system = system
    self.view = nil             -- the current WT_SITE_VALUES_1 replica
    self.hotspots = {}          -- siteId -> WTMapHotspot
    self.consumers = {}
    self.consumerOrder = {}
    self.requestTimer = 0
    self.requestAttempts = 0
    self.needsView = false
    self.pendingResult = nil    -- callback awaiting the next command result
    self.lastResult = nil
    self.isInitialized = false
    return self
end

function WorkplaceSiteClient:initialize()
    self.isInitialized = true
    if g_currentMission ~= nil and not g_currentMission:getIsServer() then
        self.needsView = true
        self.requestTimer = 0
        self.requestAttempts = 0
    end
end

function WorkplaceSiteClient:isServer()
    return g_currentMission ~= nil and g_currentMission:getIsServer()
end

-- =========================================================
-- Replica
-- =========================================================
function WorkplaceSiteClient:capabilities()
    local ready = self.view ~= nil and self.view.availability == "READY"
    return { schema = "SITE_V1", valuesFormat = WTSiteEvents.VIEW_FORMAT, ready = ready,
        reasonCode = ready and "OK" or ((self.view and self.view.reason) or "NOT_READY") }
end

local function copySite(s)
    return { siteId = s.siteId, ownerFarmId = s.ownerFarmId, purpose = s.purpose, name = s.name,
        centreX = s.centreX, centreZ = s.centreZ, radiusMetres = s.radiusMetres,
        revision = s.revision, state = s.state, reason = s.reason }
end

--- Detached copies of the replica's sites (ACTIVE only outside administration).
function WorkplaceSiteClient:getSites()
    if self.view == nil or self.view.availability ~= "READY" then
        return nil, (self.view and self.view.reason) or "NOT_READY"
    end
    local out = {}
    for _, s in ipairs(self.view.sites) do
        if self.view.administrationTargetFarmId ~= nil or s.state == "ACTIVE" then
            out[#out + 1] = copySite(s)
        end
    end
    return out, "OK"
end

function WorkplaceSiteClient:getSite(siteId)
    if self.view == nil or self.view.availability ~= "READY" then
        return nil, (self.view and self.view.reason) or "NOT_READY"
    end
    for _, s in ipairs(self.view.sites) do
        if s.siteId == siteId then
            if s.state ~= "ACTIVE" and self.view.administrationTargetFarmId == nil then
                return nil, s.reason == "MAP_MISMATCH" and "MAP_MISMATCH" or "SITE_UNAVAILABLE"
            end
            return copySite(s), "OK"
        end
    end
    return nil, "NOT_FOUND"
end

--- Replace the replica atomically; old rows are cleared before the new ones
--- land, hotspots follow, consumers get UPSERT/DELETE notices.
function WorkplaceSiteClient:applyView(view)
    if type(view) ~= "table" then return end
    local old = self.view
    self.view = view
    self.needsView = false

    local oldIds = {}
    if old ~= nil then for _, s in ipairs(old.sites or {}) do oldIds[s.siteId] = s end end
    local newIds = {}
    for _, s in ipairs(view.sites or {}) do newIds[s.siteId] = s end

    -- Hotspots: only the own-farm ACTIVE view draws on the map.
    for id, hs in pairs(self.hotspots) do
        local s = newIds[id]
        if s == nil or s.state ~= "ACTIVE" or view.administrationTargetFarmId ~= nil then
            hs:delete()
            self.hotspots[id] = nil
        end
    end
    if view.availability == "READY" and view.administrationTargetFarmId == nil then
        for _, s in ipairs(view.sites or {}) do
            if s.state == "ACTIVE" and WTMapHotspot ~= nil then
                local hs = self.hotspots[s.siteId]
                if hs == nil then
                    hs = WTMapHotspot.new(self.system and self.system.modDirectory or "")
                    if hs.setStyle ~= nil then hs:setStyle("site") end
                    hs._visible = true
                    self.hotspots[s.siteId] = hs
                end
                hs:setWorldPosition(s.centreX or 0, s.centreZ or 0)
                hs:setName(s.name or "Site")
                hs:setIsActive(false)
            end
        end
    end

    for id, s in pairs(oldIds) do
        if newIds[id] == nil then self:notify(id, s.revision, "DELETE", s.ownerFarmId) end
    end
    for _, s in ipairs(view.sites or {}) do
        local was = oldIds[s.siteId]
        if was == nil or was.revision ~= s.revision or was.state ~= s.state then
            self:notify(s.siteId, s.revision, "UPSERT", s.ownerFarmId)
        end
    end

    -- Refresh an open site manager.
    if WTDialogLoader ~= nil and WTDialogLoader.refreshSiteList ~= nil then
        WTDialogLoader.refreshSiteList()
    end
end

function WorkplaceSiteClient:getHotspotList()
    local out = {}
    for _, hs in pairs(self.hotspots) do out[#out + 1] = hs end
    return out
end

-- =========================================================
-- Consumers (client-side notices)
-- =========================================================
function WorkplaceSiteClient:notify(siteId, revision, kind, ownerFarmId)
    for _, id in ipairs(self.consumerOrder) do
        local cb = self.consumers[id]
        if cb ~= nil then pcall(cb, siteId, revision, kind, ownerFarmId) end
    end
end

function WorkplaceSiteClient:subscribe(consumerId, callback)
    if type(consumerId) ~= "string" or consumerId == "" or type(callback) ~= "function" then return false end
    if self.consumers[consumerId] == nil then self.consumerOrder[#self.consumerOrder + 1] = consumerId end
    self.consumers[consumerId] = callback
    return true
end

function WorkplaceSiteClient:unsubscribe(consumerId)
    if self.consumers[consumerId] == nil then return false end
    self.consumers[consumerId] = nil
    for i, id in ipairs(self.consumerOrder) do
        if id == consumerId then table.remove(self.consumerOrder, i) break end
    end
    return true
end

-- =========================================================
-- View request (pure client) with a bounded warm-up burst
-- =========================================================
function WorkplaceSiteClient:sendViewRequest()
    if g_client == nil or g_client.getServerConnection == nil then return false end
    local conn = g_client:getServerConnection()
    if conn == nil or conn.isConnected == false or conn.isReadyForEvents == false then return false end
    if WTSiteViewRequestEvent == nil or WTSiteViewRequestEvent.eventId == nil then return false end
    local ok = pcall(function() conn:sendEvent(WTSiteViewRequestEvent.new()) end)
    return ok
end

function WorkplaceSiteClient:requestView()
    self.needsView = true
    self.requestTimer = 0
    self.requestAttempts = 0
end

--- Ask the server to enter (farmId) or leave (nil) the administration
--- context for this connection; the reply is the next view.
function WorkplaceSiteClient:requestAdministration(farmId)
    if self:isServer() then
        local svc = self.system and self.system.siteService
        if svc ~= nil then svc:setAdministrationContext(nil, farmId) end
        return true
    end
    if g_client == nil or g_client.getServerConnection == nil then return false end
    local conn = g_client:getServerConnection()
    if conn == nil or WTSiteViewRequestEvent == nil or WTSiteViewRequestEvent.eventId == nil then return false end
    local token = (farmId ~= nil) and tostring(farmId) or "0"
    local ok = pcall(function() conn:sendEvent(WTSiteViewRequestEvent.new(token)) end)
    return ok
end

function WorkplaceSiteClient:update(dtSec)
    if not self.isInitialized or self:isServer() then return end
    if not self.needsView then return end
    self.requestTimer = self.requestTimer + dtSec
    if self.requestTimer >= WorkplaceSiteClient.REQUEST_INTERVAL_SEC then
        self.requestTimer = 0
        if self:sendViewRequest() then
            self.requestAttempts = self.requestAttempts + 1
        end
        if self.requestAttempts >= WorkplaceSiteClient.REQUEST_MAX then
            self.needsView = false
            wtLog("site view request unanswered; the next server publication will fill it")
        end
    end
end

-- =========================================================
-- Commands
-- =========================================================
--- Send a command using the replica's session and next sequence. Returns the
--- result synchronously on the host; on a client returns true (sent) and the
--- result arrives through onCommandResult. `onResult` is called either way.
function WorkplaceSiteClient:sendCommand(actionId, fields, onResult)
    local v = self.view
    if v == nil or v.availability ~= "READY" or v.commandSessionId == nil or v.nextSequence == nil then
        local refused = { outcome = "REFUSED", reasonCode = "SESSION_WITHDRAWN" }
        if onResult ~= nil then onResult(refused) end
        return refused
    end
    local req = {
        commandSessionId = v.commandSessionId,
        sequence = v.nextSequence,
        actionId = actionId,
        targetId = fields.targetId,
        expectedRevision = fields.expectedRevision,
        administrationTargetFarmId = fields.administrationTargetFarmId,
        name = fields.name or "",
        purpose = fields.purpose or "",
        centreX = fields.centreX,
        centreZ = fields.centreZ,
        radiusMetres = fields.radiusMetres,
    }
    if self:isServer() then
        local svc = self.system and self.system.siteService
        if svc == nil then
            local refused = { outcome = "REFUSED", reasonCode = "NOT_READY" }
            if onResult ~= nil then onResult(refused) end
            return refused
        end
        local result = svc:handleLocalCommand(req)
        self:onCommandResult(result)
        if onResult ~= nil then onResult(result) end
        return result
    end
    if g_client == nil or g_client.getServerConnection == nil then
        local refused = { outcome = "REFUSED", reasonCode = "NOT_READY" }
        if onResult ~= nil then onResult(refused) end
        return refused
    end
    local conn = g_client:getServerConnection()
    if conn == nil then
        local refused = { outcome = "REFUSED", reasonCode = "NOT_READY" }
        if onResult ~= nil then onResult(refused) end
        return refused
    end
    self.pendingResult = onResult
    pcall(function() conn:sendEvent(WTSiteCommandRequestEvent.new(req)) end)
    return true
end

--- The server's typed result. The replica's nextSequence follows it; a
--- withdrawn session waits for the next READY view before anything is sent.
function WorkplaceSiteClient:onCommandResult(result)
    if type(result) ~= "table" then return end
    self.lastResult = result
    if self.view ~= nil then
        if result.reasonCode == "SESSION_WITHDRAWN" then
            self.view.commandSessionId = nil
            self.view.nextSequence = nil
        elseif result.nextSequence ~= nil and self.view.commandSessionId == result.commandSessionId then
            self.view.nextSequence = result.nextSequence
        end
    end
    local cb = self.pendingResult
    self.pendingResult = nil
    if cb ~= nil then pcall(cb, result) end
end

-- =========================================================
-- Navigation
-- =========================================================
--- Enter ordinary own-farm site management; a retained administration
--- display context is cleared. Returns whether navigation was possible.
function WorkplaceSiteClient:openSiteManager(selection)
    if WTDialogLoader == nil or WTDialogLoader.showSiteList == nil then return false end
    if self.system == nil or not self.system.isInitialized then return false end
    local focus = type(selection) == "table" and selection.siteId or nil
    return WTDialogLoader.showSiteList(self.system, focus, true)
end

function WorkplaceSiteClient:delete()
    for id, hs in pairs(self.hotspots) do
        hs:delete()
        self.hotspots[id] = nil
    end
    self.view = nil
    self.isInitialized = false
end

print("[WorkplaceTriggers] WorkplaceSiteClient loaded")
