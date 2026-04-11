# Changelog

All notable changes to the Run Summary mod will be documented here.

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
