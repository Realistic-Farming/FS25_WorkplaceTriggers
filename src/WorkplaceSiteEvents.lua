-- =========================================================
-- WorkplaceSiteEvents.lua  (WT-8)
-- The mod's own private site event pair and command event pair.
-- =========================================================
-- Sites never enter the public wage snapshot or NetworkSync's public
-- registerModule (that broadcasts every module to every client). These four
-- classes ship on every install and carry only the requesting connection's
-- farm-filtered view:
--
--   WTSiteViewRequestEvent   client -> server   "send me my current site view"
--   WTSiteViewStateEvent     server -> one connection   WT_SITE_VALUES_1
--   WTSiteCommandRequestEvent client -> server  WT_SITE_COMMAND_1
--   WTSiteCommandResultEvent  server -> one connection  the typed result
--
-- Every field travels as a string token (numbers as %.17g), counts as Int32.
-- Registered at file load through the native event mechanism (InitEventClass,
-- network/EventIds.lua:7). The existing WorkplaceTriggers_Request verb channel
-- is not used for sites: its verbs are not admin-gated and carry client farm
-- ids; here the actor is resolved from the connection on the server.
-- =========================================================

WTSiteEvents = WTSiteEvents or {}
WTSiteEvents.PROTOCOL_VERSION = 1
WTSiteEvents.VIEW_FORMAT      = "WT_SITE_VALUES_1"
WTSiteEvents.COMMAND_FORMAT   = "WT_SITE_COMMAND_1"

local function numToken(v)
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return "" end
    return string.format("%.17g", v)
end
local function tokenToNum(t)
    if type(t) ~= "string" or t == "" then return nil end
    local n = tonumber(t)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end
WTSiteEvents.numToken = numToken
WTSiteEvents.tokenToNum = tokenToNum

local function writeStr(streamId, s) streamWriteString(streamId, tostring(s or "")) end

-- ---------------------------------------------------------
-- View request (client -> server, no payload)
-- ---------------------------------------------------------
WTSiteViewRequestEvent = WTSiteViewRequestEvent or {}
local WTSiteViewRequestEvent_mt = Class(WTSiteViewRequestEvent, Event)
InitEventClass(WTSiteViewRequestEvent, "WTSiteViewRequestEvent")

-- One optional token: "" keeps the current administration context, "0"
-- leaves it, "N" asks to administer farm N (a master user only; the server
-- validates and binds it to this connection's session).
function WTSiteViewRequestEvent.emptyNew() return Event.new(WTSiteViewRequestEvent_mt) end
function WTSiteViewRequestEvent.new(administrationRequest)
    local self = WTSiteViewRequestEvent.emptyNew()
    self.administrationRequest = administrationRequest or ""
    return self
end
function WTSiteViewRequestEvent:writeStream(streamId, connection)
    writeStr(streamId, self.administrationRequest or "")
end
function WTSiteViewRequestEvent:readStream(streamId, connection)
    self.administrationRequest = streamReadString(streamId)
    self:run(connection)
end
function WTSiteViewRequestEvent:run(connection)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local sys = g_WorkplaceSystem
    if sys ~= nil and sys.siteService ~= nil then
        local req = self.administrationRequest
        if req == nil or req == "" then
            sys.siteService:onViewRequest(connection)
        elseif req == "0" then
            sys.siteService:onViewRequest(connection, false)
        else
            sys.siteService:onViewRequest(connection, tonumber(req))
        end
    end
end

-- ---------------------------------------------------------
-- View state (server -> one connection)
-- ---------------------------------------------------------
-- view = { format, availability, reason, definitionRevision, commandSessionId,
--          nextSequence, administrationTargetFarmId, sites = { SITE_V1... } }
WTSiteViewStateEvent = WTSiteViewStateEvent or {}
local WTSiteViewStateEvent_mt = Class(WTSiteViewStateEvent, Event)
InitEventClass(WTSiteViewStateEvent, "WTSiteViewStateEvent")

function WTSiteViewStateEvent.emptyNew() return Event.new(WTSiteViewStateEvent_mt) end
function WTSiteViewStateEvent.new(view)
    local self = WTSiteViewStateEvent.emptyNew()
    self.view = view
    return self
end

function WTSiteViewStateEvent:writeStream(streamId, connection)
    local v = self.view or {}
    writeStr(streamId, WTSiteEvents.VIEW_FORMAT)
    writeStr(streamId, v.availability or "NOT_READY")
    writeStr(streamId, v.reason or "")
    writeStr(streamId, v.definitionRevision or "0")
    writeStr(streamId, v.commandSessionId or "")
    writeStr(streamId, v.nextSequence or "")
    writeStr(streamId, v.administrationTargetFarmId ~= nil and tostring(v.administrationTargetFarmId) or "")
    -- Whether the actor's session currently holds an administration context.
    -- The ordinary view carries it so the client can drop its administration
    -- replica when the context ends (the admin view itself has a target).
    streamWriteBool(streamId, v.administrationActive == true)
    local sites = v.sites or {}
    streamWriteInt32(streamId, #sites)
    for _, s in ipairs(sites) do
        writeStr(streamId, s.siteId)
        writeStr(streamId, tostring(s.ownerFarmId or ""))
        writeStr(streamId, s.purpose or "")
        writeStr(streamId, s.name or "")
        writeStr(streamId, numToken(s.centreX))
        writeStr(streamId, numToken(s.centreZ))
        writeStr(streamId, numToken(s.radiusMetres))
        writeStr(streamId, s.revision or "1")
        writeStr(streamId, s.state or "ACTIVE")
        writeStr(streamId, s.reason or "")
    end
end

function WTSiteViewStateEvent:readStream(streamId, connection)
    local v = {}
    v.format = streamReadString(streamId)
    v.availability = streamReadString(streamId)
    v.reason = streamReadString(streamId)
    v.definitionRevision = streamReadString(streamId)
    v.commandSessionId = streamReadString(streamId)
    v.nextSequence = streamReadString(streamId)
    local admin = streamReadString(streamId)
    v.administrationTargetFarmId = tonumber(admin)
    v.administrationActive = streamReadBool(streamId)
    local n = streamReadInt32(streamId)
    v.sites = {}
    if n < 0 or n > 4096 then n = 0 end
    for i = 1, n do
        local s = {}
        s.siteId = streamReadString(streamId)
        s.ownerFarmId = tonumber(streamReadString(streamId))
        s.purpose = streamReadString(streamId)
        s.name = streamReadString(streamId)
        s.centreX = tokenToNum(streamReadString(streamId))
        s.centreZ = tokenToNum(streamReadString(streamId))
        s.radiusMetres = tokenToNum(streamReadString(streamId))
        s.revision = streamReadString(streamId)
        s.state = streamReadString(streamId)
        s.reason = streamReadString(streamId)
        if s.reason == "" then s.reason = nil end
        v.sites[i] = s
    end
    if v.commandSessionId == "" then v.commandSessionId = nil end
    if v.nextSequence == "" then v.nextSequence = nil end
    if v.reason == "" then v.reason = nil end
    self.view = v
    self:run(connection)
end

function WTSiteViewStateEvent:run(connection)
    -- Only a pure client applies a received view; the host holds its own local view.
    if g_currentMission ~= nil and g_currentMission:getIsServer() then return end
    if self.view == nil or self.view.format ~= WTSiteEvents.VIEW_FORMAT then return end
    local sys = g_WorkplaceSystem
    if sys ~= nil and sys.siteClient ~= nil then
        sys.siteClient:applyView(self.view)
    end
end

-- ---------------------------------------------------------
-- Command request (client -> server)
-- ---------------------------------------------------------
-- req = { commandSessionId, sequence, actionId, targetId, expectedRevision,
--         administrationTargetFarmId, name, purpose, centreX, centreZ, radiusMetres }
WTSiteCommandRequestEvent = WTSiteCommandRequestEvent or {}
local WTSiteCommandRequestEvent_mt = Class(WTSiteCommandRequestEvent, Event)
InitEventClass(WTSiteCommandRequestEvent, "WTSiteCommandRequestEvent")

function WTSiteCommandRequestEvent.emptyNew() return Event.new(WTSiteCommandRequestEvent_mt) end
function WTSiteCommandRequestEvent.new(req)
    local self = WTSiteCommandRequestEvent.emptyNew()
    self.request = req
    return self
end

function WTSiteCommandRequestEvent:writeStream(streamId, connection)
    local r = self.request or {}
    streamWriteInt32(streamId, WTSiteEvents.PROTOCOL_VERSION)
    writeStr(streamId, WTSiteEvents.COMMAND_FORMAT)
    writeStr(streamId, "SITE")
    writeStr(streamId, r.commandSessionId)
    writeStr(streamId, r.sequence)
    writeStr(streamId, r.actionId)
    writeStr(streamId, r.targetId)
    writeStr(streamId, r.expectedRevision)
    writeStr(streamId, r.administrationTargetFarmId ~= nil and tostring(r.administrationTargetFarmId) or "")
    writeStr(streamId, r.name)
    writeStr(streamId, r.purpose)
    writeStr(streamId, numToken(r.centreX))
    writeStr(streamId, numToken(r.centreZ))
    writeStr(streamId, numToken(r.radiusMetres))
end

function WTSiteCommandRequestEvent:readStream(streamId, connection)
    local r = {}
    r.protocolVersion = streamReadInt32(streamId)
    r.format = streamReadString(streamId)
    r.route = streamReadString(streamId)
    r.commandSessionId = streamReadString(streamId)
    r.sequence = streamReadString(streamId)
    r.actionId = streamReadString(streamId)
    r.targetId = streamReadString(streamId)
    r.expectedRevision = streamReadString(streamId)
    local admin = streamReadString(streamId)
    r.administrationTargetFarmId = tonumber(admin)
    r.name = streamReadString(streamId)
    r.purpose = streamReadString(streamId)
    r.centreX = tokenToNum(streamReadString(streamId))
    r.centreZ = tokenToNum(streamReadString(streamId))
    r.radiusMetres = tokenToNum(streamReadString(streamId))
    if r.targetId == "" then r.targetId = nil end
    if r.expectedRevision == "" then r.expectedRevision = nil end
    self.request = r
    self:run(connection)
end

function WTSiteCommandRequestEvent:run(connection)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    local sys = g_WorkplaceSystem
    if sys == nil or sys.siteService == nil then return end   -- unloading: dropped without a result
    local r = self.request
    if r == nil or r.protocolVersion ~= WTSiteEvents.PROTOCOL_VERSION or r.format ~= WTSiteEvents.COMMAND_FORMAT or r.route ~= "SITE" then
        return
    end
    local result = sys.siteService:handleCommandFromConnection(connection, r)
    if result ~= nil and connection ~= nil and connection.sendEvent ~= nil then
        pcall(function() connection:sendEvent(WTSiteCommandResultEvent.new(result)) end)
    end
end

-- ---------------------------------------------------------
-- Command result (server -> one connection)
-- ---------------------------------------------------------
-- result = { commandSessionId, sequence, outcome, reasonCode, resultingRevision,
--            nextSequence, currentTarget = SITE_V1 | nil }
WTSiteCommandResultEvent = WTSiteCommandResultEvent or {}
local WTSiteCommandResultEvent_mt = Class(WTSiteCommandResultEvent, Event)
InitEventClass(WTSiteCommandResultEvent, "WTSiteCommandResultEvent")

function WTSiteCommandResultEvent.emptyNew() return Event.new(WTSiteCommandResultEvent_mt) end
function WTSiteCommandResultEvent.new(result)
    local self = WTSiteCommandResultEvent.emptyNew()
    self.result = result
    return self
end

function WTSiteCommandResultEvent:writeStream(streamId, connection)
    local r = self.result or {}
    writeStr(streamId, r.commandSessionId)
    writeStr(streamId, r.sequence)
    writeStr(streamId, r.outcome)
    writeStr(streamId, r.reasonCode)
    writeStr(streamId, r.resultingRevision)
    writeStr(streamId, r.nextSequence)
    local t = r.currentTarget
    streamWriteBool(streamId, t ~= nil)
    if t ~= nil then
        writeStr(streamId, t.siteId)
        writeStr(streamId, tostring(t.ownerFarmId or ""))
        writeStr(streamId, t.purpose or "")
        writeStr(streamId, t.name or "")
        writeStr(streamId, numToken(t.centreX))
        writeStr(streamId, numToken(t.centreZ))
        writeStr(streamId, numToken(t.radiusMetres))
        writeStr(streamId, t.revision or "")
        writeStr(streamId, t.state or "")
        writeStr(streamId, t.reason or "")
    end
end

function WTSiteCommandResultEvent:readStream(streamId, connection)
    local r = {}
    r.commandSessionId = streamReadString(streamId)
    r.sequence = streamReadString(streamId)
    r.outcome = streamReadString(streamId)
    r.reasonCode = streamReadString(streamId)
    r.resultingRevision = streamReadString(streamId)
    r.nextSequence = streamReadString(streamId)
    if streamReadBool(streamId) then
        local t = {}
        t.siteId = streamReadString(streamId)
        t.ownerFarmId = tonumber(streamReadString(streamId))
        t.purpose = streamReadString(streamId)
        t.name = streamReadString(streamId)
        t.centreX = tokenToNum(streamReadString(streamId))
        t.centreZ = tokenToNum(streamReadString(streamId))
        t.radiusMetres = tokenToNum(streamReadString(streamId))
        t.revision = streamReadString(streamId)
        t.state = streamReadString(streamId)
        t.reason = streamReadString(streamId)
        if t.reason == "" then t.reason = nil end
        r.currentTarget = t
    end
    if r.resultingRevision == "" then r.resultingRevision = nil end
    if r.nextSequence == "" then r.nextSequence = nil end
    self.result = r
    self:run(connection)
end

function WTSiteCommandResultEvent:run(connection)
    if g_currentMission ~= nil and g_currentMission:getIsServer() then return end
    local sys = g_WorkplaceSystem
    if sys ~= nil and sys.siteClient ~= nil and self.result ~= nil then
        sys.siteClient:onCommandResult(self.result)
    end
end

print("[WorkplaceTriggers] WorkplaceSiteEvents loaded")
