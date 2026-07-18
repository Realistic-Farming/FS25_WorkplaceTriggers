-- =========================================================
-- WorkplaceMultiplayerEvent.lua
-- Syncs trigger creation and shift start/end between server
-- and all clients.
-- Pattern: FS25 Event class (VehicleAttachEvent reference)
--
-- FS25 rules:
--   InitEventClass() registers the event — Class() alone is NOT sufficient for MP
--   Event.new() takes only the metatable (no typeId arg)
--   emptyNew() required for engine deserialisation
--   readStream must call self:run(connection) at the end
--
-- MP trigger-creation flow:
--   1. Client sends TYPE_CREATE_TRIGGER to server
--   2. Server calls g_placeableSystem:loadPlaceable(), generates
--      a stable cross-machine ID and broadcasts
--      TYPE_TRIGGER_CREATED to ALL clients
--   3. Every client (including originator) receives the stable
--      ID and queues the pendingCreate with it, then the
--      placeable replicates normally via the FS25 placeable
--      network layer
-- =========================================================

WorkplaceMultiplayerEvent = {}
WorkplaceMultiplayerEvent_mt = Class(WorkplaceMultiplayerEvent, Event)
InitEventClass(WorkplaceMultiplayerEvent, "WorkplaceMultiplayerEvent")

WorkplaceMultiplayerEvent.TYPE_SHIFT_START     = 1
WorkplaceMultiplayerEvent.TYPE_SHIFT_END       = 2
WorkplaceMultiplayerEvent.TYPE_SHIFT_CONFIRM   = 3
WorkplaceMultiplayerEvent.TYPE_CREATE_TRIGGER  = 4   -- client -> server
WorkplaceMultiplayerEvent.TYPE_TRIGGER_CREATED = 5   -- server -> all clients
WorkplaceMultiplayerEvent.TYPE_UPDATE_TRIGGER  = 6   -- client -> server (edit existing)
WorkplaceMultiplayerEvent.TYPE_DELETE_TRIGGER  = 7   -- server -> all clients
WorkplaceMultiplayerEvent.TYPE_REQUEST_SYNC    = 8   -- client -> server on join/rejoin
WorkplaceMultiplayerEvent.TYPE_SYNC_SETTINGS   = 9   -- server -> all clients (global settings)

local LOG = "[WorkplaceTriggers] MPEvent: "
local function wtLog(msg) print(LOG .. tostring(msg)) end

-- =========================================================
-- Stable ID counter (server-side only; safe because the server
-- is the sole writer and Lua is single-threaded)
-- =========================================================
WorkplaceMultiplayerEvent._serverIdCounter = 0

local function generateStableId()
    WorkplaceMultiplayerEvent._serverIdCounter =
        WorkplaceMultiplayerEvent._serverIdCounter + 1
    local t = g_currentMission and math.floor(g_currentMission.time) or 0
    return string.format("wt_%d_%d", t,
        WorkplaceMultiplayerEvent._serverIdCounter)
end

-- =========================================================
-- FS25 constructors
-- =========================================================
function WorkplaceMultiplayerEvent.emptyNew()
    local self = Event.new(WorkplaceMultiplayerEvent_mt)
    return self
end

function WorkplaceMultiplayerEvent.new(eventType, data)
    local self = WorkplaceMultiplayerEvent.emptyNew()
    self.eventType     = eventType or WorkplaceMultiplayerEvent.TYPE_SHIFT_START
    -- shift fields
    self.triggerId     = (data and data.triggerId)     or ""
    self.workplaceName = (data and data.workplaceName) or ""
    self.earnings      = (data and data.earnings)      or 0
    self.isPenalty     = (data and data.isPenalty)     or false
    -- trigger create/update fields
    self.posX          = (data and data.posX)          or 0
    self.posY          = (data and data.posY)          or 0
    self.posZ          = (data and data.posZ)          or 0
    self.hourlyWage    = (data and data.hourlyWage)    or 500
    self.triggerRadius = (data and data.triggerRadius) or 4
    self.paySchedule   = (data and data.paySchedule)   or "hourly"
    self.timeMultiplier  = (data and data.timeMultiplier)  or 0
    self.farmId          = (data and data.farmId)          or 1
    -- per-trigger zone behaviour
    -- NOTE: cannot use (a and b or c) here because b may be boolean false, which
    -- would cause Lua to evaluate the 'or' branch and always return true.
    if data ~= nil and data.endShiftOnLeave ~= nil then
        self.endShiftOnLeave = data.endShiftOnLeave
    else
        self.endShiftOnLeave = true
    end
    -- TYPE_SYNC_SETTINGS payload (server -> all clients)
    self.wageMultiplier  = (data and data.wageMultiplier)  or 1.0
    return self
end

-- =========================================================
-- Serialization
-- =========================================================
function WorkplaceMultiplayerEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId,  self.eventType)
    streamWriteString(streamId, self.triggerId     or "")
    streamWriteString(streamId, self.workplaceName or "")
    streamWriteInt32(streamId,  math.floor(self.earnings or 0))
    streamWriteBool(streamId,   self.isPenalty or false)
    -- trigger create/update fields (written for all types; cheap)
    streamWriteFloat32(streamId, self.posX          or 0)
    streamWriteFloat32(streamId, self.posY          or 0)
    streamWriteFloat32(streamId, self.posZ          or 0)
    streamWriteInt32(streamId,   math.floor(self.hourlyWage    or 500))
    streamWriteFloat32(streamId, self.triggerRadius or 4)
    streamWriteString(streamId,  self.paySchedule    or "hourly")
    streamWriteInt32(streamId,   math.floor(self.timeMultiplier or 0))
    streamWriteInt32(streamId,   math.floor(self.farmId or 1))
    streamWriteBool(streamId,    self.endShiftOnLeave ~= false)
    -- TYPE_SYNC_SETTINGS fields (written for all types; cheap and avoids type-switching)
    streamWriteFloat32(streamId, self.wageMultiplier  or 1.0)
end

function WorkplaceMultiplayerEvent:readStream(streamId, connection)
    self.eventType     = streamReadUInt8(streamId)
    self.triggerId     = streamReadString(streamId)
    self.workplaceName = streamReadString(streamId)
    self.earnings      = streamReadInt32(streamId)
    self.isPenalty     = streamReadBool(streamId)
    self.posX          = streamReadFloat32(streamId)
    self.posY          = streamReadFloat32(streamId)
    self.posZ          = streamReadFloat32(streamId)
    self.hourlyWage    = streamReadInt32(streamId)
    self.triggerRadius = streamReadFloat32(streamId)
    self.paySchedule    = streamReadString(streamId)
    self.timeMultiplier  = streamReadInt32(streamId)
    self.farmId          = streamReadInt32(streamId)
    self.endShiftOnLeave = streamReadBool(streamId)
    self.wageMultiplier  = streamReadFloat32(streamId)
    self:run(connection)   -- FS25 requirement
end

-- =========================================================
-- Processing
-- =========================================================
function WorkplaceMultiplayerEvent:run(connection)
    local sys = g_WorkplaceSystem
    if sys == nil then wtLog("run: g_WorkplaceSystem nil, ignoring"); return end

    local t = self.eventType
    if     t == WorkplaceMultiplayerEvent.TYPE_SHIFT_START     then self:handleShiftStart(sys, connection)
    elseif t == WorkplaceMultiplayerEvent.TYPE_SHIFT_END       then self:handleShiftEnd(sys, connection)
    elseif t == WorkplaceMultiplayerEvent.TYPE_SHIFT_CONFIRM   then self:handleShiftConfirm(sys)
    elseif t == WorkplaceMultiplayerEvent.TYPE_CREATE_TRIGGER  then self:handleCreateTrigger(sys, connection)
    elseif t == WorkplaceMultiplayerEvent.TYPE_TRIGGER_CREATED then self:handleTriggerCreated(sys)
    elseif t == WorkplaceMultiplayerEvent.TYPE_UPDATE_TRIGGER  then self:handleUpdateTrigger(sys, connection)
    elseif t == WorkplaceMultiplayerEvent.TYPE_DELETE_TRIGGER  then self:handleDeleteTrigger(sys)
    elseif t == WorkplaceMultiplayerEvent.TYPE_REQUEST_SYNC    then self:handleRequestSync(sys, connection)
    elseif t == WorkplaceMultiplayerEvent.TYPE_SYNC_SETTINGS   then self:handleSyncSettings(sys)
    end
end

-- =========================================================
-- Shift handlers
-- =========================================================
function WorkplaceMultiplayerEvent:handleShiftStart(sys, connection)
    if g_currentMission:getIsServer() then
        local trigger = sys.triggerManager:getTriggerById(self.triggerId)
        if trigger then
            local clientFarmId = self.farmId or 1

            -- Guard: reject if this farm already has an active shift
            if sys.shiftTracker:isShiftActiveForFarm(clientFarmId) then
                wtLog("Server: farm " .. tostring(clientFarmId) .. " already has an active shift — ignoring duplicate start")
                return
            end

            -- Start a per-farm shift slot on the server (no HUD, no single-slot mutation)
            sys.shiftTracker:startShiftForFarm(clientFarmId, trigger)

            -- Also update the single-slot fields ONLY when this is the local farm
            -- on a listen-server (so SP / listen-server host payout still works via
            -- the old endShift() path used by sendShiftEnd on the server branch).
            local localFarmId = (g_currentMission and g_currentMission:getIsClient()
                                 and g_currentMission:getFarmId()) or -1
            if clientFarmId == localFarmId then
                local ok, err = pcall(function() sys.shiftTracker:startShift(trigger, true) end)
                if not ok then
                    wtLog("Server: startShift (single-slot) error: " .. tostring(err))
                end
                sys.shiftTracker.activeFarmId      = clientFarmId
                sys.shiftTracker.shiftOwnerIsLocal = true
            else
                -- Remote farm: keep single-slot state untouched for the listen-server
                -- host's own shift, and set shiftOwnerIsLocal=false so zone checks
                -- don't fire using the host's position.
                sys.shiftTracker.shiftOwnerIsLocal = false
            end

            wtLog("Server: started shift for farm " .. tostring(clientFarmId)
                  .. " at '" .. (trigger.workplaceName or "?") .. "'")
            g_server:broadcastEvent(WorkplaceMultiplayerEvent.new(
                WorkplaceMultiplayerEvent.TYPE_SHIFT_CONFIRM,
                { triggerId      = self.triggerId,
                  workplaceName  = trigger.workplaceName  or "",
                  earnings       = 0,
                  hourlyWage     = trigger.hourlyWage     or 500,
                  paySchedule    = trigger.paySchedule    or "hourly",
                  timeMultiplier = trigger.timeMultiplier or 0,
                  farmId         = clientFarmId }
            ))
        else
            wtLog("Server: shift start rejected - trigger not found: " .. tostring(self.triggerId))
        end
    end
    -- FIX: client branch removed.
    -- Clients update their HUD only when they receive TYPE_SHIFT_CONFIRM,
    -- never on an inbound TYPE_SHIFT_START. This prevents the HUD showing
    -- a shift that the server then rejects.
end

function WorkplaceMultiplayerEvent:handleShiftEnd(sys, connection)
    if g_currentMission:getIsServer() then
        local clientFarmId = (self.farmId and self.farmId > 0) and self.farmId or 1

        if sys.shiftTracker:isShiftActiveForFarm(clientFarmId) then
            local earned, name
            if self.isPenalty then
                earned, name = sys.shiftTracker:endShiftPenaltyForFarm(clientFarmId)
                wtLog(string.format("Server: penalty-ended shift for farm %d, paid $%d from '%s'",
                    clientFarmId, earned or 0, name or "?"))
            else
                earned, name = sys.shiftTracker:endShiftForFarm(clientFarmId)
                wtLog(string.format("Server: ended shift for farm %d, paid $%d from '%s'",
                    clientFarmId, earned or 0, name or "?"))
            end

            -- Also clear the single-slot state if this farm owned it
            -- (listen-server host ended their own shift)
            if sys.shiftTracker.activeFarmId == clientFarmId
               and sys.shiftTracker:isShiftActive() then
                local ok, err = pcall(function()
                    if self.isPenalty then
                        sys.shiftTracker:endShiftPenalty()
                    else
                        sys.shiftTracker:endShift()
                    end
                end)
                if not ok then
                    wtLog("Server: single-slot endShift error (harmless): " .. tostring(err))
                end
            end

            g_server:broadcastEvent(WorkplaceMultiplayerEvent.new(
                WorkplaceMultiplayerEvent.TYPE_SHIFT_CONFIRM,
                { triggerId = "", workplaceName = name or "", earnings = earned or 0,
                  farmId = clientFarmId }
            ))
        else
            -- BUG FIX (issue #17): the server has no active shift for this farm but
            -- the client sent TYPE_SHIFT_END. Send a zero-earnings end-confirm to
            -- unstick the client.
            wtLog("Server: SHIFT_END for farm " .. tostring(clientFarmId)
                  .. " but no active shift — sending zero CONFIRM to unstick client")
            if g_server then
                g_server:broadcastEvent(WorkplaceMultiplayerEvent.new(
                    WorkplaceMultiplayerEvent.TYPE_SHIFT_CONFIRM,
                    { triggerId = "", workplaceName = "", earnings = 0, farmId = clientFarmId }
                ))
            end
        end
    end
    -- FIX: no client-side HUD update here either
end

function WorkplaceMultiplayerEvent:handleShiftConfirm(sys)
    -- triggerId == "" means shift ended; triggerId ~= "" means shift started.
    -- Do NOT use earnings > 0: that check breaks when a shift ends with $0 earned
    -- (e.g. stopped within the first fraction of a second), causing the client to
    -- misread the end-confirm as a start-confirm and leave the shift stuck active.
    local isEnd = (self.triggerId == "")

    -- Determine if this confirm belongs to the local player's farm.
    -- Only the owning farm sees the HUD update; others ignore it.
    local confirmFarmId = self.farmId or 1
    local localFarmId   = (g_currentMission and g_currentMission:getFarmId()) or 1
    local isOwner       = (confirmFarmId == localFarmId)

    -- Only update HUD for the client that owns this shift
    if sys.hud and isOwner then
        if isEnd then
            sys.hud:onShiftEnded(self.workplaceName, self.earnings)
        else
            sys.hud:onShiftStarted(self.workplaceName, 0)
        end
    end

    -- Sync shift state to client's shiftTracker so zone tracking can run client-side.
    -- IMPORTANT: only update the shiftTracker for the OWNING farm's clients.
    -- Other farms must NOT have activeTriggerId set — that would make isShiftActive()
    -- return true for them, causing wrong E-key prompts and accidental shift-end sends.
    -- On a listen-server the server already set its state via startShift(); the HOST
    -- client branch below is a no-op for remote shifts (isOwner=false), leaving the
    -- server-set state intact for payout purposes while keeping the client UI clean.
    if sys.shiftTracker then
        if isEnd then
            -- Shift ended: only clear state on the farm that owned the shift.
            if isOwner then
                sys.shiftTracker.activeTriggerId     = nil
                sys.shiftTracker.activeWorkplaceName = nil
                sys.shiftTracker.activeHourlyWage    = 0
                sys.shiftTracker.activePaySchedule   = WorkplaceShiftTracker.PAY_HOURLY
                sys.shiftTracker.shiftStartTime      = nil
                sys.shiftTracker.shiftElapsedMs      = 0
                sys.shiftTracker.leaveWarnActive     = false
                sys.shiftTracker.leaveWarnTimer      = 0
            end
        else
            -- Shift started: only the owning farm mirrors state client-side.
            -- Zone checks (updateZoneCheck) only run when shiftOwnerIsLocal=true,
            -- so non-owning clients need no state here.
            if isOwner then
                sys.shiftTracker.activeTriggerId      = self.triggerId
                sys.shiftTracker.activeWorkplaceName  = self.workplaceName
                sys.shiftTracker.activeHourlyWage     = self.hourlyWage
                sys.shiftTracker.activePaySchedule    = self.paySchedule
                sys.shiftTracker.activeTimeMultiplier = self.timeMultiplier or 0
                sys.shiftTracker.shiftStartTime       = sys.shiftTracker:getCurrentMissionTime()
                sys.shiftTracker.shiftElapsedMs       = 0
                sys.shiftTracker.leaveWarnActive      = false
                sys.shiftTracker.leaveWarnTimer       = 0
                sys.shiftTracker.shiftOwnerIsLocal    = true
            end
            -- Non-owners: leave their shiftTracker untouched.
            -- On a listen-server the server-side startShift() already set the needed
            -- fields (activeTriggerId, shiftStartTime, etc.) for payout calculation,
            -- with shiftOwnerIsLocal=false so zone checks don't fire for the host player.
        end
    end

    wtLog("Received shift confirm for '" .. tostring(self.workplaceName) .. "'")
end

-- =========================================================
-- Trigger creation handlers
-- =========================================================

-- Runs on the SERVER when a dedicated-server client requests trigger creation.
-- In SP/listen-server this is bypassed by sendCreateTrigger() above.
function WorkplaceMultiplayerEvent:handleCreateTrigger(sys, connection)
    if not g_currentMission:getIsServer() then return end

    -- ADMIN GUARD: only admin connections may create triggers on a dedicated server
    if connection and connection.getIsAdmin and not connection:getIsAdmin() then
        wtLog("Server: CREATE_TRIGGER rejected - sender is not admin")
        return
    end

    -- Use client-provided id if present so client's optimistic registration matches
    local stableId = (self.triggerId and self.triggerId ~= "") and self.triggerId or generateStableId()
    wtLog("Server: creating trigger id=" .. stableId
          .. " name='" .. self.workplaceName .. "'")

    -- Register directly on the server (no placeable)
    local triggerData = {
        id              = stableId,
        workplaceName   = self.workplaceName,
        hourlyWage      = self.hourlyWage,
        triggerRadius   = self.triggerRadius,
        posX            = self.posX,
        posY            = self.posY,
        posZ            = self.posZ,
        paySchedule     = self.paySchedule,
        timeMultiplier  = self.timeMultiplier or 0,
        endShiftOnLeave = self.endShiftOnLeave ~= false,
        playerInside    = false,
    }
    local ok, err = pcall(function()
        sys.triggerManager:registerTrigger(triggerData)
    end)
    if not ok then
        wtLog("Server: registerTrigger error (trigger still queued): " .. tostring(err))
    end

    -- Broadcast to all clients so they register the same trigger data
    -- NOTE: broadcast runs even if visual setup failed above
    g_server:broadcastEvent(WorkplaceMultiplayerEvent.new(
        WorkplaceMultiplayerEvent.TYPE_TRIGGER_CREATED,
        {
            triggerId       = stableId,
            workplaceName   = self.workplaceName,
            hourlyWage      = self.hourlyWage,
            triggerRadius   = self.triggerRadius,
            paySchedule     = self.paySchedule,
            timeMultiplier  = self.timeMultiplier or 0,
            endShiftOnLeave = self.endShiftOnLeave ~= false,
            posX            = self.posX,
            posY            = self.posY,
            posZ            = self.posZ,
            farmId          = self.farmId,
        }
    ))
end

-- Runs on every CLIENT after the server acknowledged creation.
function WorkplaceMultiplayerEvent:handleTriggerCreated(sys)
    -- Server already registered it inside handleCreateTrigger
    if g_currentMission:getIsServer() then return end

    wtLog("Client: received trigger-created id=" .. tostring(self.triggerId)
          .. " name='" .. self.workplaceName .. "'")

    -- Skip if already registered via optimistic local registration
    if sys.triggerManager:getTriggerById(self.triggerId) then
        wtLog("Client: trigger already registered locally - skipping duplicate")
        return
    end

    -- Register directly on this client (no placeable)
    local triggerData = {
        id              = self.triggerId,
        workplaceName   = self.workplaceName,
        hourlyWage      = self.hourlyWage,
        triggerRadius   = self.triggerRadius,
        posX            = self.posX,
        posY            = self.posY,
        posZ            = self.posZ,
        paySchedule     = self.paySchedule,
        timeMultiplier  = self.timeMultiplier or 0,
        endShiftOnLeave = self.endShiftOnLeave ~= false,
        playerInside    = false,
    }
    sys.triggerManager:registerTrigger(triggerData)
end

-- Runs when any client edits an existing trigger's name/wage/radius.
function WorkplaceMultiplayerEvent:handleUpdateTrigger(sys, connection)
    if g_currentMission:getIsServer() then
        -- ADMIN GUARD: only admin connections may edit triggers on a dedicated server
        -- (same pattern as handleCreateTrigger; blocks non-admin clients from
        -- changing hourlyWage or any other trigger field)
        if connection and connection.getIsAdmin and not connection:getIsAdmin() then
            wtLog("Server: UPDATE_TRIGGER rejected - sender is not admin")
            return
        end

        local trigger = sys.triggerManager:getTriggerById(self.triggerId)
        if trigger then
            trigger.workplaceName   = self.workplaceName
            trigger.hourlyWage      = self.hourlyWage
            trigger.triggerRadius   = self.triggerRadius
            trigger.paySchedule     = self.paySchedule
            trigger.timeMultiplier  = self.timeMultiplier or 0
            trigger.endShiftOnLeave = self.endShiftOnLeave ~= false
            if sys.triggerManager then
                sys.triggerManager:updateMapHotspotName(trigger)
            end
            wtLog("Server: updated trigger '" .. self.workplaceName .. "'")
            -- Broadcast authoritative update to all other clients
            g_server:broadcastEvent(WorkplaceMultiplayerEvent.new(
                WorkplaceMultiplayerEvent.TYPE_UPDATE_TRIGGER,
                {
                    triggerId       = self.triggerId,
                    workplaceName   = self.workplaceName,
                    hourlyWage      = self.hourlyWage,
                    triggerRadius   = self.triggerRadius,
                    paySchedule     = self.paySchedule,
                    timeMultiplier  = self.timeMultiplier or 0,
                    endShiftOnLeave = self.endShiftOnLeave ~= false,
                }
            ))
        else
            wtLog("Server: update rejected - trigger not found: " .. tostring(self.triggerId))
        end
    else
        -- Apply the authoritative update that came from the server
        local trigger = sys.triggerManager:getTriggerById(self.triggerId)
        if trigger then
            trigger.workplaceName   = self.workplaceName
            trigger.hourlyWage      = self.hourlyWage
            trigger.triggerRadius   = self.triggerRadius
            trigger.paySchedule     = self.paySchedule
            trigger.timeMultiplier  = self.timeMultiplier or 0
            trigger.endShiftOnLeave = self.endShiftOnLeave ~= false
            if sys.triggerManager then
                sys.triggerManager:updateMapHotspotName(trigger)
            end
        end
    end
end

-- =========================================================
-- Public send helpers (called from WorkplaceSystem / WTEditDialog)
-- =========================================================
function WorkplaceMultiplayerEvent.sendShiftStart(triggerId)
    if g_currentMission == nil then return end
    if g_currentMission:getIsServer() then
        local sys = g_WorkplaceSystem
        if sys then
            local trigger = sys.triggerManager:getTriggerById(triggerId)
            if trigger then
                local localFarmId = g_currentMission:getFarmId() or 1
                if sys.shiftTracker:isShiftActiveForFarm(localFarmId) then
                    wtLog("sendShiftStart: farm " .. tostring(localFarmId) .. " already has an active shift")
                    return
                end
                sys.shiftTracker:startShiftForFarm(localFarmId, trigger)
                -- Also update single-slot so zone-check / HUD still work for SP host
                sys.shiftTracker:startShift(trigger)
                sys.shiftTracker.activeFarmId = localFarmId
                -- Broadcast CONFIRM so listen-server clients and the host HUD all update
                if g_server then
                    g_server:broadcastEvent(WorkplaceMultiplayerEvent.new(
                        WorkplaceMultiplayerEvent.TYPE_SHIFT_CONFIRM,
                        { triggerId      = tostring(triggerId),
                          workplaceName  = trigger.workplaceName  or "",
                          earnings       = 0,
                          hourlyWage     = trigger.hourlyWage     or 500,
                          paySchedule    = trigger.paySchedule    or "hourly",
                          timeMultiplier = trigger.timeMultiplier or 0,
                          farmId         = localFarmId }
                    ))
                end
            end
        end
    else
        if g_client == nil then wtLog("sendShiftStart: g_client is nil"); return end
        local conn = g_client:getServerConnection()
        if conn == nil then wtLog("sendShiftStart: getServerConnection() nil"); return end
        local clientFarmId = g_currentMission:getFarmId() or 1
        conn:sendEvent(WorkplaceMultiplayerEvent.new(
            WorkplaceMultiplayerEvent.TYPE_SHIFT_START,
            { triggerId = triggerId, farmId = clientFarmId }))
    end
end

function WorkplaceMultiplayerEvent.sendShiftEnd(isPenalty)
    if g_currentMission == nil then return end
    if g_currentMission:getIsServer() then
        local sys = g_WorkplaceSystem
        if sys then
            local localFarmId = g_currentMission:getFarmId() or 1
            if sys.shiftTracker:isShiftActiveForFarm(localFarmId) then
                local earned, name
                if isPenalty then
                    earned, name = sys.shiftTracker:endShiftPenaltyForFarm(localFarmId)
                else
                    earned, name = sys.shiftTracker:endShiftForFarm(localFarmId)
                end
                -- Also clear single-slot state for the listen-server host
                if sys.shiftTracker:isShiftActive()
                   and sys.shiftTracker.activeFarmId == localFarmId then
                    pcall(function()
                        if isPenalty then sys.shiftTracker:endShiftPenalty()
                        else              sys.shiftTracker:endShift() end
                    end)
                end
                -- Broadcast confirm so all clients know (including listen-server host's own HUD)
                if g_server then
                    g_server:broadcastEvent(WorkplaceMultiplayerEvent.new(
                        WorkplaceMultiplayerEvent.TYPE_SHIFT_CONFIRM,
                        { triggerId = "", workplaceName = name or "", earnings = earned or 0,
                          farmId = localFarmId }
                    ))
                else
                    -- SP: update HUD directly
                    if sys.hud then sys.hud:onShiftEnded(name or "", earned or 0) end
                    if sys.shiftTracker then
                        sys.shiftTracker.activeTriggerId     = nil
                        sys.shiftTracker.activeWorkplaceName = nil
                        sys.shiftTracker.shiftStartTime      = nil
                        sys.shiftTracker.shiftElapsedMs      = 0
                    end
                end
            end
        end
    else
        if g_client == nil then wtLog("sendShiftEnd: g_client is nil"); return end
        local conn = g_client:getServerConnection()
        if conn == nil then wtLog("sendShiftEnd: getServerConnection() nil"); return end
        local clientFarmId = g_currentMission:getFarmId() or 1
        conn:sendEvent(WorkplaceMultiplayerEvent.new(
            WorkplaceMultiplayerEvent.TYPE_SHIFT_END,
            { isPenalty = isPenalty or false, farmId = clientFarmId }))
    end
end

-- Called from WTEditDialog:onClickSave() for new triggers
function WorkplaceMultiplayerEvent.sendCreateTrigger(data)
    if g_currentMission == nil then wtLog("sendCreateTrigger: g_currentMission nil"); return end
    wtLog("sendCreateTrigger: isServer=" .. tostring(g_currentMission:getIsServer())
        .. " isClient=" .. tostring(g_currentMission:getIsClient())
        .. " sys=" .. tostring(g_WorkplaceSystem ~= nil))
    if g_currentMission:getIsServer() then
        -- SP / listen-server: create trigger data directly, no placeable needed
        local sys = g_WorkplaceSystem
        if sys == nil then return end
        local stableId = generateStableId()
        local triggerData = {
            id              = stableId,
            workplaceName   = data.workplaceName or "Workplace",
            hourlyWage      = data.hourlyWage    or 500,
            triggerRadius   = data.triggerRadius or 4,
            posX            = data.posX          or 0,
            posY            = data.posY          or 0,
            posZ            = data.posZ          or 0,
            paySchedule     = data.paySchedule   or "hourly",
            timeMultiplier  = data.timeMultiplier or 0,
            endShiftOnLeave = data.endShiftOnLeave ~= false,
            playerInside    = false,
        }
        local ok2, err2 = pcall(function()
            sys.triggerManager:registerTrigger(triggerData)
        end)
        if not ok2 then
            wtLog("sendCreateTrigger: registerTrigger error: " .. tostring(err2))
        end

        -- Listen-server: broadcast to any connected clients
        if g_server then
            g_server:broadcastEvent(WorkplaceMultiplayerEvent.new(
                WorkplaceMultiplayerEvent.TYPE_TRIGGER_CREATED,
                {
                    triggerId     = stableId,
                    workplaceName   = triggerData.workplaceName,
                    hourlyWage      = triggerData.hourlyWage,
                    triggerRadius   = triggerData.triggerRadius,
                    paySchedule     = triggerData.paySchedule,
                    timeMultiplier  = triggerData.timeMultiplier,
                    endShiftOnLeave = triggerData.endShiftOnLeave ~= false,
                    posX            = triggerData.posX,
                    posY            = triggerData.posY,
                    posZ            = triggerData.posZ,
                    farmId          = data.farmId or 1,
                }
            ))
        end
    else
        -- Dedicated server client: register locally immediately (optimistic) so the
        -- trigger shows in the dialog right away, then send to server for persistence
        -- and sync to all other clients.
        local sys = g_WorkplaceSystem
        local clientId = string.format("wt_%d_%d",
            math.floor((g_currentMission and g_currentMission.time) or 0),
            math.floor(math.random() * 100000))
        if sys then
            local triggerData = {
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
                playerInside    = false,
            }
            pcall(function() sys.triggerManager:registerTrigger(triggerData) end)
        end
        -- Send to server so it registers + broadcasts to other clients
        data.triggerId = clientId
        if g_client == nil then wtLog("sendCreateTrigger: g_client is nil"); return end
        local conn = g_client:getServerConnection()
        if conn == nil then wtLog("sendCreateTrigger: getServerConnection() returned nil"); return end
        conn:sendEvent(WorkplaceMultiplayerEvent.new(
            WorkplaceMultiplayerEvent.TYPE_CREATE_TRIGGER, data))
    end
end

-- Called from WTEditDialog:onClickSave() when editing an existing trigger
function WorkplaceMultiplayerEvent.sendUpdateTrigger(triggerId, data)
    if g_currentMission == nil then return end
    data.triggerId = triggerId
    if g_currentMission:getIsServer() then
        local sys = g_WorkplaceSystem
        if sys then
            local trigger = sys.triggerManager:getTriggerById(triggerId)
            if trigger then
                trigger.workplaceName   = data.workplaceName
                trigger.hourlyWage      = data.hourlyWage
                trigger.triggerRadius   = data.triggerRadius
                trigger.paySchedule     = data.paySchedule
                trigger.timeMultiplier  = data.timeMultiplier or 0
                trigger.endShiftOnLeave = data.endShiftOnLeave ~= false
                if sys.triggerManager then
                    sys.triggerManager:updateMapHotspotName(trigger)
                end
            end
        end
    else
        if g_client == nil then wtLog("sendUpdateTrigger: g_client is nil"); return end
        local conn = g_client:getServerConnection()
        if conn == nil then wtLog("sendUpdateTrigger: getServerConnection() nil"); return end
        conn:sendEvent(WorkplaceMultiplayerEvent.new(
            WorkplaceMultiplayerEvent.TYPE_UPDATE_TRIGGER, data))
    end
end

-- Runs on every machine to deregister a trigger by ID.
-- On a dedicated server, re-broadcasts to all other clients.
function WorkplaceMultiplayerEvent:handleDeleteTrigger(sys)
    -- ADMIN GUARD: on a dedicated server, only admin clients may delete triggers.
    -- The connection object is not passed to run() so we check via g_currentMission.
    -- On a dedicated server clients, isMasterUser reflects the admin flag.
    -- (SP / listen-server hosts always pass through since getIsServer() is true.)
    if g_currentMission:getIsClient() and not g_currentMission:getIsServer() then
        if g_currentMission.isMasterUser ~= true then
            wtLog("Client: DELETE_TRIGGER blocked - not admin")
            return
        end
    end

    if sys.shiftTracker and sys.shiftTracker:isShiftActive() then
        if tostring(sys.shiftTracker.activeTriggerId) == self.triggerId then
            sys.shiftTracker:endShift()
        end
    end
    -- Also end any per-farm shifts using this trigger
    if sys.shiftTracker and sys.shiftTracker._farmShifts then
        for farmId, entry in pairs(sys.shiftTracker._farmShifts) do
            if tostring(entry.triggerId) == tostring(self.triggerId) then
                sys.shiftTracker:endShiftForFarm(farmId)
            end
        end
    end
    if sys.triggerManager then
        sys.triggerManager:deregisterTrigger(self.triggerId)
    end
    wtLog("Deleted trigger id=" .. tostring(self.triggerId))

    -- Dedicated server: forward to all clients
    if g_currentMission:getIsServer() and g_server then
        g_server:broadcastEvent(WorkplaceMultiplayerEvent.new(
            WorkplaceMultiplayerEvent.TYPE_DELETE_TRIGGER,
            { triggerId = self.triggerId }
        ))
    end
end

-- =========================================================
-- Join sync: client requests all triggers on connect/rejoin
-- =========================================================

-- Runs on the SERVER when a newly connected client sends TYPE_REQUEST_SYNC.
-- Broadcasts all triggers to ALL clients (connection param is nil on dedicated
-- server readStream, so connection:sendEvent() silently fails there).
-- handleTriggerCreated has a duplicate-check so broadcast is safe.
function WorkplaceMultiplayerEvent:handleRequestSync(sys, connection)
    wtLog(string.format("handleRequestSync: isServer=%s g_server=%s",
        tostring(g_currentMission and g_currentMission:getIsServer()),
        tostring(g_server ~= nil)))
    if not g_currentMission:getIsServer() then return end
    if g_server == nil then return end
    local triggers = sys.triggerManager and sys.triggerManager:getAllTriggers() or {}
    for _, trigger in ipairs(triggers) do
        g_server:broadcastEvent(WorkplaceMultiplayerEvent.new(
            WorkplaceMultiplayerEvent.TYPE_TRIGGER_CREATED,
            {
                triggerId       = tostring(trigger.id),
                workplaceName   = trigger.workplaceName or "Workplace",
                hourlyWage      = trigger.hourlyWage    or 500,
                triggerRadius   = trigger.triggerRadius or 4,
                paySchedule     = trigger.paySchedule    or "hourly",
                timeMultiplier  = trigger.timeMultiplier or 0,
                endShiftOnLeave = trigger.endShiftOnLeave ~= false,
                posX            = trigger.posX          or 0,
                posY            = trigger.posY          or 0,
                posZ            = trigger.posZ          or 0,
                farmId          = 1,
            }
        ))
    end
    wtLog(string.format("Sent %d trigger(s) to all clients (sync request)", #triggers))

    -- Also push global settings so non-admin clients use the server's wageMultiplier etc.
    WorkplaceMultiplayerEvent.sendSyncSettings()
end

-- =========================================================
-- Settings sync: server -> all clients (TYPE_SYNC_SETTINGS)
-- =========================================================

-- Runs on every CLIENT when the server pushes global settings.
-- wageMultiplier is server-authoritative (admin-only setting in MP).
function WorkplaceMultiplayerEvent:handleSyncSettings(sys)
    if g_currentMission:getIsServer() then return end   -- host set its own settings already
    local s = sys and sys.settings
    if not s then return end
    s.wageMultiplier = self.wageMultiplier
    wtLog(string.format("Settings synced from server: wageMult=%.2f", s.wageMultiplier))
end

-- Called by the server to push global settings to all clients.
-- Triggered on join (from handleRequestSync) and when admin changes a setting.
function WorkplaceMultiplayerEvent.sendSyncSettings()
    if g_currentMission == nil then return end
    if not g_currentMission:getIsServer() then return end
    if g_server == nil then return end
    local s = g_WorkplaceSystem and g_WorkplaceSystem.settings
    if not s then return end
    g_server:broadcastEvent(WorkplaceMultiplayerEvent.new(
        WorkplaceMultiplayerEvent.TYPE_SYNC_SETTINGS,
        { wageMultiplier = s.wageMultiplier }
    ))
    wtLog(string.format("Broadcast settings to all clients (wageMult=%.2f)", s.wageMultiplier))
end

-- Called by WorkplaceSystem:onMissionLoaded() on clients.
-- Asks the server to push all existing triggers to this client.
function WorkplaceMultiplayerEvent.sendRequestSync()
    if g_currentMission == nil then return end
    if g_currentMission:getIsServer() then return end   -- host has triggers already
    if g_client == nil then wtLog("sendRequestSync: g_client nil"); return end
    local conn = g_client:getServerConnection()
    if conn == nil then wtLog("sendRequestSync: no server connection"); return end
    conn:sendEvent(WorkplaceMultiplayerEvent.new(WorkplaceMultiplayerEvent.TYPE_REQUEST_SYNC, {}))
    wtLog("Sent trigger sync request to server")
end

-- Called from WTListDialog:onClickDel — routes through server so all clients sync
function WorkplaceMultiplayerEvent.sendDeleteTrigger(triggerId)
    if g_currentMission == nil then return end
    local sys = g_WorkplaceSystem
    if sys == nil then return end

    if g_currentMission:getIsServer() then
        -- SP / listen-server: deregister locally then broadcast
        if sys.shiftTracker and sys.shiftTracker:isShiftActive() then
            if tostring(sys.shiftTracker.activeTriggerId) == tostring(triggerId) then
                sys.shiftTracker:endShift()
            end
        end
        if sys.triggerManager then
            sys.triggerManager:deregisterTrigger(triggerId)
        end
        if g_server then
            g_server:broadcastEvent(WorkplaceMultiplayerEvent.new(
                WorkplaceMultiplayerEvent.TYPE_DELETE_TRIGGER,
                { triggerId = tostring(triggerId) }
            ))
        end
    else
        -- Dedicated server client: ask server to delete
        if g_client == nil then wtLog("sendDeleteTrigger: g_client is nil"); return end
        local conn = g_client:getServerConnection()
        if conn == nil then wtLog("sendDeleteTrigger: getServerConnection() nil"); return end
        conn:sendEvent(WorkplaceMultiplayerEvent.new(
            WorkplaceMultiplayerEvent.TYPE_DELETE_TRIGGER,
            { triggerId = tostring(triggerId) }))
    end
end

print("[WorkplaceTriggers] WorkplaceMultiplayerEvent loaded")
