-- =========================================================
-- FS25 Workplace Triggers - NetworkSync bridge
-- =========================================================
-- Optional bridge to FS25_NetworkSync. Routes all 9 original
-- WorkplaceMultiplayerEvent types through NetworkSync:
--
--   State-sync module (server->client): full trigger list +
--   settings (wageMultiplier) + active shifts. Server marks
--   dirty on any mutation; NetworkSync batches at 1Hz.
--   Client join receives the full snapshot automatically.
--
--   Action channel (client->server): shift_start, shift_end,
--   create_trigger, update_trigger, delete_trigger. Admin
--   gating for trigger CRUD; farm-scoped shift actions.
--
-- Delegate-when-present:
--   * NetworkSync installed -> this bridge handles all MP sync
--   * NetworkSync absent    -> MP sync is not available (event class removed)
-- =========================================================

WTNetworkSyncBridge = {}

WTNetworkSyncBridge.MODULE_ID = "WorkplaceTriggers"
WTNetworkSyncBridge.CHANNEL   = "WorkplaceTriggers_Sync"
WTNetworkSyncBridge.ACTION_ID = "WorkplaceTriggers_Request"

WTNetworkSyncBridge.active      = false
WTNetworkSyncBridge.stateActive = false
WTNetworkSyncBridge._ns         = nil

local function wtLog(msg)
    print("[WorkplaceTriggers] NetworkSyncBridge: " .. tostring(msg))
end

-- =========================================================
-- State serialization (server -> client full snapshot)
-- =========================================================
-- Flat array: [triggerCount, ...per trigger fields..., wageMultiplier]
-- Schema v2.  13 fields per trigger (added purpose, appended after playerInside).
local function buildStateArray()
    local arr = {}
    local sys = g_WorkplaceSystem
    local triggers = (sys and sys.triggerManager) and sys.triggerManager:getAllTriggers() or {}

    arr[#arr + 1] = #triggers
    for _, t in ipairs(triggers) do
        arr[#arr + 1] = tostring(t.id or "")
        arr[#arr + 1] = t.workplaceName or "Workplace"
        arr[#arr + 1] = t.hourlyWage or 500
        arr[#arr + 1] = t.triggerRadius or 4
        arr[#arr + 1] = t.posX or 0
        arr[#arr + 1] = t.posY or 0
        arr[#arr + 1] = t.posZ or 0
        arr[#arr + 1] = t.rotY or 0
        arr[#arr + 1] = t.paySchedule or "hourly"
        arr[#arr + 1] = t.timeMultiplier or 0
        arr[#arr + 1] = t.endShiftOnLeave ~= false
        arr[#arr + 1] = t.playerInside or false
        arr[#arr + 1] = t.purpose or ""
    end

    -- Settings (server-authoritative wage multiplier)
    local s = sys and sys.settings
    arr[#arr + 1] = s and s.wageMultiplier or 1.0

    return arr
end

-- =========================================================
-- State deserialization (client applies full snapshot)
-- =========================================================
local function applyStateArray(arr)
    if type(arr) ~= "table" then return end
    local sys = g_WorkplaceSystem
    if sys == nil or sys.triggerManager == nil then return end

    local i = 1
    local count = tonumber(arr[i]) or 0; i = i + 1

    -- BUILD 17:59: an empty snapshot is not a reason to tear the manager down. NetworkSync
    -- reapplies state on a 30s floor, and during a long join that turned into a loop of
    -- delete + initialize + "Applied 0 trigger(s)" every half minute while the i3ds were
    -- still streaming. delete() unsubscribes MessageCenter and destroys markers and
    -- hotspots; initialize() resubscribes. Doing both to arrive back where we started is
    -- pure load hitch.
    --
    -- Nothing to apply, and the manager is already up and empty: keep the settings line
    -- below and leave. Nothing to apply and not yet initialized: initialize only, no
    -- teardown of something that was never built. A snapshot with triggers in it still
    -- rebuilds exactly as before, because that is a real change and the player needs it.
    local mgr = sys.triggerManager
    local alreadyEmpty = mgr.isInitialized == true
        and (type(mgr.triggers) ~= "table" or next(mgr.triggers) == nil)

    if count == 0 and alreadyEmpty then
        if sys.settings then
            sys.settings.wageMultiplier = tonumber(arr[i]) or sys.settings.wageMultiplier or 1.0
        end
        return
    end

    if count == 0 then
        if not mgr.isInitialized then
            mgr:initialize()
        end
    else
        mgr:delete()
        mgr:initialize()
    end

    for _ = 1, count do
        local triggerData = {
            id              = tostring(arr[i] or ""),
            workplaceName   = arr[i + 1] or "Workplace",
            hourlyWage      = arr[i + 2] or 500,
            triggerRadius   = arr[i + 3] or 4,
            posX            = arr[i + 4] or 0,
            posY            = arr[i + 5] or 0,
            posZ            = arr[i + 6] or 0,
            rotY            = arr[i + 7] or 0,
            paySchedule     = arr[i + 8] or "hourly",
            timeMultiplier  = arr[i + 9] or 0,
            endShiftOnLeave = arr[i + 10] ~= false,
            playerInside    = arr[i + 11] or false,
            purpose         = arr[i + 12] or "",
        }
        sys.triggerManager:registerTrigger(triggerData)
        i = i + 13
    end

    -- Apply settings
    if sys.settings then
        sys.settings.wageMultiplier = tonumber(arr[i]) or 1.0
    end

    wtLog(string.format("Applied %d trigger(s) from NetworkSync", count))
end

-- =========================================================
-- NetworkSync callbacks (no self; called by NetworkSync)
-- =========================================================
function WTNetworkSyncBridge._onWriteState()
    return buildStateArray()
end

function WTNetworkSyncBridge._onReadState(arr)
    applyStateArray(arr)
end

-- =========================================================
-- Server-side action handler
-- =========================================================
local TRIGGER_ACTIONS = {
    create_trigger       = true,
    update_trigger       = true,
    delete_trigger       = true,
    set_trigger_purpose  = true,
}

-- BUILD 10:17 (George TASK 09:32, Brian TEST 09:03). Forward declarations, and they are
-- the whole bug: the handlers below are `local function`s defined AFTER onAction, so
-- onAction's calls compiled as GLOBAL lookups that resolve to nil at runtime - every
-- create/update/delete/shift action died with "attempt to call a nil value" inside the
-- caller's pcall, which is why the log showed a swallowed error and the Manager list
-- stayed at 0 triggers. With the names declared local BEFORE onAction, its calls close
-- over these locals and the `name = function` definitions below fill them in.
local onShiftStart, onShiftEnd, onCreateTrigger, onUpdateTrigger, onDeleteTrigger, onSetTriggerPurpose

local function onAction(userId, args)
    if type(args) ~= "table" then return end
    local actionType = args[1]
    if actionType == nil then return end

    local sys = g_WorkplaceSystem
    if sys == nil then return end

    -- Trigger CRUD: admin only
    if TRIGGER_ACTIONS[actionType] then
        -- userId == nil means the local host (listen-server / single-player host).
        -- The host holds admin rights without belonging to a specific farm, so it
        -- passes the admin gate directly (SettingsHub AdminControlRegistry pattern).
        -- A nil id must not silently skip the guard or silently fail; it gets an
        -- explicit host-admin verdict instead.
        if userId ~= nil then
            local user = g_currentMission.userManager
                and g_currentMission.userManager:getUserByUserId(userId)
            if user == nil or not (user.isMasterUser == true or user.isAdmin == true) then
                wtLog("action '" .. tostring(actionType) .. "' denied: not admin")
                return
            end
        end
    end

    -- BUILD 10:17: handler results propagate so a synchronous caller (the listen-host
    -- SAVE path) can give Sam's success/fail feel. nil counts as success - only an
    -- explicit false is a refusal (legacy handlers return nothing).
    local result
    if actionType == "shift_start" then
        result = onShiftStart(sys, userId, args)
    elseif actionType == "shift_end" then
        result = onShiftEnd(sys, userId, args)
    elseif actionType == "create_trigger" then
        result = onCreateTrigger(sys, userId, args)
    elseif actionType == "update_trigger" then
        result = onUpdateTrigger(sys, userId, args)
    elseif actionType == "delete_trigger" then
        result = onDeleteTrigger(sys, userId, args)
    elseif actionType == "set_trigger_purpose" then
        result = onSetTriggerPurpose(sys, userId, args)
    else
        return
    end

    -- Mark state dirty so the next 1Hz batch includes the change
    if WTNetworkSyncBridge.stateActive and WTNetworkSyncBridge._ns ~= nil then
        WTNetworkSyncBridge._ns:markDirty(WTNetworkSyncBridge.MODULE_ID)
    end
    return result
end

-- =========================================================
-- Shift action handlers
-- =========================================================
onShiftStart = function(sys, userId, args)
    local farmId   = args[2] or 1
    local triggerId = tostring(args[3] or "")

    local trigger = sys.triggerManager:getTriggerById(triggerId)
    if trigger == nil then
        wtLog("SHIFT_START rejected: trigger not found: " .. triggerId)
        return
    end

    if sys.shiftTracker:isShiftActiveForFarm(farmId) then
        wtLog("SHIFT_START rejected: farm " .. tostring(farmId) .. " already active")
        return
    end

    sys.shiftTracker:startShiftForFarm(farmId, trigger)

    -- Listen-server: also update single-slot state for the host's own shift
    if g_currentMission and g_currentMission:getIsServer() then
        -- `g_currentMission:getFarmId and ...` was a COMPILE error: the `:` call syntax
        -- requires an immediate argument list, so Lua stopped at `and` ("expected '(',
        -- '{' or <string>"). The whole file failed to load, taking this bridge with it.
        --
        -- Resolved with the order proven across the suite (SoilFertilizer, NPCFavor,
        -- WorkerCosts) rather than a one-character syntax patch: `getFarmId` is not in
        -- the Community LUADOC, so a guarded probe on it alone would have compiled and
        -- then silently always yielded -1, meaning the host's own shift state never
        -- updated. It stays as a last-resort probe, correctly guarded with `.`.
        local localFarmId = -1
        if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then
            localFarmId = g_localPlayer.farmId
        elseif g_currentMission.player ~= nil and g_currentMission.player.farmId ~= nil then
            localFarmId = g_currentMission.player.farmId
        elseif type(g_currentMission.getFarmId) == "function" then
            localFarmId = g_currentMission:getFarmId() or -1
        end
        if farmId == localFarmId then
            pcall(function() sys.shiftTracker:startShift(trigger, true) end)
            sys.shiftTracker.activeFarmId      = farmId
            sys.shiftTracker.shiftOwnerIsLocal = true
        else
            sys.shiftTracker.shiftOwnerIsLocal = false
        end
    end

    wtLog(string.format("SHIFT_START: farm=%d trigger='%s'", farmId, trigger.workplaceName or "?"))
end

onShiftEnd = function(sys, userId, args)
    local farmId    = args[2] or 1
    local isPenalty = args[3] == true

    if not sys.shiftTracker:isShiftActiveForFarm(farmId) then
        wtLog("SHIFT_END: farm " .. tostring(farmId) .. " not active")
        return
    end

    local earned, name
    if isPenalty then
        earned, name = sys.shiftTracker:endShiftPenaltyForFarm(farmId)
    else
        earned, name = sys.shiftTracker:endShiftForFarm(farmId)
    end

    -- Clear single-slot state if this farm owned it
    if sys.shiftTracker.activeFarmId == farmId
       and sys.shiftTracker:isShiftActive() then
        pcall(function()
            if isPenalty then sys.shiftTracker:endShiftPenalty()
            else              sys.shiftTracker:endShift() end
        end)
    end

    wtLog(string.format("SHIFT_END: farm=%d earned=$%d '%s'", farmId, earned or 0, name or "?"))
end

-- =========================================================
-- Trigger CRUD action handlers
-- =========================================================
local _serverIdCounter = 0

local function generateStableId()
    _serverIdCounter = _serverIdCounter + 1
    local t = g_currentMission and math.floor(g_currentMission.time) or 0
    return string.format("wt_%d_%d", t, _serverIdCounter)
end

onCreateTrigger = function(sys, userId, args)
    local stableId = (args[2] and args[2] ~= "") and tostring(args[2]) or generateStableId()

    local triggerData = {
        id              = stableId,
        workplaceName   = args[3] or "Workplace",
        hourlyWage      = args[4] or 500,
        triggerRadius   = args[5] or 4,
        posX            = args[6] or 0,
        posY            = args[7] or 0,
        posZ            = args[8] or 0,
        paySchedule     = args[9] or "hourly",
        timeMultiplier  = args[10] or 0,
        endShiftOnLeave = args[11] ~= false,
        purpose         = args[12] or "",
        playerInside    = false,
    }

    local ok, err = pcall(function()
        sys.triggerManager:registerTrigger(triggerData)
    end)
    if not ok then
        wtLog("CREATE_TRIGGER error: " .. tostring(err))
        -- BUILD 10:17: an explicit false travels back through onAction/requestAction so
        -- the SAVE dialog can keep the form open and warn instead of closing onto an
        -- empty list (Sam DESIGN 09:56 hard-fail feel).
        return false
    end

    wtLog("CREATE_TRIGGER: id=" .. stableId .. " name='" .. (triggerData.workplaceName or "?") .. "'")
    return true
end

onUpdateTrigger = function(sys, userId, args)
    local triggerId = tostring(args[2] or "")
    local trigger = sys.triggerManager:getTriggerById(triggerId)
    if trigger == nil then
        wtLog("UPDATE_TRIGGER rejected: not found: " .. triggerId)
        return
    end

    trigger.workplaceName   = args[3] or trigger.workplaceName
    trigger.hourlyWage      = args[4] or trigger.hourlyWage
    trigger.triggerRadius   = args[5] or trigger.triggerRadius
    trigger.paySchedule     = args[6] or trigger.paySchedule
    trigger.timeMultiplier  = args[7] or trigger.timeMultiplier
    trigger.endShiftOnLeave = args[8] ~= false

    if sys.triggerManager then
        sys.triggerManager:updateMapHotspotName(trigger)
    end

    wtLog("UPDATE_TRIGGER: " .. (trigger.workplaceName or "?"))
end

onDeleteTrigger = function(sys, userId, args)
    local triggerId = tostring(args[2] or "")

    -- End any active shifts using this trigger
    if sys.shiftTracker then
        if sys.shiftTracker:isShiftActive()
           and tostring(sys.shiftTracker.activeTriggerId) == triggerId then
            sys.shiftTracker:endShift()
        end
        if sys.shiftTracker._farmShifts then
            for farmId, entry in pairs(sys.shiftTracker._farmShifts) do
                if tostring(entry.triggerId) == triggerId then
                    sys.shiftTracker:endShiftForFarm(farmId)
                end
            end
        end
    end

    if sys.triggerManager then
        sys.triggerManager:deregisterTrigger(triggerId)
    end

    wtLog("DELETE_TRIGGER: id=" .. triggerId)
end

onSetTriggerPurpose = function(sys, userId, args)
    local triggerId = tostring(args[2] or "")
    -- Distinguish an explicit clear (empty string) from an absent value:
    -- args[3] is the purpose; nil means "no value supplied", "" means "clear".
    if args[3] == nil then
        wtLog("SET_TRIGGER_PURPOSE rejected: no purpose value: id=" .. triggerId)
        return
    end

    local ok = sys.triggerManager:setTriggerPurpose(triggerId, args[3])
    if not ok then
        wtLog("SET_TRIGGER_PURPOSE rejected: trigger not found: id=" .. triggerId)
        return
    end

    wtLog("SET_TRIGGER_PURPOSE: id=" .. triggerId .. " purpose='" .. tostring(args[3]) .. "'")
end

-- =========================================================
-- Public: send a client->server action through NetworkSync
-- =========================================================
-- On the server (listen-host or dedicated): runs onAction directly, then marks dirty.
-- On a client: sends via NetworkSync requestAction for server-side execution.

function WTNetworkSyncBridge.requestAction(args)
    if WTNetworkSyncBridge.active and WTNetworkSyncBridge._ns ~= nil then
        if g_currentMission ~= nil and g_currentMission:getIsServer() then
            onAction(nil, args)
            return true
        end
        WTNetworkSyncBridge._ns:requestAction(WTNetworkSyncBridge.ACTION_ID, args)
        return true
    end
    return false
end

-- =========================================================
-- Public send helpers (replace WorkplaceMultiplayerEvent.send*)
-- Each returns true when NetworkSync handled it (caller skips own event).
-- =========================================================

function WTNetworkSyncBridge.sendShiftStart(triggerId)
    local farmId = (g_currentMission and g_currentMission:getFarmId()) or 1
    return WTNetworkSyncBridge.requestAction({ "shift_start", farmId, tostring(triggerId) })
end

function WTNetworkSyncBridge.sendShiftEnd(isPenalty)
    local farmId = (g_currentMission and g_currentMission:getFarmId()) or 1
    return WTNetworkSyncBridge.requestAction({ "shift_end", farmId, isPenalty == true })
end

function WTNetworkSyncBridge.sendCreateTrigger(data)
    local farmId = (g_currentMission and g_currentMission:getFarmId()) or 1
    local clientId = string.format("wt_%d_%d",
        math.floor((g_currentMission and g_currentMission.time) or 0),
        math.floor(math.random() * 100000))

    -- Optimistic local registration on client
    if g_currentMission and not g_currentMission:getIsServer() then
        local sys = g_WorkplaceSystem
        if sys and sys.triggerManager then
            pcall(function()
                sys.triggerManager:registerTrigger({
                    id              = clientId,
                    workplaceName   = data.workplaceName or "Workplace",
                    hourlyWage      = data.hourlyWage    or 500,
                    triggerRadius   = data.triggerRadius or 4,
                    posX            = data.posX          or 0,
                    posY            = data.posY          or 0,
                    posZ            = data.posZ          or 0,
                    paySchedule     = data.paySchedule   or "hourly",
                    timeMultiplier  = data.timeMultiplier or 0,
                    endShiftOnLeave = data.endShiftOnLeave ~= false,
                    purpose         = data.purpose       or "",
                    playerInside    = false,
                })
            end)
        end
    end

    return WTNetworkSyncBridge.requestAction({
        "create_trigger", clientId,
        data.workplaceName   or "Workplace",
        data.hourlyWage      or 500,
        data.triggerRadius   or 4,
        data.posX            or 0,
        data.posY            or 0,
        data.posZ            or 0,
        data.paySchedule     or "hourly",
        data.timeMultiplier  or 0,
        data.endShiftOnLeave ~= false,
        data.purpose         or "",
    })
end

function WTNetworkSyncBridge.sendUpdateTrigger(triggerId, data)
    return WTNetworkSyncBridge.requestAction({
        "update_trigger", tostring(triggerId),
        data.workplaceName,
        data.hourlyWage,
        data.triggerRadius,
        data.paySchedule,
        data.timeMultiplier or 0,
        data.endShiftOnLeave ~= false,
    })
end

function WTNetworkSyncBridge.sendDeleteTrigger(triggerId)
    return WTNetworkSyncBridge.requestAction({ "delete_trigger", tostring(triggerId) })
end

-- Server-authoritative designation. Safe to call on both server and client:
-- requestAction runs locally on the server (under the admin gate) and forwards
-- on a client. Pass purpose = "" to clear the designation.
function WTNetworkSyncBridge.sendSetTriggerPurpose(triggerId, purpose)
    if purpose == nil then return false end
    return WTNetworkSyncBridge.requestAction({
        "set_trigger_purpose", tostring(triggerId), tostring(purpose),
    })
end

function WTNetworkSyncBridge.sendSyncSettings()
    if not WTNetworkSyncBridge.stateActive or WTNetworkSyncBridge._ns == nil then
        return false
    end
    WTNetworkSyncBridge._ns:markDirty(WTNetworkSyncBridge.MODULE_ID)
    return true
end

-- =========================================================
-- Registration (called from WorkplaceSystem:onMissionLoaded)
-- =========================================================
function WTNetworkSyncBridge.register()
    WTNetworkSyncBridge.active      = false
    WTNetworkSyncBridge.stateActive = false
    WTNetworkSyncBridge._ns         = nil

    local ns = (g_currentMission ~= nil and g_currentMission.networkSync) or g_networkSync
    if ns == nil then
        wtLog("NetworkSync not detected; MP sync disabled (requires FS25_NetworkSync)")
        return
    end

    local ok, err = pcall(function()
        ns:registerModule(WTNetworkSyncBridge.MODULE_ID, {
            channel      = WTNetworkSyncBridge.CHANNEL,
            onWriteState = WTNetworkSyncBridge._onWriteState,
            onReadState  = WTNetworkSyncBridge._onReadState,
        })
        ns:registerAction(WTNetworkSyncBridge.ACTION_ID, {
            adminOnly = false,
            onAction  = onAction,
        })
    end)

    if ok then
        WTNetworkSyncBridge.active      = true
        WTNetworkSyncBridge.stateActive = true
        WTNetworkSyncBridge._ns         = ns
        wtLog("Registered with NetworkSync (state module + action channel)")
    else
        wtLog("Registration failed: " .. tostring(err))
    end
end

print("[WorkplaceTriggers] WTNetworkSyncBridge loaded")
