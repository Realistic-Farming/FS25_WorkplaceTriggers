-- =========================================================
-- WorkplaceStateLedgerBridge.lua
-- Optional bridge to FS25_StateLedger.
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Workplace Triggers ships standalone, so this is strictly delegate-when-present:
--   * StateLedger installed  -> the master save file is the LOAD source of truth for
--     the trigger definitions (FS25_WorkplaceTriggers.xml is still written every save
--     as a safety copy, so removing the ledger later never loses data).
--   * StateLedger absent     -> nothing changes; FS25_WorkplaceTriggers.xml is primary
--     as always.
--
-- Only the trigger DEFINITIONS (+ the HUD layout) live here, mirroring exactly what
-- WorkplaceSaveLoad writes. The mod SETTINGS do NOT go through StateLedger: they are
-- SettingsHub's domain (WorkplaceSettingsHubBridge), matching the state-to-StateLedger
-- / settings-to-SettingsHub split every ecosystem mod follows.
--
-- On the first load after installing the ledger onto an existing save the ledger has
-- no block yet (deserialize delivers nil), so onMissionLoaded falls back to importing
-- FS25_WorkplaceTriggers.xml. From then on the ledger carries the state.
--
-- The cross-mod handle is g_currentMission.stateLedger (the bare g_stateLedger global
-- is only visible inside StateLedger's own mod environment). We force an idempotent
-- parseFile() right after registering so deserialize delivers NOW, before onMissionLoaded
-- decides the load source in the same phase (the hook-order timing gotcha).
-- =========================================================

WorkplaceStateLedgerBridge = {}

-- Provisional module id. This is the persistence KEY inside the master file, so it
-- must be locked with Claude(A) before any release (a later rename orphans saved
-- trigger data). Matches the name Point-1 registers and the <Mod>_<Thing> scheme.
-- (Arissani's readiness prose calls it "WorkplaceTriggers_Triggers"; Point-1's actual
-- registration code names it "WorkplaceTriggers_Data" -- flagged for the lock.)
WorkplaceStateLedgerBridge.MODULE_ID = "WorkplaceTriggers_Data"
WorkplaceStateLedgerBridge.SCHEMA    = 1

WorkplaceStateLedgerBridge.active       = false   -- ledger present and we registered
WorkplaceStateLedgerBridge.delivered    = false   -- deserialize has fired (once)
WorkplaceStateLedgerBridge.pendingState = nil     -- cached table from deserialize (nil = new/no block)

local function wtLog(msg)
    print("[WorkplaceTriggers] StateLedger: " .. tostring(msg))
end

-- Build the full trigger state: trigger definitions + HUD layout. Mirrors exactly
-- what WorkplaceSaveLoad:saveToXMLFile writes into FS25_WorkplaceTriggers.xml.
function WorkplaceStateLedgerBridge.buildState(sys)
    local out = { schema = WorkplaceStateLedgerBridge.SCHEMA, triggers = {} }
    if sys ~= nil and sys.triggerManager ~= nil then
        for _, t in ipairs(sys.triggerManager:getAllTriggers()) do
            out.triggers[#out.triggers + 1] = {
                id              = tostring(t.id or ""),
                name            = t.workplaceName or "Workplace",
                hourlyWage      = t.hourlyWage or 500,
                triggerRadius   = t.triggerRadius or 4,
                posX            = t.posX or 0,
                posY            = t.posY or 0,
                posZ            = t.posZ or 0,
                rotY            = t.rotY or 0,
                paySchedule     = t.paySchedule or "hourly",
                timeMultiplier  = t.timeMultiplier or 0,
                endShiftOnLeave = t.endShiftOnLeave ~= false,
            }
        end
    end
    if sys ~= nil and sys.hud ~= nil then
        out.hudLayout = {
            posX      = sys.hud.posX,
            posY      = sys.hud.posY,
            scale     = sys.hud.scale,
            widthMult = sys.hud.widthMult,
        }
    end
    return out
end

-- Apply the cached ledger state into the system. Twin of WorkplaceSaveLoad:loadFromXMLFile,
-- reading from the table instead of XML. Called only when hasLedgerState() is true, at
-- which point the trigger list is still empty (the own XML import was skipped), so this
-- registers into a clean manager with no clear needed.
function WorkplaceStateLedgerBridge.applyState(sys)
    local data = WorkplaceStateLedgerBridge.pendingState
    if type(data) ~= "table" or sys == nil then return false end

    local count = 0
    if type(data.triggers) == "table" and sys.triggerManager ~= nil then
        for _, t in ipairs(data.triggers) do
            -- Same shape WorkplaceSaveLoad:loadFromXMLFile builds (pure data object).
            sys.triggerManager:registerTrigger({
                id              = t.id,
                workplaceName   = t.name or "Workplace",
                hourlyWage      = t.hourlyWage or 500,
                triggerRadius   = t.triggerRadius or 4,
                posX            = t.posX or 0,
                posY            = t.posY or 0,
                posZ            = t.posZ or 0,
                paySchedule     = t.paySchedule or "hourly",
                timeMultiplier  = t.timeMultiplier or 0,
                endShiftOnLeave = t.endShiftOnLeave ~= false,
                playerInside    = false,
            })
            count = count + 1
        end
    end

    local hud = data.hudLayout
    if type(hud) == "table" and hud.posX ~= nil and sys.hud ~= nil then
        sys.hud:loadFromSettings({
            hudPosX      = hud.posX,
            hudPosY      = hud.posY,
            hudScale     = hud.scale,
            hudWidthMult = hud.widthMult,
        })
    end

    wtLog(string.format("Restored %d trigger(s) from StateLedger", count))
    return true
end

-- True when the ledger is the source of truth for this load (present, registered, and
-- it delivered an actual block). When present but empty, onMissionLoaded imports the
-- existing FS25_WorkplaceTriggers.xml instead.
function WorkplaceStateLedgerBridge.hasLedgerState()
    return WorkplaceStateLedgerBridge.active
        and WorkplaceStateLedgerBridge.delivered
        and WorkplaceStateLedgerBridge.pendingState ~= nil
end

-- Register with StateLedger if present, then force an idempotent parseFile so
-- deserialize delivers now (this runs in the same phase StateLedger parses, so hook
-- order would otherwise decide delivery). No-op if StateLedger is absent.
function WorkplaceStateLedgerBridge.register(sys)
    WorkplaceStateLedgerBridge.active       = false
    WorkplaceStateLedgerBridge.delivered    = false
    WorkplaceStateLedgerBridge.pendingState = nil

    local ledger = (g_currentMission ~= nil and g_currentMission.stateLedger) or g_stateLedger
    if ledger == nil then
        return
    end
    if sys == nil then return end

    local ok, err = pcall(function()
        ledger:registerModule(WorkplaceStateLedgerBridge.MODULE_ID, {
            serialize = function()
                return WorkplaceStateLedgerBridge.buildState(sys)
            end,
            deserialize = function(data)
                WorkplaceStateLedgerBridge.delivered    = true
                WorkplaceStateLedgerBridge.pendingState = data   -- nil on a brand-new save
            end,
        })
        -- Idempotent: forces delivery now if StateLedger has not parsed yet; a no-op
        -- when it already has (or when its own onMissionLoaded fires later).
        if ledger.parseFile ~= nil then
            ledger:parseFile()
        end
    end)

    if ok then
        WorkplaceStateLedgerBridge.active = true
        wtLog(string.format("Registered with StateLedger as '%s' (FS25_WorkplaceTriggers.xml kept as safety copy)",
            WorkplaceStateLedgerBridge.MODULE_ID))
    else
        wtLog("StateLedger registration failed: " .. tostring(err) .. " (falling back to own XML)")
    end
end
