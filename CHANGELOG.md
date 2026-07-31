# Changelog

All notable changes to this addon are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/), versioning follows [SemVer](https://semver.org/).

## [0.1.0-beta.1] - 2026-07-31

First beta. Headline feature is peer-to-peer recipe sync.

### Added

- P2P recipe sync: your character periodically broadcasts its known recipes to the guild and picks up everyone else's the same way, over addon chat messages — no exporting or importing needed for guildmates running the addon. Includes a reactive hello for new peers, a periodic gossip handshake to catch drift, and targeted asks to fill gaps.
- Settings page: toggle the minimap icon, tune the P2P announce interval and the peer-count threshold that slows it down, manually refresh the guild roster / clean up departed peers, and force an immediate broadcast (same entry point as `/or debug broadcast`).
- Fuzzy (fzf-style) search on the Overview roster and the per-character recipe list.
- Known P2P peers are now included in the website export.
- Debug tooling for solo-testing the P2P mesh without a second account: `/or debug` slash commands, plus an optional in-UI Debug page (off by default).

### Changed

- Overview is now the default page and sits at the top of the sidebar; Import/Export and the new Settings page moved into an "Options" section, since P2P sync covers the common case and manual import/export is now the exception.
- P2P announce throttle now has a bootstrap phase: below 5 known peers, you announce on every login with no wait, so a new or isolated client gets found fast. The existing announce-interval/slowdown settings only kick in once you're past that.

### Fixed

- Minimap icon now respects square/non-round minimap shapes (e.g. ElvUI) instead of always orbiting a fixed circle.
- Overview roster search no longer stutters the whole game — per-character profession summaries are cached and invalidated only for the character that actually changed, instead of walking the whole recipe catalog for every guild member on every keystroke.
- ChatThrottleLib's hook registration no longer errors on clients where `SendChatMessage`/`SendAddonMessage` aren't global.
- P2P ASK requests guarded against non-guild senders and repeat spam.
- Debug output and export reminders referenced a nonexistent `/gt` slash command; the addon only registers `/or` (and `/ourrecipes`).
- Settings page content now scrolls instead of overflowing past the bottom of the window.

### Removed

- First Aid dropped from the recipe catalog — noise, nobody cares who knows it.
