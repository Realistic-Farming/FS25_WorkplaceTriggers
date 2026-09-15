# Changelog

All notable changes to FS25_WorkplaceTriggers will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

### Added
- **Named farm sites (WT-8).** A second kind of named place beside wage triggers: a farm-owned circle with a name and a purpose, no wage, shift or capacity. Sites live in their own save container (StateLedger module `WorkplaceTriggers_Sites` and `FS25_WorkplaceTriggers_Sites.xml`), reach each farm's players privately through the mod's own event pair, and are created, edited, deleted and (by a server administrator) transferred through a sessioned command channel gated by the native farm permission. The Workplace Manager gains a Farm Sites entry with a sibling site manager and editor; own-farm sites draw on the map in blue. Consumers read them through `mission.workplaceTriggers` (`registerSitePurpose`, `getSiteCapabilities`, `getSitesForFarm`, `getSite`, `subscribeSiteChanges`, `unsubscribeSiteChanges`, `openSiteManager`).
- Changelog file established (suite ruling 2026-08-22).
- Playtest fixes: WT_TOGGLE_HUD (RShift+K) and WT_HUD_EDIT (RShift+C) chords, WorkplaceHUD, MasterHUD bridge.
- Control Center action: WT_MENU opens the workplace menu from the suite Control Center (requires SettingsHub).

## [1.1.1.2] - 2026-08-22

- First entry under changelog tracking.
