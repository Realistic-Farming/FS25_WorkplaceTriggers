-- =========================================================
-- WorkplaceSiteService.lua  (WT-8)
-- Server-side provider: actor resolution, permission, sessions, commands,
-- private views, notices, save backends, farm deletion, load finalization,
-- and the mission-handle adapters (dot-bound closures).
-- =========================================================
-- Engine seams (D:\FS25_Decoded\dataS\scripts_decompiled):
--   FSBaseMission:getHasPlayerPermission(permission, connection, farmId)
--     FSBaseMission.lua:2070; Farm.PERMISSION.UPDATE_FARM farms/Farm.lua:23
--   FSBaseMission:getFarmId(connection) :1067; UserManager:getUserByConnection
--     users/UserManager.lua:74; User:getIsMasterUser users/User.lua:93
--   FarmManager:getFarmById farms/FarmManager.lua:203, SPECTATOR_FARM_ID :5,
--     mergedFarms :18 filled by mergeFarmsForSingleplayer :100-126,
--     FARM_DELETED published by destroyFarm :355 (MessageType.lua:28)
--   BaseMission:finishLoadingTask / onFinishedLoading BaseMission.lua:211-227
--     (isLoaded, numLoadingTasks); FSBaseMission:onFinishedLoading :701
--   missionInfo.mapId FSCareerMissionInfo.lua:476; g_terrainSize FSBaseMission.lua:1261
-- =========================================================

WorkplaceSiteService = WorkplaceSiteService or {}
WorkplaceSiteService_mt = Class(WorkplaceSiteService)

WorkplaceSiteService.LEDGER_MODULE_ID = "WorkplaceTriggers_Sites"
WorkplaceSiteService.SEQUENCE_LIMIT   = 2147483647
WorkplaceSiteService.ACTIONS = { CREATE_SITE = true, UPDATE_SITE = true, DELETE_SITE = true, TRANSFER_SITE = true }

local Store = WorkplaceSiteStore
local SPECTATOR = 0

local function wtLog(msg)
    print("[WorkplaceTriggers] Sites: " .. tostring(msg))
end

-- =========================================================
-- Construction
-- =========================================================
function WorkplaceSiteService.new(system)
    local self = setmetatable({}, WorkplaceSiteService_mt)
    self.system = system
    self.store = Store.new()
    self.sessions = {}          -- sessionKey (connection object or "local") -> session
    self.sessionSerial = "0"
    self.subscribers = {}       -- connection -> true (remote view subscribers)
    self.consumers = {}         -- consumerId -> callback
    self.consumerOrder = {}
    self.ledgerActive = false
    self.ledgerDelivered = false
    self.ledgerPending = nil
    self.staged = false
    self.finishedLoadingWrapper = nil
    self.finishedLoadingOriginal = nil
    self.finishedLoadingMission = nil
    self.isInitialized = false
    return self
end

function WorkplaceSiteService:isServer()
    return g_currentMission ~= nil and g_currentMission:getIsServer()
end

function WorkplaceSiteService:liveMapId()
    local mi = g_currentMission and g_currentMission.missionInfo
    return mi and mi.mapId or nil
end

function WorkplaceSiteService:liveTerrainSize()
    if type(g_terrainSize) == "number" and g_terrainSize > 0 then return g_terrainSize end
    if g_currentMission ~= nil and type(g_currentMission.terrainSize) == "number" then return g_currentMission.terrainSize end
    return nil
end

-- =========================================================
-- Initialization: backends, staging, native completion binding
-- =========================================================
function WorkplaceSiteService:initialize()
    if self.isInitialized then return end
    self.isInitialized = true
    if not self:isServer() then return end

    self:registerLedgerModule()
    self:stageFromBackends()
    self:installFinishedLoadingBinding()
    self:subscribeFarmMessages()
    self:finalizeIfLoaded()
end

--- Own StateLedger module, beside (never inside) WorkplaceTriggers_Data.
function WorkplaceSiteService:registerLedgerModule()
    self.ledgerActive = false
    self.ledgerDelivered = false
    self.ledgerPending = nil
    local ledger = (g_currentMission ~= nil and g_currentMission.stateLedger) or g_stateLedger
    if ledger == nil then return end
    local svc = self
    local ok, err = pcall(function()
        ledger:registerModule(WorkplaceSiteService.LEDGER_MODULE_ID, {
            serialize = function()
                if not svc.store.staged then return nil end
                return svc.store:serialize(svc:liveMapId(), svc:liveTerrainSize())
            end,
            deserialize = function(data)
                svc.ledgerDelivered = true
                svc.ledgerPending = data
            end,
        })
        if ledger.parseFile ~= nil then ledger:parseFile() end
    end)
    if ok then
        self.ledgerActive = true
        wtLog("registered StateLedger module '" .. WorkplaceSiteService.LEDGER_MODULE_ID .. "' (own XML kept as safety copy)")
    else
        wtLog("StateLedger registration failed: " .. tostring(err) .. " (own XML only)")
    end
end

--- Load order: a delivered known ledger block; else the own XML file with a
--- known schema; else first use, empty. Never merged record by record.
function WorkplaceSiteService:stageFromBackends(missionInfo)
    local mapId, terrainSize = self:liveMapId(), self:liveTerrainSize()
    if self.ledgerActive and self.ledgerDelivered and Store.isKnownContainer(self.ledgerPending) then
        self.store:stageContainer(self.ledgerPending, mapId, terrainSize)
        wtLog(string.format("staged %d site(s) from StateLedger", #self.store.records))
        self.staged = true
        return
    end
    local path = Store.getXMLPath(missionInfo)
    if path ~= nil and XMLFile ~= nil and XMLFile.loadIfExists ~= nil then
        local xmlFile = XMLFile.loadIfExists("workplaceSitesSave", path)
        if xmlFile ~= nil then
            local c = Store.readXML(xmlFile)
            xmlFile:delete()
            if c ~= nil then
                self.store:stageContainer(c, mapId, terrainSize)
                wtLog(string.format("staged %d site(s) from %s", #self.store.records, path))
                self.staged = true
                return
            end
        end
    end
    self.store:stageEmpty(mapId, terrainSize)
    self.staged = true
    wtLog("no site container found; first use")
end

--- Both backends every save. Called from the mod's save hook (server only).
function WorkplaceSiteService:saveToXMLFile(missionInfo)
    if not self:isServer() or not self.store.staged then return end
    local path = Store.getXMLPath(missionInfo)
    if path == nil or XMLFile == nil then return end
    local xmlFile = XMLFile.create("workplaceSitesSave", path, Store.XML_ROOT)
    if xmlFile == nil then return end
    Store.writeXML(xmlFile, self.store:serialize(self:liveMapId(), self:liveTerrainSize()))
    xmlFile:save()
    xmlFile:delete()
    wtLog(string.format("saved %d site(s) to %s", #self.store.records, path))
end

-- The loaded-mission predicate: native farm reconstruction has completed.
local function missionLoaded(mission)
    return mission ~= nil and mission.isLoaded == true and (mission.numLoadingTasks or 0) <= 0
end
WorkplaceSiteService.missionLoaded = missionLoaded

--- Owner checks ride the mission's own onFinishedLoading, after the original
--- body. The wrapper is installed on the mission instance, preserves the
--- captured method and its returns, and restores itself only if it is still
--- the current method (an enclosing foreign wrapper stays intact).
function WorkplaceSiteService:installFinishedLoadingBinding()
    local mission = g_currentMission
    if mission == nil or type(mission.onFinishedLoading) ~= "function" then return end
    if self.finishedLoadingWrapper ~= nil then return end
    local svc = self
    local original = mission.onFinishedLoading
    local wrapper = function(m, ...)
        local results = { original(m, ...) }
        if svc.finishedLoadingMission == m and g_WorkplaceSystem ~= nil and g_WorkplaceSystem.siteService == svc then
            svc:finalizeIfLoaded()
        end
        return unpack(results)
    end
    self.finishedLoadingWrapper = wrapper
    self.finishedLoadingOriginal = original
    self.finishedLoadingMission = mission
    mission.onFinishedLoading = wrapper
end

function WorkplaceSiteService:removeFinishedLoadingBinding()
    local mission = self.finishedLoadingMission
    if mission ~= nil and self.finishedLoadingWrapper ~= nil and mission.onFinishedLoading == self.finishedLoadingWrapper then
        mission.onFinishedLoading = self.finishedLoadingOriginal
    end
    self.finishedLoadingWrapper = nil
    self.finishedLoadingOriginal = nil
    self.finishedLoadingMission = nil
end

--- Idempotent: finalize owners once the mission is loaded, then READY and publish.
function WorkplaceSiteService:finalizeIfLoaded()
    if not self:isServer() or not self.store.staged or self.store.finalized then return false end
    if not missionLoaded(g_currentMission) then return false end
    local function farmExists(farmId)
        return g_farmManager ~= nil and g_farmManager.getFarmById ~= nil and g_farmManager:getFarmById(farmId) ~= nil
    end
    local merged = g_farmManager ~= nil and g_farmManager.mergedFarms or nil
    self.store:finalizeOwners(farmExists, merged)
    wtLog(string.format("site capabilities READY (%d site(s), container %s)", #self.store.records, self.store.containerState))
    for _, r in ipairs(self.store.records) do
        self:notify(r.siteId, r.revision, "UPSERT", r.ownerFarmId)
    end
    self:publishAll()
    return true
end

function WorkplaceSiteService:subscribeFarmMessages()
    if g_messageCenter == nil or MessageType == nil then return end
    if MessageType.FARM_DELETED ~= nil then
        g_messageCenter:subscribe(MessageType.FARM_DELETED, self.onFarmDeleted, self)
    end
    if MessageType.PLAYER_FARM_CHANGED ~= nil then
        g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, self.onPlayerFarmChanged, self)
    end
end

--- Live farm deletion: sites UNAVAILABLE at once, sessions on that farm
--- withdrawn, views republished.
function WorkplaceSiteService:onFarmDeleted(farmId)
    if not self:isServer() then return end
    local changed = self.store:markFarmUnavailable(farmId)
    for key, session in pairs(self.sessions) do
        if session.farmId == farmId or session.administrationTargetFarmId == farmId then
            self.sessions[key] = nil
        end
    end
    for _, r in ipairs(changed) do
        self:notify(r.siteId, r.revision, "UPSERT", r.ownerFarmId)
    end
    self:publishAll()
end

function WorkplaceSiteService:onPlayerFarmChanged()
    if not self:isServer() then return end
    -- Any actor's farm may have changed: sessions bound to a farm are re-checked
    -- at their next command; views are republished now.
    self:publishAll()
end

function WorkplaceSiteService:delete()
    if g_messageCenter ~= nil and g_messageCenter.unsubscribeAll ~= nil then
        g_messageCenter:unsubscribeAll(self)
    end
    self:removeFinishedLoadingBinding()
    self.sessions = {}
    self.subscribers = {}
    self.isInitialized = false
end

-- =========================================================
-- Actor resolution and permission
-- =========================================================
--- The trusted actor for a connection (nil = the local host / singleplayer).
function WorkplaceSiteService:resolveActor(connection)
    local actor = { connection = connection, farmId = nil, userId = nil, isMasterUser = false, isLocal = connection == nil }
    if connection == nil then
        if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
            local ok, id = pcall(g_currentMission.getFarmId, g_currentMission)
            if ok then actor.farmId = id end
        end
        actor.userId = g_currentMission ~= nil and g_currentMission.playerUserId or nil
        actor.isMasterUser = true
        return actor
    end
    local user = nil
    if g_currentMission ~= nil and g_currentMission.userManager ~= nil and g_currentMission.userManager.getUserByConnection ~= nil then
        user = g_currentMission.userManager:getUserByConnection(connection)
    end
    if user ~= nil then
        if user.getId ~= nil then actor.userId = user:getId() end
        if user.getIsMasterUser ~= nil then actor.isMasterUser = user:getIsMasterUser() == true
        else actor.isMasterUser = user.isMasterUser == true end
    end
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        local ok, id = pcall(g_currentMission.getFarmId, g_currentMission, connection)
        if ok then actor.farmId = id end
    end
    return actor
end

local function farmExistsLive(farmId)
    return g_farmManager ~= nil and g_farmManager.getFarmById ~= nil and g_farmManager:getFarmById(farmId) ~= nil
end

--- A remote connection the server can still reach. isConnected is only ever
--- cleared on a client's server connection (network/Client.lua:155, 176, 440),
--- so on the server the user record is the liveness test: the user manager
--- drops it when the connection closes (users/UserManager.lua:74).
local function connectionIsLive(connection)
    if connection == nil then return false end
    if connection.isConnected == false then return false end
    local um = g_currentMission ~= nil and g_currentMission.userManager or nil
    if um ~= nil and um.getUserByConnection ~= nil then
        return um:getUserByConnection(connection) ~= nil
    end
    return true
end
WorkplaceSiteService.connectionIsLive = connectionIsLive

--- Native UPDATE_FARM permission on a target farm.
function WorkplaceSiteService:hasNativePermission(actor, targetFarmId)
    if g_currentMission == nil or g_currentMission.getHasPlayerPermission == nil then
        return actor.isLocal == true
    end
    local perm = (Farm ~= nil and Farm.PERMISSION ~= nil and Farm.PERMISSION.UPDATE_FARM) or "updateFarm"
    local ok, allowed = pcall(g_currentMission.getHasPlayerPermission, g_currentMission, perm, actor.connection, targetFarmId)
    return ok and allowed == true
end

--- An explicit administration context: a master user naming an existing,
--- non-spectator farm. Returns the target farm id or nil.
function WorkplaceSiteService:administrationTarget(actor, requested)
    if requested == nil then return nil end
    if not actor.isMasterUser then return nil end
    if not Store.isOrdinaryFarmId(requested) or not farmExistsLive(requested) then return nil end
    return requested
end

--- Permission for a farm-scoped site command. The native call admits the
--- farm manager, a granted right, the host and a master user; the site path
--- narrows it with the own-farm fence unless an administration context names
--- the target (Arissani, 2026-09-12).
function WorkplaceSiteService:mayEditFarm(actor, targetFarmId, adminTarget)
    if adminTarget ~= nil then
        -- The administered farm's own sites, or an orphan of a missing farm.
        if adminTarget == targetFarmId then return true, "OK" end
        if not farmExistsLive(targetFarmId) then return true, "OK" end
        return false, "UNAUTHORIZED"
    end
    if not Store.isOrdinaryFarmId(targetFarmId) then return false, "INVALID_FARM" end
    if actor.farmId ~= targetFarmId then return false, "UNAUTHORIZED" end
    if not self:hasNativePermission(actor, targetFarmId) then return false, "UNAUTHORIZED" end
    return true, "OK"
end

-- =========================================================
-- Sessions
-- =========================================================
local function sessionKey(actor)
    return actor.connection or "local"
end

function WorkplaceSiteService:isEligibleForCommands(actor)
    if actor.isMasterUser then return true end
    return Store.isOrdinaryFarmId(actor.farmId)
end

--- Issue (or keep) the session for an actor's current binding.
--- The permission snapshot a session is bound to: a change (the farm manager
--- right granted or revoked) withdraws the session at the next republish.
function WorkplaceSiteService:permissionSnapshot(actor)
    if actor.isMasterUser then return true end
    if not Store.isOrdinaryFarmId(actor.farmId) then return false end
    return self:hasNativePermission(actor, actor.farmId)
end

function WorkplaceSiteService:issueSession(actor, adminTarget)
    local key = sessionKey(actor)
    local s = self.sessions[key]
    local perm = self:permissionSnapshot(actor)
    if s ~= nil and not s.reissue and s.userId == actor.userId and s.farmId == actor.farmId and s.isMasterUser == actor.isMasterUser
        and s.administrationTargetFarmId == adminTarget and s.hasPermission == perm then
        return s
    end
    self.sessionSerial = Store.incrementDecimal(self.sessionSerial)
    s = {
        commandSessionId = "s" .. self.sessionSerial,
        userId = actor.userId, farmId = actor.farmId, isMasterUser = actor.isMasterUser,
        administrationTargetFarmId = adminTarget,
        hasPermission = perm,
        nextSequence = 1,
        lastSequence = nil,
        lastResult = nil,
    }
    self.sessions[key] = s
    return s
end

function WorkplaceSiteService:withdrawSession(actor)
    self.sessions[sessionKey(actor)] = nil
end

--- Withdraw every session bound to a farm (an owner change): the session is
--- flagged for reissue, so a command against it is SESSION_WITHDRAWN and the
--- next republish issues a fresh id while the actor's administration context
--- is kept. Returns the number withdrawn.
function WorkplaceSiteService:withdrawSessionsOnFarms(farmIds)
    local set = {}
    for _, id in ipairs(farmIds) do if id ~= nil then set[id] = true end end
    local n = 0
    for _, session in pairs(self.sessions) do
        if set[session.farmId] or (session.administrationTargetFarmId ~= nil and set[session.administrationTargetFarmId]) then
            session.reissue = true
            n = n + 1
        end
    end
    return n
end

--- Republish to the actor after any real session change, so nothing is stuck.
function WorkplaceSiteService:republishActor(actor)
    if actor.connection == nil then
        self:publishLocal()
    else
        self:publishTo(actor.connection)
    end
end

-- =========================================================
-- Views
-- =========================================================
function WorkplaceSiteService:capabilities()
    local ready = self.store:isReady()
    return { schema = "SITE_V1", valuesFormat = WTSiteEvents.VIEW_FORMAT, ready = ready, reasonCode = ready and "OK" or "NOT_READY" }
end

--- Build the private WT_SITE_VALUES_1 view for an actor. Ordinary: own farm,
--- ACTIVE only. Administration: the target farm, every record with its state.
--- `session` is the session already issued for this publish (the same one
--- stamps the ordinary and the administration view); nil issues one here.
--- `adminActive` marks the ordinary view of an actor whose session holds an
--- administration context.
function WorkplaceSiteService:buildView(actor, adminTarget, session, adminActive)
    local view = { format = WTSiteEvents.VIEW_FORMAT, definitionRevision = self.store.containerRevision, sites = {},
                   administrationActive = adminActive == true or adminTarget ~= nil }
    if not self.store:isReady() then
        view.availability = "NOT_READY"
        view.reason = "NOT_READY"
        return view
    end
    local farmId = adminTarget or actor.farmId
    if not Store.isOrdinaryFarmId(farmId) then
        view.availability = "NOT_READY"
        view.reason = "INVALID_FARM"
        return view
    end
    view.availability = "READY"
    view.reason = nil
    if adminTarget ~= nil then
        view.sites = self.store:listForAdministration(farmId, farmExistsLive)
    else
        view.sites = self.store:listForFarm(farmId, false)
    end
    view.administrationTargetFarmId = adminTarget
    if self:isEligibleForCommands(actor) then
        local s = session or self:issueSession(actor, adminTarget)
        view.commandSessionId = s.commandSessionId
        view.nextSequence = tostring(s.nextSequence)
    end
    return view
end

--- A client's view request. administrationRequest: nil keeps the context,
--- false leaves it, a number asks to administer that farm (validated).
function WorkplaceSiteService:onViewRequest(connection, administrationRequest)
    if connection == nil then return end
    if connection.streamId ~= nil and NetworkNode ~= nil and connection.streamId == NetworkNode.LOCAL_STREAM_ID then return end
    if not connectionIsLive(connection) then return end
    self.subscribers[connection] = true
    if administrationRequest == false then
        self:setAdministrationContext(connection, nil)
        return
    elseif administrationRequest ~= nil then
        local ok = self:setAdministrationContext(connection, administrationRequest)
        if ok then return end
    end
    self:publishTo(connection)
end

--- The two views of one actor: the ordinary own-farm replica always, and the
--- administration replica in addition while the session holds a context.
--- One session stamps both.
function WorkplaceSiteService:buildViewsFor(actor)
    local admin = nil
    local s = self.sessions[sessionKey(actor)]
    if s ~= nil and s.administrationTargetFarmId ~= nil and actor.isMasterUser then
        admin = self:administrationTarget(actor, s.administrationTargetFarmId)
    end
    local session = nil
    if self.store:isReady() and self:isEligibleForCommands(actor) then
        session = self:issueSession(actor, admin)
    end
    local ordinary = self:buildView(actor, nil, session, admin ~= nil)
    local adminView = nil
    if admin ~= nil then adminView = self:buildView(actor, admin, session, true) end
    return ordinary, adminView
end

function WorkplaceSiteService:publishTo(connection)
    if not connectionIsLive(connection) then
        self.subscribers[connection] = nil
        self.sessions[connection] = nil
        return
    end
    local actor = self:resolveActor(connection)
    local ordinary, adminView = self:buildViewsFor(actor)
    pcall(function() connection:sendEvent(WTSiteViewStateEvent.new(ordinary)) end)
    if adminView ~= nil then
        pcall(function() connection:sendEvent(WTSiteViewStateEvent.new(adminView)) end)
    end
end

--- Every remote subscriber, and the local context's view in process.
function WorkplaceSiteService:publishAll()
    if not self:isServer() then return end
    for connection in pairs(self.subscribers) do
        self:publishTo(connection)
    end
    -- Sessions of connections that are gone (never published to again).
    for key in pairs(self.sessions) do
        if key ~= "local" and not connectionIsLive(key) then self.sessions[key] = nil end
    end
    self:publishLocal()
end

--- The listen host and singleplayer player have no connection: their view is
--- built here, in process, and is the only site list their map and manager read.
function WorkplaceSiteService:publishLocal()
    local sys = self.system
    if sys == nil or sys.siteClient == nil then return end
    local actor = self:resolveActor(nil)
    local ordinary, adminView = self:buildViewsFor(actor)
    sys.siteClient:applyView(ordinary)
    if adminView ~= nil then sys.siteClient:applyView(adminView) end
end

--- Enter or leave the administration context for the local host / a client.
function WorkplaceSiteService:setAdministrationContext(connection, targetFarmId)
    local actor = self:resolveActor(connection)
    local admin = self:administrationTarget(actor, targetFarmId)
    if targetFarmId ~= nil and admin == nil then return false, "UNAUTHORIZED" end
    self:withdrawSession(actor)
    self:issueSession(actor, admin)
    if connection == nil then self:publishLocal() else self:publishTo(connection) end
    return true, "OK"
end

-- =========================================================
-- Consumer notices and reads
-- =========================================================
function WorkplaceSiteService:notify(siteId, revision, kind, ownerFarmId)
    for _, id in ipairs(self.consumerOrder) do
        local cb = self.consumers[id]
        if cb ~= nil then pcall(cb, siteId, revision, kind, ownerFarmId) end
    end
end

function WorkplaceSiteService:subscribe(consumerId, callback)
    if type(consumerId) ~= "string" or consumerId == "" or type(callback) ~= "function" then return false end
    if self.consumers[consumerId] == nil then self.consumerOrder[#self.consumerOrder + 1] = consumerId end
    self.consumers[consumerId] = callback
    return true
end

function WorkplaceSiteService:unsubscribe(consumerId)
    if self.consumers[consumerId] == nil then return false end
    self.consumers[consumerId] = nil
    for i, id in ipairs(self.consumerOrder) do
        if id == consumerId then table.remove(self.consumerOrder, i) break end
    end
    return true
end

--- Server-side read with a trusted context {farmId, userId, isMasterUser, administrationTargetFarmId?}.
function WorkplaceSiteService:getSitesForFarm(ctx)
    if not self.store:isReady() then return nil, "NOT_READY" end
    if type(ctx) ~= "table" then return nil, "UNAUTHORIZED" end
    local admin = nil
    if ctx.administrationTargetFarmId ~= nil then
        if ctx.isMasterUser ~= true then return nil, "UNAUTHORIZED" end
        admin = self:administrationTarget({ isMasterUser = true }, ctx.administrationTargetFarmId)
        if admin == nil then return nil, "INVALID_FARM" end
    end
    local farmId = admin or ctx.farmId
    if not Store.isOrdinaryFarmId(farmId) then return nil, "INVALID_FARM" end
    if admin ~= nil then return self.store:listForAdministration(farmId, farmExistsLive), "OK" end
    return self.store:listForFarm(farmId, false), "OK"
end

function WorkplaceSiteService:getSite(siteId, ctx)
    if not self.store:isReady() then return nil, "NOT_READY" end
    if type(ctx) ~= "table" then return nil, "UNAUTHORIZED" end
    local r = self.store:get(siteId)
    if r == nil then return nil, "NOT_FOUND" end
    local admin = nil
    if ctx.administrationTargetFarmId ~= nil and ctx.isMasterUser == true then
        admin = self:administrationTarget({ isMasterUser = true }, ctx.administrationTargetFarmId)
    end
    if admin ~= nil then
        if r.ownerFarmId ~= admin and not (r.state == Store.STATE_UNAVAILABLE and not farmExistsLive(r.ownerFarmId)) then
            return nil, "UNAUTHORIZED"
        end
    elseif r.ownerFarmId ~= ctx.farmId then
        return nil, "UNAUTHORIZED"
    end
    local d = Store.detached(r)
    d.state, d.reason = self.store:effectiveState(r)
    if d.state ~= Store.STATE_ACTIVE and admin == nil then
        return nil, d.reason == Store.REASON_MAP_MISMATCH and "MAP_MISMATCH" or "SITE_UNAVAILABLE"
    end
    return d, "OK"
end

-- =========================================================
-- Commands
-- =========================================================
local function parseSequence(s)
    if type(s) ~= "string" or s:find("^[1-9][0-9]*$") == nil or #s > 10 then return nil end
    local n = tonumber(s)
    if n == nil or n > WorkplaceSiteService.SEQUENCE_LIMIT then return nil end
    return n
end

local function targetOf(store, r)
    if r == nil then return nil end
    local d = Store.detached(r)
    d.state, d.reason = store:effectiveState(r)
    return d
end

--- Handle a command for an actor. Returns the typed result table.
function WorkplaceSiteService:handleCommand(actor, req)
    local result = { commandSessionId = "", sequence = "", outcome = "REFUSED", reasonCode = "INVALID_FIELDS", resultingRevision = nil, nextSequence = nil, currentTarget = nil }
    if type(req) ~= "table" then return result end
    result.commandSessionId = req.commandSessionId or ""
    result.sequence = req.sequence or ""
    if not WorkplaceSiteService.ACTIONS[req.actionId] then return result end
    if not self.store:isReady() then result.reasonCode = "NOT_READY" return result end

    -- Session binding. A request naming a stale or foreign session id is
    -- refused without touching the actor's current session; only a changed
    -- binding (user, farm, master flag, permission) or no session at all is a
    -- real withdrawal. Either way the actor is republished so nothing is stuck.
    local s = self.sessions[sessionKey(actor)]
    if s == nil or s.reissue or s.userId ~= actor.userId or s.farmId ~= actor.farmId or s.isMasterUser ~= actor.isMasterUser
        or s.hasPermission ~= self:permissionSnapshot(actor) then
        if s ~= nil and s.reissue then
            -- Keep the administration context; the republish reissues the id.
            self:republishActor(actor)
        else
            self:withdrawSession(actor)
            self:republishActor(actor)
        end
        result.reasonCode = "SESSION_WITHDRAWN"
        return result
    end
    if s.commandSessionId ~= req.commandSessionId then
        result.reasonCode = "SESSION_WITHDRAWN"
        self:republishActor(actor)
        return result
    end
    local seq = parseSequence(req.sequence)
    if seq == nil then return result end
    result.nextSequence = tostring(s.nextSequence)
    if s.lastSequence ~= nil and seq == s.lastSequence and s.lastResult ~= nil then
        return s.lastResult   -- a retry of the consumed pair returns the retained result
    end
    if seq ~= s.nextSequence then
        result.reasonCode = "COMMAND_OUTSTANDING"
        return result
    end

    -- Consume the sequence: whatever happens below, this pair is spent.
    s.lastSequence = seq
    if s.nextSequence >= WorkplaceSiteService.SEQUENCE_LIMIT then
        self:withdrawSession(actor)
    else
        s.nextSequence = s.nextSequence + 1
    end
    result.nextSequence = tostring(s.nextSequence)

    local adminTarget = s.administrationTargetFarmId
    local action = req.actionId

    if action == "CREATE_SITE" then
        -- The owner rides the wire explicitly: a named farm must equal the
        -- session's administration context; without the field the site is
        -- the actor's own, never the retained context.
        local requested = req.administrationTargetFarmId
        if requested ~= nil and requested ~= adminTarget then
            result.reasonCode = "UNAUTHORIZED"
        else
            local owner = requested or actor.farmId
            if not Store.isOrdinaryFarmId(owner) or not farmExistsLive(owner) then
                result.reasonCode = "INVALID_FARM"
            else
                local ok, why = self:mayEditFarm(actor, owner, requested)
                if not ok then
                    result.reasonCode = why
                else
                    local r, reason = self.store:create(owner, { name = req.name, purpose = req.purpose, centreX = req.centreX, centreZ = req.centreZ, radiusMetres = req.radiusMetres })
                    if r == nil then
                        result.reasonCode = reason
                    else
                        result.outcome = "APPLIED"
                        result.reasonCode = "OK"
                        result.resultingRevision = r.revision
                        result.currentTarget = targetOf(self.store, r)
                        self:notify(r.siteId, r.revision, "UPSERT", r.ownerFarmId)
                    end
                end
            end
        end
    elseif action == "UPDATE_SITE" or action == "DELETE_SITE" then
        if req.administrationTargetFarmId ~= nil then
            result.reasonCode = "INVALID_FIELDS"
        else
            local r = self.store:get(req.targetId or "")
            if r == nil then
                result.reasonCode = "NOT_FOUND"
            else
                -- Record state first: farm ids are reused (farms/FarmManager.lua:368),
                -- so a manager on a reused id never reshapes or deletes a dead
                -- farm's UNAVAILABLE sites. UNAVAILABLE is cleared only by
                -- TRANSFER_SITE, or DELETE_SITE by a master user inside an
                -- administration context (brief 4.2 / 4.7).
                local effState = self.store:effectiveState(r)
                local unavailable = effState ~= Store.STATE_ACTIVE
                local ok, why
                if unavailable then
                    -- A reused farm id never counts as the owner (FarmManager.lua:368):
                    -- the record is recoverable only by a master user inside an
                    -- explicit administration context, and only by deletion.
                    if action == "DELETE_SITE" and actor.isMasterUser and adminTarget ~= nil then
                        ok, why = true, "OK"
                    else
                        ok, why = false, "SITE_UNAVAILABLE"
                    end
                else
                    ok, why = self:mayEditFarm(actor, r.ownerFarmId, adminTarget)
                end
                if not ok then
                    result.reasonCode = why
                    result.currentTarget = (why == "SITE_UNAVAILABLE" and actor.isMasterUser and adminTarget ~= nil) and targetOf(self.store, r) or nil
                elseif req.expectedRevision ~= r.revision then
                    result.reasonCode = "STALE_REVISION"
                    result.currentTarget = targetOf(self.store, r)
                elseif action == "UPDATE_SITE" then
                    if self.store:isMapMismatch() then
                        result.reasonCode = "MAP_MISMATCH"
                        result.currentTarget = targetOf(self.store, r)
                    else
                        local updated, reason = self.store:update(r.siteId, { name = req.name, purpose = req.purpose, centreX = req.centreX, centreZ = req.centreZ, radiusMetres = req.radiusMetres })
                        if updated == nil then
                            result.reasonCode = reason
                            result.currentTarget = targetOf(self.store, r)
                        else
                            result.outcome = "APPLIED"
                            result.reasonCode = "OK"
                            result.resultingRevision = updated.revision
                            result.currentTarget = targetOf(self.store, updated)
                            self:notify(updated.siteId, updated.revision, "UPSERT", updated.ownerFarmId)
                        end
                    end
                else
                    local deleted = self.store:delete(r.siteId)
                    result.outcome = "APPLIED"
                    result.reasonCode = "OK"
                    result.resultingRevision = deleted.revision
                    result.currentTarget = nil
                    self:notify(deleted.siteId, deleted.revision, "DELETE", deleted.ownerFarmId)
                end
            end
        end
    elseif action == "TRANSFER_SITE" then
        local target = self:administrationTarget(actor, req.administrationTargetFarmId)
        if not actor.isMasterUser or target == nil or target ~= adminTarget then
            result.reasonCode = (not actor.isMasterUser) and "UNAUTHORIZED" or "INVALID_FARM"
        else
            local r = self.store:get(req.targetId or "")
            if r == nil then
                result.reasonCode = "NOT_FOUND"
            elseif req.expectedRevision ~= r.revision then
                result.reasonCode = "STALE_REVISION"
                result.currentTarget = targetOf(self.store, r)
            else
                local oldOwner = r.ownerFarmId
                local moved, reason = self.store:transfer(r.siteId, target)
                if moved == nil then
                    result.reasonCode = reason
                    result.currentTarget = targetOf(self.store, r)
                else
                    result.outcome = "APPLIED"
                    result.reasonCode = "OK"
                    result.resultingRevision = moved.revision
                    result.currentTarget = targetOf(self.store, moved)
                    self:notify(moved.siteId, moved.revision, "UPSERT", moved.ownerFarmId)
                    -- Ownership moved: sessions bound to the old and the new
                    -- owner farm are withdrawn (brief 4.7 withdrawal triggers);
                    -- the republish below reissues them against the new state.
                    self:withdrawSessionsOnFarms({ oldOwner, moved.ownerFarmId })
                end
            end
        end
    end

    if self.sessions[sessionKey(actor)] == s then s.lastResult = result end
    if result.outcome == "APPLIED" then
        self:publishAll()
    end
    return result
end

--- Entry from the wire: resolve the actor from the connection.
function WorkplaceSiteService:handleCommandFromConnection(connection, req)
    if connection == nil then return nil end
    return self:handleCommand(self:resolveActor(connection), req)
end

--- Entry for the local host / singleplayer (no connection).
function WorkplaceSiteService:handleLocalCommand(req)
    return self:handleCommand(self:resolveActor(nil), req)
end

-- =========================================================
-- Mission-handle adapters: dot-bound closures on the published manager.
-- Callers supply no implicit self; a colon call shifts the arguments and
-- is refused by the validation of the first bound parameter.
-- =========================================================
function WorkplaceSiteService.installAdapters(handle, system)
    if handle == nil then return end
    local function svc() return system ~= nil and system.siteService or nil end
    local function client() return system ~= nil and system.siteClient or nil end
    local function onClient() return g_currentMission ~= nil and not g_currentMission:getIsServer() end

    handle.registerSitePurpose = function(token, spec)
        if WorkplaceSiteRegistry == nil then return false, "NOT_READY" end
        return WorkplaceSiteRegistry.registerPurpose(token, spec)
    end
    handle.getSiteCapabilities = function()
        if onClient() then
            local c = client()
            if c == nil then return { schema = "SITE_V1", valuesFormat = WTSiteEvents.VIEW_FORMAT, ready = false, reasonCode = "NOT_READY" } end
            return c:capabilities()
        end
        local s = svc()
        if s == nil then return { schema = "SITE_V1", valuesFormat = WTSiteEvents.VIEW_FORMAT, ready = false, reasonCode = "NOT_READY" } end
        return s:capabilities()
    end
    handle.getSitesForFarm = function(trustedActorContext)
        if onClient() or trustedActorContext == nil then
            local c = client()
            if c == nil then return nil, "NOT_READY" end
            return c:getSites()
        end
        local s = svc()
        if s == nil then return nil, "NOT_READY" end
        return s:getSitesForFarm(trustedActorContext)
    end
    handle.getSite = function(siteId, trustedActorContext)
        if onClient() or trustedActorContext == nil then
            local c = client()
            if c == nil then return nil, "NOT_READY" end
            return c:getSite(siteId)
        end
        local s = svc()
        if s == nil then return nil, "NOT_READY" end
        return s:getSite(siteId, trustedActorContext)
    end
    handle.subscribeSiteChanges = function(consumerId, callback)
        if onClient() then
            local c = client()
            return c ~= nil and c:subscribe(consumerId, callback) or false
        end
        local s = svc()
        return s ~= nil and s:subscribe(consumerId, callback) or false
    end
    handle.unsubscribeSiteChanges = function(consumerId)
        local c, s = client(), svc()
        local a = c ~= nil and c:unsubscribe(consumerId) or false
        local b = s ~= nil and s:unsubscribe(consumerId) or false
        return a or b
    end
    handle.openSiteManager = function(selection)
        local c = client()
        if c == nil then return false end
        return c:openSiteManager(selection)
    end
end

print("[WorkplaceTriggers] WorkplaceSiteService loaded")
