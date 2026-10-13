-- =========================================================
-- WTMapHotspot.lua
-- Per-trigger map icon renderer for Workplace Triggers.
--
-- APPROACH: Direct drawFields hook (NOT addMapHotspot).
-- Using g_currentMission:addMapHotspot requires matching an
-- undocumented MapHotspot.CATEGORY_* integer so the game's
-- filter passes the hotspot to drawHotspot().  Getting it
-- wrong means the hotspot is silently skipped every frame.
--
-- Instead we hook ingameMap.drawFields (same technique as
-- NPCFavor, FS25_AutoDrive, etc.) and call our own render
-- directly, bypassing the filter entirely.
--
-- Each WTMapHotspot owns:
--   - A coloured icon Overlay (mod's icon_wt.png, or fallback
--     to a plain-colour tile with "W")
--   - A name-label drawn via renderText above the icon
--   - Green tint = idle, Gold tint = shift active
--
-- The hook is installed once from WorkplaceTriggerManager
-- after loadMission00Finished fires.  Each frame it iterates
-- self.triggers (held by the manager) and calls
-- hotspot:drawOnMap(map) for each one.
-- =========================================================

WTMapHotspot = WTMapHotspot or {}
WTMapHotspot_mt = Class(WTMapHotspot)   -- gives instances isa()

-- Size constants (normalised screen units)
WTMapHotspot.ICON_W    = 0.018   -- icon width
WTMapHotspot.ICON_H    = 0.018   -- icon height (square)
WTMapHotspot.TEXT_SIZE = 0.009   -- label height
WTMapHotspot.LABEL_GAP = 0.004   -- gap between icon top and label bottom

-- Idle  (green tones matching the "OTHERS" category)
WTMapHotspot.C_IDLE      = {0.20, 0.75, 0.30, 1.00}   -- icon tint
WTMapHotspot.C_IDLE_TXT  = {0.85, 1.00, 0.88, 0.95}   -- label

-- Active shift  (gold / amber)
WTMapHotspot.C_ACT       = {1.00, 0.75, 0.10, 1.00}
WTMapHotspot.C_ACT_TXT   = {1.00, 0.96, 0.70, 0.98}

-- Named farm site (WT-8): blue, a place marker rather than a job offer.
WTMapHotspot.C_SITE      = {0.25, 0.55, 0.95, 1.00}
WTMapHotspot.C_SITE_TXT  = {0.80, 0.90, 1.00, 0.95}

-- Constructor
function WTMapHotspot.new(modDirectory)
    local self = setmetatable({}, WTMapHotspot_mt)
    self.modDirectory   = modDirectory or ""
    self.isActive       = false
    self.worldX         = 0
    self.worldZ         = 0
    self.name           = "Workplace"
    self.style          = "workplace"   -- or "site" (WT-8)
    self._iconOverlay   = nil
    self._bgOverlay     = nil    -- plain-colour fallback background
    self._overlaysReady = false
    return self
end

function WTMapHotspot:setWorldPosition(x, z)
    self.worldX = x or 0
    self.worldZ = z or 0
end

function WTMapHotspot:setName(name)
    self.name = name or "Workplace"
end

function WTMapHotspot:setIsActive(active)
    self.isActive = active == true
end

--- "workplace" (default) or "site": a site draws in the site colours and
--- never takes the active-shift tint.
function WTMapHotspot:setStyle(style)
    self.style = (style == "site") and "site" or "workplace"
end

-- Overlay lazy init
function WTMapHotspot:ensureOverlays()
    if self._overlaysReady then return end
    self._overlaysReady = true

    -- Try to load the mod's own icon PNG
    if self.modDirectory ~= "" then
        local path = Utils.getFilename("icon_wt.png", self.modDirectory)
        if path then
            local ok, ov = pcall(Overlay.new, path, 0, 0,
                WTMapHotspot.ICON_W, WTMapHotspot.ICON_H)
            if ok and ov then self._iconOverlay = ov end
        end
    end

    -- Plain colour square fallback (always works)
    if g_overlayManager and g_plainColorSliceId then
        local ok, ov = pcall(function()
            return g_overlayManager:createOverlay(
                g_plainColorSliceId, 0, 0,
                WTMapHotspot.ICON_W, WTMapHotspot.ICON_H)
        end)
        if ok and ov then self._bgOverlay = ov end
    end
end

-- Delete
function WTMapHotspot:delete()
    if self._iconOverlay then
        self._iconOverlay:delete()
        self._iconOverlay = nil
    end
    if self._bgOverlay then
        self._bgOverlay:delete()
        self._bgOverlay = nil
    end
end

-- Draw on map (called every frame from the hook)
-- map = the IngameMap instance passed to drawFields
function WTMapHotspot:drawOnMap(map)
    if not map or not map.layout then return end

    -- World -> normalised map coords
    -- Pattern from NPCFavor / FS25 community mods
    local nx = (self.worldX + map.worldCenterOffsetX) / map.worldSizeX
               * map.mapExtensionScaleFactor + map.mapExtensionOffsetX
    local nz = (self.worldZ + map.worldCenterOffsetZ) / map.worldSizeZ
               * map.mapExtensionScaleFactor + map.mapExtensionOffsetZ

    local sx, sy, _, visible =
        map.layout:getMapObjectPosition(
            nx, nz,
            WTMapHotspot.ICON_W, WTMapHotspot.ICON_H,
            0, true)

    if not visible then return end

    self:ensureOverlays()

    local iconC = self.isActive and WTMapHotspot.C_ACT     or WTMapHotspot.C_IDLE
    local txtC  = self.isActive and WTMapHotspot.C_ACT_TXT or WTMapHotspot.C_IDLE_TXT
    if self.style == "site" then
        iconC = WTMapHotspot.C_SITE
        txtC  = WTMapHotspot.C_SITE_TXT
    end

    -- Draw icon (mod PNG on top of a coloured background square)
    if self._bgOverlay then
        self._bgOverlay:setPosition(sx, sy)
        self._bgOverlay:setDimension(WTMapHotspot.ICON_W, WTMapHotspot.ICON_H)
        self._bgOverlay:setColor(iconC[1], iconC[2], iconC[3], 0.85)
        self._bgOverlay:render()
    end
    if self._iconOverlay then
        self._iconOverlay:setPosition(sx, sy)
        self._iconOverlay:setDimension(WTMapHotspot.ICON_W, WTMapHotspot.ICON_H)
        self._iconOverlay:setColor(1, 1, 1, 1)   -- full white so PNG colours show
        self._iconOverlay:render()
    elseif not self._bgOverlay then
        -- Absolute fallback: text glyph
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(iconC[1], iconC[2], iconC[3], 1)
        setTextBold(true)
        renderText(sx + WTMapHotspot.ICON_W * 0.5,
                   sy + (WTMapHotspot.ICON_H - WTMapHotspot.TEXT_SIZE) * 0.5,
                   WTMapHotspot.TEXT_SIZE, self.style == "site" and "S" or "W")
        setTextBold(false)
        setTextColor(1, 1, 1, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
    end

    -- Name label centred above the icon
    -- (Only draw when map is not in its smallest mini-map state)
    if map.layout and map.layout.scale and map.layout.scale > 0.5 then
        local labelY = sy + WTMapHotspot.ICON_H + WTMapHotspot.LABEL_GAP
        local labelX = sx + WTMapHotspot.ICON_W * 0.5
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextBold(false)
        setTextColor(txtC[1], txtC[2], txtC[3], txtC[4])
        renderText(labelX, labelY, WTMapHotspot.TEXT_SIZE, self.name or "Workplace")
        setTextColor(1, 1, 1, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
    end
end
