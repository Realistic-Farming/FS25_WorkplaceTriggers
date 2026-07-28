# Vision: FS25_WorkplaceTriggers

> Ecosystem role: **Labor** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit (Point 1-5, ecosystem-map, notes).
> Last updated: 2026-07-08

## 1. One-line purpose
Off-farm work: place workplace triggers at locations around the map so you or your workers can take paid jobs away from the farm, tying labour and NPCs into the wider world.

## 2. Problem it solves
FS25 income is on-farm only; there is no loop for working elsewhere. WorkplaceTriggers adds trigger-based off-farm jobs that pay, giving the labour and NPC systems somewhere to plug into beyond the field.

## 3. Design pillars
- **Server-authoritative triggers.** Trigger state and job payouts are server-owned and synced.
- **Correct detection.** Peer mods are found via `g_currentMission` handles, never getfenv globals.
- **Correct API direction.** WorkplaceTriggers is READ by WorkerCosts; it does not call into WorkerCosts. It never invents peer functions.
- **Labour and NPC aware.** It reads NPCFavor and WorkerCosts to place jobs in context.

## 4. Role in the ecosystem
- Public handle on `g_currentMission.workplaceTriggers` (the `g_WorkplaceSystem` getfenv export is the access-pattern violation, replaced by the mission handle).
- Reads from (consumes): NPCFavor (`g_currentMission.npcFavorSystem`) and WorkerCosts (`g_currentMission.workerCostsManager`). Both detections must move off getfenv to the mission handle.
- Read by (consumers): WorkerCosts (through the WorkplaceTriggers companion read surface), FarmTablet.
- Core-API registration status (specced in Point 1-5, not yet wired):
  - StateLedger (save/load): planned, replacing FS25_WorkplaceTriggers.xml (triggers + HUD) and workplace_triggers_settings.xml (7 settings); removes the FSCareerMissionInfo save hook.
  - NetworkSync (MP state): planned, replacing WorkplaceMultiplayerEvent (9 types); TYPE_REQUEST_SYNC / TYPE_SYNC_SETTINGS become redundant once getFullState delivers the join snapshot.
  - MasterHUD (overlays): planned, removing the FSBaseMission.draw hook + addModEventListener.
  - SettingsHub (admin settings): planned, replacing the full ESC-menu section (6 controls + header) from WorkplaceSettingsIntegration.

## 5. Explicit non-goals
- Does not call WorkerCosts. The old WorkerCostsIntegration calls (registerOffFarmJob / deregisterOffFarmJob / recordJobIncome) do not exist in WorkerCosts and are removed. Data flows WorkerCosts reads WorkplaceTriggers, not the reverse.
- No getfenv-based peer detection.

## 6. Success criteria
- Off-farm jobs pay out correctly and stay consistent in multiplayer.
- Peer detection uses `npcFavorSystem` and `workerCostsManager` mission handles.
- A cooldown caps trigger spam.

## 7. Open questions for the audit
- Confirm TYPE_REQUEST_SYNC / TYPE_SYNC_SETTINGS can be dropped once NetworkSync getFullState handles the join snapshot.
- Confirm the companion read surface WorkerCosts needs from WorkplaceTriggers.
