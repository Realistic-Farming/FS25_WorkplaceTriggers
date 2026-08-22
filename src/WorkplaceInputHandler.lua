-- =========================================================
-- WorkplaceInputHandler.lua
-- Input state management helper.
-- The actual E-key RVB hook lives in main.lua following the
-- NPCFavor pattern (PlayerInputComponent.registerActionEvents).
-- This module holds any additional input-related state.
-- =========================================================

WorkplaceInputHandler = WorkplaceInputHandler or {}
WorkplaceInputHandler_mt = Class(WorkplaceInputHandler)

local function wtLog(msg)
    print("[WorkplaceTriggers] InputHandler: " .. tostring(msg))
end

function WorkplaceInputHandler.new(system)
    local self = setmetatable({}, WorkplaceInputHandler_mt)
    self.system = system
    self.isInitialized = false
    return self
end

function WorkplaceInputHandler:initialize()
    self.isInitialized = true
    wtLog("Initialized")
end

function WorkplaceInputHandler:delete()
    self.isInitialized = false
    wtLog("Deleted")
end
