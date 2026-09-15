-- WT-8: named farm sites contract.
--!load: src/WTMapHotspot.lua, src/WorkplaceSiteRegistry.lua, src/WorkplaceSiteStore.lua, src/WorkplaceSiteEvents.lua, src/WorkplaceSiteService.lua, src/WorkplaceSiteClient.lua
-- Part 1 is the delivered reference bar (Office Tyson/StockGuard-First-Family-
-- 2026-09-15/reference-tests/WT-8-named_site_contract_spec_test.lua), a
-- modeled contract kept as shipped minus its trailing summary call. Part 2
-- drives the built registry, store, service, events and client replica.
-- Nothing here proves native GUI, XML on disk, map drawing, MP timing or
-- gameplay.

-- =====================================================================
-- PART 1: the delivered reference bar (modeled)
-- =====================================================================
do
local nextId=1
local function create(farm,name,x,z,radius)
 local id="site-"..nextId;nextId=nextId+1
 return {siteId=id,farm=farm,name=name,x=x,z=z,radius=radius,state="ACTIVE",revision=1}
end
local function ordinary(rows,farm)
 local out={};for _,s in ipairs(rows)do if s.farm==farm and s.state=="ACTIVE" then out[#out+1]=s end end;return out
end
local function admin(rows,farm) local out={};for _,s in ipairs(rows)do if s.farm==farm then out[#out+1]=s end end;return out end
local a=create(1,"Main yard",0,0,50);local b=create(1,"North bins",40,0,30);local other=create(2,"Other",0,0,100)
T.ok("site ids are opaque and nonempty",#a.siteId>0)
T.ok("separate sites never reuse an id",a.siteId~=b.siteId)
T.eq("ordinary catalogue returns own active sites",#ordinary({a,b,other},1),2)
b.state="UNAVAILABLE";b.reason="MAP_MISMATCH"
T.eq("ordinary catalogue excludes unavailable site",#ordinary({a,b,other},1),1)
T.eq("admin recovery catalogue retains unavailable site",#admin({a,b,other},1),2)
T.eq("unavailable reason stays explicit",admin({a,b},1)[2].reason,"MAP_MISMATCH")
T.eq("another farm receives no site",#ordinary({a,b},3),0)
local function contains(s,x,z) local dx,dz=x-s.x,z-s.z;return dx*dx+dz*dz<=s.radius*s.radius end
T.eq("site uses its actual circular radius",contains(a,30,40),true)
T.eq("outside point is not a member",contains(a,51,0),false)
local stock={id="grain",amount=100};local memberships=0
for _,s in ipairs({a,b})do if contains(s,40,0)then memberships=memberships+1 end end
T.eq("overlap may place one stock in two information groups",memberships,2)
T.eq("overlap never duplicates physical quantity",stock.amount,100)
T.eq("site carries no wage",a.wage,nil)
T.eq("site carries no shift schedule",a.schedule,nil)
local purposeRegistry={}
local missionHandle={}
missionHandle.registerSitePurpose=function(token,spec)
 if type(token)~="string" or type(spec)~="table" then return false,"INVALID_FIELDS" end
 purposeRegistry[token]=spec.class
 return true,"OK"
end
local ok,reason=missionHandle.registerSitePurpose("stockguard.yard",{class="FARM",label="Yard"})
T.eq("dot-bound purpose registration succeeds",ok,true)
T.eq("dot-bound purpose registration returns owner result",reason,"OK")
T.eq("dot-bound closure receives token without implicit self",purposeRegistry["stockguard.yard"],"FARM")
local colonOk,colonReason=missionHandle:registerSitePurpose("wrong.call",{class="FARM",label="Wrong"})
T.eq("colon call is rejected because it shifts the bound arguments",colonOk,false)
T.eq("colon call exposes invalid fields rather than silent registration",colonReason,"INVALID_FIELDS")
T.eq("colon call cannot register the requested token",purposeRegistry["wrong.call"],nil)
local old=a.siteId;a.state="UNAVAILABLE";local replacement=create(1,"Main yard",0,0,50)
T.ok("recreated site receives a new id",replacement.siteId~=old)
T.eq("old unavailable id does not reactivate",a.state,"UNAVAILABLE")
end

-- =====================================================================
-- PART 2: the built provider
-- =====================================================================

-- Live farms and actors.
local FARMS = {}
local function setFarms(ids) for k in pairs(FARMS) do FARMS[k] = nil end for _, id in ipairs(ids) do FARMS[id] = { farmId = id } end end
g_farmManager = { getFarmById = function(_, id) return FARMS[id] end, mergedFarms = nil }
local ACTORS = {}   -- connection -> { farmId, user }
local LOCAL = { farmId = 1 }
g_currentMission.getFarmId = function(_, conn) if conn == nil then return LOCAL.farmId end local a = ACTORS[conn] return a and a.farmId or nil end
g_currentMission.userManager = { getUserByConnection = function(_, conn) local a = ACTORS[conn] return a and a.user or nil end }
g_currentMission.playerUserId = 1
-- Native permission: server local or master -> true; else farm manager on the matching farm.
g_currentMission.getHasPlayerPermission = function(_, perm, conn, farmId)
    if conn == nil then return true end
    local a = ACTORS[conn]
    if a == nil then return false end
    if a.user and a.user:getIsMasterUser() then return true end
    return a.isFarmManager == true and a.farmId == farmId
end
local function newConn(id) return { streamId = id, isConnected = true, isReadyForEvents = true, sent = {}, sendEvent = function(self, e) self.sent[#self.sent + 1] = e end } end
local function user(id, master) return { getId = function() return id end, getIsMasterUser = function() return master == true end } end

-- Deliver an event over the mock stream to the current g_WorkplaceSystem.
local function deliver(event, asServer, connection)
    local s = NewStream()
    event:writeStream(s, nil)
    g_currentMission._isServer = asServer
    local rx
    if event.eventClassName == "WTSiteViewRequestEvent" then rx = WTSiteViewRequestEvent.emptyNew()
    elseif event.eventClassName == "WTSiteViewStateEvent" then rx = WTSiteViewStateEvent.emptyNew()
    elseif event.eventClassName == "WTSiteCommandRequestEvent" then rx = WTSiteCommandRequestEvent.emptyNew()
    else rx = WTSiteCommandResultEvent.emptyNew() end
    rx:readStream(s, connection)
    return rx
end

local function newSystem()
    local sys = { isInitialized = true, modDirectory = "" }
    sys.siteService = WorkplaceSiteService.new(sys)
    sys.siteClient = WorkplaceSiteClient.new(sys)
    WorkplaceSiteService.installAdapters(sys, sys)
    return sys
end

-- (A) Registry: validation, order, duplicates, dot-bound adapter.
do
    local ok, why = WorkplaceSiteRegistry.registerPurpose("stockguard.yard", { class = "FARM", label = "Yard" })
    T.eq("A1 FARM token registers", ok, true)
    T.eq("A2 result OK", why, "OK")
    T.eq("A3 duplicate token and class is ignored, still OK", (WorkplaceSiteRegistry.registerPurpose("stockguard.yard", { class = "FARM", label = "Again" })), true)
    T.eq("A4 label of the first registration stays", WorkplaceSiteRegistry.getPurpose("stockguard.yard").label, "Yard")
    T.eq("A5 class change on a known token refused", (WorkplaceSiteRegistry.registerPurpose("stockguard.yard", { class = "WORLD", label = "x" })), false)
    T.eq("A6 markup in a token refused", (WorkplaceSiteRegistry.registerPurpose("bad<token", { class = "FARM", label = "x" })), false)
    T.eq("A7 65-byte token refused", (WorkplaceSiteRegistry.registerPurpose(string.rep("a", 65), { class = "FARM", label = "x" })), false)
    T.eq("A8 WORLD token accepted", (WorkplaceSiteRegistry.registerPurpose("coop.home", { class = "WORLD", label = "Co-op" })), true)
    T.eq("A9 editor list offers FARM tokens only", #WorkplaceSiteRegistry.getPurposes("FARM"), 1)
    T.eq("A10 registration order kept", WorkplaceSiteRegistry.getPurposes()[2].token, "coop.home")
    T.ok("A11 exported through getfenv", g_WorkplaceSiteRegistry == WorkplaceSiteRegistry)
    local sys = newSystem()
    local okD, whyD = sys.registerSitePurpose("compost.yard", { class = "FARM", label = "Compost" })
    T.eq("A12 mission adapter delegates to the registry", okD, true)
    T.eq("A13 adapter returns the registry's result", whyD, "OK")
    local okC, whyC = sys:registerSitePurpose("colon.call", { class = "FARM", label = "Wrong" })
    T.eq("A14 colon call on the adapter is refused", okC, false)
    T.eq("A15 with INVALID_FIELDS", whyC, "INVALID_FIELDS")
    T.eq("A16 colon call registered nothing", WorkplaceSiteRegistry.getPurpose("colon.call"), nil)
end

-- (B) Store: validation, ids, revisions, listing, counter, XML and container round trips.
do
    local st = WorkplaceSiteStore.new()
    st:stageEmpty("map01", 2048)
    st:finalizeOwners(function() return true end, nil)
    local r, why = st:create(1, { name = "Main Yard", purpose = "", centreX = 10, centreZ = 20, radiusMetres = 50 })
    T.ok("B1 create ok", r ~= nil)
    T.eq("B2 first id", r.siteId, "site_1")
    T.eq("B3 revision starts at 1", r.revision, "1")
    T.eq("B4 spectator owner refused", select(2, st:create(0, { name = "x", centreX = 0, centreZ = 0, radiusMetres = 5 })), "INVALID_FARM")
    T.eq("B5 empty name refused", select(2, st:create(1, { name = "", centreX = 0, centreZ = 0, radiusMetres = 5 })), "INVALID_FIELDS")
    T.eq("B6 129-byte name refused", select(2, st:create(1, { name = string.rep("n", 129), centreX = 0, centreZ = 0, radiusMetres = 5 })), "INVALID_FIELDS")
    T.eq("B7 radius below 1 m refused", select(2, st:create(1, { name = "x", centreX = 0, centreZ = 0, radiusMetres = 0.5 })), "OUT_OF_BOUNDS")
    T.eq("B8 radius above the diagonal refused", select(2, st:create(1, { name = "x", centreX = 0, centreZ = 0, radiusMetres = 2048 * 1.5 })), "OUT_OF_BOUNDS")
    T.eq("B9 centre outside the terrain refused", select(2, st:create(1, { name = "x", centreX = 5000, centreZ = 0, radiusMetres = 5 })), "OUT_OF_BOUNDS")
    T.eq("B10 NaN centre refused", select(2, st:create(1, { name = "x", centreX = 0/0, centreZ = 0, radiusMetres = 5 })), "INVALID_FIELDS")
    local u = st:update("site_1", { name = "Main Yard", purpose = "stockguard.yard", centreX = 10, centreZ = 20, radiusMetres = 60 })
    T.eq("B11 update advances revision", u.revision, "2")
    local b = st:create(1, { name = "North", centreX = 100, centreZ = 100, radiusMetres = 30 })
    local o = st:create(2, { name = "Other", centreX = 0, centreZ = 0, radiusMetres = 10 })
    T.eq("B12 own farm ACTIVE listing", #st:listForFarm(1, false), 2)
    T.eq("B13 other farm sees none of them", #st:listForFarm(3, false), 0)
    st:delete("site_2")
    local again = st:create(1, { name = "North", centreX = 100, centreZ = 100, radiusMetres = 30 })
    T.eq("B14 a deleted id is never reissued", again.siteId, "site_4")
    st:markFarmUnavailable(2)
    T.eq("B15 farm deletion marks its site UNAVAILABLE", st:get("site_3").state, "UNAVAILABLE")
    T.eq("B16 with reason", st:get("site_3").reason, "FARM_DELETED")
    T.eq("B17 ordinary listing hides it", #st:listForFarm(2, false), 0)
    T.eq("B18 administration listing of farm 1 includes the orphan of missing farm 2", #st:listForAdministration(1, function(id) return id == 1 end), 3)
    T.eq("B19 transfer moves and re-activates", st:transfer("site_3", 1).state, "ACTIVE")
    T.eq("B20 transfer advanced the revision again (deletion mark was 2)", st:get("site_3").revision, "3")

    -- Container round trip through the mock XML and back.
    local c = st:serialize("map01", 2048)
    local xml = NewXmlMock()
    WorkplaceSiteStore.writeXML(xml, c)
    T.eq("B21 xml schema stamp", xml.store["workplaceSites#siteSchemaVersion"], 1)
    T.eq("B22 xml counter as a string", xml.store["workplaceSites#nextSiteCounter"], "5")
    local back = WorkplaceSiteStore.readXML(xml)
    T.eq("B23 xml reads back the site count", #back.sites, 3)
    local st2 = WorkplaceSiteStore.new()
    st2:stageContainer(back, "map01", 2048)
    T.eq("B24 staged container keeps the counter", st2.nextSiteCounter, "5")
    T.eq("B25 staged container is not mismatched on the same map", st2.containerState, "OK")
    T.eq("B26 staged, not yet ready", st2:isReady(), false)
    -- Counter restores as the greater of persisted and highest parsed plus one.
    back.nextSiteCounter = "2"
    local st3 = WorkplaceSiteStore.new()
    st3:stageContainer(back, "map01", 2048)
    T.eq("B27 counter never drops below highest site plus one", st3.nextSiteCounter, "5")
    T.eq("B28 an unknown schema is not a known container", WorkplaceSiteStore.isKnownContainer({ siteSchemaVersion = 9 }), false)
    T.eq("B29 nil is not delivered", WorkplaceSiteStore.isKnownContainer(nil), false)
    T.eq("B30 empty table is not delivered", WorkplaceSiteStore.isKnownContainer({}), false)
end

-- (C) Map mismatch and owner finalization (persisted UNAVAILABLE first, merge, missing owner).
do
    local c = { siteSchemaVersion = 1, mapId = "map01", terrainSize = 2048, nextSiteCounter = "4", sites = {
        { siteId = "site_1", ownerFarmId = 3, purpose = "", name = "Old", centreX = 1, centreZ = 1, radiusMetres = 5, revision = "3", state = "UNAVAILABLE", reason = "FARM_DELETED" },
        { siteId = "site_2", ownerFarmId = 4, purpose = "", name = "Merged", centreX = 1, centreZ = 1, radiusMetres = 5, revision = "1", state = "ACTIVE", reason = "" },
        { siteId = "site_3", ownerFarmId = 7, purpose = "", name = "Gone", centreX = 1, centreZ = 1, radiusMetres = 5, revision = "2", state = "ACTIVE", reason = "" },
    } }
    local st = WorkplaceSiteStore.new()
    st:stageContainer(c, "map01", 2048)
    st:finalizeOwners(function(id) return id == 1 end, { [4] = 1 })
    T.eq("C1 persisted UNAVAILABLE stays and keeps its owner", st:get("site_1").ownerFarmId, 3)
    T.eq("C2 persisted UNAVAILABLE keeps its revision", st:get("site_1").revision, "3")
    T.eq("C3 merged farm rewrites the owner", st:get("site_2").ownerFarmId, 1)
    T.eq("C4 and advances the revision", st:get("site_2").revision, "2")
    T.eq("C5 missing owner becomes UNAVAILABLE", st:get("site_3").state, "UNAVAILABLE")
    T.eq("C6 with OWNER_MISSING", st:get("site_3").reason, "OWNER_MISSING")
    T.eq("C7 finalize is idempotent", st:finalizeOwners(function() return true end, nil), false)

    local mm = WorkplaceSiteStore.new()
    mm:stageContainer(c, "map02", 2048)
    T.eq("C8 different mapId is MAP_MISMATCH", mm.containerState, "MAP_MISMATCH")
    mm:finalizeOwners(function() return true end, nil)
    T.eq("C9 mismatch: every site reads UNAVAILABLE", #mm:listForFarm(4, false), 0)
    T.eq("C10 mismatch: stamps are never rewritten", mm:serialize("map02", 2048).mapId, "map01")
    T.eq("C11 mismatch: transfer refused", select(2, mm:transfer("site_2", 1)), "MAP_MISMATCH")
    T.ok("C12 mismatch: delete allowed", mm:delete("site_2") ~= nil)
    local ts = WorkplaceSiteStore.new()
    ts:stageContainer(c, "map01", 4096)
    T.eq("C13 different terrain size is MAP_MISMATCH", ts.containerState, "MAP_MISMATCH")
    local mm2 = WorkplaceSiteStore.new()
    mm2:stageContainer(c, "map01", 2048)
    T.eq("C14 a later load on the original map recovers", mm2.containerState, "OK")
end

-- (D) Service: local host, permission fence, session and sequence discipline.
do
    setFarms({ 1, 2 })
    LOCAL.farmId = 1
    g_currentMission._isServer = true
    g_currentMission.isLoaded = true
    g_currentMission.numLoadingTasks = 0
    local sys = newSystem()
    g_WorkplaceSystem = sys
    sys.siteService:initialize()
    T.eq("D1 capabilities READY after finalization", sys.getSiteCapabilities().ready, true)
    local view = sys.siteClient.view
    T.eq("D2 local host got its view in process", view and view.availability, "READY")
    T.ok("D3 local host has a command session", view.commandSessionId ~= nil)
    T.eq("D4 first sequence is 1", view.nextSequence, "1")

    local created
    local result = sys.siteClient:sendCommand("CREATE_SITE", { name = "Main Yard", purpose = "stockguard.yard", centreX = 10, centreZ = 20, radiusMetres = 100 }, function(r) created = r end)
    T.eq("D5 host create applied", result.outcome, "APPLIED")
    T.eq("D6 result carries the created target", result.currentTarget.siteId, "site_1")
    T.eq("D7 nextSequence advanced", result.nextSequence, "2")
    T.eq("D8 replica replaced after the command", #sys.siteClient.view.sites, 1)
    T.eq("D9 replica nextSequence follows the result", sys.siteClient.view.nextSequence, "2")
    T.eq("D10 a hotspot was created for the own-farm site", #sys.siteClient:getHotspotList(), 1)

    -- Sequence discipline: a repeated pair returns the retained result; a wrong sequence is refused.
    local s = sys.siteService.sessions["local"]
    local retry = sys.siteService:handleLocalCommand({ commandSessionId = s.commandSessionId, sequence = "1", actionId = "CREATE_SITE", name = "Main Yard", purpose = "", centreX = 10, centreZ = 20, radiusMetres = 100 })
    T.eq("D11 retry of the consumed pair returns the original site", retry.currentTarget.siteId, "site_1")
    T.eq("D12 and creates no second site", #sys.siteService.store.records, 1)
    local skip = sys.siteService:handleLocalCommand({ commandSessionId = s.commandSessionId, sequence = "5", actionId = "CREATE_SITE", name = "x", purpose = "", centreX = 0, centreZ = 0, radiusMetres = 5 })
    T.eq("D13 a sequence that is not next is COMMAND_OUTSTANDING", skip.reasonCode, "COMMAND_OUTSTANDING")
    T.eq("D14 and consumed nothing", sys.siteService.sessions["local"].nextSequence, 2)
    local bad = sys.siteService:handleLocalCommand({ commandSessionId = "nope", sequence = "2", actionId = "DELETE_SITE", targetId = "site_1", expectedRevision = "1" })
    T.eq("D15 a foreign session id is SESSION_WITHDRAWN", bad.reasonCode, "SESSION_WITHDRAWN")
    local v2 = sys.siteClient.view
    T.eq("D16 but the actor's current session is retained and republished", v2.commandSessionId, s.commandSessionId)

    -- Stale revision: two edits against one revision.
    local site = sys.siteClient.view.sites[1]
    local e1 = sys.siteClient:sendCommand("UPDATE_SITE", { targetId = site.siteId, expectedRevision = site.revision, name = "Yard A", purpose = "", centreX = 10, centreZ = 20, radiusMetres = 80 })
    T.eq("D17 first edit applied", e1.outcome, "APPLIED")
    local e2 = sys.siteClient:sendCommand("UPDATE_SITE", { targetId = site.siteId, expectedRevision = site.revision, name = "Yard B", purpose = "", centreX = 10, centreZ = 20, radiusMetres = 70 })
    T.eq("D18 second edit against the old revision is STALE_REVISION", e2.reasonCode, "STALE_REVISION")
    T.eq("D19 with the current definition", e2.currentTarget.name, "Yard A")
    T.eq("D20 a refused command still consumed its sequence", sys.siteClient.view.nextSequence, tostring(tonumber(e1.nextSequence) + 1))

    -- Own-farm fence for the host: another farm's site is UNAUTHORIZED even though native would pass.
    local other = sys.siteService.store:create(2, { name = "Theirs", centreX = 0, centreZ = 0, radiusMetres = 5 })
    local fence = sys.siteClient:sendCommand("DELETE_SITE", { targetId = other.siteId, expectedRevision = other.revision })
    T.eq("D21 host outside an administration context cannot touch another farm's site", fence.reasonCode, "UNAUTHORIZED")
    -- administrationTargetFarmId on UPDATE/DELETE is INVALID_FIELDS.
    local badField = sys.siteClient:sendCommand("DELETE_SITE", { targetId = other.siteId, expectedRevision = other.revision, administrationTargetFarmId = 2 })
    T.eq("D22 administrationTargetFarmId on DELETE is INVALID_FIELDS", badField.reasonCode, "INVALID_FIELDS")
    -- Administration context: the host administers farm 2.
    T.eq("D23 host enters administration of farm 2", (sys.siteService:setAdministrationContext(nil, 2)), true)
    T.eq("D24 the administration replica lists farm 2", sys.siteClient.adminView.administrationTargetFarmId, 2)
    T.eq("D25 the administration replica carries farm 2's site", sys.siteClient.adminView.sites[1].name, "Theirs")
    T.eq("D25b the ordinary replica stays the own farm", sys.siteClient.view.administrationTargetFarmId, nil)
    T.eq("D25c the ordinary replica marks the context active", sys.siteClient.view.administrationActive, true)
    local adminDel = sys.siteClient:sendCommand("DELETE_SITE", { targetId = other.siteId, expectedRevision = other.revision })
    T.eq("D26 in administration the delete applies", adminDel.outcome, "APPLIED")
    T.eq("D27 administering a missing farm is refused", (sys.siteService:setAdministrationContext(nil, 9)), false)
    sys.siteService:setAdministrationContext(nil, nil)
    T.eq("D28 leaving administration drops the administration replica", sys.siteClient.adminView, nil)
    T.eq("D28b the manager view is the own farm again", sys.siteClient:getManagerView().administrationTargetFarmId, nil)
    T.eq("D29 spectator farm cannot own a site", (sys.siteService.store:create(0, { name = "x", centreX = 0, centreZ = 0, radiusMetres = 5 })), nil)
end

-- (E) Remote clients: view request, private filtered view, command wire, farm manager vs plain member.
do
    setFarms({ 1, 2 })
    LOCAL.farmId = 1
    g_currentMission._isServer = true
    local server = newSystem()
    g_WorkplaceSystem = server
    server.siteService:initialize()
    server.siteService.store:create(1, { name = "Farm1 Yard", centreX = 1, centreZ = 1, radiusMetres = 50 })
    server.siteService.store:create(2, { name = "Farm2 Yard", centreX = 2, centreZ = 2, radiusMetres = 50 })

    local c2 = newConn(5)   -- a farm manager on farm 2
    ACTORS[c2] = { farmId = 2, user = user(20, false), isFarmManager = true }
    local c3 = newConn(6)   -- a plain member of farm 2
    ACTORS[c3] = { farmId = 2, user = user(30, false), isFarmManager = false }
    local spec = newConn(7) -- a spectator
    ACTORS[spec] = { farmId = 0, user = user(40, false) }

    deliver(WTSiteViewRequestEvent.new(""), true, c2)
    T.eq("E1 view request answered with one state event", #c2.sent, 1)
    local client2 = newSystem()
    g_WorkplaceSystem = client2
    deliver(c2.sent[1], false, nil)
    local v = client2.siteClient.view
    T.eq("E2 client replica READY", v.availability, "READY")
    T.eq("E3 only the client's farm's site travels", #v.sites, 1)
    T.eq("E4 and it is farm 2's", v.sites[1].name, "Farm2 Yard")
    T.eq("E5 farm manager gets a command session", v.commandSessionId ~= nil, true)
    T.eq("E6 client capability READY", client2.getSiteCapabilities().ready, true)
    T.eq("E7 client read through the adapter", (client2.getSitesForFarm())[1].name, "Farm2 Yard")

    -- Client command over the wire: create a site on farm 2.
    g_WorkplaceSystem = client2
    g_client = { getServerConnection = function() return c2 end }
    local sentBefore = #c2.sent
    local got
    client2.siteClient:sendCommand("CREATE_SITE", { name = "Bins", purpose = "", centreX = 5, centreZ = 5, radiusMetres = 20 }, function(r) got = r end)
    T.eq("E8 client sent one command event", #c2.sent - sentBefore, 1)
    local reqEvent = c2.sent[#c2.sent]
    g_WorkplaceSystem = server
    drainCount = #c2.sent
    deliver(reqEvent, true, c2)
    T.ok("E9 server answered with a result event and a republished view", #c2.sent >= drainCount + 1)
    local resultEvent, viewEvent
    for i = drainCount + 1, #c2.sent do
        local e = c2.sent[i]
        if e.eventClassName == "WTSiteCommandResultEvent" then resultEvent = e end
        if e.eventClassName == "WTSiteViewStateEvent" then viewEvent = e end
    end
    g_WorkplaceSystem = client2
    deliver(resultEvent, false, nil)
    T.eq("E10 client received APPLIED", got.outcome, "APPLIED")
    T.eq("E11 created id", got.currentTarget.siteId, "site_3")
    if viewEvent then deliver(viewEvent, false, nil) end
    T.eq("E12 client replica now has two farm 2 sites", #client2.siteClient.view.sites, 2)
    T.eq("E13 replica nextSequence follows", client2.siteClient.view.nextSequence, got.nextSequence)

    -- A plain member with no updateFarm right is refused; a spectator has no session.
    g_WorkplaceSystem = server
    deliver(WTSiteViewRequestEvent.new(""), true, c3)
    local client3 = newSystem()
    g_WorkplaceSystem = client3
    deliver(c3.sent[1], false, nil)
    T.ok("E14 plain member still sees the farm's sites", #client3.siteClient.view.sites == 2)
    local s3 = server.siteService.sessions[c3]
    T.ok("E15 plain member gets a session (eligibility is farm membership; permission is per command)", s3 ~= nil)
    g_WorkplaceSystem = server
    local refused = server.siteService:handleCommandFromConnection(c3, { commandSessionId = s3.commandSessionId, sequence = "1", actionId = "CREATE_SITE", name = "x", purpose = "", centreX = 0, centreZ = 0, radiusMetres = 5 })
    T.eq("E16 plain member without updateFarm is UNAUTHORIZED", refused.reasonCode, "UNAUTHORIZED")
    deliver(WTSiteViewRequestEvent.new(""), true, spec)
    local clientS = newSystem()
    g_WorkplaceSystem = clientS
    deliver(spec.sent[1], false, nil)
    T.eq("E17 spectator view is NOT_READY", clientS.siteClient.view.availability, "NOT_READY")
    T.eq("E18 spectator reason INVALID_FARM", clientS.siteClient.view.reason, "INVALID_FARM")

    -- A client cannot name another farm: the actor is resolved server-side.
    g_WorkplaceSystem = server
    local s2 = server.siteService.sessions[c2]
    local cross = server.siteService:handleCommandFromConnection(c2, { commandSessionId = s2.commandSessionId, sequence = tostring(s2.nextSequence), actionId = "DELETE_SITE", targetId = "site_1", expectedRevision = "1" })
    T.eq("E19 a farm 2 manager cannot delete farm 1's site", cross.reasonCode, "UNAUTHORIZED")
    T.eq("E20 refusal carries no other farm's definition", cross.currentTarget, nil)

    -- Master user administration over the wire: enter farm 1, transfer an orphan.
    local admin = newConn(8)
    ACTORS[admin] = { farmId = 2, user = user(50, true) }
    g_currentMission._isServer = true
    -- A farm cannot be deleted while any of its players is online (Farm.lua:452),
    -- so its former members are spectators by the time the notice arrives.
    ACTORS[c2].farmId = 0
    ACTORS[c3].farmId = 0
    server.siteService:onFarmDeleted(2)   -- farm 2 gone: its sites orphaned
    setFarms({ 1 })
    T.eq("E21 farm deletion orphaned farm 2's sites", server.siteService.store:get("site_2").state, "UNAVAILABLE")
    T.eq("E22 farm deletion withdrew farm 2 sessions", server.siteService.sessions[c2], nil)
    ACTORS[admin] = { farmId = 1, user = user(50, true) }
    deliver(WTSiteViewRequestEvent.new("1"), true, admin)
    local adminClient = newSystem()
    g_WorkplaceSystem = adminClient
    -- Two views travel: the ordinary own-farm replica, then the administration replica.
    deliver(admin.sent[#admin.sent - 1], false, nil)
    deliver(admin.sent[#admin.sent], false, nil)
    local av = adminClient.siteClient.adminView
    T.eq("E23 admin view administers farm 1", av.administrationTargetFarmId, 1)
    T.eq("E24 admin view lists farm 1's site plus the orphans", #av.sites, 3)
    local orphan
    for _, s in ipairs(av.sites) do if s.siteId == "site_2" then orphan = s end end
    T.eq("E25 orphan shows UNAVAILABLE with its reason", orphan.reason, "FARM_DELETED")
    g_WorkplaceSystem = server
    g_currentMission._isServer = true
    local sa = server.siteService.sessions[admin]
    local moved = server.siteService:handleCommandFromConnection(admin, { commandSessionId = sa.commandSessionId, sequence = tostring(sa.nextSequence), actionId = "TRANSFER_SITE", targetId = "site_2", expectedRevision = orphan.revision, administrationTargetFarmId = 1 })
    T.eq("E26 transfer applied", moved.outcome, "APPLIED")
    T.eq("E27 site now owned by farm 1 and ACTIVE", moved.currentTarget.ownerFarmId .. "/" .. moved.currentTarget.state, "1/ACTIVE")
    -- The transfer withdrew the sessions on farm 1 (the new owner), the acting master's included;
    -- the republish reissued it with the administration context kept.
    local saOld = sa
    sa = server.siteService.sessions[admin]
    T.ok("E27b the acting master's session was reissued", sa ~= nil and sa ~= saOld)
    T.eq("E27c with its administration context kept", sa.administrationTargetFarmId, 1)
    local noAdmin = server.siteService:handleCommandFromConnection(admin, { commandSessionId = sa.commandSessionId, sequence = tostring(sa.nextSequence), actionId = "TRANSFER_SITE", targetId = "site_3", expectedRevision = "1", administrationTargetFarmId = 9 })
    T.eq("E28 transfer to a missing farm is INVALID_FARM", noAdmin.reasonCode, "INVALID_FARM")
    -- A non-master cannot transfer.
    ACTORS[c3] = { farmId = 1, user = user(30, false), isFarmManager = true }
    server.siteService:publishTo(c3)
    local sc3 = server.siteService.sessions[c3]
    local notMaster = server.siteService:handleCommandFromConnection(c3, { commandSessionId = sc3.commandSessionId, sequence = tostring(sc3.nextSequence), actionId = "TRANSFER_SITE", targetId = "site_3", expectedRevision = "1", administrationTargetFarmId = 1 })
    T.eq("E29 a non-master user cannot TRANSFER_SITE", notMaster.reasonCode, "UNAUTHORIZED")
    g_client = nil
end

-- (F) Consumer notices and the ledger / XML load order.
do
    setFarms({ 1 })
    LOCAL.farmId = 1
    g_currentMission._isServer = true
    local sys = newSystem()
    g_WorkplaceSystem = sys
    local notices = {}
    T.eq("F1 subscribe through the adapter", sys.subscribeSiteChanges("stockguard", function(id, rev, kind, farm) notices[#notices + 1] = kind .. ":" .. id end), true)
    sys.siteService:initialize()
    local r = sys.siteService.store:create(1, { name = "Yard", centreX = 0, centreZ = 0, radiusMetres = 5 })
    sys.siteService:notify(r.siteId, r.revision, "UPSERT", 1)
    T.eq("F2 UPSERT notice delivered", notices[#notices], "UPSERT:site_1")
    sys.siteService.store:delete("site_1")
    sys.siteService:notify("site_1", "1", "DELETE", 1)
    T.eq("F3 DELETE notice delivered", notices[#notices], "DELETE:site_1")
    T.eq("F4 unsubscribe", sys.unsubscribeSiteChanges("stockguard"), true)

    -- Ledger delivered block wins over XML; a foreign block falls to XML; nothing merges.
    local ledger = { modules = {} }
    ledger.registerModule = function(_, id, spec) ledger.modules[id] = spec end
    ledger.parseFile = function() end
    g_currentMission.stateLedger = ledger
    local sys2 = newSystem()
    g_WorkplaceSystem = sys2
    sys2.siteService:registerLedgerModule()
    T.ok("F5 own ledger module registered", ledger.modules["WorkplaceTriggers_Sites"] ~= nil)
    ledger.modules["WorkplaceTriggers_Sites"].deserialize({ siteSchemaVersion = 1, mapId = "map01", terrainSize = 2048, nextSiteCounter = "3", sites = {
        { siteId = "site_2", ownerFarmId = 1, purpose = "", name = "FromLedger", centreX = 1, centreZ = 1, radiusMetres = 5, revision = "1", state = "ACTIVE" } } })
    sys2.siteService:stageFromBackends()
    T.eq("F6 delivered ledger block is the source", sys2.siteService.store:get("site_2").name, "FromLedger")
    local sys3 = newSystem()
    g_WorkplaceSystem = sys3
    sys3.siteService:registerLedgerModule()
    ledger.modules["WorkplaceTriggers_Sites"].deserialize({ alien = true })
    XMLFile.loadIfExists = function() return nil end
    sys3.siteService:stageFromBackends()
    T.eq("F7 a foreign ledger table is not delivered; first use", #sys3.siteService.store.records, 0)
    T.eq("F8 serialize of an unstaged store is nil (never a synthetic empty container)", newSystem().siteService.store.staged, false)
    g_currentMission.stateLedger = nil
    XMLFile.loadIfExists = nil
end

-- (G) The loading boundary: staging never decides farms; finalization waits for isLoaded.
do
    setFarms({ 1 })
    g_currentMission._isServer = true
    g_currentMission.isLoaded = false
    g_currentMission.numLoadingTasks = 2
    local original = function(m) m._nativeFinished = true return "native" end
    g_currentMission.onFinishedLoading = original
    local sys = newSystem()
    g_WorkplaceSystem = sys
    sys.siteService.store:stageEmpty("map01", 2048)
    sys.siteService.staged = true
    sys.siteService.store.records[1] = { siteId = "site_1", ownerFarmId = 7, purpose = "", name = "x", centreX = 0, centreZ = 0, radiusMetres = 5, revision = "1", state = "ACTIVE" }
    sys.siteService.store.byId["site_1"] = sys.siteService.store.records[1]
    sys.siteService:installFinishedLoadingBinding()
    T.eq("G1 not finalized while loading tasks remain", sys.siteService:finalizeIfLoaded(), false)
    T.eq("G2 capabilities NOT_READY while waiting", sys.getSiteCapabilities().reasonCode, "NOT_READY")
    T.eq("G3 owner not judged while waiting", sys.siteService.store:get("site_1").state, "ACTIVE")
    g_currentMission.isLoaded = true
    g_currentMission.numLoadingTasks = 0
    local ret = g_currentMission:onFinishedLoading()
    T.eq("G4 wrapper returns the original's result", ret, "native")
    T.eq("G5 the native body ran", g_currentMission._nativeFinished, true)
    T.eq("G6 finalized at the boundary", sys.siteService.store:isReady(), true)
    T.eq("G7 missing owner judged only then", sys.siteService.store:get("site_1").state, "UNAVAILABLE")
    sys.siteService:removeFinishedLoadingBinding()
    T.eq("G8 teardown restored the original when still current", g_currentMission.onFinishedLoading, original)
    -- A foreign wrapper on top is left intact.
    local sys2 = newSystem()
    g_WorkplaceSystem = sys2
    sys2.siteService:installFinishedLoadingBinding()
    local foreign = function(m) return "foreign" end
    g_currentMission.onFinishedLoading = foreign
    sys2.siteService:removeFinishedLoadingBinding()
    T.eq("G9 an enclosing foreign wrapper is not cut", g_currentMission.onFinishedLoading, foreign)
    g_currentMission.onFinishedLoading = nil
end

-- (H) Event wire round trips keep every field.
do
    local view = { availability = "READY", reason = nil, definitionRevision = "7", commandSessionId = "s9", nextSequence = "3", administrationTargetFarmId = nil,
        sites = { { siteId = "site_1", ownerFarmId = 1, purpose = "stockguard.yard", name = "Main Yard", centreX = 0.1, centreZ = -1234.5, radiusMetres = 100, revision = "2", state = "ACTIVE" } } }
    local s = NewStream()
    WTSiteViewStateEvent.new(view):writeStream(s, nil)
    local rx = WTSiteViewStateEvent.emptyNew()
    g_currentMission._isServer = true   -- run() is a no-op on the server; we only inspect the decoded view
    rx:readStream(s, nil)
    T.eq("H1 format token", rx.view.format, "WT_SITE_VALUES_1")
    T.eq("H2 x round-trips exactly", rx.view.sites[1].centreX, 0.1)
    T.eq("H3 z round-trips exactly", rx.view.sites[1].centreZ, -1234.5)
    T.eq("H4 purpose token", rx.view.sites[1].purpose, "stockguard.yard")
    T.eq("H5 session and sequence", rx.view.commandSessionId .. "/" .. rx.view.nextSequence, "s9/3")
    T.eq("H6 nil admin target stays nil", rx.view.administrationTargetFarmId, nil)
    local req = { commandSessionId = "s1", sequence = "4", actionId = "UPDATE_SITE", targetId = "site_1", expectedRevision = "2", name = "N", purpose = "", centreX = 5, centreZ = 6, radiusMetres = 7 }
    local s2 = NewStream()
    WTSiteCommandRequestEvent.new(req):writeStream(s2, nil)
    local rx2 = WTSiteCommandRequestEvent.emptyNew()
    g_currentMission._isServer = false
    rx2:readStream(s2, nil)
    T.eq("H7 request protocol 1", rx2.request.protocolVersion, 1)
    T.eq("H8 request format", rx2.request.format, "WT_SITE_COMMAND_1")
    T.eq("H9 request route SITE", rx2.request.route, "SITE")
    T.eq("H10 request fields", rx2.request.targetId .. "/" .. rx2.request.expectedRevision .. "/" .. rx2.request.radiusMetres, "site_1/2/7")
    T.eq("H11 absent admin target stays nil", rx2.request.administrationTargetFarmId, nil)
end


-- =====================================================================
-- PART 3: Bob's cold review of PR #37 (2026-09-15), fixed on the branch
-- =====================================================================

-- (I) BLOCKER 1 / MAJOR 3: two replicas; nil-context reads never see the administration view.
do
    setFarms({ 1, 2 })
    LOCAL.farmId = 1
    g_currentMission._isServer = true
    g_currentMission.isLoaded = true
    g_currentMission.numLoadingTasks = 0
    local server = newSystem()
    g_WorkplaceSystem = server
    server.siteService:initialize()
    server.siteService.store:create(1, { name = "Own Yard", centreX = 1, centreZ = 1, radiusMetres = 50 })
    server.siteService.store:create(2, { name = "Their Yard", centreX = 2, centreZ = 2, radiusMetres = 50 })
    local master = newConn(30)
    ACTORS[master] = { farmId = 1, user = user(300, true) }
    local notices = {}
    local client = newSystem()
    client.siteClient:subscribe("stockguard", function(id, rev, kind, owner) notices[#notices + 1] = kind .. ":" .. id .. ":" .. tostring(owner) end)
    -- Ordinary view first.
    g_WorkplaceSystem = server
    deliver(WTSiteViewRequestEvent.new(""), true, master)
    g_WorkplaceSystem = client
    deliver(master.sent[#master.sent], false, nil)
    T.eq("I1 ordinary replica holds the own farm's site", client.siteClient:getSites()[1].name, "Own Yard")
    T.eq("I2 no administration replica yet", client.siteClient.adminView, nil)
    T.eq("I3 one hotspot for the own site", #client.siteClient:getHotspotList(), 1)
    local noticesBefore = #notices
    -- Enter administration of farm 2: two views travel.
    g_WorkplaceSystem = server
    local before = #master.sent
    deliver(WTSiteViewRequestEvent.new("2"), true, master)
    T.eq("I4 entering administration sends the ordinary and the administration view", #master.sent - before, 2)
    g_WorkplaceSystem = client
    deliver(master.sent[before + 1], false, nil)
    deliver(master.sent[before + 2], false, nil)
    T.eq("I5 administration replica targets farm 2", client.siteClient.adminView.administrationTargetFarmId, 2)
    T.eq("I6 administration replica carries farm 2's site", client.siteClient.adminView.sites[1].name, "Their Yard")
    T.eq("I7 nil-context read still returns only the own farm", client.siteClient:getSites()[1].name, "Own Yard")
    T.eq("I7b and exactly one row", #client.siteClient:getSites(), 1)
    T.eq("I8 getSite on the other farm's id is NOT_FOUND outside the manager", select(2, client.siteClient:getSite("site_2")), "NOT_FOUND")
    T.eq("I9 the own hotspot survives administration", #client.siteClient:getHotspotList(), 1)
    T.eq("I10 no UPSERT/DELETE notices for the administration replica", #notices, noticesBefore)
    T.eq("I11 the manager reads the administration replica", client.siteClient:getManagerView().administrationTargetFarmId, 2)
    T.eq("I12 the adapter's nil-context read is the ordinary replica", (client.getSitesForFarm())[1].name, "Own Yard")
    -- Leave administration: the ordinary view says the context is gone.
    g_WorkplaceSystem = server
    before = #master.sent
    deliver(WTSiteViewRequestEvent.new("0"), true, master)
    T.eq("I13 leaving sends one ordinary view", #master.sent - before, 1)
    g_WorkplaceSystem = client
    deliver(master.sent[#master.sent], false, nil)
    T.eq("I14 administration replica dropped", client.siteClient.adminView, nil)
    T.eq("I15 no DELETE notice for the own site on leaving", #notices, noticesBefore)
    -- A plain member's own-farm right gates the manager's controls.
    local member = newConn(31)
    ACTORS[member] = { farmId = 1, user = user(301, false), isFarmManager = false }
    g_WorkplaceSystem = server
    deliver(WTSiteViewRequestEvent.new(""), true, member)
    local memberClient = newSystem()
    g_WorkplaceSystem = memberClient
    deliver(member.sent[#member.sent], false, nil)
    g_currentMission._isServer = false
    g_currentMission.isMasterUser = false
    local savedGetHas = g_currentMission.getHasPlayerPermission
    g_currentMission.getHasPlayerPermission = function(_, perm, conn, farmId) return conn == nil and farmId == 1 and LOCAL.isFarmManager == true end
    LOCAL.isFarmManager = false
    T.ok("I16 plain member has a session", memberClient.siteClient.view.commandSessionId ~= nil)
    T.eq("I17 but no command right without UPDATE_FARM", memberClient.siteClient:hasCommandRight(), false)
    LOCAL.isFarmManager = true
    T.eq("I18 a farm manager has the command right", memberClient.siteClient:hasCommandRight(), true)
    LOCAL.isFarmManager = nil
    g_currentMission.getHasPlayerPermission = savedGetHas
    g_currentMission._isServer = true
end

-- (J) BLOCKER 2: UNAVAILABLE records are never reshaped; only a master in administration deletes them.
do
    setFarms({ 1, 2 })
    LOCAL.farmId = 1
    g_currentMission._isServer = true
    local server = newSystem()
    g_WorkplaceSystem = server
    server.siteService:initialize()
    local dead = server.siteService.store:create(2, { name = "Dead Farm Yard", centreX = 2, centreZ = 2, radiusMetres = 50 })
    server.siteService:onFarmDeleted(2)
    setFarms({ 1 })
    T.eq("J1 orphan is UNAVAILABLE", server.siteService.store:get(dead.siteId).state, "UNAVAILABLE")
    -- Farm id 2 is reused by a new farm with a manager.
    setFarms({ 1, 2 })
    local reuse = newConn(40)
    ACTORS[reuse] = { farmId = 2, user = user(400, false), isFarmManager = true }
    server.siteService:publishTo(reuse)
    local sr = server.siteService.sessions[reuse]
    local rec = server.siteService.store:get(dead.siteId)
    local upd = server.siteService:handleCommandFromConnection(reuse, { commandSessionId = sr.commandSessionId, sequence = tostring(sr.nextSequence), actionId = "UPDATE_SITE", targetId = dead.siteId, expectedRevision = rec.revision, name = "Mine now", purpose = "", centreX = 0, centreZ = 0, radiusMetres = 9 })
    T.eq("J2 a manager on the reused id cannot reshape the dead farm's site", upd.reasonCode, "SITE_UNAVAILABLE")
    T.eq("J3 the record is unchanged", server.siteService.store:get(dead.siteId).name, "Dead Farm Yard")
    sr = server.siteService.sessions[reuse]
    local del = server.siteService:handleCommandFromConnection(reuse, { commandSessionId = sr.commandSessionId, sequence = tostring(sr.nextSequence), actionId = "DELETE_SITE", targetId = dead.siteId, expectedRevision = rec.revision })
    T.eq("J4 nor delete it", del.reasonCode, "SITE_UNAVAILABLE")
    T.ok("J5 the record still exists", server.siteService.store:get(dead.siteId) ~= nil)
    -- A master user outside administration cannot delete it either.
    local master = newConn(41)
    ACTORS[master] = { farmId = 1, user = user(410, true) }
    server.siteService:publishTo(master)
    local sm = server.siteService.sessions[master]
    local delOut = server.siteService:handleCommandFromConnection(master, { commandSessionId = sm.commandSessionId, sequence = tostring(sm.nextSequence), actionId = "DELETE_SITE", targetId = dead.siteId, expectedRevision = rec.revision })
    T.eq("J6 a master outside administration cannot delete an UNAVAILABLE record", delOut.reasonCode, "SITE_UNAVAILABLE")
    -- Inside administration of any farm the master may.
    server.siteService:setAdministrationContext(master, 1)
    sm = server.siteService.sessions[master]
    local updAdmin = server.siteService:handleCommandFromConnection(master, { commandSessionId = sm.commandSessionId, sequence = tostring(sm.nextSequence), actionId = "UPDATE_SITE", targetId = dead.siteId, expectedRevision = rec.revision, name = "x", purpose = "", centreX = 0, centreZ = 0, radiusMetres = 9 })
    T.eq("J7 UPDATE on an orphan is refused even in administration", updAdmin.reasonCode, "SITE_UNAVAILABLE")
    sm = server.siteService.sessions[master]
    local delAdmin = server.siteService:handleCommandFromConnection(master, { commandSessionId = sm.commandSessionId, sequence = tostring(sm.nextSequence), actionId = "DELETE_SITE", targetId = dead.siteId, expectedRevision = rec.revision })
    T.eq("J8 DELETE of an orphan by a master in administration applies", delAdmin.outcome, "APPLIED")
    T.eq("J9 the record is gone", server.siteService.store:get(dead.siteId), nil)
end

-- (K) MAJOR 4: a stale or foreign session id never withdraws the current session; withdrawals republish.
do
    setFarms({ 1, 2 })
    LOCAL.farmId = 1
    g_currentMission._isServer = true
    local server = newSystem()
    g_WorkplaceSystem = server
    server.siteService:initialize()
    local conn = newConn(50)
    ACTORS[conn] = { farmId = 1, user = user(500, false), isFarmManager = true }
    server.siteService.subscribers[conn] = true
    server.siteService:publishTo(conn)
    local s = server.siteService.sessions[conn]
    local sentBefore = #conn.sent
    local stale = server.siteService:handleCommandFromConnection(conn, { commandSessionId = "s0", sequence = "1", actionId = "CREATE_SITE", name = "x", purpose = "", centreX = 0, centreZ = 0, radiusMetres = 5 })
    T.eq("K1 stale id refused SESSION_WITHDRAWN", stale.reasonCode, "SESSION_WITHDRAWN")
    T.eq("K2 the current session is retained", server.siteService.sessions[conn], s)
    T.eq("K3 the actor was republished", #conn.sent, sentBefore + 1)
    -- Binding change: the user lost the farm; the session is withdrawn and a fresh one published.
    ACTORS[conn].farmId = 2
    sentBefore = #conn.sent
    local changed = server.siteService:handleCommandFromConnection(conn, { commandSessionId = s.commandSessionId, sequence = tostring(s.nextSequence), actionId = "CREATE_SITE", name = "x", purpose = "", centreX = 0, centreZ = 0, radiusMetres = 5 })
    T.eq("K4 changed binding is SESSION_WITHDRAWN", changed.reasonCode, "SESSION_WITHDRAWN")
    T.ok("K5 a fresh session was issued by the republish", server.siteService.sessions[conn] ~= nil and server.siteService.sessions[conn] ~= s)
    T.eq("K6 republished", #conn.sent, sentBefore + 1)
    -- Permission change (manager right revoked) also reissues at the next republish.
    local s2 = server.siteService.sessions[conn]
    ACTORS[conn].isFarmManager = false
    server.siteService:publishTo(conn)
    T.ok("K7 a permission change reissues the session", server.siteService.sessions[conn] ~= s2)
    -- Pure client: SESSION_WITHDRAWN makes it ask for a view again.
    local client = newSystem()
    client.siteClient.isInitialized = true
    client.siteClient.view = { availability = "READY", commandSessionId = "s9", nextSequence = "1", sites = {} }
    client.siteClient.needsView = false
    g_currentMission._isServer = false
    client.siteClient:onCommandResult({ commandSessionId = "s9", sequence = "1", outcome = "REFUSED", reasonCode = "SESSION_WITHDRAWN" })
    T.eq("K8 client clears its session", client.siteClient.view.commandSessionId, nil)
    T.eq("K9 client requests a view again", client.siteClient.needsView, true)
    g_currentMission._isServer = true
end

-- (L) MAJOR 6: CREATE names its owner explicitly.
do
    setFarms({ 1, 2 })
    LOCAL.farmId = 1
    g_currentMission._isServer = true
    local server = newSystem()
    g_WorkplaceSystem = server
    server.siteService:initialize()
    local master = newConn(60)
    ACTORS[master] = { farmId = 1, user = user(600, true) }
    server.siteService:setAdministrationContext(master, 2)
    local sm = server.siteService.sessions[master]
    T.eq("L0 session administers farm 2", sm.administrationTargetFarmId, 2)
    local own = server.siteService:handleCommandFromConnection(master, { commandSessionId = sm.commandSessionId, sequence = tostring(sm.nextSequence), actionId = "CREATE_SITE", name = "Own", purpose = "", centreX = 0, centreZ = 0, radiusMetres = 5 })
    T.eq("L1 CREATE without the field applies", own.outcome, "APPLIED")
    T.eq("L2 on the actor's own farm, not the retained context", own.currentTarget.ownerFarmId, 1)
    sm = server.siteService.sessions[master]
    local theirs = server.siteService:handleCommandFromConnection(master, { commandSessionId = sm.commandSessionId, sequence = tostring(sm.nextSequence), actionId = "CREATE_SITE", administrationTargetFarmId = 2, name = "Theirs", purpose = "", centreX = 0, centreZ = 0, radiusMetres = 5 })
    T.eq("L3 CREATE naming the administered farm applies", theirs.outcome, "APPLIED")
    T.eq("L4 on that farm", theirs.currentTarget.ownerFarmId, 2)
    sm = server.siteService.sessions[master]
    local wrong = server.siteService:handleCommandFromConnection(master, { commandSessionId = sm.commandSessionId, sequence = tostring(sm.nextSequence), actionId = "CREATE_SITE", administrationTargetFarmId = 1, name = "Wrong", purpose = "", centreX = 0, centreZ = 0, radiusMetres = 5 })
    T.eq("L5 naming a farm other than the context is UNAUTHORIZED", wrong.reasonCode, "UNAUTHORIZED")
end

-- (M) MAJOR 7: names are bytes and control characters only.
do
    local ok = WorkplaceSiteStore.validateFields({ name = "Smith & Sons <Yard>", purpose = "", centreX = 0, centreZ = 0, radiusMetres = 5 }, 2048)
    T.eq("M1 markup characters in a name are accepted", ok, true)
    local ok2 = WorkplaceSiteStore.validateFields({ name = "bad\nname", purpose = "", centreX = 0, centreZ = 0, radiusMetres = 5 }, 2048)
    T.eq("M2 a control character is refused", ok2, false)
    local ok3 = WorkplaceSiteStore.validateFields({ name = string.rep("é", 65), purpose = "", centreX = 0, centreZ = 0, radiusMetres = 5 }, 2048)
    T.eq("M3 130 bytes of UTF-8 exceed the 128-byte bound", ok3, false)
    T.eq("M4 FALLBACK_TERRAIN is gone", WorkplaceSiteStore.FALLBACK_TERRAIN, nil)
end

-- (N) MAJOR 8: a connection whose user record is gone is pruned on the server.
do
    setFarms({ 1 })
    LOCAL.farmId = 1
    g_currentMission._isServer = true
    local server = newSystem()
    g_WorkplaceSystem = server
    server.siteService:initialize()
    local conn = newConn(70)
    ACTORS[conn] = { farmId = 1, user = user(700, false), isFarmManager = true }
    deliver(WTSiteViewRequestEvent.new(""), true, conn)
    T.eq("N1 subscribed", server.siteService.subscribers[conn], true)
    T.ok("N2 session issued", server.siteService.sessions[conn] ~= nil)
    ACTORS[conn] = nil   -- the user manager no longer knows the connection
    local sentBefore = #conn.sent
    server.siteService:publishAll()
    T.eq("N3 dead subscriber dropped", server.siteService.subscribers[conn], nil)
    T.eq("N4 dead session dropped", server.siteService.sessions[conn], nil)
    T.eq("N5 nothing sent to it", #conn.sent, sentBefore)
    T.eq("N6 a dead connection cannot subscribe", (function() deliver(WTSiteViewRequestEvent.new(""), true, conn) return server.siteService.subscribers[conn] end)(), nil)
end

-- (O) MAJOR 9: TRANSFER withdraws the sessions of the old and the new owner farm.
do
    setFarms({ 1, 2 })
    LOCAL.farmId = 1
    g_currentMission._isServer = true
    local server = newSystem()
    g_WorkplaceSystem = server
    server.siteService:initialize()
    local site = server.siteService.store:create(2, { name = "Moving", centreX = 0, centreZ = 0, radiusMetres = 5 })
    local farm2 = newConn(80)
    ACTORS[farm2] = { farmId = 2, user = user(800, false), isFarmManager = true }
    local farm1 = newConn(81)
    ACTORS[farm1] = { farmId = 1, user = user(810, false), isFarmManager = true }
    server.siteService.subscribers[farm1] = true
    server.siteService.subscribers[farm2] = true
    server.siteService:publishTo(farm1)
    server.siteService:publishTo(farm2)
    local s1, s2 = server.siteService.sessions[farm1], server.siteService.sessions[farm2]
    local master = newConn(82)
    ACTORS[master] = { farmId = 1, user = user(820, true) }
    server.siteService:setAdministrationContext(master, 1)
    local sm = server.siteService.sessions[master]
    local moved = server.siteService:handleCommandFromConnection(master, { commandSessionId = sm.commandSessionId, sequence = tostring(sm.nextSequence), actionId = "TRANSFER_SITE", targetId = site.siteId, expectedRevision = site.revision, administrationTargetFarmId = 1 })
    T.eq("O1 transfer applied", moved.outcome, "APPLIED")
    T.ok("O2 farm 1's session was withdrawn and reissued", server.siteService.sessions[farm1] ~= s1)
    T.ok("O3 farm 2's session was withdrawn and reissued", server.siteService.sessions[farm2] ~= s2)
    T.ok("O4 both were republished with a session", server.siteService.sessions[farm1] ~= nil and server.siteService.sessions[farm2] ~= nil)
end

-- (P) MINOR 11 / 12: guard order and dropped-record logging.
do
    local server = newSystem()
    local r = server.siteService:handleCommand({ isLocal = true }, nil)
    T.eq("P1 a nil request is refused, not an error", r.reasonCode, "INVALID_FIELDS")
    local logged = {}
    local savedPrint = print
    print = function(msg) logged[#logged + 1] = tostring(msg) end
    local st = WorkplaceSiteStore.new()
    st:stageContainer({ siteSchemaVersion = WorkplaceSiteStore.SCHEMA_VERSION, mapId = "m", terrainSize = 2048, nextSiteCounter = "1", sites = {
        { siteId = "site_1", ownerFarmId = 1, name = "a", centreX = 0, centreZ = 0, radiusMetres = 5, revision = "1", state = "ACTIVE" },
        { siteId = "site_1", ownerFarmId = 1, name = "dup", centreX = 0, centreZ = 0, radiusMetres = 5, revision = "1", state = "ACTIVE" },
        { siteId = "site_2", ownerFarmId = 1, name = "nan", centreX = 0/0, centreZ = 0, radiusMetres = 5, revision = "1", state = "ACTIVE" },
    } }, "m", 2048)
    print = savedPrint
    local dup, nan = false, false
    for _, l in ipairs(logged) do
        if l:find("duplicate id", 1, true) then dup = true end
        if l:find("non%-finite geometry") then nan = true end
    end
    T.eq("P2 one record kept", #st.records, 1)
    T.eq("P3 the duplicate was logged", dup, true)
    T.eq("P4 the non-finite record was logged", nan, true)
end
