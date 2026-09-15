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
WTDialogLoader.siteLoaded        = false   -- WT-8 sibling dialogs
WTDialogLoader.siteListInstance  = nil
WTDialogLoader.siteEditInstance  = nil

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

-- =========================================================
-- WT-8 site dialogs (siblings, loaded on first use)
-- =========================================================
function WTDialogLoader.ensureSiteLoaded()
    if WTDialogLoader.siteLoaded then return true end
    if not g_gui then return false end
    local modDir = WTDialogLoader.modDirectory
    if not modDir then return false end
    local listInst = WTSiteListDialog.new()
    local ok, err = pcall(function()
        g_gui:loadGui(modDir .. "gui/WTSiteListDialog.xml", "WTSiteListDialog", listInst)
    end)
    if not ok then
        wtLog("ERROR loading WTSiteListDialog: " .. tostring(err))
        return false
    end
    WTDialogLoader.siteListInstance = listInst
    local editInst = WTSiteEditDialog.new()
    ok, err = pcall(function()
        g_gui:loadGui(modDir .. "gui/WTSiteEditDialog.xml", "WTSiteEditDialog", editInst)
    end)
    if not ok then
        wtLog("ERROR loading WTSiteEditDialog: " .. tostring(err))
        return false
    end
    WTDialogLoader.siteEditInstance = editInst
    WTDialogLoader.siteLoaded = true
    wtLog("Site dialogs loaded OK")
    return true
end

--- Show the site manager, optionally focused on a site. clearAdmin leaves a
--- retained administration display context (openSiteManager from a consumer).
function WTDialogLoader.showSiteList(system, focusSiteId, clearAdmin)
    if not WTDialogLoader.ensureSiteLoaded() then return false end
    local inst = WTDialogLoader.siteListInstance
    if inst and inst.setSystem then inst:setSystem(system, focusSiteId, clearAdmin) end
    local ok, err = pcall(function() g_gui:showDialog("WTSiteListDialog") end)
    if not ok then
        wtLog("ERROR showing WTSiteListDialog: " .. tostring(err))
        return false
    end
    if inst and inst.system and inst.refresh then inst:refresh() end
    return true
end

function WTDialogLoader.showSiteEdit(system, site, isNew, adminFarmId)
    if not WTDialogLoader.ensureSiteLoaded() then return false end
    local inst = WTDialogLoader.siteEditInstance
    if inst and inst.setData then inst:setData(system, site, isNew, adminFarmId) end
    local ok, err = pcall(function() g_gui:showDialog("WTSiteEditDialog") end)
    if not ok then
        wtLog("ERROR showing WTSiteEditDialog: " .. tostring(err))
        return false
    end
    return true
end

--- A replaced replica refreshes an open site manager.
function WTDialogLoader.refreshSiteList()
    local inst = WTDialogLoader.siteListInstance
    if inst ~= nil and inst.system ~= nil and inst.refresh ~= nil and g_gui ~= nil and g_gui.getIsDialogVisible ~= nil then
        pcall(function() if g_gui:getIsDialogVisible() then inst:refresh() end end)
    end
end

print("[WorkplaceTriggers] WTDialogLoader loaded")
