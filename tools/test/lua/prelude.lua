-- prelude.lua - minimal FS25 engine mock + tiny test framework for FS25_WorkplaceTriggers.
-- Loaded first by run-tests.mjs, before src modules and the test file. Only stubs what
-- module load + the functions under test touch; extend as new tests need more surface.

unpack = unpack or table.unpack

-- Class(classTable[, parent]): instances get __index = classTable; classTable inherits from parent.
function Class(classTable, parent)
  classTable = classTable or {}
  if parent ~= nil then
    setmetatable(classTable, { __index = parent })
  end
  classTable.__index = classTable
  return classTable
end

-- Event base + registration
Event = {}
function Event.new(mt) return setmetatable({}, mt) end
function InitEventClass(class, name) class.eventClassName = name end

-- getfenv(0) export route used by the registry and main.lua
if getfenv == nil then
  local G = _G
  function getfenv(level) return G end
end

Logging = { info = function() end, warning = function() end, error = function() end }
table.size = table.size or function(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end

-- Network stream mock: a plain table; write appends cells, read walks a cursor.
function NewStream() return { cells = {}, w = 0, r = 0 } end
local function _w(s, v) s.w = s.w + 1; s.cells[s.w] = v end
local function _r(s) s.r = s.r + 1; return s.cells[s.r] end
function streamWriteInt32(s, v)  _w(s, math.floor(v)) end
function streamReadInt32(s)       return _r(s) end
function streamWriteUInt8(s, v)   _w(s, math.floor(v)) end
function streamReadUInt8(s)        return _r(s) end
function streamWriteBool(s, v)    _w(s, v and true or false) end
function streamReadBool(s)         return _r(s) end
function streamWriteFloat32(s, v) _w(s, v) end
function streamReadFloat32(s)      return _r(s) end
function streamWriteString(s, v)  _w(s, tostring(v)) end
function streamReadString(s)       return _r(s) end

-- In-memory XMLFile mock: attribute table keyed by path.
XMLFile = XMLFile or {}
function NewXmlMock()
  local store = {}
  local m = { store = store }
  m.setInt = function(_, k, v) store[k] = v end
  m.setFloat = function(_, k, v) store[k] = v end
  m.setString = function(_, k, v) store[k] = v end
  m.setBool = function(_, k, v) store[k] = v end
  local function get(_, k, default) if store[k] ~= nil then return store[k] end return default end
  m.getInt, m.getFloat, m.getString, m.getBool = get, get, get, get
  m.hasProperty = function(_, k) return store[k] ~= nil end
  m.save = function() return true end
  m.delete = function() end
  return m
end

-- Mission / farm stubs (tests set fields as needed)
g_currentMission = { _isServer = true, isLoaded = true, numLoadingTasks = 0, missionInfo = { mapId = "map01" } }
function g_currentMission:getIsServer() return self._isServer end
g_terrainSize = 2048
g_server = nil
g_client = nil
g_messageCenter = { subscribe = function() end, unsubscribe = function() end, unsubscribeAll = function() end, publish = function() end }
MessageType = MessageType or { FARM_DELETED = 28, PLAYER_FARM_CHANGED = 25 }
NetworkNode = NetworkNode or { LOCAL_STREAM_ID = 0 }
FarmManager = FarmManager or { SPECTATOR_FARM_ID = 0, SINGLEPLAYER_FARM_ID = 1, MAX_FARM_ID = 8, GUIDED_TOUR_FARM_ID = 14, INVALID_FARM_ID = 15 }
Farm = Farm or { PERMISSION = { UPDATE_FARM = "updateFarm" } }

function print_silent() end

-- tiny test framework (emits ##TEST_ markers parsed by run-tests.mjs)
T = { _pass = 0, _fail = 0 }
local function _pass(name) T._pass = T._pass + 1; print("##TEST_PASS " .. name) end
local function _fail(name, msg) T._fail = T._fail + 1; print("##TEST_FAIL " .. name .. " :: " .. tostring(msg)) end
function T.ok(name, cond, msg)
  if cond then _pass(name) else _fail(name, msg or "expected truthy, got " .. tostring(cond)) end
end
function T.eq(name, got, want)
  if got == want then _pass(name) else _fail(name, "got " .. tostring(got) .. " want " .. tostring(want)) end
end
function T.near(name, got, want, tol)
  tol = tol or 1e-6
  if type(got) == "number" and math.abs(got - want) <= tol then _pass(name)
  else _fail(name, "got " .. tostring(got) .. " want ~" .. tostring(want)) end
end
function T.summary() print("##TEST_SUMMARY " .. T._pass .. " " .. T._fail) end
