# CLAUDE.md

## Git Workflow — ONE FEATURE, ONE PR

> **Tyson's ruling, 2026-08-10. BINDING on every human and every agent seat, including Bob, Fred and Sasha, because those seats are the ones opening PRs.**

- **Every feature, fix or brief gets its OWN BRANCH**, cut fresh from `development`:
  `feat/<ID>-<slug>`, `fix/<ID>-<slug>`, or `docs/<slug>` / `chore/<slug>` for non-code work
  (e.g. `feat/SCS-037-caught-up-hour`).
  Commit **only that one item** on it.
- **The PR is `feat/...` → `development`.** One item per PR, always. Delete the branch on merge.
- **NEVER open a feature PR from `development` itself.** `development` is the trunk: a PR based on it
  silently absorbs every commit that lands while it is open, under a title that still describes the
  first one. **This happened twice in two days**, the second time to the seat that had just reported it.
- **`development` → `main` is a RELEASE PR only**, titled `Release vX.Y.Z`. It may carry many features
  *by design* and its body lists them. It is never a feature PR.
- **Never commit or push directly to `main`.** Check your branch at the start of every session.
- If a PR does end up carrying more than its title says: **retitle, rebody with the full commit list,
  and refresh every approval.** An old approval never covers code it did not see.

```bash
git checkout development && git pull
git checkout -b feat/SCS-037-caught-up-hour
#   ...commit the ONE feature...
git push -u origin feat/SCS-037-caught-up-hour
gh pr create --base development
#   -> Sasha approves -> Tyson merges -> branch deleted
```

**Sasha approves, Tyson merges.** No seat both approves and lands the same PR.

## Project Overview
FS25_WorkplaceTriggers - Placeable off-farm work triggers for FS25.
Patterns: NPCFavor (HUD, RVB input, GUI, events) + SeasonalCropStress (save/load, placeables, integrations).

## Session Reminders
1. Read this file before writing any code
2. NEVER name i3d root node 'root'
3. addTrigger() second arg MUST be a string
4. No unicode in Lua files (FS25 Lua 5.1 parser rejects it)
5. g_gui:loadGui() arg 3 = class table, not instance
6. Dialog callbacks: NEVER name them onClose or onOpen
7. XML save: use OOP xmlFile:setInt() etc. (not legacy global API)
8. HUD Y=0 at BOTTOM, increases UP
9. Images from ZIP: set via setImageFilename() in Lua, not XML
10. No os.time() - use g_currentMission.time
11. Field/trigger registration: addUpdateable() + isMissionStarted guard pattern
12. No goto, no continue in Lua 5.1

## Architecture
Central coordinator: WorkplaceSystem (global: g_WorkplaceSystem)
Subsystems owned by coordinator: TriggerManager, ShiftTracker, FinanceIntegration, HUD, Input