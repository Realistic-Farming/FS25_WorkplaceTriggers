-- =========================================================
-- WorkplaceGUI.lua
-- Thin coordinator. All actual GUI is in WTListDialog and
-- WTEditDialog (proper FS25 MessageDialog subclasses loaded
-- via g_gui:loadGui and shown via g_gui:showDialog).
-- No overlay rendering. No mouse hit-test code.
-- =========================================================

WorkplaceGUI = WorkplaceGUI or {}
WorkplaceGUI_mt = Class(WorkplaceGUI)

local function wtLog(msg)
    print("[WorkplaceTriggers] GUI: " .. tostring(msg))
end

function WorkplaceGUI.new(system)
    local self = setmetatable({}, WorkplaceGUI_mt)
    self.system = system
    self.isInitialized = false
    return self
end

function WorkplaceGUI:initialize()
    self.isInitialized = true
    wtLog("Initialized")
end

function WorkplaceGUI:toggle()
    if not self.isInitialized then return end
    if g_gui and g_gui:getIsDialogVisible() then
        g_gui:closeDialogs()
        return
    end
    WTDialogLoader.showList(self.system)
end

function WorkplaceGUI:isOpen()
    return g_gui ~= nil and g_gui:getIsDialogVisible()
end

-- FS25 GUI system handles update/draw - these are no-ops
function WorkplaceGUI:update(dtSec) end
function WorkplaceGUI:draw() end

function WorkplaceGUI:delete()
    self.isInitialized = false
    wtLog("Deleted")
end
