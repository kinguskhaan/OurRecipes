local GT = GuildThing

-----------------------------
-- P2P RECIPE SYNC --
-----------------------------
-- Symmetric addon-message mesh over the guild channel: every GuildThing
-- client broadcasts its own known recipes (as compact spellIDs, not
-- names) and merges what it hears from everyone else. No leader
-- election or officer targeting — every client sends and receives the
-- same way, so sync keeps working even when officers are offline.
-- Populates GuildThingDB.P2PData, read directly by Core.lua (same
-- relationship GuildData.lua already has with GuildThingDB.GuildData).

-----------------------------
-- ALGORITHM --
-----------------------------
-- All 5 steps are built.
--
-- knownPeers = whoever has an entry in GuildThingDB.P2PData — no
-- separate table. If someone logs in and broadcasts their stuff, that
-- proves they have the addon; once we've added their recipes, they're
-- in our knownPeers. If they were new to us, we're probably new to
-- them too — so we whisper back our own recipes, and they add us to
-- their knownPeers the same way. That's the whole discovery mechanism.
--
-- On throttling: ~3000 CPS (own output, sustained) gets you disconnected.
-- ChatThrottleLib handles this for us — shared safe budget across every
-- addon using it, so a single broadcast is never the risk. The actual
-- risk is many outgoing WHISPERS firing from the SAME client back to
-- back (e.g. 3's reactive hello, if a bunch of strangers all broadcast
-- during the same login) — that's why 3-4 queue/stagger instead of
-- firing everything at once.

-- 1. BROADCAST — on login, or when own recipes changed, compress own
--    known recipes and send to guild chat. Below BOOTSTRAP_PEER_THRESHOLD
--    known peers, no throttle at all — every login rebroadcasts, since a
--    fresh/isolated client needs to be found fast. Above that, skip if
--    unchanged and sent recently (user-configurable announceIntervalHours,
--    24h default; multiplied by SLOWDOWN_FACTOR once knownPeers reaches
--    peerThreshold, also user-configurable, 10 default — see
--    GetP2PSettings/GetResendIntervalSeconds below). This is mainly for
--    onboarding new people, not for freshness — once most of the guild
--    already knows you, broadcasting every day forever is just noise.

-- 2. RECEIVE — rebuild the compressed data, save it, add sender to
--    knownPeers. We fill in the new recipes, never overwrite, so we
--    don't risk writing over stuff with old data.

-- 3. REACTIVE HELLO — hear someone new for the first time -> put them
--    in a queue, and whisper them one by one, a few seconds apart,
--    regardless of how many piled up (a fresh login can hear a bunch
--    of strangers broadcast at once). Whispering them our own stuff
--    also adds us to their knownPeers, no reply needed back.

-- 4. GOSSIP HANDSHAKE — every so often, whisper one online knownPeer
--    (prefer whoever we haven't gossiped with longest, skip anyone
--    within the last 24h) a single combined hash of everything in
--    P2PData. If it matches, they reply "same", done. If not, they
--    reply with a small digest (name/hash/timestamp per person, their
--    K stalest rows) — for each row that doesn't match what we already
--    have, we ASK them for it (5). Only finds gaps in one direction
--    per round (we check against them, not the reverse) — the other
--    direction happens whenever they initiate a round against us or
--    someone else instead.

-- 5. ASK — whisper someone directly for one specific person's data,
--    merge it in (recipes only ever get added, so merging is always
--    safe, even if we guessed wrong about who had the fresher copy).

local ADDON_PREFIX = "GT_RECIPES"
local CHUNK_BODY_LIMIT = 230 -- addon messages cap at 255 chars; header eats ~16-25
local SEQ_WRAP = 100

-----------------------------
-- GUILD-SCOPED P2P STORAGE --
-----------------------------
-- GuildThingDB is account-wide (plain SavedVariables, not PerCharacter —
-- see the .toc), so without this, playing characters in different guilds
-- would fight over one shared P2P cache: logging into an alt in Guild B
-- makes GT.PruneDepartedPeers (roster-based, checks the CURRENTLY logged
-- in character's guild) look like everyone from Guild A just "departed",
-- silently deleting their data — and logging back to Guild A does the
-- same to Guild B's data. Scoping P2PData/P2PGossipState by guild+realm
-- keeps each guild's peer knowledge in its own bucket: alts in the SAME
-- guild still share one bucket (no need to re-collect), but different
-- guilds never step on each other.
-- Exposed (not local) so Core.lua's "other characters in this guild"
-- lookup (GT.GetOtherOwnCharactersInGuild) can tag which guild each of
-- your alts belongs to using the exact same key, without duplicating
-- this logic.
function GT.GetGuildKey()
	local guildName = GetGuildInfo("player")
	if not guildName then
		return nil
	end
	return string.lower(guildName .. "-" .. GetRealmName())
end

-- Returns this guild's P2PData bucket, or nil if not currently in a
-- guild. One-time migrates a pre-existing flat GuildThingDB.P2PData
-- (from before per-guild scoping existed) into the CURRENT guild's
-- bucket — the common single-guild case keeps all its data with no
-- action needed; anything that turns out to belong to a different guild
-- gets naturally pruned away by the normal roster-based cleanup.
function GT.GetP2PData()
	local guildKey = GT.GetGuildKey()
	if not guildKey then
		return nil
	end
	GuildThingDB.P2PDataByGuild = GuildThingDB.P2PDataByGuild or {}
	if GuildThingDB.P2PData and not GuildThingDB.P2PDataByGuild[guildKey] then
		GuildThingDB.P2PDataByGuild[guildKey] = GuildThingDB.P2PData
		GuildThingDB.P2PData = nil
	end
	GuildThingDB.P2PDataByGuild[guildKey] = GuildThingDB.P2PDataByGuild[guildKey] or {}
	return GuildThingDB.P2PDataByGuild[guildKey]
end

-- Same migration/scoping as GT.GetP2PData, for the gossip-partner
-- cooldown table.
function GT.GetP2PGossipState()
	local guildKey = GT.GetGuildKey()
	if not guildKey then
		return nil
	end
	GuildThingDB.P2PGossipStateByGuild = GuildThingDB.P2PGossipStateByGuild or {}
	if GuildThingDB.P2PGossipState and not GuildThingDB.P2PGossipStateByGuild[guildKey] then
		GuildThingDB.P2PGossipStateByGuild[guildKey] = GuildThingDB.P2PGossipState
		GuildThingDB.P2PGossipState = nil
	end
	GuildThingDB.P2PGossipStateByGuild[guildKey] = GuildThingDB.P2PGossipStateByGuild[guildKey] or {}
	return GuildThingDB.P2PGossipStateByGuild[guildKey]
end

-- Diagnostic counters for the oversized-message guard below, surfaced on
-- the Peer data page (UI.lua) via GT.GetOversizedDropInfo — distinct from
-- ChatThrottleLib's own pacing (GT.GetChatThrottleInfo further down):
-- this is a message refused outright, not one merely delayed.
local oversizedDropCount = 0
local lastOversizedDropAt = nil

-- Every successful send THIS addon made this session — separate from
-- ChatThrottleLib's own nTotalSent (see GetChatThrottleInfo below), which
-- is shared across every addon embedding the same library instance and
-- therefore useless for telling whether OurRecipes specifically is
-- sending too much.
local ownMessagesSent = 0

function GT.GetOversizedDropInfo()
	return { count = oversizedDropCount, lastAt = lastOversizedDropAt }
end

-- Diagnostic-only, session-local logs surfaced on the Peer data page
-- (UI.lua) for troubleshooting "is this actually working" — e.g. 0 known
-- peers despite other people having the addon installed. raw records
-- every addon message heard from someone else regardless of type or
-- whether it ever fully assembled, so "did anything even arrive" is
-- answerable without guessing; completed records only payloads that
-- fully decoded, tagged so a reactive hello (isHello: a WHISPER of
-- someone's own data, unprompted — see SendHelloTo, the only sender that
-- omits payload.s) is distinguishable from a broadcast or an ASK reply
-- relaying a third party; outgoing mirrors the same shape for our own sends.
local MAX_LOG_ENTRIES = 15
local rawMessageLog = {}
local completedPayloadLog = {}
local outgoingMessageLog = {}

-- No-ops unless Developer mode is on — these logs are session-local Lua
-- tables to begin with (never touch GuildThingDB/SavedVariables, on or
-- off), but skip even building them up in memory for everyone who never
-- opens that page.
local function PushLog(log, entry)
	if not GT.IsDeveloperModeEnabled() then
		return
	end
	table.insert(log, entry)
	while #log > MAX_LOG_ENTRIES do
		table.remove(log, 1)
	end
end

-- "kind" for a message we RECEIVED — sniffed from its own shape, since
-- OnAddonMessage doesn't know yet what it is when it logs. Outgoing sends
-- pass their kind explicitly instead (see SafeSendAddonMessage below) —
-- every call site already knows exactly what it's sending, no sniffing needed.
local function ClassifyMessage(message)
	if message:sub(1, 4) == "SYN:" then
		return "SYN"
	elseif message == "ACKM" then
		return "ACKM"
	elseif message:sub(1, 5) == "ACKD:" then
		return "ACKD"
	elseif message:sub(1, 5) == "ASKQ:" then
		return "ASKQ"
	elseif message:match("^%d+:%d+:%d+:") then
		return "chunk"
	end
	return "unknown"
end

function GT.GetP2PTrafficLog()
	return { raw = rawMessageLog, completed = completedPayloadLog, outgoing = outgoingMessageLog }
end

-- Every send funnels through here. Nothing should ever actually hit the
-- 255-char cap (control messages are fixed-format, data payloads are
-- pre-chunked to CHUNK_BODY_LIMIT above) — this is just the one place
-- that would notice and drop it if that assumption ever broke, instead
-- of the message silently vanishing into the client with no trace.
-- kind: purely diagnostic label for the outgoing log above (see
-- ClassifyMessage — this is the explicit equivalent for sends, where the
-- caller already knows what it's sending).
local function SafeSendAddonMessage(prio, message, chatType, target, kind)
	if #message > 255 then
		oversizedDropCount = oversizedDropCount + 1
		lastOversizedDropAt = time()
		print(
			("|cffff0000[GuildThing]|r dropped oversized addon message (%d bytes > 255): %s..."):format(
				#message,
				message:sub(1, 40)
			)
		)
		return
	end
	ownMessagesSent = ownMessagesSent + 1
	PushLog(outgoingMessageLog, { at = time(), to = target, channel = chatType, kind = kind, message = message })
	ChatThrottleLib:SendAddonMessage(prio, ADDON_PREFIX, message, chatType, target)
end

-- ChatThrottleLib's own pacing state for the "BULK" priority (the only one
-- this addon uses) — reaches into its internals since it exposes no public
-- introspection API, but the vendored copy's shape is stable. queued: a
-- message is sitting in CTL's send queue, not yet actually gone out yet.
-- availBandwidth going negative means CTL itself is currently over budget
-- and holding sends back, regardless of anything this addon's own
-- throttle logic decided. sharedLibraryTotalSent is CTL-wide (see
-- ChatThrottleLib.lua's top-of-file version check — every addon embedding
-- it reuses the SAME global instance), NOT specific to OurRecipes; use
-- ownMessagesSent for that.
function GT.GetChatThrottleInfo()
	local prio = ChatThrottleLib.Prio and ChatThrottleLib.Prio.BULK
	if not prio then
		return nil
	end
	return {
		queued = prio.Ring.pos ~= nil,
		sharedLibraryTotalSent = prio.nTotalSent,
		ownMessagesSent = ownMessagesSent,
		availBandwidth = prio.avail,
	}
end

-----------------------------
-- P2P SETTINGS (user-configurable) --
-----------------------------
-- Once knownPeers reaches peerThreshold, the announce interval is
-- multiplied by this — broadcasting is for onboarding people who don't
-- know you yet, not for freshness (that's the gossip handshake's job), so
-- once most of the guild already knows you there's diminishing value in
-- still broadcasting every announceIntervalHours forever. Not itself a
-- user setting — two knobs (threshold + interval) is already enough to
-- reason about without also configuring the slowdown multiplier.
local SLOWDOWN_FACTOR = 3

-- Below this many known peers, GetResendIntervalSeconds skips the
-- throttle entirely (returns 0) — a brand new or isolated client should
-- get found fast, so every login re-announces rather than waiting on
-- announceIntervalHours. Fixed, not a user setting, same reasoning as
-- SLOWDOWN_FACTOR above.
local BOOTSTRAP_PEER_THRESHOLD = 5

local function GetP2PSettings()
	GuildThingDB.p2pSettings = GuildThingDB.p2pSettings or {}
	local settings = GuildThingDB.p2pSettings
	settings.peerThreshold = settings.peerThreshold or 10
	settings.announceIntervalHours = settings.announceIntervalHours or 24
	return settings
end
GT.GetP2PSettings = GetP2PSettings

function GT.SetP2PPeerThreshold(n)
	GetP2PSettings().peerThreshold = math.max(1, tonumber(n) or 10)
end

function GT.SetP2PAnnounceIntervalHours(n)
	GetP2PSettings().announceIntervalHours = math.max(1, tonumber(n) or 24)
end

local function CountKnownPeers()
	local count = 0
	for _ in pairs(GT.GetP2PData() or {}) do
		count = count + 1
	end
	return count
end

-- Plain name/class/recipe-count list for the Settings page's "known
-- peers" collapse box (UI.lua) — a friendlier, non-Developer-mode view
-- than the full Peer data JSON dump, for anyone just wanting to confirm
-- "who am I actually syncing with" without opening Developer mode.
-- key on each entry is the actual GT.GetP2PData() map key — needed by
-- callers (the Settings page's per-peer "Remove" button, GT.RemovePeer
-- below) that need to remove one specific entry.
function GT.GetKnownPeerNames()
	local peers = {}
	for key, entry in pairs(GT.GetP2PData() or {}) do
		-- type(entry.name) == "string": defends against a stray pre-fix
		-- corrupted entry (see HandleCompletePayload's payload.s guard)
		-- still sitting in SavedVariables from before that validation existed.
		if type(entry.name) == "string" then
			local recipeCount = 0
			for _ in pairs(entry.recipeNames or {}) do
				recipeCount = recipeCount + 1
			end
			table.insert(peers, { key = key, name = entry.name, class = entry.class, recipeCount = recipeCount })
		end
	end
	table.sort(peers, function(a, b) return a.name:lower() < b.name:lower() end)
	return peers
end

-- Removes one specific peer by their GT.GetP2PData() key (see
-- GT.GetKnownPeerNames) — the Settings page's per-peer "Remove" button.
-- Unlike GT.PruneDepartedPeers this doesn't check guild membership at
-- all: it's a deliberate manual removal, not automatic cleanup, so it
-- works regardless of why the user wants that entry gone.
function GT.RemovePeer(key)
	local data = GT.GetP2PData()
	local entry = data and data[key]
	if not entry then
		return false
	end
	data[key] = nil
	GT.InvalidateProfessionSummaryCacheFor(entry.name, entry.realm)
	return true
end

local function GetResendIntervalSeconds()
	local settings = GetP2PSettings()
	local knownPeers = CountKnownPeers()
	if knownPeers < BOOTSTRAP_PEER_THRESHOLD then
		return 0
	end
	local seconds = settings.announceIntervalHours * 3600
	if knownPeers >= settings.peerThreshold then
		seconds = seconds * SLOWDOWN_FACTOR
	end
	return seconds
end

-- Settings-page live preview: current peer count and what interval that
-- actually works out to right now, so the two raw numbers aren't the only
-- thing a user has to reason about.
GT.CountKnownPeers = CountKnownPeers
GT.GetBootstrapPeerThreshold = function() return BOOTSTRAP_PEER_THRESHOLD end

function GT.GetEffectiveAnnounceIntervalHours()
	return GetResendIntervalSeconds() / 3600
end

-----------------------------
-- REVERSE CATALOG INDEX --
-----------------------------
-- spellID <-> recipe name, built once from the bundled catalog. The
-- ID->name direction turns a received flat ID list back into recipe
-- names without ever transmitting the names themselves; the reverse is
-- needed for ASK (5), which re-encodes a cached entry's recipe names
-- back into IDs to relay it in the same compact wire format. Only
-- kind == "spell" entries are covered (2 of ~2170 catalog entries are
-- kind == "item" and are a deliberately accepted gap here — still
-- covered by manual export/import).
local spellIDToRecipeName = {}
local recipeNameToSpellID = {}
for _, profName in ipairs(GT.GetProfessionOrder()) do
	for _, recipe in ipairs(GT.GetCatalogForProfession(profName)) do
		if recipe.kind == "spell" and recipe.id then
			spellIDToRecipeName[recipe.id] = recipe.name
			recipeNameToSpellID[recipe.name] = recipe.id
		end
	end
end

-----------------------------
-- SENDING --
-----------------------------

-- Every spellID for a currently-known recipe, across every profession
-- self has scanned. Built entirely from existing public GT.* API — no
-- new Core.lua plumbing needed for the sending side.
local function CollectSelfKnownSpellIDs()
	local selfName, selfRealm
	for _, char in ipairs(GT.GetRoster()) do
		if char.isSelf then
			selfName, selfRealm = char.name, char.realm
			break
		end
	end
	if not selfName then
		return {}
	end

	local ids = {}
	for _, profName in ipairs(GT.GetProfessionNames()) do
		for _, status in ipairs(GT.GetCharacterRecipeStatuses(selfName, selfRealm, profName)) do
			if status.known and status.kind == "spell" and status.id then
				table.insert(ids, status.id)
			end
		end
	end
	return ids
end

-- Same encode pipeline for a GUILD broadcast, a WHISPER hello, or an
-- ASK response — JSON -> zlib -> Base64 -> 230-char chunks. subjectName
-- is only set for an ASK response, where we're relaying someone ELSE's
-- cached data rather than sending our own (see HandleCompletePayload).
-- ids may be empty (a professionless sender) — still sent, not skipped,
-- so that sender gets a real P2PData entry on the receiving end and can
-- take part in gossip as a peer, not just a silent broadcast listener.
local function ChunksFromIDs(ids, class, subjectName)
	local payload = { c = class, ids = ids, s = subjectName }
	local json = GuildThing_JSON:encode(payload)
	local compressed = LibDeflate:CompressZlib(json)
	local blob = GuildThing_Base64.encode(compressed)

	local chunks = {}
	for i = 1, #blob, CHUNK_BODY_LIMIT do
		table.insert(chunks, blob:sub(i, i + CHUNK_BODY_LIMIT - 1))
	end
	return chunks
end

-- seq rolls 0-99 per send (not per chunk) so a receiver can tell a fresh
-- send apart from a stale one still trickling in from before.
local sendSeq = 0

-- ChatThrottleLib paces and bursts these safely on its own (shared budget
-- with every other addon using it) — no need for our own delay/stagger.
local function SendChunks(chunks, chatType, target)
	sendSeq = (sendSeq + 1) % SEQ_WRAP
	local seq = sendSeq
	local total = #chunks
	for i, chunk in ipairs(chunks) do
		local header = string.format("%d:%d:%d:", seq, i, total)
		SafeSendAddonMessage("BULK", header .. chunk, chatType, target, "chunk")
	end
end

-- Throttle state lives in GuildThingDB alongside the other per-character
-- fields (entry.professions, entry.lastImport) — signature is just the
-- sorted, comma-joined spellID list, cheap to compare as a plain string.
-- force (GT.DebugForceBroadcast) skips the throttle entirely.
-- Session-only, not persisted — surfaced via GT.GetSelfBroadcastInfo for
-- the Peer data page (UI.lua). lastThrottledAt/Reason: the last time a
-- send was attempted but skipped. lastSentReason: what actually triggered
-- the most recent successful send ("login", "profession-scan", "force").
local lastThrottledAt = nil
local lastThrottledReason = nil
local lastSentReason = nil

-- allowUnchangedResend: whether an UNCHANGED signature is even allowed to
-- justify a resend on its own (subject to the normal timing throttle
-- below) — true for the login/periodic-reannounce path (the whole point
-- there is reaching peers who haven't heard from you in a while, even
-- with nothing new to report), false for the SaveProfession-triggered
-- path (opening/scrolling a profession window you've already fully
-- scanned re-fires TRADE_SKILL_UPDATE repeatedly with identical data —
-- that alone should never justify a broadcast, regardless of throttle
-- state; only actually learning something new should).
-- reason: human-readable trigger label, purely diagnostic (see above).
local function TryBroadcastSelfRecipes(force, allowUnchangedResend, reason)
	if not IsInGuild() then
		return
	end

	local ids = CollectSelfKnownSpellIDs()
	table.sort(ids)
	local signature = table.concat(ids, ",")

	local key = GT.CharKey()
	GuildThingDB[key] = GuildThingDB[key] or {}
	local entry = GuildThingDB[key]

	local unchanged = entry.p2pLastSentSignature == signature
	if not force and unchanged then
		if not allowUnchangedResend then
			return
		end
		local recentlySent = entry.p2pLastSentAt and (time() - entry.p2pLastSentAt) < GetResendIntervalSeconds()
		if recentlySent then
			lastThrottledAt = time()
			lastThrottledReason = reason
			return
		end
	end

	local chunks = ChunksFromIDs(ids, select(2, UnitClass("player")))
	if not chunks then
		return
	end
	SendChunks(chunks, "GUILD")

	entry.p2pLastSentSignature = signature
	entry.p2pLastSentAt = time()
	lastSentReason = reason
end

-- Broadcast scheduling info for the Peer data page (UI.lua) — note this
-- is a threshold, not a timer: nothing actually re-sends until the next
-- PLAYER_LOGIN, GT.SaveProfession call, or manual force (Settings page
-- "Force broadcast now" / /or debug broadcast) happens to land after it.
function GT.GetSelfBroadcastInfo()
	local entry = GuildThingDB[GT.CharKey()]
	local lastSentAt = entry and entry.p2pLastSentAt
	local intervalSeconds = GetResendIntervalSeconds()
	return {
		lastSentAt = lastSentAt,
		lastSentReason = lastSentReason,
		resendIntervalSeconds = intervalSeconds,
		earliestNextBroadcastAt = lastSentAt and (lastSentAt + intervalSeconds) or nil,
		lastThrottledAt = lastThrottledAt,
		lastThrottledReason = lastThrottledReason,
	}
end

-----------------------------
-- REACTIVE HELLO --
-----------------------------
-- Fires on our side when we hear a GUILD broadcast from someone not yet
-- in GuildThingDB.P2PData — whisper them our own data so they learn
-- about us too, without waiting on our own next scheduled broadcast.
-- Never triggers off a WHISPER (see the channel check in OnAddonMessage)
-- — otherwise two strangers who don't know each other could whisper
-- "hello" back and forth forever.
local HELLO_STAGGER_SECONDS = 3

local helloQueue = {}
local helloQueued = {} -- set, dedupes a sender already waiting in the queue

local function SendHelloTo(senderName)
	local ids = CollectSelfKnownSpellIDs()
	local chunks = ChunksFromIDs(ids, select(2, UnitClass("player")))
	if not chunks then
		return
	end
	SendChunks(chunks, "WHISPER", senderName)
end

-- Drains one entry every HELLO_STAGGER_SECONDS, no matter how many piled
-- up — a fresh login can hear a whole batch of strangers broadcast at
-- once, and this keeps us from opening a dozen whisper streams at once.
local function DrainHelloQueue()
	local senderName = table.remove(helloQueue, 1)
	if not senderName then
		return
	end
	SendHelloTo(senderName)
	C_Timer.After(HELLO_STAGGER_SECONDS, DrainHelloQueue)
end

-- helloQueued entries are never cleared once set (session-only, resets on
-- reload/login) — a sender's own broadcast is usually several chunks, and
-- their P2PData entry only appears once ALL of them arrive. Clearing this
-- as soon as a hello drained (previously: in DrainHelloQueue) left a
-- window where a still-arriving chunk from the SAME broadcast would see
-- "not yet in P2PData" again and queue a second, redundant hello before
-- the first broadcast had even finished assembling.
local function QueueHello(senderName)
	if helloQueued[senderName] then
		return
	end
	helloQueued[senderName] = true
	local wasEmpty = #helloQueue == 0
	table.insert(helloQueue, senderName)
	if wasEmpty then
		DrainHelloQueue()
	end
end

-----------------------------
-- GOSSIP HANDSHAKE + ASK --
-----------------------------
-- Wire format for everything below: a single non-chunked WHISPER,
-- distinguished from a DATA chunk (which always starts "digits:") by a
-- leading letter tag. Small enough to never need chunking themselves —
-- a hash or a handful of digest rows, not a recipe list.
local GOSSIP_INTERVAL_SECONDS = 60 * 60
local GOSSIP_COOLDOWN_SECONDS = 24 * 60 * 60
local DIGEST_ROW_LIMIT = 5

-- Canonical (sorted) recipe-name signature for one cached entry, hashed
-- with LibDeflate's Adler32 so it stays short — same reasoning as the
-- sorted spellID signature in TryBroadcastSelfRecipes: identical recipe
-- sets must hash identically regardless of table iteration order.
local function EntrySignatureHash(entry)
	local names = {}
	for name in pairs(entry.recipeNames) do
		table.insert(names, name)
	end
	table.sort(names)
	return LibDeflate:Adler32(table.concat(names, ","))
end

-- Everything the gossip mesh treats as "stuff I can tell someone about":
-- real received peers (GT.GetP2PData) PLUS this account's own alts in the
-- same guild, viewed as P2PData-shaped entries sourced from their own
-- real scan (GT.BuildOwnAltP2PEntry, Core.lua). An alt that rarely logs
-- in still gets its recipes spread through the guild this way — lazily,
-- only when a gossip partner's digest actually reveals they're missing
-- it, then answered on demand by OnAskRequest below — rather than a
-- blanket broadcast on every login regardless of whether anyone needs it.
function GT.GetGossipableEntries()
	local combined = {}
	for key, entry in pairs(GT.GetP2PData() or {}) do
		combined[key] = entry
	end
	for _, alt in ipairs(GT.GetOtherOwnCharactersInGuild()) do
		local altEntry = GT.BuildOwnAltP2PEntry(alt.key)
		if altEntry then
			combined[GT.ClubScanKey(altEntry.name, altEntry.realm)] = altEntry
		end
	end
	return combined
end

-- One hash standing in for everything gossipable — cheap enough to
-- whisper every round, and matching means there's nothing more to do
-- this round.
local function BuildCombinedHash()
	local entries = GT.GetGossipableEntries()
	local keys = {}
	for key in pairs(entries) do
		table.insert(keys, key)
	end
	table.sort(keys)

	local parts = {}
	for _, key in ipairs(keys) do
		table.insert(parts, key .. ":" .. EntrySignatureHash(entries[key]))
	end
	return LibDeflate:Adler32(table.concat(parts, ";"))
end

-- The K entries we've held onto longest without refreshing, so a
-- mismatch eventually surfaces every cached person over enough rounds
-- instead of only ever re-checking the same few.
local function BuildDigestRows(limit)
	local entries = GT.GetGossipableEntries()
	local keys = {}
	for key in pairs(entries) do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return (entries[a].receivedAt or 0) < (entries[b].receivedAt or 0)
	end)

	local rows = {}
	for i = 1, math.min(limit, #keys) do
		local entry = entries[keys[i]]
		table.insert(rows, string.format("%s,%s,%d", entry.name, EntrySignatureHash(entry), entry.receivedAt or 0))
	end
	return table.concat(rows, ";")
end

local function ParseDigestRows(str)
	local rows = {}
	for rowStr in str:gmatch("[^;]+") do
		local name, hash, receivedAt = rowStr:match("^([^,]+),([^,]+),(%d+)$")
		if name then
			table.insert(rows, { name = name, hash = hash, receivedAt = tonumber(receivedAt) })
		end
	end
	return rows
end

-- Classic-era roster lookup by name — GuildThingDB.ClubScan (Core.lua)
-- doesn't track online status, so this is the simplest direct source.
-- Guild size keeps this cheap even scanned once per candidate; gossip
-- only runs hourly. Returns the roster's online flag, or nil if the
-- name isn't a guild member at all.
local function FindGuildRosterEntry(name)
	for i = 1, GetNumGuildMembers() do
		local rosterName, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
		local rosterShortName = rosterName and rosterName:match("^([^-]+)")
		if rosterShortName and string.lower(rosterShortName) == string.lower(name) then
			return online
		end
	end
	return nil
end

local function IsGuildMemberOnline(name)
	return FindGuildRosterEntry(name) == true
end

-- WHISPER isn't guild-scoped in WoW — anyone who knows this addon's
-- prefix/format could whisper an ASKQ for guild recipe data without
-- being a member. OnAskRequest checks this before ever replying.
local function IsGuildMember(name)
	return FindGuildRosterEntry(name) ~= nil
end
GT.IsGuildMember = IsGuildMember

local function GetGossipState()
	return GT.GetP2PGossipState() or {}
end

local function PickGossipPartner()
	local state = GetGossipState()
	local candidates = {}
	for key, entry in pairs(GT.GetP2PData() or {}) do
		local lastSynced = state[key]
		local recently = lastSynced and (time() - lastSynced) < GOSSIP_COOLDOWN_SECONDS
		if not recently and entry.name and IsGuildMemberOnline(entry.name) then
			table.insert(candidates, entry.name)
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[math.random(#candidates)]
end

-- GetGuildRosterInfo can serve stale/empty data until something has
-- requested a refresh this session. The refresh call moved to C_GuildInfo
-- at some point; global GuildRoster() no longer exists on this client.
local function RequestGuildRosterRefresh()
	if C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	elseif GuildRoster then
		GuildRoster()
	end
end

local function TryGossipHandshake()
	if not IsInGuild() then
		return
	end

	-- Kick a refresh every round so IsGuildMemberOnline isn't working off
	-- a roster from before login.
	RequestGuildRosterRefresh()

	local partner = PickGossipPartner()
	if not partner then
		return
	end

	local state = GetGossipState()
	state[GT.ClubScanKey(partner, GetRealmName())] = time()

	SafeSendAddonMessage("BULK", "SYN:" .. BuildCombinedHash(), "WHISPER", partner, "SYN")
end

-- Timestamp of the most recent gossip round, whether or not a partner
-- was actually found — the Peer data page (UI.lua, via
-- GT.GetGossipRuntimeInfo below) uses this plus GOSSIP_INTERVAL_SECONDS
-- to show when the next one is due. Session-only, not persisted: it's a
-- recursive C_Timer chain, not a saved schedule, and resets on reload.
local lastGossipRoundAt = nil

local function ScheduleGossipHandshake()
	lastGossipRoundAt = time()
	TryGossipHandshake()
	C_Timer.After(GOSSIP_INTERVAL_SECONDS, ScheduleGossipHandshake)
end

function GT.GetGossipRuntimeInfo()
	return {
		intervalSeconds = GOSSIP_INTERVAL_SECONDS,
		lastRoundAt = lastGossipRoundAt,
		nextRoundAt = lastGossipRoundAt and (lastGossipRoundAt + GOSSIP_INTERVAL_SECONDS) or nil,
	}
end

-- Snapshot of who's still waiting for their reactive-hello reply — see
-- QueueHello/DrainHelloQueue above. Pending names in send order, oldest
-- (next to drain) first.
function GT.GetHelloQueueSnapshot()
	local pending = {}
	for _, name in ipairs(helloQueue) do
		table.insert(pending, name)
	end
	return {
		staggerSeconds = HELLO_STAGGER_SECONDS,
		pending = pending,
	}
end

-- Someone whispered us their combined hash. Matching means we already
-- have everything they do — reply "same" and stop. Otherwise hand back
-- our own digest so they can spot which of our cached entries differ
-- from theirs (see OnAckDigest for the other half of that exchange).
local function OnSyn(senderName, theirHash)
	if tostring(BuildCombinedHash()) == theirHash then
		SafeSendAddonMessage("BULK", "ACKM", "WHISPER", senderName, "ACKM")
	else
		SafeSendAddonMessage("BULK", "ACKD:" .. BuildDigestRows(DIGEST_ROW_LIMIT), "WHISPER", senderName, "ACKD")
	end
end

-- For every row that doesn't match what we already have cached (missing
-- entirely, or a different hash), ASK the peer who showed it to us —
-- one whisper per gap, ChatThrottleLib paces them same as anything else.
-- Compares against GT.GetGossipableEntries() — the same combined set
-- BuildCombinedHash/BuildDigestRows advertise to gossip partners — not
-- just GT.GetP2PData(). Comparing against P2PData alone meant any of your
-- own alts (only ever present in the gossipable set, never actually
-- stored in P2PData) permanently looked "missing", triggering a wasted
-- ASKQ round-trip for them every single round.
local function OnAckDigest(senderName, rowsStr)
	local entries = GT.GetGossipableEntries()
	for _, row in ipairs(ParseDigestRows(rowsStr)) do
		local key = GT.ClubScanKey(row.name, GetRealmName())
		local ownEntry = entries[key]
		local ownHash = ownEntry and tostring(EntrySignatureHash(ownEntry))
		if ownHash ~= row.hash then
			SafeSendAddonMessage("BULK", "ASKQ:" .. row.name, "WHISPER", senderName, "ASKQ")
		end
	end
end

-- In-memory, keyed by "asker:target" — not per-asker, since one honest
-- gossip round can legitimately ASK about DIGEST_ROW_LIMIT different
-- people back to back. Only blocks asking about the SAME person
-- repeatedly, which is what spam/abuse would actually look like.
local ASK_COOLDOWN_SECONDS = 60
local askCooldowns = {}

-- Someone asked for a specific person's cached data. Re-encode their
-- recipe names back into spellIDs (recipeNameToSpellID) so the reply
-- goes out in the same compact chunked format as a normal broadcast,
-- just tagged with whose data it actually is.
local function OnAskRequest(senderName, targetName)
	if not IsGuildMember(senderName) then
		return
	end

	local cooldownKey = senderName .. ":" .. targetName
	local lastAnswered = askCooldowns[cooldownKey]
	if lastAnswered and (time() - lastAnswered) < ASK_COOLDOWN_SECONDS then
		return
	end

	local entry = GT.GetGossipableEntries()[GT.ClubScanKey(targetName, GetRealmName())]
	if not entry then
		return
	end
	askCooldowns[cooldownKey] = time()

	local ids = {}
	for name in pairs(entry.recipeNames) do
		local id = recipeNameToSpellID[name]
		if id then
			table.insert(ids, id)
		end
	end
	table.sort(ids)

	local chunks = ChunksFromIDs(ids, entry.class, targetName)
	if not chunks then
		return
	end
	SendChunks(chunks, "WHISPER", senderName)
end

-----------------------------
-- RECEIVING --
-----------------------------

-- In-memory only, keyed by sender name — no need to survive a reload. A
-- chunk with a new seq resets that sender's buffer, superseding whatever
-- broadcast was previously in-flight from them.
local pendingChunks = {}

-- Reverse of TryBroadcastSelfRecipes' send pipeline: Base64 -> zlib ->
-- JSON -> spellID list -> recipe names. Stored under the SENDER's
-- name-realm key normally — but payload.s (only set on an ASK reply,
-- see OnAskRequest) means this is someone else's data relayed through
-- the sender, so it's stored under the subject's key instead. Either
-- way we fill in on top of whatever's already cached rather than
-- replacing it — recipes are only ever gained, so union is always
-- correct even if the relayed copy turns out to be the staler one. Any
-- decode step failing (corrupt/partial data) just drops the payload
-- silently, never touches our own saved data.
local function HandleCompletePayload(senderName, blob, channel)
	local decodeOk, compressed = pcall(GuildThing_Base64.decode, blob)
	if not decodeOk or not compressed then
		return
	end

	local zlibOk, json = pcall(function()
		return LibDeflate:DecompressZlib(compressed)
	end)
	if not zlibOk or not json then
		return
	end

	local jsonOk, payload = pcall(function()
		return GuildThing_JSON:decode(json)
	end)
	if not jsonOk or type(payload) ~= "table" or type(payload.ids) ~= "table" then
		return
	end

	-- payload.s is untrusted network data — a peer on a corrupt/mismatched
	-- version (or anything else that produced a non-string here) must not
	-- get to name a P2PData entry with it. table.sort in GT.GetRoster
	-- (Core.lua) assumes every name is a string and calls :lower() on it;
	-- a stray number here previously crashed the whole Overview roster.
	local rawSubject = type(payload.s) == "string" and payload.s or nil

	-- rawPayloadS: payload.s AS RECEIVED, whatever type it actually was —
	-- tostring'd so a corrupt/unexpected value (e.g. a number, like the
	-- one that once turned up in the wild) is directly visible in the log
	-- instead of silently vanishing into the senderName fallback below.
	-- Same idea as the outgoing/raw logs' `message` field: capture what
	-- actually came in, not just what we decided to do with it, so a
	-- future case like that is diagnosable from the log alone.
	PushLog(completedPayloadLog, {
		at = time(),
		from = senderName,
		channel = channel,
		subject = rawSubject or senderName,
		rawPayloadS = payload.s ~= nil and tostring(payload.s) or nil,
		isHello = channel == "WHISPER" and not rawSubject,
	})

	local subjectName = rawSubject or senderName
	local key = GT.ClubScanKey(subjectName, GetRealmName())

	-- A relayed reply CAN legitimately name the current character as its
	-- subject — e.g. a gossip partner's digest still lists you (you're
	-- never in your own P2PData to begin with, since self-echoes are
	-- filtered before this ever runs, so your own row always looks
	-- "missing" to OnAckDigest), which gets ASKQ'd and answered right
	-- back to you. Storing that would create a permanent ghost entry for
	-- yourself: it can never fail the guild-membership prune check, so it
	-- never gets cleaned up, inflates GT.CountKnownPeers(), shows your own
	-- name in the "Known peers" list, and could even get you picked as
	-- your own gossip partner. You already have full authoritative data
	-- about yourself locally — never worth caching a copy of it here.
	if key == GT.ClubScanKey(UnitName("player"), GetRealmName()) then
		return
	end

	local p2pData = GT.GetP2PData()
	if not p2pData then
		return
	end

	local existing = p2pData[key]
	local recipeNames = existing and existing.recipeNames or {}
	for _, spellID in ipairs(payload.ids) do
		local name = spellIDToRecipeName[spellID]
		if name then
			recipeNames[name] = true
		end
	end

	p2pData[key] = {
		name = subjectName,
		realm = GetRealmName(),
		class = payload.c,
		recipeNames = recipeNames,
		receivedAt = time(),
	}
	GT.InvalidateProfessionSummaryCacheFor(subjectName, GetRealmName())
end

-- Buffers chunks per sender until all of them have arrived, then hands
-- the reassembled blob to HandleCompletePayload. Every other GT_RECIPES
-- message (broadcast or otherwise) funnels through here.
local function OnAddonMessage(prefix, message, channel, sender)
	if prefix ~= ADDON_PREFIX then
		return
	end

	-- sender may arrive as "Name-Realm" even in a single-realm guild
	-- depending on connected-realm settings — normalize to just the name,
	-- same single-realm assumption used everywhere else in this addon.
	local senderName = sender:match("^([^-]+)")
	if not senderName then
		return
	end
	if string.lower(senderName) == string.lower(UnitName("player")) then
		return
	end -- ignore our own broadcast, if it ever echoes

	PushLog(
		rawMessageLog,
		{ at = time(), from = senderName, channel = channel, kind = ClassifyMessage(message), message = message }
	)

	-- Only a GUILD broadcast can trigger a hello — never a WHISPER, or
	-- two strangers who don't know each other could whisper back and
	-- forth forever.
	if channel == "GUILD" and not GT.GetP2PEntry(senderName, GetRealmName()) then
		QueueHello(senderName)
	end

	-- Gossip handshake + ASK control messages are single, non-chunked
	-- whispers tagged with a leading letter — never mistaken for a DATA
	-- chunk header, which always starts with digits.
	if message:sub(1, 4) == "SYN:" then
		OnSyn(senderName, message:sub(5))
		return
	elseif message == "ACKM" then
		return
	elseif message:sub(1, 5) == "ACKD:" then
		OnAckDigest(senderName, message:sub(6))
		return
	elseif message:sub(1, 5) == "ASKQ:" then
		OnAskRequest(senderName, message:sub(6))
		return
	end

	local seq, index, total, chunk = message:match("^(%d+):(%d+):(%d+):(.*)$")
	if not seq then
		return
	end
	seq, index, total = tonumber(seq), tonumber(index), tonumber(total)

	local buffer = pendingChunks[senderName]
	if not buffer or buffer.seq ~= seq then
		buffer = { seq = seq, total = total, chunks = {}, receivedCount = 0 }
		pendingChunks[senderName] = buffer
	end

	if not buffer.chunks[index] then
		buffer.chunks[index] = chunk
		buffer.receivedCount = buffer.receivedCount + 1
	end

	if buffer.receivedCount == buffer.total then
		local parts = {}
		for i = 1, buffer.total do
			table.insert(parts, buffer.chunks[i])
		end
		pendingChunks[senderName] = nil
		HandleCompletePayload(senderName, table.concat(parts), channel)
	end
end

-- Developer-only: wipes every peer this character's guild bucket knows
-- about (GT.GetP2PData()), for testing sync/pruning from a clean slate
-- without waiting for real (or fake) peers to naturally age out. Doesn't
-- touch gossipPartnerCooldowns — those are harmless bookkeeping either
-- way (see GT.GetP2PGossipState) and clearing them isn't the point here.
function GT.DebugResetPeers()
	local data = GT.GetP2PData()
	if not data then
		return 0
	end
	local count = 0
	for key in pairs(data) do
		data[key] = nil
		count = count + 1
	end
	return count
end

-----------------------------
-- PEER GC (departed members) --
-----------------------------
-- P2PData never removes an entry on its own — someone who leaves the
-- guild would otherwise stay cached (and keep showing up in the Overview
-- roster/crafters lookups) forever. Runs automatically off the same
-- GUILD_ROSTER_UPDATE signal Core.lua's ScanGuildClubProfessions already
-- reacts to (see the hook there) — no separate polling timer needed, it
-- piggybacks on guild roster churn the addon was already watching for.
-- Also callable directly (Settings button) for an on-demand check.
function GT.PruneDepartedPeers()
	local data = GT.GetP2PData()
	if not data then
		return 0
	end

	-- GUILD_ROSTER_UPDATE (this function's automatic trigger, Core.lua)
	-- fires early after login/reload, sometimes before the server has
	-- actually sent the full roster — GetNumGuildMembers() reads 0 in that
	-- window. Every real peer would fail IsGuildMember and get wiped for
	-- no reason. A real guild always has at least the player as a member,
	-- so 0 here means "not loaded yet", not "empty guild" — skip pruning
	-- rather than trusting an incomplete roster.
	if GetNumGuildMembers() == 0 then
		return 0
	end

	local removed = 0
	for key, entry in pairs(data) do
		if not IsGuildMember(entry.name) then
			data[key] = nil
			GT.InvalidateProfessionSummaryCacheFor(entry.name, entry.realm)
			removed = removed + 1
		end
	end
	return removed
end

-- GUILD_ROSTER_UPDATE can fire several times in a burst while the server
-- sends the roster in batches — for a large guild (seen in the wild:
-- 431 members) those batches can legitimately be spaced several seconds
-- apart, so even a "quiet for a few seconds" debounce can still fire on
-- a still-incomplete roster if it ever catches a gap between two
-- batches. A nonzero-but-incomplete count was enough to wipe real peers
-- who just hadn't landed in the partial roster yet — and once wiped,
-- that data is just gone, no self-correction later undoes it. Given
-- that, this errs heavily toward correctness over speed: pruning isn't
-- time-critical (nothing breaks if it waits), being wrong is expensive
-- and permanent, so patience costs nothing here.
--
-- Verify convergence, not just a single quiet interval: only trust the
-- roster once GetNumGuildMembers() reads the SAME count
-- PRUNE_REQUIRED_STABLE_STREAK times in a row (a lone match could still
-- just be a lull between batches for a big guild). Capped at
-- MAX_PRUNE_SETTLE_CHECKS rounds so a guild that pathologically never
-- reports a stable count still eventually prunes rather than never
-- running at all — worst case a couple minutes, which is fine here.
--
-- Also rate-limited to once a day (GuildThingDB.lastPeerPruneAt): there's
-- no need to even attempt this on every single login/reload, and fewer
-- attempts means fewer chances to ever hit an unlucky timing window in
-- the first place. force bypasses the daily limit — used by the manual
-- Settings-page "Refresh roster / clean up peers" button and the Debug
-- page's test button, since an explicit user request should always
-- actually run, not get silently skipped by the automatic path's limit.
--
-- Every caller — the automatic GUILD_ROSTER_UPDATE hook (Core.lua), the
-- manual Settings button, and the Debug page test button — routes
-- through this ONE function, so none of them duplicate (and risk
-- drifting out of sync with) this same guard. callback (optional)
-- receives the removed count once the prune actually runs, or is
-- skipped entirely by the daily rate limit.
local PRUNE_SETTLE_CHECK_SECONDS = 5
local PRUNE_REQUIRED_STABLE_STREAK = 3
local MAX_PRUNE_SETTLE_CHECKS = 20
local PRUNE_MIN_INTERVAL_SECONDS = 24 * 60 * 60

local pruneDebounceTimer
local pruneLastSeenMemberCount = nil
local pruneStableStreak = 0
local pruneChecksRemaining = 0

-- verbose: prints each settle-check round to chat — only ever passed by
-- the Debug page's explicit "Test roster prune settling" button/command,
-- never by the automatic GUILD_ROSTER_UPDATE hook or the Settings-page
-- button, so a regular user never sees this chatter from something that
-- just ran on its own in the background. Deliberately NOT gated on
-- Developer mode alone — that would still print during an automatic run
-- for anyone who happens to have it enabled, which is exactly the noise
-- this is meant to avoid.
function GT.RequestDebouncedPeerPrune(callback, force, verbose)
	if not force then
		local lastPrunedAt = GuildThingDB.lastPeerPruneAt
		if lastPrunedAt and (time() - lastPrunedAt) < PRUNE_MIN_INTERVAL_SECONDS then
			if callback then
				callback(0)
			end
			return
		end
	end

	if pruneDebounceTimer then
		pruneDebounceTimer:Cancel()
	end
	pruneLastSeenMemberCount = nil
	pruneStableStreak = 0
	pruneChecksRemaining = MAX_PRUNE_SETTLE_CHECKS

	local function CheckSettled()
		pruneDebounceTimer = nil
		local currentCount = GetNumGuildMembers()
		pruneChecksRemaining = pruneChecksRemaining - 1

		if currentCount == pruneLastSeenMemberCount then
			pruneStableStreak = pruneStableStreak + 1
		else
			pruneStableStreak = 1
		end
		pruneLastSeenMemberCount = currentCount

		local settled = pruneStableStreak >= PRUNE_REQUIRED_STABLE_STREAK or pruneChecksRemaining <= 0

		if verbose then
			if settled then
				print(
					("|cffffff00[GuildThing]|r roster settle check: %d members, stable x%d — settled, pruning now."):format(
						currentCount,
						pruneStableStreak
					)
				)
			else
				print(
					("|cffffff00[GuildThing]|r roster settle check: %d members, stable x%d/%d — checking again in %ds (%d left)."):format(
						currentCount,
						pruneStableStreak,
						PRUNE_REQUIRED_STABLE_STREAK,
						PRUNE_SETTLE_CHECK_SECONDS,
						pruneChecksRemaining
					)
				)
			end
		end

		if not settled then
			pruneDebounceTimer = C_Timer.NewTimer(PRUNE_SETTLE_CHECK_SECONDS, CheckSettled)
			return
		end

		local removed = GT.PruneDepartedPeers()
		GuildThingDB.lastPeerPruneAt = time()
		if verbose then
			print(("|cffffff00[GuildThing]|r roster settle check: pruned %d departed peer(s)."):format(removed))
		end
		if callback then
			callback(removed)
		end
	end

	pruneDebounceTimer = C_Timer.NewTimer(PRUNE_SETTLE_CHECK_SECONDS, CheckSettled)
end

-- Settings-page button: request a fresh roster from the server, then prune
-- through the same debounced path as automatic roster updates — NOT
-- immediately, since the refresh request is async (server round-trip) and
-- pruning right away would race the same partial-roster window
-- GT.RequestDebouncedPeerPrune exists to avoid. force=true: an explicit
-- button click should always actually run, not get silently skipped by
-- the once-a-day limit. callback receives the removed count once the
-- settle-check finishes, a few seconds to a couple minutes later.
function GT.RefreshGuildRosterAndPrunePeers(callback)
	RequestGuildRosterRefresh()
	GT.RequestDebouncedPeerPrune(callback, true)
end

-----------------------------
-- EVENT WIRING --
-----------------------------

C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)

local p2pFrame = CreateFrame("Frame")
p2pFrame:RegisterEvent("CHAT_MSG_ADDON")
p2pFrame:RegisterEvent("PLAYER_LOGIN")
p2pFrame:SetScript("OnEvent", function(_, event, ...)
	if event == "CHAT_MSG_ADDON" then
		OnAddonMessage(...)
	else
		TryBroadcastSelfRecipes(false, true, "login")
		ScheduleGossipHandshake()
	end
end)

-- Re-check the throttle whenever a fresh scan completes too (not just on
-- login) — hooking GT.SaveProfession rather than the TRADE_SKILL_UPDATE
-- events directly since that's the single choke point both ScanTradeSkill
-- and ScanCraft already funnel through. Wrapped so SaveProfession's own
-- (skillName, recipes) arguments never get passed through as our force
-- parameter — hooksecurefunc forwards the hooked call's original args.
hooksecurefunc(GT, "SaveProfession", function()
	TryBroadcastSelfRecipes(false, false, "profession-scan")
end)

-----------------------------
-- DEBUG HOOKS --
-----------------------------
-- Thin wrappers so /or debug (Debug.lua) can exercise this file's
-- internals without a second account/client online — everything above
-- is guild-chat/whisper based and otherwise hard to test solo.
function GT.DebugForceBroadcast()
	TryBroadcastSelfRecipes(true, nil, "force")
end

function GT.DebugForceGossip(targetName)
	SafeSendAddonMessage("BULK", "SYN:" .. BuildCombinedHash(), "WHISPER", targetName, "SYN")
end

-- Exposes the otherwise-local BuildCombinedHash so a debug SYN can be
-- hand-built to deliberately match (or not) — the only way to solo-test
-- both branches of OnSyn.
function GT.DebugGetCombinedHash()
	return BuildCombinedHash()
end

function GT.DebugSimulateMessage(senderName, message, channel)
	OnAddonMessage(ADDON_PREFIX, message, channel or "GUILD", senderName)
end

-- Builds a real chunked broadcast for one or more comma-separated recipe
-- names (looked up via recipeNameToSpellID) and feeds it through
-- OnAddonMessage as if fakeName had sent it — exercises the actual
-- encode/chunk/decode pipeline, not just a hand-typed message string.
-- Enough recipe names pushes the encoded blob past CHUNK_BODY_LIMIT,
-- the only way to solo-test multi-chunk reassembly.
function GT.DebugFakeRecipeBroadcast(fakeName, recipeNamesStr, class)
	local ids = {}
	for rawName in recipeNamesStr:gmatch("[^,]+") do
		local recipeName = rawName:match("^%s*(.-)%s*$")
		local id = recipeNameToSpellID[recipeName]
		if id then
			table.insert(ids, id)
		else
			print("|cffff0000[GuildThing debug]|r unknown recipe name: " .. recipeName)
		end
	end
	if #ids == 0 then
		return
	end

	local chunks = ChunksFromIDs(ids, class or "WARRIOR")
	if not chunks then
		return
	end

	local total = #chunks
	for i, chunk in ipairs(chunks) do
		local header = string.format("%d:%d:%d:", 1, i, total)
		OnAddonMessage(ADDON_PREFIX, header .. chunk, "GUILD", fakeName)
	end
end
