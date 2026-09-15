-- =========================================================
-- WorkplaceSiteStore.lua  (WT-8)
-- The server-side site collection and its own save container.
-- =========================================================
-- A site is a farm-owned circle with a name and a purpose. It is not a job:
-- no wage, no shift, no clock-in, no capacity, no access right, no material.
--
-- SITE_V1 record: siteId (string, opaque, never reused), ownerFarmId
-- (integer), purpose (token or ""), name (1 to 128 UTF-8 bytes), centreX and
-- centreZ (metres, finite, inside the terrain), radiusMetres (finite, 1 to the
-- terrain diagonal), revision (string, opaque, advances on every accepted
-- change), state (ACTIVE or UNAVAILABLE) and, when unavailable, reason.
--
-- The container carries siteSchemaVersion, mapId, terrainSize, nextSiteCounter
-- (a decimal string, so no integer width applies; issuing stops at
-- 2147483647 rather than wrapping) and the records. It is never opened by the
-- 1.1.2.0 wage writers: an own StateLedger module (WorkplaceTriggers_Sites)
-- and an own XML file (FS25_WorkplaceTriggers_Sites.xml).
--
-- Load: stage the selected container without deciding anything about farms;
-- finalize owners only once the native farms are usable (the service binds
-- that to the mission's onFinishedLoading boundary). Container MAP_MISMATCH
-- wins over everything: every site reads UNAVAILABLE with that reason,
-- TRANSFER is refused, DELETE allowed, stamps never rewritten.
-- =========================================================

WorkplaceSiteStore = WorkplaceSiteStore or {}
WorkplaceSiteStore_mt = Class(WorkplaceSiteStore)

WorkplaceSiteStore.SCHEMA_VERSION   = 1
WorkplaceSiteStore.STATE_ACTIVE      = "ACTIVE"
WorkplaceSiteStore.STATE_UNAVAILABLE = "UNAVAILABLE"
WorkplaceSiteStore.CONTAINER_OK           = "OK"
WorkplaceSiteStore.CONTAINER_MAP_MISMATCH = "MAP_MISMATCH"
WorkplaceSiteStore.REASON_OWNER_MISSING   = "OWNER_MISSING"
WorkplaceSiteStore.REASON_FARM_DELETED    = "FARM_DELETED"
WorkplaceSiteStore.REASON_MAP_MISMATCH    = "MAP_MISMATCH"
WorkplaceSiteStore.MAX_NAME_BYTES    = 128
WorkplaceSiteStore.MAX_PURPOSE_BYTES = 64
WorkplaceSiteStore.MIN_RADIUS        = 1
WorkplaceSiteStore.DEFAULT_RADIUS    = 100
WorkplaceSiteStore.COUNTER_LIMIT     = "2147483647"
WorkplaceSiteStore.FALLBACK_TERRAIN  = 2048 * 2   -- when g_terrainSize is nil, diagonal falls back to 2048 * sqrt(2)

local SPECTATOR = 0

local function wtLog(msg)
    print("[WorkplaceTriggers] Sites: " .. tostring(msg))
end

-- =========================================================
-- Decimal string counters
-- =========================================================
local function isCanonicalDecimal(s)
    return type(s) == "string" and s ~= "" and #s <= 32 and s:find("^[1-9][0-9]*$") ~= nil
end
WorkplaceSiteStore.isCanonicalDecimal = isCanonicalDecimal

local function incrementDecimal(s)
    if not isCanonicalDecimal(s) then return "1" end
    local bytes = { s:byte(1, #s) }
    local i = #bytes
    while i >= 1 do
        if bytes[i] < 57 then
            bytes[i] = bytes[i] + 1
            return string.char(unpack(bytes))
        end
        bytes[i] = 48
        i = i - 1
    end
    return "1" .. string.char(unpack(bytes))
end
WorkplaceSiteStore.incrementDecimal = incrementDecimal

local function compareDecimal(a, b)
    if #a ~= #b then return (#a < #b) and -1 or 1 end
    if a == b then return 0 end
    return (a < b) and -1 or 1
end
WorkplaceSiteStore.compareDecimal = compareDecimal

local function isFinite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
WorkplaceSiteStore.isFinite = isFinite

-- =========================================================
-- Construction
-- =========================================================
function WorkplaceSiteStore.new()
    local self = setmetatable({}, WorkplaceSiteStore_mt)
    self:reset()
    return self
end

function WorkplaceSiteStore:reset()
    self.records = {}
    self.byId = {}
    self.nextSiteCounter = "1"
    self.mapId = nil
    self.terrainSize = nil
    self.containerState = WorkplaceSiteStore.CONTAINER_OK
    self.staged = false
    self.finalized = false
    self.containerRevision = "1"
end

function WorkplaceSiteStore:isReady()
    return self.finalized == true
end

function WorkplaceSiteStore:isMapMismatch()
    return self.containerState == WorkplaceSiteStore.CONTAINER_MAP_MISMATCH
end

--- Terrain diagonal used as the radius bound.
function WorkplaceSiteStore.terrainDiagonal(terrainSize)
    local size = terrainSize
    if not isFinite(size) or size <= 0 then size = 2048 end
    return size * math.sqrt(2)
end

-- =========================================================
-- Validation
-- =========================================================
--- Validate the editable fields of a definition. Returns ok, reasonCode.
function WorkplaceSiteStore.validateFields(fields, terrainSize)
    if type(fields) ~= "table" then return false, "INVALID_FIELDS" end
    local name = fields.name
    if type(name) ~= "string" or name == "" or #name > WorkplaceSiteStore.MAX_NAME_BYTES then
        return false, "INVALID_FIELDS"
    end
    if name:find("[<>&%c]") ~= nil then return false, "INVALID_FIELDS" end
    local purpose = fields.purpose
    if purpose == nil then purpose = "" end
    if type(purpose) ~= "string" or #purpose > WorkplaceSiteStore.MAX_PURPOSE_BYTES or purpose:find("[<>&\"'%c]") ~= nil then
        return false, "INVALID_FIELDS"
    end
    if not isFinite(fields.centreX) or not isFinite(fields.centreZ) or not isFinite(fields.radiusMetres) then
        return false, "INVALID_FIELDS"
    end
    local size = terrainSize
    if not isFinite(size) or size <= 0 then size = 2048 end
    local half = size * 0.5
    if fields.centreX < -half or fields.centreX > half or fields.centreZ < -half or fields.centreZ > half then
        return false, "OUT_OF_BOUNDS"
    end
    local diag = WorkplaceSiteStore.terrainDiagonal(size)
    if fields.radiusMetres < WorkplaceSiteStore.MIN_RADIUS or fields.radiusMetres > diag then
        return false, "OUT_OF_BOUNDS"
    end
    return true, "OK"
end

local function isOrdinaryFarmId(farmId)
    if type(farmId) ~= "number" or farmId ~= math.floor(farmId) then return false end
    if farmId == SPECTATOR then return false end
    local maxId = (FarmManager ~= nil and FarmManager.MAX_FARM_ID) or 8
    return farmId >= 1 and farmId <= maxId
end
WorkplaceSiteStore.isOrdinaryFarmId = isOrdinaryFarmId

-- =========================================================
-- Records
-- =========================================================
local function detached(r)
    return {
        siteId = r.siteId, ownerFarmId = r.ownerFarmId, purpose = r.purpose, name = r.name,
        centreX = r.centreX, centreZ = r.centreZ, radiusMetres = r.radiusMetres,
        revision = r.revision, state = r.state, reason = r.reason,
    }
end
WorkplaceSiteStore.detached = detached

function WorkplaceSiteStore:bumpContainer()
    self.containerRevision = incrementDecimal(self.containerRevision)
end

function WorkplaceSiteStore:issueSiteId()
    if compareDecimal(self.nextSiteCounter, WorkplaceSiteStore.COUNTER_LIMIT) > 0 then
        return nil
    end
    local id = "site_" .. self.nextSiteCounter
    self.nextSiteCounter = incrementDecimal(self.nextSiteCounter)
    return id
end

--- Create. Returns record or nil, reasonCode. Owner must be an ordinary farm.
function WorkplaceSiteStore:create(ownerFarmId, fields)
    if not isOrdinaryFarmId(ownerFarmId) then return nil, "INVALID_FARM" end
    local ok, why = WorkplaceSiteStore.validateFields(fields, self.terrainSize)
    if not ok then return nil, why end
    local id = self:issueSiteId()
    if id == nil then return nil, "INVALID_FIELDS" end
    local r = {
        siteId = id, ownerFarmId = ownerFarmId, purpose = fields.purpose or "", name = fields.name,
        centreX = fields.centreX, centreZ = fields.centreZ, radiusMetres = fields.radiusMetres,
        revision = "1", state = WorkplaceSiteStore.STATE_ACTIVE, reason = nil,
    }
    self.records[#self.records + 1] = r
    self.byId[id] = r
    self:bumpContainer()
    return r, "OK"
end

--- Update the editable fields. Returns record or nil, reasonCode.
function WorkplaceSiteStore:update(siteId, fields)
    local r = self.byId[siteId]
    if r == nil then return nil, "NOT_FOUND" end
    local ok, why = WorkplaceSiteStore.validateFields(fields, self.terrainSize)
    if not ok then return nil, why end
    r.name = fields.name
    r.purpose = fields.purpose or ""
    r.centreX = fields.centreX
    r.centreZ = fields.centreZ
    r.radiusMetres = fields.radiusMetres
    r.revision = incrementDecimal(r.revision)
    self:bumpContainer()
    return r, "OK"
end

function WorkplaceSiteStore:delete(siteId)
    local r = self.byId[siteId]
    if r == nil then return nil, "NOT_FOUND" end
    for i = #self.records, 1, -1 do
        if self.records[i] == r then table.remove(self.records, i) end
    end
    self.byId[siteId] = nil
    self:bumpContainer()
    return r, "OK"
end

--- Transfer ownership; the record becomes ACTIVE. Refused on a mismatched map.
function WorkplaceSiteStore:transfer(siteId, newFarmId)
    local r = self.byId[siteId]
    if r == nil then return nil, "NOT_FOUND" end
    if self:isMapMismatch() then return nil, "MAP_MISMATCH" end
    if not isOrdinaryFarmId(newFarmId) then return nil, "INVALID_FARM" end
    r.ownerFarmId = newFarmId
    r.state = WorkplaceSiteStore.STATE_ACTIVE
    r.reason = nil
    r.revision = incrementDecimal(r.revision)
    self:bumpContainer()
    return r, "OK"
end

--- FARM_DELETED: every site of that farm becomes UNAVAILABLE at once.
function WorkplaceSiteStore:markFarmUnavailable(farmId)
    local changed = {}
    for _, r in ipairs(self.records) do
        if r.ownerFarmId == farmId and r.state == WorkplaceSiteStore.STATE_ACTIVE then
            r.state = WorkplaceSiteStore.STATE_UNAVAILABLE
            r.reason = WorkplaceSiteStore.REASON_FARM_DELETED
            r.revision = incrementDecimal(r.revision)
            changed[#changed + 1] = r
        end
    end
    if #changed > 0 then self:bumpContainer() end
    return changed
end

function WorkplaceSiteStore:get(siteId)
    return self.byId[siteId]
end

--- Effective state of a record: the container's mismatch outranks the record.
function WorkplaceSiteStore:effectiveState(r)
    if self:isMapMismatch() then
        return WorkplaceSiteStore.STATE_UNAVAILABLE, WorkplaceSiteStore.REASON_MAP_MISMATCH
    end
    return r.state, r.reason
end

--- Detached definitions for a farm. Ordinary: ACTIVE only. Administration:
--- every record with its effective state and reason.
function WorkplaceSiteStore:listForFarm(farmId, includeUnavailable)
    local out = {}
    for _, r in ipairs(self.records) do
        if r.ownerFarmId == farmId then
            local state, reason = self:effectiveState(r)
            if state == WorkplaceSiteStore.STATE_ACTIVE or includeUnavailable then
                local d = detached(r)
                d.state = state
                d.reason = reason
                out[#out + 1] = d
            end
        end
    end
    return out
end

--- Administration listing for a target farm: that farm's records with
--- their effective state, plus every UNAVAILABLE record whose owner farm no
--- longer exists, so an orphan can be moved to the administered farm or
--- deleted. Geometry of an unavailable record is not trusted by readers.
function WorkplaceSiteStore:listForAdministration(farmId, farmExists)
    local out = {}
    for _, r in ipairs(self.records) do
        local state, reason = self:effectiveState(r)
        local orphan = r.state == WorkplaceSiteStore.STATE_UNAVAILABLE and not farmExists(r.ownerFarmId)
        if r.ownerFarmId == farmId or orphan then
            local d = detached(r)
            d.state = state
            d.reason = reason
            out[#out + 1] = d
        end
    end
    return out
end

-- =========================================================
-- Container: stage, finalize, serialize
-- =========================================================
--- Build the persistable container (plain data, both backends).
function WorkplaceSiteStore:serialize(liveMapId, liveTerrainSize)
    local mapId = self.mapId
    local terrainSize = self.terrainSize
    -- Stamps are written with what the container already carries; a fresh
    -- container takes the live stamps. A mismatched container never rewrites.
    if mapId == nil and not self:isMapMismatch() then mapId = liveMapId end
    if terrainSize == nil and not self:isMapMismatch() then terrainSize = liveTerrainSize end
    local out = {
        siteSchemaVersion = WorkplaceSiteStore.SCHEMA_VERSION,
        mapId = mapId or "",
        terrainSize = terrainSize or 0,
        nextSiteCounter = self.nextSiteCounter,
        sites = {},
    }
    for _, r in ipairs(self.records) do
        out.sites[#out.sites + 1] = {
            siteId = r.siteId, ownerFarmId = r.ownerFarmId, purpose = r.purpose or "", name = r.name,
            centreX = r.centreX, centreZ = r.centreZ, radiusMetres = r.radiusMetres,
            revision = r.revision, state = r.state, reason = r.reason or "",
        }
    end
    return out
end

--- Is a delivered container one this store knows? nil, empty and foreign
--- tables are all "not delivered".
function WorkplaceSiteStore.isKnownContainer(c)
    return type(c) == "table" and c.siteSchemaVersion == WorkplaceSiteStore.SCHEMA_VERSION
end

local function parseSiteNumber(siteId)
    if type(siteId) ~= "string" then return nil end
    local digits = siteId:match("^site_([1-9][0-9]*)$")
    return digits
end

--- Stage a known container. No owner decisions, no revision changes, no
--- publication. Returns true, or false when the container is not usable.
function WorkplaceSiteStore:stageContainer(c, liveMapId, liveTerrainSize)
    if not WorkplaceSiteStore.isKnownContainer(c) then return false end
    self:reset()
    self.staged = true
    self.mapId = (type(c.mapId) == "string" and c.mapId ~= "") and c.mapId or nil
    self.terrainSize = isFinite(c.terrainSize) and c.terrainSize > 0 and c.terrainSize or nil

    local highest = "0"
    for _, s in ipairs(c.sites or {}) do
        if type(s) == "table" and type(s.siteId) == "string" and s.siteId ~= "" and self.byId[s.siteId] == nil
            and isFinite(s.centreX) and isFinite(s.centreZ) and isFinite(s.radiusMetres) then
            local r = {
                siteId = s.siteId,
                ownerFarmId = tonumber(s.ownerFarmId) or -1,
                purpose = type(s.purpose) == "string" and s.purpose or "",
                name = (type(s.name) == "string" and s.name ~= "") and s.name or "Site",
                centreX = s.centreX, centreZ = s.centreZ, radiusMetres = s.radiusMetres,
                revision = isCanonicalDecimal(s.revision) and s.revision or "1",
                state = (s.state == WorkplaceSiteStore.STATE_UNAVAILABLE) and WorkplaceSiteStore.STATE_UNAVAILABLE or WorkplaceSiteStore.STATE_ACTIVE,
                reason = (type(s.reason) == "string" and s.reason ~= "") and s.reason or nil,
            }
            if r.state == WorkplaceSiteStore.STATE_ACTIVE then r.reason = nil end
            self.records[#self.records + 1] = r
            self.byId[r.siteId] = r
            local n = parseSiteNumber(r.siteId)
            if n ~= nil and compareDecimal(n, highest) > 0 then highest = n end
        end
    end
    -- Counter: the greater of the persisted counter and the highest parsed number plus one.
    local persisted = isCanonicalDecimal(c.nextSiteCounter) and c.nextSiteCounter or "1"
    local fromSites = incrementDecimal(highest)
    self.nextSiteCounter = (compareDecimal(persisted, fromSites) >= 0) and persisted or fromSites

    -- Map identity: a mismatch of either stamp marks the whole container.
    local mismatch = false
    if self.mapId ~= nil and liveMapId ~= nil and self.mapId ~= liveMapId then mismatch = true end
    if self.terrainSize ~= nil and isFinite(liveTerrainSize) and liveTerrainSize > 0 and self.terrainSize ~= liveTerrainSize then mismatch = true end
    self.containerState = mismatch and WorkplaceSiteStore.CONTAINER_MAP_MISMATCH or WorkplaceSiteStore.CONTAINER_OK
    if mismatch then
        wtLog(string.format("container MAP_MISMATCH (stored map '%s' size %s, live map '%s' size %s); sites read unavailable",
            tostring(self.mapId), tostring(self.terrainSize), tostring(liveMapId), tostring(liveTerrainSize)))
    else
        -- A matching live stamp is adopted so a first save on this map carries it.
        if self.mapId == nil then self.mapId = liveMapId end
        if self.terrainSize == nil and isFinite(liveTerrainSize) and liveTerrainSize > 0 then self.terrainSize = liveTerrainSize end
    end
    return true
end

--- First use: an empty container stamped with the live mission.
function WorkplaceSiteStore:stageEmpty(liveMapId, liveTerrainSize)
    self:reset()
    self.staged = true
    self.mapId = liveMapId
    if isFinite(liveTerrainSize) and liveTerrainSize > 0 then self.terrainSize = liveTerrainSize end
    return true
end

--- Owner checks, once the native farms are usable. Persisted UNAVAILABLE stays
--- first; an ACTIVE record with a proved singleplayer merge rewrites to the
--- surviving farm and advances; otherwise a valid owner is retained or a
--- proved missing owner becomes UNAVAILABLE. Container mismatch changes no
--- record. Idempotent.
---@param farmExists function(farmId) -> boolean
---@param mergedFarms table|nil        oldFarmId -> survivingFarmId
function WorkplaceSiteStore:finalizeOwners(farmExists, mergedFarms)
    if self.finalized then return false end
    if not self:isMapMismatch() then
        for _, r in ipairs(self.records) do
            if r.state == WorkplaceSiteStore.STATE_ACTIVE then
                local merged = mergedFarms ~= nil and mergedFarms[r.ownerFarmId] or nil
                if merged ~= nil and isOrdinaryFarmId(merged) and farmExists(merged) then
                    r.ownerFarmId = merged
                    r.revision = incrementDecimal(r.revision)
                elseif isOrdinaryFarmId(r.ownerFarmId) and farmExists(r.ownerFarmId) then
                    -- retained
                else
                    r.state = WorkplaceSiteStore.STATE_UNAVAILABLE
                    r.reason = WorkplaceSiteStore.REASON_OWNER_MISSING
                    r.revision = incrementDecimal(r.revision)
                end
            end
        end
    end
    self.finalized = true
    self:bumpContainer()
    return true
end

-- =========================================================
-- XML backend (own file, never the wage file)
-- =========================================================
WorkplaceSiteStore.XML_ROOT = "workplaceSites"

function WorkplaceSiteStore.writeXML(xmlFile, container)
    local root = WorkplaceSiteStore.XML_ROOT
    xmlFile:setInt(root .. "#siteSchemaVersion", container.siteSchemaVersion)
    xmlFile:setString(root .. "#mapId", container.mapId or "")
    xmlFile:setFloat(root .. "#terrainSize", container.terrainSize or 0)
    xmlFile:setString(root .. "#nextSiteCounter", container.nextSiteCounter or "1")
    xmlFile:setInt(root .. ".sites#count", #container.sites)
    for i, s in ipairs(container.sites) do
        local key = string.format("%s.sites.site(%d)", root, i - 1)
        xmlFile:setString(key .. "#siteId", s.siteId)
        xmlFile:setInt(key .. "#ownerFarmId", s.ownerFarmId)
        xmlFile:setString(key .. "#purpose", s.purpose or "")
        xmlFile:setString(key .. "#name", s.name)
        xmlFile:setFloat(key .. "#centreX", s.centreX)
        xmlFile:setFloat(key .. "#centreZ", s.centreZ)
        xmlFile:setFloat(key .. "#radiusMetres", s.radiusMetres)
        xmlFile:setString(key .. "#revision", s.revision)
        xmlFile:setString(key .. "#state", s.state)
        xmlFile:setString(key .. "#reason", s.reason or "")
    end
end

--- Read the own XML file into a container, or nil when absent or unknown.
function WorkplaceSiteStore.readXML(xmlFile)
    local root = WorkplaceSiteStore.XML_ROOT
    if not xmlFile:hasProperty(root .. "#siteSchemaVersion") then return nil end
    local c = {
        siteSchemaVersion = xmlFile:getInt(root .. "#siteSchemaVersion", 0),
        mapId = xmlFile:getString(root .. "#mapId", ""),
        terrainSize = xmlFile:getFloat(root .. "#terrainSize", 0),
        nextSiteCounter = xmlFile:getString(root .. "#nextSiteCounter", "1"),
        sites = {},
    }
    if c.siteSchemaVersion ~= WorkplaceSiteStore.SCHEMA_VERSION then return nil end
    local count = xmlFile:getInt(root .. ".sites#count", 0)
    for i = 1, count do
        local key = string.format("%s.sites.site(%d)", root, i - 1)
        if not xmlFile:hasProperty(key .. "#siteId") then break end
        c.sites[#c.sites + 1] = {
            siteId = xmlFile:getString(key .. "#siteId", ""),
            ownerFarmId = xmlFile:getInt(key .. "#ownerFarmId", -1),
            purpose = xmlFile:getString(key .. "#purpose", ""),
            name = xmlFile:getString(key .. "#name", "Site"),
            centreX = xmlFile:getFloat(key .. "#centreX", 0),
            centreZ = xmlFile:getFloat(key .. "#centreZ", 0),
            radiusMetres = xmlFile:getFloat(key .. "#radiusMetres", 0),
            revision = xmlFile:getString(key .. "#revision", "1"),
            state = xmlFile:getString(key .. "#state", "ACTIVE"),
            reason = xmlFile:getString(key .. "#reason", ""),
        }
    end
    return c
end

function WorkplaceSiteStore.getXMLPath(missionInfo)
    local mi = missionInfo or (g_currentMission and g_currentMission.missionInfo)
    local dir = mi and mi.savegameDirectory
    if dir == nil then return nil end
    return dir .. "/FS25_WorkplaceTriggers_Sites.xml"
end

print("[WorkplaceTriggers] WorkplaceSiteStore loaded")
