-- =========================================================
-- NPCFavorIntegration.lua
-- Optional bridge to FS25_NPCFavor.
-- When a player works a shift, their relationship with the
-- "employer" NPC (chosen per trigger) improves slightly.
--
-- Gracefully skipped if FS25_NPCFavor is not loaded.
-- Detection: g_NPCFavorSystem ~= nil
-- =========================================================
-- RULES: No unicode, no goto, no continue (Lua 5.1)
-- =========================================================

NPCFavorIntegration = NPCFavorIntegration or {}
NPCFavorIntegration_mt = Class(NPCFavorIntegration)

local LOG = "[WorkplaceTriggers] NPCFavor: "

local function wtLog(msg)
    print(LOG .. tostring(msg))
end

-- Favor gained per real in-game hour worked
NPCFavorIntegration.FAVOR_PER_HOUR = 2

function NPCFavorIntegration.new(system)
    local self = setmetatable({}, NPCFavorIntegration_mt)
    self.system      = system
    self.isAvailable = false
    return self
end

function NPCFavorIntegration:initialize()
    -- Detect NPCFavor presence
    if getfenv(0)["g_NPCFavorSystem"] ~= nil then
        self.isAvailable = true
        wtLog("FS25_NPCFavor detected - favor integration active")
    else
        wtLog("FS25_NPCFavor not loaded - integration skipped")
    end
end

-- =========================================================
-- Called by ShiftTracker:endShift() via WorkplaceSystem
-- trigger: the trigger table (may have npcFavorTargetId field)
-- elapsedHours: in-game hours the shift ran
-- =========================================================
function NPCFavorIntegration:onShiftCompleted(trigger, elapsedHours)
    if not self.isAvailable then return end
    if trigger == nil then return end

    local npcId = trigger.npcFavorTargetId
    if npcId == nil then return end

    local favorSystem = getfenv(0)["g_NPCFavorSystem"]
    if favorSystem == nil then return end

    local gain = math.max(1, math.floor(
        (elapsedHours or 0) * self.FAVOR_PER_HOUR
    ))

    -- NPCFavor public API: addFavor(npcId, amount)
    local ok, err = pcall(function()
        favorSystem:addFavor(npcId, gain)
    end)

    if ok then
        wtLog(string.format(
            "Added %d favor to NPC '%s' for shift at '%s'",
            gain, tostring(npcId), trigger.workplaceName or "?"
        ))
    else
        wtLog("addFavor error: " .. tostring(err))
    end
end

-- =========================================================
-- Query: list available NPC names for the edit dialog
-- Returns table of {id, name} pairs, or empty table
-- =========================================================
function NPCFavorIntegration:getAvailableNPCs()
    if not self.isAvailable then return {} end
    local favorSystem = getfenv(0)["g_NPCFavorSystem"]
    if favorSystem == nil then return {} end

    local result = {}
    local ok, npcs = pcall(function()
        if favorSystem.getAllNPCs ~= nil then
            return favorSystem:getAllNPCs()
        end
        return {}
    end)
    if not ok then return {} end

    for _, npc in ipairs(npcs or {}) do
        table.insert(result, {
            id   = npc.id   or npc.npcId or tostring(npc),
            name = npc.name or npc.npcName or "NPC",
        })
    end
    return result
end

function NPCFavorIntegration:delete()
    self.isAvailable = false
    wtLog("Deleted")
end

print("[WorkplaceTriggers] NPCFavorIntegration loaded")
