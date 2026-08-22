-- =========================================================
-- WTDialogLoader.lua
-- Lazy-loads WTListDialog and WTEditDialog via g_gui:loadGui.
-- Stores instances directly so setSystem/setData work.
-- Pattern: DialogLoader.lua from FS25_NPCFavor
-- =========================================================
-- CRITICAL: g_gui:loadGui() arg 3 = CLASS TABLE, not instance.
-- We pass the class, then retrieve the instance g_gui created.
-- =========================================================

WTDialogLoader = WTDialogLoader or {}

WTDialogLoader.modDirectory  = nil
WTDialogLoader.loaded        = false
WTDialogLoader.listInstance  = nil
WTDialogLoader.editInstance  = nil

local function wtLog(msg)
    print("[WorkplaceTriggers] DialogLoader: " .. tostring(msg))
end

function WTDialogLoader.init(modDir)
    WTDialogLoader.modDirectory = modDir
end

-- =========================================================
-- Ensure both dialogs are loaded into g_gui
-- =========================================================
function WTDialogLoader.ensureLoaded()
    if WTDialogLoader.loaded then return true end
    if not g_gui then
        wtLog("g_gui not available")
        return false
    end
    local modDir = WTDialogLoader.modDirectory
    if not modDir then
        wtLog("modDirectory not set")
        return false
    end

    -- Load List dialog
    -- g_gui:loadGui(xmlPath, name, classTable) - arg 3 is CLASS TABLE
    local listInst = WTListDialog.new()
    local ok, err = pcall(function()
        g_gui:loadGui(modDir .. "gui/WTListDialog.xml", "WTListDialog", listInst)
    end)
    if not ok then
        wtLog("ERROR loading WTListDialog: " .. tostring(err))
        return false
    end
    WTDialogLoader.listInstance = listInst

    -- Load Edit dialog
    local editInst = WTEditDialog.new()
    ok, err = pcall(function()
        g_gui:loadGui(modDir .. "gui/WTEditDialog.xml", "WTEditDialog", editInst)
    end)
    if not ok then
        wtLog("ERROR loading WTEditDialog: " .. tostring(err))
        return false
    end
    WTDialogLoader.editInstance = editInst

    WTDialogLoader.loaded = true
    wtLog("Both dialogs loaded OK")
    return true
end

-- =========================================================
-- Show the list dialog
-- =========================================================
function WTDialogLoader.showList(system)
    if not WTDialogLoader.ensureLoaded() then
        wtLog("Cannot show list - load failed")
        return false
    end

    local inst = WTDialogLoader.listInstance
    if inst and inst.setSystem then
        inst:setSystem(system)
    end

    local ok, err = pcall(function()
        g_gui:showDialog("WTListDialog")
    end)
    if not ok then
        wtLog("ERROR showing WTListDialog: " .. tostring(err))
        return false
    end

    -- onOpen may fire before setSystem is applied on first load; refresh ensures data is visible.
    if inst and inst.system and inst.refresh then
        inst:refresh()
    end

    return true
end

-- =========================================================
-- Show the edit dialog
-- trigger = existing trigger table, or nil for new
-- isNew   = true when creating
-- =========================================================
function WTDialogLoader.showEdit(system, trigger, isNew)
    if not WTDialogLoader.ensureLoaded() then
        wtLog("Cannot show edit - load failed")
        return false
    end

    local inst = WTDialogLoader.editInstance
    if inst and inst.setData then
        inst:setData(system, trigger, isNew)
    end

    local ok, err = pcall(function()
        g_gui:showDialog("WTEditDialog")
    end)
    if not ok then
        wtLog("ERROR showing WTEditDialog: " .. tostring(err))
        return false
    end
    return true
end

print("[WorkplaceTriggers] WTDialogLoader loaded")
