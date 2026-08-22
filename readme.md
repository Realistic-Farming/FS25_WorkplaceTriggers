# FS25 Workplace Triggers
### *Placeable Off-Farm Work System*

[![Downloads](https://img.shields.io/github/downloads/TheCodingDad-TisonK/FS25_WorkplaceTriggers/total?style=for-the-badge&logo=github&color=4caf50&logoColor=white)](https://github.com/TheCodingDad-TisonK/FS25_WorkplaceTriggers/releases)
[![Release](https://img.shields.io/github/v/release/TheCodingDad-TisonK/FS25_WorkplaceTriggers?style=for-the-badge&logo=tag&color=76c442&logoColor=white)](https://github.com/TheCodingDad-TisonK/FS25_WorkplaceTriggers/releases/latest)
[![License](https://img.shields.io/badge/license-CC%20BY--NC--ND%204.0-lightgrey?style=for-the-badge&logo=creativecommons&logoColor=white)](https://creativecommons.org/licenses/by-nc-nd/4.0/)

<br>

> *"I've always wanted to 'work' at the post office on Judith Plains, but there was no way to make it official. This mod makes those little roleplay moments count with real income."*

<br>

**Turn any location on any map into a legitimate workplace.** Place a trigger, name it, set a wage and pay schedule, and earn income while you're "on the clock." Perfect for roleplayers who want their farmers to have side jobs, or anyone who wants to supplement their farm income with off-farm work.

`Singleplayer` · `Multiplayer` · `Persistent saves` · `EN / DE / FR / IT / NL / PL`

---

## Features

**Placeable trigger zones** — invisible zones you drop anywhere on any map, indoors or outdoors. No 3D object cluttering your scenery, just a named work location. Zone radius is configurable per trigger from 1 m up to 300 m.

**Custom workplace names** — call it Post Office, Feed Mill, Grandpa's Workshop, or anything that fits your map and your roleplay.

**Three pay schedules** — choose per trigger how you get paid:
- **Hourly** — wage x in-game hours worked (classic time-on-clock pay)
- **Flat Rate** — a fixed amount paid out at the end of every shift, regardless of time spent
- **Daily** — wage x number of in-game days worked

**Time multiplier per trigger** — control how fast in-game time counts for wage calculation. Options: Auto (follows server game speed), x1 (real time), x3, x5, x10.

**Zone-leave penalty** — if you leave the trigger zone during a shift, a 10-second countdown appears in the HUD. Step back inside (or within 8 m of the zone edge) to cancel it. If the countdown expires the shift auto-ends and you receive only 20% of your accrued earnings.

**Shift tracking HUD** — while on shift a panel shows the active workplace, time elapsed, and current earnings in real time. Toggle it with `Alt+W`. Enter edit mode with the *Toggle HUD Edit Mode* action (no default key - assign one under Options > Controls > Mods) to drag and resize the panel; position and scale are saved per savegame.

**Workplace Manager** — a full list dialog showing all placed triggers with name, wage, pay schedule, and coordinates. Add, edit, or delete any trigger from one screen. Open it with the *Open Workplace Manager* action (no default key - assign one under Options > Controls > Mods).

**Shift history log** — the last 50 completed shifts are recorded with workplace name, duration, payout, pay schedule, and in-game day.

**Persistent saves** — all trigger placements, names, wages, pay schedules, and HUD position survive game saves and reloads. Each savegame has its own independent set.

**Multiplayer** — each player tracks their own shift independently; earnings go into the shared farm account. All shift events are server-authoritative. Triggers are synced to clients on join/rejoin automatically.

**Optional integrations:**
- *FS25_NPCFavor* — completing shifts builds your relationship with the NPC you work for
- *FS25_WorkerCosts* — shift income is tracked alongside AI worker wages for a balanced economy view

Both integrations are silently skipped if those mods are not loaded.

---

## How to Use

1. Open the **Workplace Manager** (assign a key to *Open Workplace Manager* under Options > Controls > Mods) and click **Add**
2. Name the workplace, set a wage, choose a pay schedule, time multiplier, and zone radius — then confirm
3. The trigger is placed at your current player position
4. Walk into the trigger zone — an interaction prompt appears
5. Press **Shift+Alt+W** to start your shift; press it again to end the shift and collect wages

**Controls:**

| Key | Action |
|-----|--------|
| `Shift+Alt+W` | Start / end shift (when inside a trigger zone) |
| `Alt+W` | Show / hide the shift HUD |
| *Open Workplace Manager* action | Open / close Workplace Manager (no default key - assign under Options > Controls > Mods) |
| *Toggle HUD Edit Mode* action | HUD edit mode: drag and resize the shift panel (no default key - assign under Options > Controls > Mods) |

---

## Console Commands

Open the developer console (default: `` ` ``) and type:

| Command | Description |
|---------|-------------|
| `wtHelp` | Show all available commands |
| `wtStatus` | Show current shift status and live earnings |
| `wtList` | List all placed workplace triggers with coordinates |
| `wtDebug` | Toggle debug logging |
| `wtGui` | Toggle the Workplace Manager GUI |

---

## Settings

Available under **ESC > Settings > General Settings > Workplace Triggers:**

| Setting | Default | Description |
|---------|---------|-------------|
| Show Shift HUD | On | Show the shift panel while on shift |
| HUD Scale | 1.0x | Scale of the panel (0.75x / 1.0x / 1.25x / 1.5x / 2.0x) |
| Show Notifications | On | Flash notifications on shift start and end |
| Wage Multiplier | 1.0x | Global multiplier applied on top of per-trigger wages (0.5x – 2.0x) |
| End Shift on Leave | On | Auto-cancel with 20% penalty when you leave the zone |
| Show Earnings in HUD | On | Show the current earnings row in the HUD panel |
| Debug Mode | Off | Write detailed entries to the game log |

Settings are saved per savegame to `<savegameDir>/workplace_triggers_settings.xml`.

---

## Changelog

### v1.0.4.0
- Raised trigger radius maximum from 50 m to 300 m; edit dialog step increased to 5 m

### v1.0.3.0
- Fixed MP trigger sync; triggers now survive client join/rejoin via deferred sync request with up to 5 retry attempts
- Fixed farm ID routing so wages reach the correct farm in multiplayer
- Added time multiplier selector per trigger (Auto / x1 / x3 / x5 / x10)

### v1.0.2.0
- Fixed SHIFT_CONFIRM broadcast to include `hourlyWage` and `paySchedule` so zone-leave penalty calculates correctly on the client

### v1.0.1.0
- Added zone-leave penalty: 10-second countdown when player leaves the zone, 20% payout on auto-cancel

### v1.0.0.0
- Pay schedules: Hourly, Flat Rate, and Daily options per trigger
- Multiplayer sync: shift events routed through network events, server-authoritative
- Shift history log: last 50 completed shifts stored per session
- FS25_NPCFavor integration: optional, graceful, builds NPC favor on shift completion
- FS25_WorkerCosts integration: optional, graceful, registers triggers as off-farm jobs

### v0.1.0.0
- Initial release: trigger placement, hourly wages, shift HUD, Workplace Manager GUI, settings, save/load, map icons, console commands

---

## Contributing

Found a bug? [Open an issue](https://github.com/TheCodingDad-TisonK/FS25_WorkplaceTriggers/issues/new/choose) — the template will guide you through what information is needed.

---

## License

This mod is licensed under **[CC BY-NC-ND 4.0](https://creativecommons.org/licenses/by-nc-nd/4.0/)**.

You may share it in its original form with attribution. You may not sell it, modify and redistribute it, or reupload it under a different name or authorship. Contributions via pull request are explicitly permitted and encouraged.

**Author:** TisonK · **Version:** 1.0.4.0

© 2026 TisonK — See [LICENSE](LICENSE) for full terms.

---

<div align="center">

*Farming Simulator 25 is published by GIANTS Software. This is an independent fan creation, not affiliated with or endorsed by GIANTS Software.*

*Work anywhere, earn everywhere.*

</div>
