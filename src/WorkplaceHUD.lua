-- =========================================================
-- WorkplaceHUD.lua
-- Renders the active shift HUD panel.
-- Position: bottom-left (Y=0 is BOTTOM in FS25, increases UP).
-- =========================================================
-- Pattern: NPCFavorHUD.lua from FS25_NPCFavor
-- =========================================================
-- IMPORTANT: ALL renderOverlay / renderText calls MUST be
-- inside draw callbacks (FSBaseMission.draw hook), never update.
-- =========================================================
-- EDIT MODE: Press Shift (WT_HUD_EDIT) to toggle drag/resize.
--   - Drag body     : move the panel
--   - Drag corners  : uniform scale (resize all dimensions)
--   - Drag L/R edge : width-only resize
-- Position/scale are persisted via WorkplaceSaveLoad (XML).
-- =========================================================

-- BUILD 17:57 + ATTN 18:02 (Wizard hot-reload law, FS25-HotReload-Guide.md Part 1):
-- reuse the existing class table on Ctrl+R reload so updated methods land on the
-- table live metatables already reference, instead of orphaning it.
WorkplaceHUD = WorkplaceHUD or {}
WorkplaceHUD_mt = Class(WorkplaceHUD)

local function wtLog(msg)
    print("[WorkplaceTriggers] HUD: " .. tostring(msg))
end

local function getBaseGameRenderer()
    local hud = (g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD
    return hud ~= nil and hud.renderer or nil
end

function WorkplaceHUD.new(system)
    local self = setmetatable({}, WorkplaceHUD_mt)
    self.system = system

    -- Position (normalized 0-1, Y=0 is bottom).
    -- BUILD 06:43 (Sam DESIGN 06:42): fresh-save home is middle-RIGHT in the suite's
    -- staggered default layout - right edge at ~0.98 (posX 0.76 + BASE_WIDTH 0.22),
    -- vertically centered. The old (0.02, 0.12) default sat on the vanilla
    -- bottom-left corner. A saved layout still wins (settings.hudPosX/Y override
    -- these on load).
    -- BUILD 15:33 (Sam DESIGN 15:30): posX 0.320 - the left-center column.
    -- Wizard 2026-08-21: factory home updated to the suite layout Wizard
    -- arranged in-game (bottom-left lane). A saved layout still wins.
    self.posX = 0.143437
    self.posY = 0.037963

    -- Scale multiplier applied to all dimensions and text
    self.scale = 1.0

    -- Width multiplier (adjusted by left/right edge-drag)
    self.widthMult     = 0.935938   -- factory suite layout (Wizard 2026-08-21)
    self.MIN_WIDTH_MULT = 0.5
    self.MAX_WIDTH_MULT = 2.5

    -- Edit/drag state (runtime only, never persisted)
    self.editMode    = false
    self.dragging    = false
    self.dragOffsetX = 0
    self.dragOffsetY = 0

    -- Corner resize state
    self.resizing          = false
    self.resizeStartMouseX = 0
    self.resizeStartMouseY = 0
    self.resizeStartScale  = 1.0
    self.MIN_SCALE         = 0.5
    self.MAX_SCALE         = 2.5

    -- Edge (width) drag state
    self.edgeDragging       = nil   -- nil | "left" | "right"
    self.edgeDragStartX     = 0
    self.edgeDragStartWidth = 1.0

    -- Hover feedback
    self.hoverCorner        = nil   -- nil | "bl" | "br" | "tl" | "tr"
    self.RESIZE_HANDLE_SIZE = 0.008

    -- Camera freeze (edit mode)
    self.savedCamRotX = nil
    self.savedCamRotY = nil
    self.savedCamRotZ = nil

    -- Notification flash state
    self.flashMessage  = nil
    self.flashTimer    = 0
    self.flashDuration = 4.0
    self.flashColor    = {1, 0.85, 0.3, 1}

    -- Leave-zone warning state
    self.leaveWarnActive      = false
    self.leaveWarnSecondsLeft = 0

    -- Animation
    self.animTimer = 0

    -- Colors
    self.COLORS = {
        BG                  = {0.08, 0.08, 0.08, 0.80},
        BORDER              = {0.35, 0.55, 0.90, 0.70},
        BORDER_NORM         = {0.30, 0.35, 0.45, 0.45},
        SHADOW              = {0.00, 0.00, 0.00, 0.35},
        HEADER              = {1.00, 1.00, 1.00, 1.00},
        LABEL               = {0.75, 0.75, 0.75, 1.00},
        VALUE               = {1.00, 1.00, 1.00, 1.00},
        EARN_COLOR          = {0.35, 0.90, 0.35, 1.00},
        FLASH_BG            = {0.12, 0.12, 0.12, 0.88},
        HINT                = {0.70, 0.80, 1.00, 0.90},
        RESIZE_HANDLE       = {0.30, 0.50, 0.90, 0.60},
        RESIZE_HANDLE_HOVER = {0.50, 0.70, 1.00, 0.90},
        RESIZE_ACTIVE       = {0.30, 0.80, 0.30, 0.80},
    }

    -- Base dimensions (before scale)
    self.BASE_WIDTH       = 0.22
    self.BASE_ROW_HEIGHT  = 0.018
    self.BASE_PADDING     = 0.009
    self.BASE_TEXT_SMALL  = 0.012
    self.BASE_TEXT_MEDIUM = 0.015

    -- 1x1 pixel overlay for drawing colored rectangles
    self.bgOverlay = nil
    if createImageOverlay then
        self.bgOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end

    self.isInitialized = false
    return self
end

function WorkplaceHUD:initialize()
    -- Apply scale from settings if available
    local s = self.system and self.system.settings
    if s then
        if s.hudScale then self.scale = s.hudScale end
    end
    self.isInitialized = true
    wtLog("Initialized")
end

-- =========================================================
-- Settings Persistence (called from WorkplaceSaveLoad)
-- =========================================================
function WorkplaceHUD:loadFromSettings(settings)
    if not settings then return end
    self.posX      = settings.hudPosX      or self.posX
    self.posY      = settings.hudPosY      or self.posY
    self.scale     = settings.hudScale     or self.scale
    self.widthMult = settings.hudWidthMult or self.widthMult
    self:clampPosition()
end

function WorkplaceHUD:saveToSettings(settings)
    if not settings then return end
    settings.hudPosX      = self.posX
    settings.hudPosY      = self.posY
    settings.hudScale     = self.scale
    settings.hudWidthMult = self.widthMult
end

-- =========================================================
-- Shift Events (called by ShiftTracker)
-- =========================================================
function WorkplaceHUD:onShiftStarted(workplaceName, hourlyWage)
    self:showFlash(
        string.format(g_i18n:getText("wt_hud_shift_started") or "Shift started at %s\n$%d/hr",
            workplaceName, hourlyWage),
        {0.35, 0.90, 0.35, 1}
    )
end

function WorkplaceHUD:onShiftEnded(workplaceName, earnings)
    -- Always clear the leave warning when shift ends
    self.leaveWarnActive      = false
    self.leaveWarnSecondsLeft = 0
    self:showFlash(
        string.format(g_i18n:getText("wt_hud_shift_ended") or "Shift ended\n+$%d earned",
            earnings),
        {1, 0.85, 0.3, 1}
    )
end

function WorkplaceHUD:onShiftAbandonedPenalty(workplaceName, penaltyPay, fullEarnings)
    -- Clear the leave warning
    self.leaveWarnActive      = false
    self.leaveWarnSecondsLeft = 0
    -- Build the penalty message using the translation key, with a longer display time
    local fmt = g_i18n:getText("wt_hud_shift_abandoned")
        or "Shift ended - left work area! | Only 20%% paid: $%d (would have been $%d) | Always end your shift manually for full pay."
    local msg = string.format(fmt, penaltyPay, fullEarnings)
    self:showFlash(msg, {1, 0.35, 0.35, 1}, 5.0)   -- red tint, longer display
end

-- =========================================================
-- Flash Notification
-- =========================================================
function WorkplaceHUD:showFlash(message, color, duration)
    self.flashMessage  = message
    self.flashTimer    = 0
    self.flashDuration = duration or 4.0
    self.flashColor    = color or {1, 0.85, 0.3, 1}
end

-- =========================================================
-- Edit Mode Toggle (called from main.lua Shift key binding)
-- =========================================================
function WorkplaceHUD:toggleEditMode()
    if self.editMode then
        self:exitEditMode()
    else
        self:enterEditMode()
    end
end

function WorkplaceHUD:enterEditMode()
    self.editMode = true
    self.dragging = false

    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true)
    end

    -- Save camera rotation so we can freeze it each frame
    if getCamera then
        local cam = getCamera()
        if cam and cam ~= 0 and getRotation then
            self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = getRotation(cam)
        end
    end

    wtLog("Edit mode ON - drag to move, corners to resize, edges for width")
end

function WorkplaceHUD:exitEditMode()
    self.editMode     = false
    self.dragging     = false
    self.resizing     = false
    self.edgeDragging = nil
    self.hoverCorner  = nil

    self.savedCamRotX = nil
    self.savedCamRotY = nil
    self.savedCamRotZ = nil

    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(false)
    end

    -- Persist position/scale immediately on exit
    if self.system and self.system.saveLoad then
        self.system.saveLoad:savePendingHUD()
    end

    wtLog("Edit mode OFF - position saved")
end

-- =========================================================
-- Mouse Event (drag / resize logic - only active in editMode)
-- =========================================================
function WorkplaceHUD:mouseEvent(posX, posY, isDown, isUp, button)
    if not self.editMode then return end

    -- Left mouse button
    if isDown and button == 1 then
        -- Priority 1: corner handles (uniform scale)
        local corner = self:hitTestCorner(posX, posY)
        if corner then
            self.resizing          = true
            self.dragging          = false
            self.edgeDragging      = nil
            self.resizeStartMouseX = posX
            self.resizeStartMouseY = posY
            self.resizeStartScale  = self.scale
            return
        end

        -- Priority 2: left/right edge (width only)
        local edge = self:hitTestEdge(posX, posY)
        if edge then
            self.edgeDragging       = edge
            self.dragging           = false
            self.resizing           = false
            self.edgeDragStartX     = posX
            self.edgeDragStartWidth = self.widthMult
            return
        end

        -- Priority 3: panel body drag
        local hx, hy, hw, hh = self:getHUDRect()
        if posX >= hx and posX <= hx + hw and posY >= hy and posY <= hy + hh then
            self.dragging     = true
            self.resizing     = false
            self.edgeDragging = nil
            self.dragOffsetX  = posX - self.posX
            self.dragOffsetY  = posY - self.posY
        end
    end

    -- Release
    if isUp and button == 1 then
        if self.dragging or self.resizing or self.edgeDragging then
            self.dragging     = false
            self.resizing     = false
            self.edgeDragging = nil
            self:clampPosition()
            if self.system and self.system.saveLoad then
                self.system.saveLoad:savePendingHUD()
            end
        end
    end

    -- Track movement
    if self.dragging then
        self.posX = posX - self.dragOffsetX
        self.posY = posY - self.dragOffsetY
        self:clampPosition()
    end

    if self.resizing then
        local hudX, hudY, hudW, hudH = self:getHUDRect()
        local cx = hudX + hudW / 2
        local cy = hudY + hudH / 2
        local startDist = math.sqrt((self.resizeStartMouseX - cx)^2 + (self.resizeStartMouseY - cy)^2)
        local currDist  = math.sqrt((posX - cx)^2 + (posY - cy)^2)
        local dx = posX - self.resizeStartMouseX
        local dy = posY - self.resizeStartMouseY
        local diagonal = math.sqrt(dx * dx + dy * dy) * 2.0
        if currDist < startDist then diagonal = -diagonal end
        local newScale = self.resizeStartScale + diagonal
        self.scale = math.max(self.MIN_SCALE, math.min(self.MAX_SCALE, newScale))
        self:clampPosition()
    end

    if self.edgeDragging then
        local dx = posX - self.edgeDragStartX
        if self.edgeDragging == "left" then dx = -dx end
        local newMult = self.edgeDragStartWidth + dx * 3.0
        self.widthMult = math.max(self.MIN_WIDTH_MULT, math.min(self.MAX_WIDTH_MULT, newMult))
        self:clampPosition()
    end
end

-- =========================================================
-- Geometry Helpers
-- =========================================================
function WorkplaceHUD:getHUDRect()
    local s    = self.scale
    local pad  = self.BASE_PADDING     * s
    local rowH = self.BASE_ROW_HEIGHT  * s
    local tm   = self.BASE_TEXT_MEDIUM * s
    local w    = self.BASE_WIDTH * self.widthMult * s

    local numRows = 3
    local panelH  = pad * 2 + tm + numRows * rowH + rowH * 0.3

    local panelX = self.posX - pad
    local panelY = self.posY - pad
    local panelW = w + pad * 2

    return panelX, panelY, panelW, panelH
end

function WorkplaceHUD:clampPosition()
    local _, _, hw, hh = self:getHUDRect()
    self.posX = math.max(0.01, math.min(1.0 - hw + 0.01, self.posX))
    self.posY = math.max(0.01, math.min(0.99 - hh + 0.01, self.posY))
end

function WorkplaceHUD:getResizeHandleRects()
    local hx, hy, hw, hh = self:getHUDRect()
    local hs = self.RESIZE_HANDLE_SIZE
    return {
        bl = {x = hx,           y = hy,           w = hs, h = hs},
        br = {x = hx + hw - hs, y = hy,           w = hs, h = hs},
        tl = {x = hx,           y = hy + hh - hs, w = hs, h = hs},
        tr = {x = hx + hw - hs, y = hy + hh - hs, w = hs, h = hs},
    }
end

function WorkplaceHUD:hitTestCorner(posX, posY)
    local handles = self:getResizeHandleRects()
    for key, rect in pairs(handles) do
        if posX >= rect.x and posX <= rect.x + rect.w
           and posY >= rect.y and posY <= rect.y + rect.h then
            return key
        end
    end
    return nil
end

function WorkplaceHUD:hitTestEdge(posX, posY)
    local hx, hy, hw, hh = self:getHUDRect()
    local edgeW = 0.008
    -- Left edge
    if posX >= hx - edgeW / 2 and posX <= hx + edgeW / 2
       and posY >= hy and posY <= hy + hh then
        return "left"
    end
    -- Right edge
    if posX >= hx + hw - edgeW / 2 and posX <= hx + hw + edgeW / 2
       and posY >= hy and posY <= hy + hh then
        return "right"
    end
    return nil
end

-- =========================================================
-- Update (logic only - no rendering)
-- =========================================================
function WorkplaceHUD:update(dtSec)
    if not self.isInitialized then return end
    self.animTimer = self.animTimer + dtSec

    -- Flash timer
    if self.flashMessage then
        self.flashTimer = self.flashTimer + dtSec
        if self.flashTimer >= self.flashDuration then
            self.flashMessage = nil
            self.flashTimer   = 0
        end
    end

    -- Edit mode per-frame enforcement
    if self.editMode then
        -- Re-assert cursor (engine may reset it)
        if g_inputBinding and g_inputBinding.setShowMouseCursor then
            g_inputBinding:setShowMouseCursor(true)
        end

        -- Freeze camera rotation
        if self.savedCamRotX and getCamera and setRotation then
            local cam = getCamera()
            if cam and cam ~= 0 then
                setRotation(cam, self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ)
            end
        end

        -- Auto-exit if a dialog/GUI opens
        if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then
            self:exitEditMode()
        end

        -- Hover detection for corner handles
        if not self.dragging and not self.resizing then
            if g_inputBinding and g_inputBinding.mousePosXLast and g_inputBinding.mousePosYLast then
                self.hoverCorner = self:hitTestCorner(g_inputBinding.mousePosXLast, g_inputBinding.mousePosYLast)
            else
                self.hoverCorner = nil
            end
        end
    else
        self.hoverCorner = nil
    end
end

-- =========================================================
-- Draw (rendering - ONLY called from FSBaseMission.draw)
-- =========================================================
function WorkplaceHUD:draw()
    if not self.isInitialized then return end
    if not self.bgOverlay then return end

    -- Skip when any GUI is open (edit mode also auto-exits in update())
    if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then return end
    if g_currentMission and g_currentMission.paused then return end

    -- BUILD 08:50 (Sam DESIGN 08:49 + Brian TEST 07:31): hide means HIDE. One gate,
    -- FIRST, over everything this HUD paints - shift panel, leave-zone warning and
    -- shift flash included. The old order drew the warning and flash before the gate
    -- as "money-relevant exceptions"; Sam's lock is that a hidden HUD paints nothing,
    -- and a leaky exception is how Brian read a surviving panel as a broken toggle.
    -- Edit mode still paints (the escape hatch for placing a hidden panel).
    --
    -- The hidden truth is read from BOTH reachable settings handles - the instance
    -- this HUD was constructed with AND the published g_WorkplaceSystem - because
    -- Brian's live log showed the toggle callback flipping state while a panel kept
    -- painting. From source these are one object; if any runtime path ever splits
    -- them, either handle saying hidden now hides, so the player's press can never
    -- again be logged and ignored.
    local cfg  = self.system and self.system.settings
    local gcfg = (g_WorkplaceSystem ~= nil) and g_WorkplaceSystem.settings or nil
    local hidden = (cfg ~= nil and cfg.showHud == false)
        or (gcfg ~= nil and gcfg.showHud == false)
    if hidden and not self.editMode then return end

    -- Leave-zone warning (visible whenever the HUD itself is not hidden)
    if self.leaveWarnActive then
        self:drawLeaveWarning()
    end

    -- Flash notification (if notifications enabled)
    if self.flashMessage then
        if not cfg or cfg.showNotifications ~= false then
            self:drawFlash()
        end
    end

    -- Reaching here means either not hidden, or hidden-but-editing (the escape
    -- hatch, which must paint the panel for placement). The shift-or-edit gate
    -- below still applies as before.

    -- Only draw shift panel when a shift is active OR in edit mode
    local tracker     = self.system.shiftTracker
    local shiftActive = tracker ~= nil and tracker:isShiftActive()

    if not shiftActive and not self.editMode then return end

    self:drawShiftPanel(tracker, shiftActive)
end

-- =========================================================
-- Shift Panel Rendering
-- =========================================================
function WorkplaceHUD:drawShiftPanel(tracker, shiftActive)
    local s    = self.scale
    local pad  = self.BASE_PADDING     * s
    local rowH = self.BASE_ROW_HEIGHT  * s
    local w    = self.BASE_WIDTH * self.widthMult * s
    local ts   = self.BASE_TEXT_SMALL  * s
    local tm   = self.BASE_TEXT_MEDIUM * s

    local numRows  = 3
    local panelH   = pad * 2 + tm + numRows * rowH + rowH * 0.3
    local panelX   = self.posX - pad
    local panelY   = self.posY - pad
    local panelW   = w + pad * 2

    local renderer = getBaseGameRenderer()
    local usedNativePanel = renderer ~= nil and renderer.renderPanel ~= nil
        and renderer:renderPanel(panelX, panelY, panelW, panelH, self.COLORS.BG[4])
    if not usedNativePanel then
        -- Standalone fallback: retain the original graph_pixel shadow, fill and border.
        local so = 0.002 * s
        setOverlayColor(self.bgOverlay,
            self.COLORS.SHADOW[1], self.COLORS.SHADOW[2],
            self.COLORS.SHADOW[3], self.COLORS.SHADOW[4])
        renderOverlay(self.bgOverlay, panelX + so, panelY - so, panelW, panelH)

        setOverlayColor(self.bgOverlay,
            self.COLORS.BG[1], self.COLORS.BG[2],
            self.COLORS.BG[3], self.COLORS.BG[4])
        renderOverlay(self.bgOverlay, panelX, panelY, panelW, panelH)

        local bw = 0.001
        setOverlayColor(self.bgOverlay,
            self.COLORS.BORDER_NORM[1], self.COLORS.BORDER_NORM[2],
            self.COLORS.BORDER_NORM[3], self.COLORS.BORDER_NORM[4])
        renderOverlay(self.bgOverlay, panelX, panelY + panelH - bw, panelW, bw)  -- top
        renderOverlay(self.bgOverlay, panelX, panelY, panelW, bw)                -- bottom
        renderOverlay(self.bgOverlay, panelX, panelY, bw, panelH)                -- left
        renderOverlay(self.bgOverlay, panelX + panelW - bw, panelY, bw, panelH)  -- right
    end

    -- ---------------------------------------------------
    -- Edit mode overlay: pulsing border + handles + hint
    -- ---------------------------------------------------
    if self.editMode then
        local pulse = 0.5 + 0.5 * math.sin(self.animTimer * 4)
        local borderAlpha = 0.4 + 0.4 * pulse
        local ebw = 0.002

        local borderColor = self.COLORS.BORDER
        if self.resizing or self.edgeDragging then
            borderColor = self.COLORS.RESIZE_ACTIVE
        end
        setOverlayColor(self.bgOverlay, borderColor[1], borderColor[2], borderColor[3], borderAlpha)
        renderOverlay(self.bgOverlay, panelX, panelY + panelH - ebw, panelW, ebw)
        renderOverlay(self.bgOverlay, panelX, panelY, panelW, ebw)
        renderOverlay(self.bgOverlay, panelX, panelY, ebw, panelH)
        renderOverlay(self.bgOverlay, panelX + panelW - ebw, panelY, ebw, panelH)

        -- Left / right edge width handles
        local edgeHandleW = 0.004
        local edgeInset   = panelH * 0.15
        local edgeH       = panelH - edgeInset * 2
        local edgeY       = panelY + edgeInset
        local lc = (self.edgeDragging == "left")  and self.COLORS.RESIZE_ACTIVE or self.COLORS.RESIZE_HANDLE
        local rc = (self.edgeDragging == "right") and self.COLORS.RESIZE_ACTIVE or self.COLORS.RESIZE_HANDLE
        setOverlayColor(self.bgOverlay, lc[1], lc[2], lc[3], lc[4])
        renderOverlay(self.bgOverlay, panelX - edgeHandleW / 2, edgeY, edgeHandleW, edgeH)
        setOverlayColor(self.bgOverlay, rc[1], rc[2], rc[3], rc[4])
        renderOverlay(self.bgOverlay, panelX + panelW - edgeHandleW / 2, edgeY, edgeHandleW, edgeH)

        -- Corner resize handles
        local handles = self:getResizeHandleRects()
        for key, rect in pairs(handles) do
            local hc
            if self.resizing then
                hc = self.COLORS.RESIZE_ACTIVE
            elseif self.hoverCorner == key then
                hc = self.COLORS.RESIZE_HANDLE_HOVER
            else
                hc = self.COLORS.RESIZE_HANDLE
            end
            setOverlayColor(self.bgOverlay, hc[1], hc[2], hc[3], hc[4])
            renderOverlay(self.bgOverlay, rect.x, rect.y, rect.w, rect.h)
        end

        -- Hint text below panel
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextBold(false)
        setTextColor(self.COLORS.HINT[1], self.COLORS.HINT[2],
                     self.COLORS.HINT[3], self.COLORS.HINT[4])
        local hintText = g_i18n:getText("wt_hud_edit_hint") or "Drag | Corners=Scale | Edges=Width | Edit/Move key to exit"
        local scaleStr = string.format(" (%d%%)", math.floor(self.scale * 100 + 0.5))
        renderText(self.posX, panelY - ts * 1.4, ts * 0.85, hintText .. scaleStr)
        setTextColor(1, 1, 1, 1)
    end

    -- Pulsing green left accent bar (only when shift active)
    if shiftActive then
        local pulse = 0.6 + 0.4 * math.sin(self.animTimer * 2.5)
        setOverlayColor(self.bgOverlay,
            self.COLORS.EARN_COLOR[1], self.COLORS.EARN_COLOR[2],
            self.COLORS.EARN_COLOR[3], pulse * 0.85)
        renderOverlay(self.bgOverlay, panelX, panelY, 0.003, panelH)
    end

    -- Header: "ON SHIFT" or edit mode placeholder
    local headerY = panelY + panelH - pad - tm
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(true)
    setTextColor(self.COLORS.HEADER[1], self.COLORS.HEADER[2],
                 self.COLORS.HEADER[3], self.COLORS.HEADER[4])
    if shiftActive then
        renderText(self.posX, headerY, tm, g_i18n:getText("wt_hud_on_shift") or "ON SHIFT")
    else
        renderText(self.posX, headerY, tm, g_i18n:getText("wt_hud_edit_mode") or "HUD EDIT MODE")
    end
    setTextBold(false)

    if not shiftActive then
        setTextColor(1, 1, 1, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        return
    end

    -- Row 1: Workplace name
    local row1Y = headerY - rowH * 1.1
    local workplaceName = tracker:getActiveWorkplaceName() or "Workplace"
    if string.len(workplaceName) > 24 then
        workplaceName = string.sub(workplaceName, 1, 22) .. ".."
    end
    setTextColor(self.COLORS.LABEL[1], self.COLORS.LABEL[2],
                 self.COLORS.LABEL[3], self.COLORS.LABEL[4])
    renderText(self.posX, row1Y, ts, g_i18n:getText("wt_hud_location") or "Location:")
    setTextColor(self.COLORS.VALUE[1], self.COLORS.VALUE[2],
                 self.COLORS.VALUE[3], self.COLORS.VALUE[4])
    setTextAlignment(RenderText.ALIGN_RIGHT)
    renderText(self.posX + w, row1Y, ts, workplaceName)
    setTextAlignment(RenderText.ALIGN_LEFT)

    -- Row 2: Elapsed time
    local row2Y = row1Y - rowH
    local hours   = tracker:getElapsedHours()
    local minutes = math.floor((hours - math.floor(hours)) * 60)
    local timeStr = string.format("%dh %02dm", math.floor(hours), minutes)
    setTextColor(self.COLORS.LABEL[1], self.COLORS.LABEL[2],
                 self.COLORS.LABEL[3], self.COLORS.LABEL[4])
    renderText(self.posX, row2Y, ts, g_i18n:getText("wt_hud_time") or "Time:")
    setTextColor(self.COLORS.VALUE[1], self.COLORS.VALUE[2],
                 self.COLORS.VALUE[3], self.COLORS.VALUE[4])
    setTextAlignment(RenderText.ALIGN_RIGHT)
    renderText(self.posX + w, row2Y, ts, timeStr)
    setTextAlignment(RenderText.ALIGN_LEFT)

    -- Row 3: Current earnings (only if setting enabled)
    local cfg = self.system and self.system.settings
    if not cfg or cfg.showEarningsInHud ~= false then
        local row3Y = row2Y - rowH
        local earnings    = tracker:getCurrentEarnings()
        local earningsStr = string.format("$%d", earnings)
        setTextColor(self.COLORS.LABEL[1], self.COLORS.LABEL[2],
                     self.COLORS.LABEL[3], self.COLORS.LABEL[4])
        renderText(self.posX, row3Y, ts, g_i18n:getText("wt_hud_earned") or "Earned:")
        setTextColor(self.COLORS.EARN_COLOR[1], self.COLORS.EARN_COLOR[2],
                     self.COLORS.EARN_COLOR[3], self.COLORS.EARN_COLOR[4])
        setTextAlignment(RenderText.ALIGN_RIGHT)
        renderText(self.posX + w, row3Y, ts, earningsStr)
        setTextAlignment(RenderText.ALIGN_LEFT)
    end

    -- Reset text state
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

-- =========================================================
-- Flash Notification Rendering
-- =========================================================
function WorkplaceHUD:drawFlash()
    if not self.flashMessage or not self.bgOverlay then return end

    local s   = self.scale
    local pad = self.BASE_PADDING    * s
    local ts  = self.BASE_TEXT_SMALL * s
    local w   = self.BASE_WIDTH * self.widthMult * s

    -- Split message on \n
    local lines = {}
    for line in (self.flashMessage .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then table.insert(lines, line) end
    end
    if #lines == 0 then lines = {self.flashMessage} end

    -- Measure required width from the longest line.
    -- FS25 renderText uses normalised screen height for text size.
    -- Average char width ≈ ts * 0.52 is a safe estimate for the default font.
    -- We add left/right padding and cap at 0.70 (leaves margin on a 16:9 screen).
    local CHAR_WIDTH_RATIO = 0.52
    local MAX_FLASH_WIDTH  = 0.70
    local minW = w + pad * 2    -- never narrower than the HUD panel
    local contentW = minW
    for _, line in ipairs(lines) do
        local lineW = #line * ts * CHAR_WIDTH_RATIO + pad * 2 + 0.008
        if lineW > contentW then contentW = lineW end
    end
    local flashW = math.min(contentW, MAX_FLASH_WIDTH)

    local lineSpacing = ts * 1.35
    local flashH  = pad + #lines * lineSpacing + pad * 0.5
    local flashX  = self.posX - pad
    -- If the box would bleed off the right edge, shift it left to fit
    if flashX + flashW > 0.98 then
        flashX = 0.98 - flashW
    end
    local _, panelY, _, panelH = self:getHUDRect()
    local baseY   = panelY + panelH + 0.008 * s

    -- Fade in/out
    local t = self.flashTimer
    local d = self.flashDuration
    local alpha = 1.0
    if t < 0.3 then
        alpha = t / 0.3
    elseif t > d - 1.0 then
        alpha = math.max(0, (d - t) / 1.0)
    end
    local pulse = 0.75 + 0.25 * math.sin(self.animTimer * 5)

    -- Background
    local c = self.flashColor
    setOverlayColor(self.bgOverlay,
        self.COLORS.FLASH_BG[1], self.COLORS.FLASH_BG[2],
        self.COLORS.FLASH_BG[3], self.COLORS.FLASH_BG[4] * alpha)
    renderOverlay(self.bgOverlay, flashX, baseY, flashW, flashH)

    -- Accent bar
    setOverlayColor(self.bgOverlay, c[1], c[2], c[3], (c[4] or 1) * alpha)
    renderOverlay(self.bgOverlay, flashX, baseY, 0.003, flashH)

    -- Text lines
    setTextAlignment(RenderText.ALIGN_LEFT)
    for i, line in ipairs(lines) do
        local lineY = baseY + flashH - pad - i * lineSpacing
        if i == 1 then
            setTextBold(true)
            setTextColor(c[1], c[2], c[3], alpha * pulse)
        else
            setTextBold(false)
            setTextColor(c[1], c[2], c[3], alpha * 0.85)
        end
        renderText(flashX + 0.008, lineY, ts, line)
    end
    setTextBold(false)

    -- Reset
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

-- =========================================================
-- Cleanup
-- =========================================================
function WorkplaceHUD:delete()
    if self.editMode then
        if g_inputBinding and g_inputBinding.setShowMouseCursor then
            g_inputBinding:setShowMouseCursor(false)
        end
        self.editMode     = false
        self.dragging     = false
        self.resizing     = false
        self.edgeDragging = nil
        self.hoverCorner  = nil
        self.savedCamRotX = nil
        self.savedCamRotY = nil
        self.savedCamRotZ = nil
    end

    if self.bgOverlay then
        delete(self.bgOverlay)
        self.bgOverlay = nil
    end
    self.isInitialized = false
    wtLog("Deleted")
end
-- =========================================================
-- Leave-Zone Warning Overlay
-- Called by WorkplaceShiftTracker:updateZoneCheck()
-- =========================================================
function WorkplaceHUD:showLeaveWarning(secondsLeft)
    self.leaveWarnActive     = true
    self.leaveWarnSecondsLeft = math.max(0, secondsLeft)
end

function WorkplaceHUD:hideLeaveWarning()
    self.leaveWarnActive      = false
    self.leaveWarnSecondsLeft = 0
end

function WorkplaceHUD:drawLeaveWarning()
    if not self.leaveWarnActive then return end
    if not self.bgOverlay then return end

    local secondsLeft = self.leaveWarnSecondsLeft or 10
    local t           = self.animTimer or 0

    -- Pulse: fast red blink, gets faster as time runs out
    local urgency  = 1.0 - (secondsLeft / 10.0)           -- 0=calm, 1=urgent
    local pulseHz  = 2.0 + urgency * 4.0                   -- 2 Hz -> 6 Hz
    local pulse    = 0.55 + 0.45 * math.abs(math.sin(t * pulseHz * math.pi))
    local alpha    = 0.82 * pulse

    -- Panel: centred horizontally, upper-centre vertically
    local panelW = 0.30
    local panelH = 0.072
    local panelX = 0.5 - panelW * 0.5
    local panelY = 0.72

    -- Red backdrop
    setOverlayColor(self.bgOverlay, 0.55, 0.04, 0.04, alpha * 0.88)
    renderOverlay(self.bgOverlay, panelX, panelY, panelW, panelH)

    -- Bright red border (top and bottom strips)
    local borderH = 0.0035
    setOverlayColor(self.bgOverlay, 1.0, 0.15, 0.15, alpha)
    renderOverlay(self.bgOverlay, panelX, panelY + panelH - borderH, panelW, borderH)
    renderOverlay(self.bgOverlay, panelX, panelY,                    panelW, borderH)

    -- Main warning text
    local tsLarge = 0.020
    local tsMed   = 0.014
    local cx      = 0.5

    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextBold(true)
    setTextColor(1.0, 0.2, 0.2, alpha)
    renderText(cx, panelY + panelH - 0.025, tsLarge,
        g_i18n:getText("wt_warn_title") or "RETURN TO WORK AREA")

    -- Countdown line
    setTextBold(false)
    local countdownStr
    if secondsLeft > 0.5 then
        countdownStr = string.format(
            g_i18n:getText("wt_warn_countdown") or "Shift cancels in %d seconds",
            math.ceil(secondsLeft))
    else
        countdownStr = g_i18n:getText("wt_warn_cancelling") or "Cancelling shift..."
    end
    setTextColor(1.0, 0.75, 0.75, alpha)
    renderText(cx, panelY + 0.018, tsMed, countdownStr)

    -- Reset
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

-- =========================================================
-- BUILD 17:57 + ATTN 18:02 (hot-reload guide Part 2): force-patch the live
-- instance after a Ctrl+R reload - g_WorkplaceSystem global; holds .hud.
if g_WorkplaceSystem ~= nil and g_WorkplaceSystem.hud ~= nil then
    local inst = g_WorkplaceSystem.hud
    for k, v in pairs(WorkplaceHUD) do
        if type(v) == "function" then
            inst[k] = v
        end
    end
end
