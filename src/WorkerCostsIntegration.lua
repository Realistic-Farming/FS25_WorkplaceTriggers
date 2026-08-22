-- =========================================================
-- WorkerCostsIntegration.lua
-- Optional bridge to FS25_WorkerCosts.
-- Registers each workplace trigger as a "job" so WorkerCosts
-- can offset shift income against AI worker wages, giving a
-- balanced economy picture.
--
-- Gracefully skipped if FS25_WorkerCosts is not loaded.
-- Detection: g_WorkerCostsSystem ~= nil
-- =========================================================
-- RULES: No unicode, no goto, no continue (Lua 5.1)
-- =========================================================

WorkerCostsIntegration = WorkerCostsIntegration or {}
WorkerCostsIntegration_mt = Class(WorkerCostsIntegration)

local LOG = "[WorkplaceTriggers] WorkerCosts: "

local function wtLog(msg)
    print(LOG .. tostring(msg))
end

function WorkerCostsIntegration.new(system)
    local self = setmetatable({}, WorkerCostsIntegration_mt)
    self.system      = system
    self.isAvailable = false
    -- Track registered job IDs so we can clean them up
    self.registeredJobIds = {}
    return self
end

function WorkerCostsIntegration:initialize()
    if getfenv(0)["g_WorkerCostsSystem"] ~= nil then
        self.isAvailable = true
        wtLog("FS25_WorkerCosts detected - integration active")
    else
        wtLog("FS25_WorkerCosts not loaded - integration skipped")
    end
end

-- =========================================================
-- Register a trigger as an off-farm job with WorkerCosts.
-- Called after a trigger is created or loaded.
-- =========================================================
function WorkerCostsIntegration:registerJob(trigger)
    if not self.isAvailable then return end
    if trigger == nil then return end

    local wcs = getfenv(0)["g_WorkerCostsSystem"]
    if wcs == nil then return end

    local jobId = "WT_" .. tostring(trigger.id)

    local ok, err = pcall(function()
        -- WorkerCosts public API (best-effort - check if the method exists)
        if wcs.registerOffFarmJob then
            wcs:registerOffFarmJob(jobId, {
                name       = trigger.workplaceName or "Workplace",
                hourlyRate = trigger.hourlyWage    or 500,
                type       = "workplace_trigger",
            })
        end
    end)

    if ok then
        self.registeredJobIds[trigger.id] = jobId
        wtLog(string.format("Registered job '%s' (id=%s)", trigger.workplaceName or "?", jobId))
    else
        wtLog("registerOffFarmJob error: " .. tostring(err))
    end
end

-- =========================================================
-- Deregister a trigger's job when the trigger is deleted.
-- =========================================================
function WorkerCostsIntegration:deregisterJob(triggerId)
    if not self.isAvailable then return end

    local jobId = self.registeredJobIds[triggerId]
    if jobId == nil then return end

    local wcs = getfenv(0)["g_WorkerCostsSystem"]
    if wcs == nil then return end

    local ok, err = pcall(function()
        if wcs.deregisterOffFarmJob then
            wcs:deregisterOffFarmJob(jobId)
        end
    end)

    if ok then
        self.registeredJobIds[triggerId] = nil
        wtLog("Deregistered job " .. tostring(jobId))
    else
        wtLog("deregisterOffFarmJob error: " .. tostring(err))
    end
end

-- =========================================================
-- Notify WorkerCosts that a shift was completed.
-- =========================================================
function WorkerCostsIntegration:onShiftCompleted(trigger, earned)
    if not self.isAvailable then return end
    if trigger == nil then return end

    local wcs = getfenv(0)["g_WorkerCostsSystem"]
    if wcs == nil then return end

    local jobId = self.registeredJobIds[trigger.id]
    if jobId == nil then return end

    local ok, err = pcall(function()
        if wcs.recordJobIncome then
            wcs:recordJobIncome(jobId, earned or 0)
        end
    end)

    if not ok then
        wtLog("recordJobIncome error: " .. tostring(err))
    end
end

function WorkerCostsIntegration:delete()
    -- Clean up all registered jobs
    if self.isAvailable then
        for triggerId, _ in pairs(self.registeredJobIds) do
            self:deregisterJob(triggerId)
        end
    end
    self.registeredJobIds = {}
    self.isAvailable = false
    wtLog("Deleted")
end

print("[WorkplaceTriggers] WorkerCostsIntegration loaded")
