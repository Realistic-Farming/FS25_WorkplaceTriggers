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
- [ ] StateLedger: both XML files (triggers + HUD, and the 7 settings).
- [ ] NetworkSync: WorkplaceMultiplayerEvent (9 types); drop TYPE_REQUEST_SYNC / TYPE_SYNC_SETTINGS once getFullState lands.
- [ ] MasterHUD: remove FSBaseMission.draw + addModEventListener.
- [ ] SettingsHub: remove the ESC section (6 controls + header).
- [ ] Reads NPCFavor (`npcFavorSystem`) + WorkerCosts (`workerCostsManager`); read by WorkerCosts.

## Docs / localization
- [ ] Keep all 26 languages in step for any new setting.
- [ ] Update README/version on each release.

## Blocked / waiting on
- [!] Bedrock migrations (waits on: adopting the four engines; SoilFertilizer is the reference pattern).
