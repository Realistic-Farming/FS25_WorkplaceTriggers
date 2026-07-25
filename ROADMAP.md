# Roadmap: FS25_WorkplaceTriggers

> Ecosystem role: **Labor** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline.
> Forward-looking only. Shipped history lives in CHANGELOG.md and the releases.

## How to use this file
- Populate the milestones below from the audit baseline once it lands.
- Each item should be small enough to map to a `TODO.md` entry.
- Keep it honest: near-term is committed, mid-term is intended, long-term is aspirational.

## Current baseline
- Version at baseline: v1.1.1.1
- Audit reference: ecosystem-dev-tracking Point 1-5 (FS25_WorkplaceTriggers, 2026-06-30)
- Baseline date: 2026-06-30 (updated 2026-07-25)

## Near-term (next release cycle)
- [x] Fast-track BL17: cooldown cap on triggers to stop spam. DONE.
- [x] MP wage exploit (9f0845f): the UPDATE_TRIGGER multiplayer event now requires an admin. DONE.
- [ ] Fix the detection violations: NPCFavorIntegration and WorkerCostsIntegration must use `g_currentMission.npcFavorSystem` and `g_currentMission.workerCostsManager`, not getfenv globals.
- [ ] Remove the wrong-direction WorkerCosts calls (registerOffFarmJob / deregisterOffFarmJob / recordJobIncome); replace the `g_WorkplaceSystem` getfenv export with the mission handle.

## Mid-term (this season)
- [~] Bedrock migration: StateLedger + MasterHUD + SettingsHub bridged (939f701, c98a876, delegate-when-present). NetworkSync (WorkplaceMultiplayerEvent) deferred - a money-authority-class request/response protocol (shifts pay wages server-side), needs the NS build-brief.
- [ ] Expose the companion read surface WorkerCosts consumes.

## Long-term / aspirational
- [ ] Richer workplace types and job variety.

## Cross-mod / ecosystem dependencies
- [ ] Reads NPCFavor (`npcFavorSystem`) and WorkerCosts (`workerCostsManager`).
- [ ] Read by WorkerCosts (via the WorkplaceTriggers companion API).
- [~] Bedrock 3/4 done (StateLedger + MasterHUD + SettingsHub); NetworkSync deferred (money-authority class).

## Deferred / parked
- TYPE_REQUEST_SYNC / TYPE_SYNC_SETTINGS join handshake: parked for removal once NetworkSync getFullState replaces it.
