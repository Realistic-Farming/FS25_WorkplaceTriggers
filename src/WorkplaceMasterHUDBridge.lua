-- =========================================================
-- WorkplaceMasterHUDBridge.lua
-- Optional bridge to FS25_MasterHUD.
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Workplace Triggers ships standalone, so this is delegate-when-present:
--   * MasterHUD installed -> WT registers its HUD draw as a self-draw.
--     MasterHUD then owns the single draw loop, the menu/dialog suspend, and
--     cross-mod ordering, so the shift HUD stacks cleanly with the rest of the
--     ecosystem instead of every mod hooking FSBaseMission.draw independently.
--   * MasterHUD absent -> WT's own FSBaseMission.draw hook runs the exact same
--     draw, exactly as before.
--
-- MasterHUD owns draw ordering + suspend only, not layout and not input, so the
-- HUD keeps positioning itself and the edit-mode mouse handler (addModEventListener
-- in main.lua) stays on WT's own input path. drawStack() is the single source of
-- the draw body, shared with the fallback hook so the two paths can never diverge.
-- =========================================================

WorkplaceMasterHUDBridge = {}

WorkplaceMasterHUDBridge.HUD_ID = "WorkplaceTriggers_HUD"
WorkplaceMasterHUDBridge.active = false   -- MasterHUD present and we registered

local function wtLog(msg)
    print("[WorkplaceTriggers] MasterHUD: " .. tostring(msg))
end

-- The WT HUD draw body. Same call the standalone FSBaseMission.draw hook makes;
-- WorkplaceSystem:draw() self-guards on isInitialized and the HUD on client.
function WorkplaceMasterHUDBridge.drawStack()
    -- Suite hide: MasterHUD # key. No-op when MasterHUD absent.
    local mh = (g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD
    if mh ~= nil and mh.areHudsHidden ~= nil and mh:areHudsHidden() then return end
    if g_WorkplaceSystem ~= nil then
        g_WorkplaceSystem:draw()
    end
end

-- Register with MasterHUD if present. Called from WorkplaceSystem:onMissionLoaded,
-- after the HUD has published its g_currentMission handle (Mission00.load).
function WorkplaceMasterHUDBridge.register()
    WorkplaceMasterHUDBridge.active = false

    local hud = (g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD
    if hud == nil then return end

    local ok, err = pcall(function()
        hud:subscribe(WorkplaceMasterHUDBridge.HUD_ID, {
            draw = WorkplaceMasterHUDBridge.drawStack,
        })
    end)

    if ok then
        WorkplaceMasterHUDBridge.active = true
        wtLog("Registered WT HUD with MasterHUD (single draw loop + menu-suspend)")
        if hud.registerEditListener ~= nil then
            hud:registerEditListener(WorkplaceMasterHUDBridge.HUD_ID, {
                enter = function()
                    local sys = g_WorkplaceSystem
                    if sys ~= nil and sys.hud ~= nil and sys.hud.enterEditMode ~= nil then
                        sys.hud:enterEditMode()
                    end
                end,
                exit = function()
                    local sys = g_WorkplaceSystem
                    if sys ~= nil and sys.hud ~= nil and sys.hud.editMode
                        and sys.hud.exitEditMode ~= nil then
                        sys.hud:exitEditMode()
                    end
                end,
            })
        end
    else
        wtLog("MasterHUD registration failed: " .. tostring(err) .. " (using own draw hook)")
    end
end
