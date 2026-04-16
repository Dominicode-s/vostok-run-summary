# Changelog

All notable changes to the Run Summary mod will be documented here.

## v1.2.4
- **Fixed camera being half-locked after closing the shelter summary** — closing the modal was force-setting `gameData.freeze = false`, which left the shelter UI in a broken half-resumed state until the player pressed Esc a second time. The modal now snapshots `freeze` on open and restores it on close, matching whatever state the game had before the summary appeared.
- **Fixed the "every second" stutter** — `get_tree().node_added` was connected in `_ready` and stayed subscribed for the life of the session (main menu, shelter, everywhere), invoking the filter for every particle / bullet / UI node the engine spawned. The signal is now connected only while a run is active and disconnected on run end. The filter itself was also reordered to do the O(1) `has_method("Death")` check before walking the property list.
- Rate-limited the inventory pickup poll from once-per-frame to 4 Hz — iterating every child of `inventoryGrid` every frame was steady-state waste; 250 ms is plenty to catch every pickup.

## v1.2.3
- **Fixed crash when dying in a shelter** — every Vostok gameplay scene (Cabin, Village, the zones, etc.) has a root Node named "Map", and the mod was comparing `scene.name` strings to detect map-to-map transitions. Since every map was named "Map", transitions between gameplay scenes went undetected, which left the cached `_interface` reference pointing at the freed Interface from the previous map. When the next `_end_run` (triggered by entering the shelter) then tried to read inventory value via that dangling reference, the game crashed.
- Scene-change detection now compares by Node identity, not name, so map-to-map transitions are caught correctly.
- Added `is_instance_valid()` guards around every `_interface` access — the mod was using `if _interface == null` checks, which don't catch Godot 4's freed-but-not-null state. Any future transition race is now handled gracefully.

## v1.2.2
- Matched the modal text to MJRamon's v1.2.0 design intent — the main title ("Run Summary" / "Death Summary") and the category headers ("Combat", "Loot", "Economy", "Survival", "Progression") are now Title Case instead of ALL CAPS, and the title no longer force-overrides the theme color. The template's muted styling now shows through as the designer intended.

## v1.2.1
- **Fixed XP gained showing 0 with XP & Skills System v2.1.0+** — XP Skills now writes per-profile data at `user://XPData_<profile>.cfg`, but Run Summary was still reading the legacy `user://XPData.cfg`. Both mods now use the same profile-aware path.
- **Fixed run history being shared across Patty's Profiles** — history is now keyed by active profile at `user://RunSummaryHistory_<profile>.cfg`. First-time switch migrates the legacy `RunSummaryHistory.cfg` into the active profile and deletes the legacy file so other profiles start fresh.
- When switching profile in the Patty UI mid-session, the F6 "show last run" summary now reloads from the new profile's history on the next scene change.

## v1.2.0
- **UI overhaul** — huge thanks to **MJRamon** for the new visual design. Both modal and history views now use structured `.tscn` scenes with a themed header, icon, styled category headers, row bullets, and pill-style compact stats on history cards. Four new template scenes under `scenes/templates/` (`RunSummaryStatsHeader`, `RunSummaryStatsRow`, `RunSummaryHistoryEntry`, `RunSummaryHistoryStatPart`) make future visual tweaks editor-driven rather than code-driven.
- Rewrote the modal and history builders to instance the template scenes per real stat row / run entry instead of constructing bespoke Labels in code. Section skipping and conditional rows still work the same; empty sections are omitted entirely.
- Removed now-dead style constants and helper functions (`_add_section_header`, `_add_stat_row`, `_add_spacer`, `_add_separator`) — all styling lives in the `.tscn` templates.

## v1.1.4
- Fixed XP gained always showing 0 or incorrect values in run summary
- XP tracking now reads XPData.cfg directly at run start/end instead of polling in-memory values

## v1.1.3
- Fixed kill tracking not working without XP Skills mod — game removed built-in XP fields
- Replaced XP-delta kill detection with direct AI death polling via node_added signal
- Migrated UI from procedural code to .tscn scene files for easier community restyling
- Extracted style constants (colors, font sizes) to top of Main.gd

## v1.1.2
- Fixed kills not being tracked — `isFiring` timing race condition in game's physics frame
- Kill detection now checks `Input.is_action_pressed("fire")` for reliable same-frame attribution

## v1.1.1

- Added `type` and `default_type` fields to MCM Keycode entry per MCM docs

## v1.1.0

- Real-time kill tracking — kills are now detected frame-by-frame instead of estimated from XP
- Gun kill attribution via `isFiring` check — AI-on-AI kills (Faction Warfare) no longer counted
- Grenade kill attribution — tracks grenade throw state with a 6-second window
- Boss kills tracked and displayed separately in combat stats
- Works independently — no dependency on XP & Skills mod

## v1.0.1

- Added ModWorkshop update detection link
- Added README with install instructions and feature overview
- Fixed scrollbar overlapping stat values
- Included README in VMZ package

## v1.0.0

### Features
- Post-run summary modal automatically appears after every raid (death or shelter return)
- **Combat stats** — kills, damage taken, conditions sustained
- **Loot stats** — items picked up during the run (filtered to actual items only)
- **Survival stats** — energy, hydration, health, and mental drain with separate restoration tracking (eating/drinking shows up)
- **Economy stats** — cash earned (requires [Cash System](https://github.com/Dominicode-s/vostok-cash) mod)
- **XP stats** — experience gained (requires [XP & Skills System](https://github.com/Dominicode-s/vostok-skills) mod)
- **Run timer** — total time spent in raid
- Run history browser for the last 10 runs, saved to disk
- Reopen last summary anytime with **F6** (configurable)
- MCM integration for toggling auto-show and rebinding the hotkey
- Pure autoload mod — no script overrides, zero conflict risk with other mods
