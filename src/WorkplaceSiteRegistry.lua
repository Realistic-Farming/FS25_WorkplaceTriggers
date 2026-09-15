-- =========================================================
-- WorkplaceSiteRegistry.lua  (WT-8)
-- Purpose token registry for named farm sites.
-- =========================================================
-- A module-level table that exists from the moment this file is sourced, so
-- a consumer (StockGuard first) may register its purpose token before or
-- after WorkplaceTriggers finishes loading. Exported through getfenv(0) as
-- g_WorkplaceSiteRegistry, the same route main.lua uses for g_WorkplaceSystem,
-- because a table created in a mod file is otherwise private to that mod's
-- environment (mods.lua gives each mod its own env). The mission handle also
-- reaches it through registerSitePurpose (WorkplaceSiteService adapters).
--
-- Rules: a token is 1 to 64 bytes and XML-safe; class is FARM or WORLD; label
-- is a string of at most 128 bytes. A duplicate token with the same class is
-- ignored (still OK). WORLD tokens are accepted for wage triggers and never
-- offered by the site editor. Unknown tokens on existing sites are preserved
-- by the store, never rejected here.
-- =========================================================

WorkplaceSiteRegistry = WorkplaceSiteRegistry or {}

WorkplaceSiteRegistry.MAX_TOKEN_BYTES = 64
WorkplaceSiteRegistry.MAX_LABEL_BYTES = 128
WorkplaceSiteRegistry.CLASS_FARM  = "FARM"
WorkplaceSiteRegistry.CLASS_WORLD = "WORLD"

WorkplaceSiteRegistry._order  = WorkplaceSiteRegistry._order  or {}   -- tokens in registration order
WorkplaceSiteRegistry._byToken = WorkplaceSiteRegistry._byToken or {} -- token -> { class, label }

--- A token is XML-safe when it carries no markup or control characters.
function WorkplaceSiteRegistry.isValidToken(token)
    if type(token) ~= "string" or token == "" or #token > WorkplaceSiteRegistry.MAX_TOKEN_BYTES then
        return false
    end
    if token:find("[<>&\"'%c]") ~= nil then return false end
    if token:find("^%s") ~= nil or token:find("%s$") ~= nil then return false end
    return true
end

--- Register a purpose token. Returns true, "OK" or false, "INVALID_FIELDS".
function WorkplaceSiteRegistry.registerPurpose(token, spec)
    if not WorkplaceSiteRegistry.isValidToken(token) then return false, "INVALID_FIELDS" end
    if type(spec) ~= "table" then return false, "INVALID_FIELDS" end
    local class = spec.class
    if class ~= WorkplaceSiteRegistry.CLASS_FARM and class ~= WorkplaceSiteRegistry.CLASS_WORLD then
        return false, "INVALID_FIELDS"
    end
    local label = spec.label
    if type(label) ~= "string" or label == "" or #label > WorkplaceSiteRegistry.MAX_LABEL_BYTES then
        return false, "INVALID_FIELDS"
    end
    if label:find("[<>&%c]") ~= nil then return false, "INVALID_FIELDS" end

    local existing = WorkplaceSiteRegistry._byToken[token]
    if existing ~= nil then
        if existing.class == class then
            return true, "OK"   -- duplicate token plus class is ignored
        end
        return false, "INVALID_FIELDS"   -- a token never changes class
    end
    WorkplaceSiteRegistry._byToken[token] = { class = class, label = label }
    WorkplaceSiteRegistry._order[#WorkplaceSiteRegistry._order + 1] = token
    return true, "OK"
end

--- Known tokens in registration order, as detached copies.
---@param class string|nil  restrict to one class
function WorkplaceSiteRegistry.getPurposes(class)
    local out = {}
    for _, token in ipairs(WorkplaceSiteRegistry._order) do
        local spec = WorkplaceSiteRegistry._byToken[token]
        if spec ~= nil and (class == nil or spec.class == class) then
            out[#out + 1] = { token = token, class = spec.class, label = spec.label }
        end
    end
    return out
end

function WorkplaceSiteRegistry.getPurpose(token)
    local spec = WorkplaceSiteRegistry._byToken[token]
    if spec == nil then return nil end
    return { token = token, class = spec.class, label = spec.label }
end

function WorkplaceSiteRegistry.isFarmPurpose(token)
    local spec = WorkplaceSiteRegistry._byToken[token]
    return spec ~= nil and spec.class == WorkplaceSiteRegistry.CLASS_FARM
end

-- Export once, at source time, so another mod's mission-load code can see it.
if getfenv ~= nil then
    getfenv(0)["g_WorkplaceSiteRegistry"] = WorkplaceSiteRegistry
end

print("[WorkplaceTriggers] WorkplaceSiteRegistry loaded")
