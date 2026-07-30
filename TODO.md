# TODO: FS25_WorkplaceTriggers

> Ecosystem role: **Labor** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## Bugs
- [x] 2026-07-30: `src/integrations/WTNetworkSyncBridge.lua:192` failed to COMPILE - `g_currentMission:getFarmId and ...`. The `:` call syntax requires an immediate argument list, so Lua stopped at `and` ("expected '(', '{' or <string>"). The whole file was rejected and the NetworkSync bridge was dead in every session. Resolved with the suite's proven local-farm-id order (`g_localPlayer.farmId`, then `g_currentMission.player.farmId`) rather than a one-character patch: `getFarmId` is not in the Community LUADOC, so a guarded probe on it alone would have compiled and then silently always yielded -1, leaving the host's own shift state permanently un-updated.
- [ ] **ROOT CAUSE, still open: `build.sh` has NO Lua 5.1 syntax gate**, which is the only reason the above reached the game. SoilFertilizer catches this class before it ships (pre-commit `luaparse` pinned to 5.1 across all sources, plus lint). Port that gate here or into `build.sh` as a build-failing step.

## From the ecosystem audit (Arissani)
- [x] Fast-track BL17: cooldown cap on triggers to stop spam. DONE.
- [ ] Fix detection: `g_NPCFavorSystem` -> `g_currentMission.npcFavorSystem`; `g_WorkerCostsSystem` -> `g_currentMission.workerCostsManager`.
- [ ] Remove wrong-direction WorkerCosts calls (registerOffFarmJob / deregisterOffFarmJob / recordJobIncome); replace the `g_WorkplaceSystem` getfenv export with the mission handle.

## Bugs
- [x] MP wage exploit (9f0845f): the UPDATE_TRIGGER multiplayer event now requires an admin. Closes a path where a non-admin client could push wage/trigger changes.
- [!] Detection violations in both companion integrations (getfenv instead of mission handles).
- [!] Wrong API direction: WorkerCostsIntegration calls functions that do not exist in WorkerCosts.
- [x] WT-001 / WT-002 / WT-003: additional WorkplaceTriggers bugs fixed in 2026-07-26 bug sweep, merged to main.

## Features / enhancements
- [~] BL17 cooldown DONE; the companion read surface for WorkerCosts still open.

## Cross-mod integration
- [x] StateLedger: `WorkplaceTriggers_Data` bridge live (trigger definitions + HUD layout; commit c98a876, delegate-when-present, own XML kept as the safety copy, force-parseFile timing). Settings go to SettingsHub, NOT a second SL module (state-to-SL / settings-to-SettingsHub split).
- [!] NetworkSync: **DEFERRED, bundled with the NPCFavor money-authority session.** On source inspection (2026-07-11) WorkplaceMultiplayerEvent is not a state broadcast but a hardened request/response protocol: the client-initiated shift start/end PAY WAGES server-side (endShiftForFarm -> addMoney), with per-farm shift slots, listen-server vs dedicated branches, admin guards, optimistic client registration, and documented MP fixes (#17). So its NS migration is the SAME money-authority-refactor class as NPCFavor (route money-carrying actions through NS Path 3 with validation), not a mechanical swap. Needs the NS build-brief + two-machine MP test. Point-2's `ns:sendCommand` API is stale vs live NS v2 (registerAction / requestAction).
- [x] MasterHUD: `WorkplaceTriggers_HUD` bridged (commit 939f701); own FSBaseMission.draw stands down when active. Edit-mode mouse (addModEventListener) stays on the own input path.
- [x] SettingsHub: `WorkplaceTriggers` module bridged (bare name, selfPersisted, 7 settings; commit 939f701). Wage/schedule adminOnly, HUD/notification prefs player-local. ESC section kept as the standalone fallback.
- [ ] Reads NPCFavor (`npcFavorSystem`) + WorkerCosts (`workerCostsManager`); read by WorkerCosts.

## Docs / localization
- [ ] Keep all 26 languages in step for any new setting.
- [ ] Update README/version on each release.

## Blocked / waiting on
- [~] Bedrock migrations: StateLedger + SettingsHub + MasterHUD DONE (commits 939f701, c98a876). Only the NetworkSync transactional bridge remains (deferred - needs the NS build-brief, see Cross-mod integration).
