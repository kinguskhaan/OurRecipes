# Changelog

All notable changes to this addon are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/), versioning follows [SemVer](https://semver.org/).

## [0.1.0-beta.5] - 2026-08-03

### Added

- Overview: up to 3 "Open <profession>" buttons for any catalogued profession you know but haven't scanned yet (Alchemy/Blacksmithing/Enchanting/Engineering/Jewelcrafting/Leatherworking/Tailoring/Cooking) — one click opens that profession's window via `CastSpellByID`, letting the existing scan-on-open hook pick it up, instead of needing to find and open it yourself. Buttons disappear per-profession once scanned; Overview now also refreshes itself automatically right after a scan completes (no more manual re-click or `/reload` needed to see the result).
- Settings: collapsible "Known peers" list — a plain-language, always-available (not Developer-mode-gated) answer to "who am I actually syncing with", showing name/class/recipe count per peer.
- Peer data page's "Copy to clipboard" button renamed to "Highlight text" — WoW addons have no real clipboard API, it only ever selected the text for a manual Ctrl+C.

### Fixed

- A completed P2P payload with a non-string `s` field (seen in the wild from a real peer, cause unconfirmed) got used directly as that peer's name, producing entries like `P2PData["1-realm"]` with `name = 1` — which then crashed Overview's roster sort (`:lower()` on a number) and, since a numeric "name" never matches a real guild member, got immediately auto-pruned every roster update before it could ever be seen. `payload.s` is now validated as a string before use; `GT.GetRoster` also drops any non-string-named entry defensively, so an already-corrupted saved entry can't crash the client either.
- `GT.PruneDepartedPeers()` (runs automatically on every `GUILD_ROSTER_UPDATE`) had no guard against firing before the server had actually sent the full guild roster after login/reload — `GetNumGuildMembers()` reading 0 in that window made every real peer look departed and wiped the entire P2P cache on login. Now skips pruning entirely when the roster reads as empty, since a real guild always has at least the player as a member.
- The "Open <profession>" feature's original design (`GetProfessions()` + `CastSpellByName`) turned out to be unreliable on this client build — `GetProfessions()` returned nil for both profession slots despite the character having real trained professions, and hardcoded classic/TBC-era profession spell IDs didn't match this build's numbering at all. Replaced with a live `GetSpellInfo(professionName)` + `IsSpellKnown` + `CastSpellByID` lookup instead of guessing IDs.
- Fixed the buttons briefly overlapping/rendering behind the roster list right after appearing — the scroll list's anchor was computed against the warning banner even when the (lower) buttons were also visible.
- Debug page's "Reset my professions" button wasn't wired to the same auto-refresh as a real scan, so Overview (and the "Open <profession>" buttons) could show stale state until manually navigated away and back.

## [0.1.0-beta.4] - 2026-08-02

### Fixed

- Broadcast throttle was structurally bypassed below the 5-peer bootstrap threshold: `GetResendIntervalSeconds()` returning 0 made the "recently sent" check impossible to satisfy, so every `SaveProfession` call (i.e. every `TRADE_SKILL_UPDATE`, which fires repeatedly just from having a profession window open) sent a full, unthrottled broadcast — not just on login as intended. Broadcasts triggered by a profession scan now only go out when the known-recipe signature actually changed; login keeps the "always eligible below threshold" behavior, since re-announcing to reach peers who haven't heard from you yet is the point there.
- Reactive hello could be sent twice for the same broadcast: the dedupe flag was cleared as soon as a hello drained from the queue, which — when the queue was empty — happens synchronously on the very first chunk of a sender's multi-chunk broadcast, before the rest of that broadcast has even finished assembling into a real peer entry. The flag is now session-permanent instead (reset only on reload/login).
- "Simulate multi-chunk" debug button now sends the full Engineering catalog instead of a fixed count (previously 40) — the fixed count had compressed down to a single chunk, silently no longer testing multi-chunk reassembly at all.

### Added

- Peer data page: reactive-hello and own-broadcast throttle state now show *why* the last one fired (`login` / `profession-scan` / `force`), plus separate own-vs-shared ChatThrottleLib send counters — the shared one is a global counter across every addon embedding the same library instance (WeakAuras, DBM, etc. all reuse the same instance), not specific to this addon, so it was misleading on its own.
- Peer data page: raw/completed traffic logs now tag each entry with a message `kind` (SYN/ACKM/ACKD/ASKQ/chunk), plus a new `outgoing` log mirroring the same shape for sends. All three only get built up in memory while Developer mode is on.

## [0.1.0-beta.3] - 2026-08-02

### Added

- Red warning banner on the Overview roster when this character has never scanned a profession: "You have no imported professions. Please open your professions once so this addon can pick them up." A silent client with zero scanned professions otherwise looks identical to a working one with just no data yet.
- Peer data page now also shows P2P scheduling/traffic info: last and next gossip round, own last/next-eligible broadcast, the pending reactive-hello queue, and a raw + completed message traffic log (who sent what, over which channel, and whether it was a reactive hello) — for diagnosing "is this actually syncing with anyone" without guessing.
- Debug page: "Reset my professions" button, for testing the no-profession banner without actually forgetting a real profession in-game.

### Changed

- Interface version bumped to 20506 to match the current Anniversary client build.

### Fixed

- Reset-my-professions debug tool now invalidates the cached profession summary too, not just the live data — Overview's roster count no longer shows a stale known-recipe number after a reset.
- The no-profession banner no longer follows you into a character's profession page — it only shows on the roster level now.

## [0.1.0-beta.2] - 2026-08-02

### Added

- Developer mode: a toggle on the Settings page (off by default) that adds a "Developer" section to the sidebar, separate from Options — the P2P debug tools moved there, alongside a new Peer data page showing a live pretty-printed JSON dump of what this character has learned about the guild's peers.

### Changed

- Debug page is no longer gated behind a hardcoded flag in code — it's now a persisted in-game setting (Developer mode), so it doesn't take an addon edit to reach it.

### Fixed

- Professionless characters now still broadcast (and answer hellos), so they register as real peers instead of silently being unable to take part in gossip or answer ASKs.
- Overview roster now sorts characters with real recipe data ahead of rank-only entries, instead of letting a high raw skill rank with no actual data outrank someone with real data.
- All P2P addon message sends now go through a guard that checks the 255-char client cap and drops (with a visible warning) instead of the message silently vanishing — nothing currently hits the cap, but this gives a trace if that assumption ever breaks.

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
