# TODO: FS25_WorkplaceTriggers

> Ecosystem role: **Labor** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## From the ecosystem audit (Arissani)
- [ ] Fast-track BL17: cooldown cap on triggers to stop spam.
- [ ] Fix detection: `g_NPCFavorSystem` -> `g_currentMission.npcFavorSystem`; `g_WorkerCostsSystem` -> `g_currentMission.workerCostsManager`.
- [ ] Remove wrong-direction WorkerCosts calls (registerOffFarmJob / deregisterOffFarmJob / recordJobIncome); replace the `g_WorkplaceSystem` getfenv export with the mission handle.

## Bugs
- [!] Detection violations in both companion integrations (getfenv instead of mission handles).
- [!] Wrong API direction: WorkerCostsIntegration calls functions that do not exist in WorkerCosts.

## Features / enhancements
- [ ] BL17 cooldown; the companion read surface for WorkerCosts.

## Cross-mod integration
- [x] StateLedger: `WorkplaceTriggers_Data` bridge live (trigger definitions + HUD layout; commit c98a876, delegate-when-present, own XML kept as the safety copy, force-parseFile timing). Settings go to SettingsHub, NOT a second SL module (state-to-SL / settings-to-SettingsHub split).
- [ ] NetworkSync: **DEFERRED** - real transactional bridge (WorkplaceMultiplayerEvent, 9 types: shift start/end carry wage payments, trigger CRUD is cross-client state). Point-2's `ns:sendCommand` API is stale vs live NS v2 (registerAction / requestAction). Needs the NS build-brief + two-machine MP test.
- [x] MasterHUD: `WorkplaceTriggers_HUD` bridged (commit 939f701); own FSBaseMission.draw stands down when active. Edit-mode mouse (addModEventListener) stays on the own input path.
- [x] SettingsHub: `WorkplaceTriggers` module bridged (bare name, selfPersisted, 7 settings; commit 939f701). Wage/schedule adminOnly, HUD/notification prefs player-local. ESC section kept as the standalone fallback.
- [ ] Reads NPCFavor (`npcFavorSystem`) + WorkerCosts (`workerCostsManager`); read by WorkerCosts.

## Docs / localization
- [ ] Keep all 26 languages in step for any new setting.
- [ ] Update README/version on each release.

## Blocked / waiting on
- [~] Bedrock migrations: StateLedger + SettingsHub + MasterHUD DONE (commits 939f701, c98a876). Only the NetworkSync transactional bridge remains (deferred - needs the NS build-brief, see Cross-mod integration).
