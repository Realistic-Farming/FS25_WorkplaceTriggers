# TODO: FS25_WorkplaceTriggers

> Ecosystem role: **Labor** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## Bugs
- [x] 2026-08-31: **DOUBLE PAYOUT fixed (issue #29).** `onShiftEnd` in the NetworkSync bridge paid via `endShiftForFarm`, then cleared the local farm's single-slot mirror by calling `endShift()`/`endShiftPenalty()`, which paid a second time (`addMoney` is server-gated, so both fired on the host). `endShift`/`endShiftPenalty` now accept `skipPayout`; the bridge mirror-clear and the trigger-delete finish pass `true`. In-game verification pending.

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
- [x] Trigger purpose designation (2026-08-05): optional `purpose` on the trigger record, server-gated `set_trigger_purpose` bridge action under the existing admin gate, `getTriggersByPurpose`. Persisted through own XML + StateLedger bridge + NetworkSync snapshot/actions. First consumer: Co-Op Home Ladder rung 3. Non-breaking both directions (loader defaults every read).

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

## Fast-track fixes (2026-08-07)
- [x] F145: registerTrigger id de-dup. The placeable and standalone-XML load both registered the same trigger; the purpose designation landed on the purposeless duplicate. Replaces in place so the newest data wins.
- [x] F144: rotY was saved but never read on load, so trigger orientation reset on reload. Read and restore it.
- [x] Action-guard nil-userId: the trigger CRUD admin check skipped the guard when userId == nil (listen-server host). Nil now resolves as host-admin (SettingsHub pattern).

## 2026-10-14 (Fred (via Desk)): keyboard defaults (Wizard, #39)

- [x] `modDesc.xml`: WT_INTERACT on Right Ctrl + K, WT_MENU on Right Shift + Y, WT_TOGGLE_HUD on Right Ctrl + I; the de, en, fr, it, nl and pl translation files.
- [ ] The localized Help pages and shop text still name E for the interact in de, fr, it, nl and pl (MAINTENANCE row 301, parked: later, not queued).
- [~] In game (owed): TESTING row 543.

## 2026-10-14 (Fred (via Desk)): build packaging (MAINTENANCE row 314)

- [x] `build.sh`: keeps the `.git` file out of the zip on both paths, and its Python fallback (taken when there is no `zip` command, as in Git Bash) names the zip `FS25_WorkplaceTriggers.zip` instead of after the folder, so `--deploy` copies the zip it just built rather than a missing or stale one.
- [x] Built from a worktree (Python fallback; this machine's Git Bash has no `zip`) before and after this change: development wrote `bf-WorkplaceTriggers.zip`, named after the folder, with 45 entries, one of them the worktree `.git` file; this branch writes `FS25_WorkplaceTriggers.zip` with 44, exactly that file removed, every other entry byte-identical (CRC), nothing added. The `zip` command path gets the same `.git` exclusion but was not run here.
- Build tooling only, no in-game check (TESTING row 576).
