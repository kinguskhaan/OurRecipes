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

-- Every send funnels through here. Nothing should ever actually hit the
-- 255-char cap (control messages are fixed-format, data payloads are
-- pre-chunked to CHUNK_BODY_LIMIT above) — this is just the one place
-- that would notice and drop it if that assumption ever broke, instead
-- of the message silently vanishing into the client with no trace.
local function SafeSendAddonMessage(prio, message, chatType, target)
	if #message > 255 then
		print(
			("|cffff0000[GuildThing]|r dropped oversized addon message (%d bytes > 255): %s..."):format(
				#message,
				message:sub(1, 40)
			)
		)
		return
	end
	ChatThrottleLib:SendAddonMessage(prio, ADDON_PREFIX, message, chatType, target)
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
	for _ in pairs(GuildThingDB.P2PData or {}) do
		count = count + 1
	end
	return count
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
		SafeSendAddonMessage("BULK", header .. chunk, chatType, target)
	end
end

-- Throttle state lives in GuildThingDB alongside the other per-character
-- fields (entry.professions, entry.lastImport) — signature is just the
-- sorted, comma-joined spellID list, cheap to compare as a plain string.
-- force (GT.DebugForceBroadcast) skips the throttle entirely.
local function TryBroadcastSelfRecipes(force)
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
	local recentlySent = entry.p2pLastSentAt and (time() - entry.p2pLastSentAt) < GetResendIntervalSeconds()
	if not force and unchanged and recentlySent then
		return
	end

	local chunks = ChunksFromIDs(ids, select(2, UnitClass("player")))
	if not chunks then
		return
	end
	SendChunks(chunks, "GUILD")

	entry.p2pLastSentSignature = signature
	entry.p2pLastSentAt = time()
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
	helloQueued[senderName] = nil
	SendHelloTo(senderName)
	C_Timer.After(HELLO_STAGGER_SECONDS, DrainHelloQueue)
end

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

-- One hash standing in for our entire P2PData — cheap enough to whisper
-- every round, and matching means there's nothing more to do this round.
local function BuildCombinedHash()
	local keys = {}
	for key in pairs(GuildThingDB.P2PData or {}) do
		table.insert(keys, key)
	end
	table.sort(keys)

	local parts = {}
	for _, key in ipairs(keys) do
		table.insert(parts, key .. ":" .. EntrySignatureHash(GuildThingDB.P2PData[key]))
	end
	return LibDeflate:Adler32(table.concat(parts, ";"))
end

-- The K entries we've held onto longest without refreshing, so a
-- mismatch eventually surfaces every cached person over enough rounds
-- instead of only ever re-checking the same few.
local function BuildDigestRows(limit)
	local keys = {}
	for key in pairs(GuildThingDB.P2PData or {}) do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return (GuildThingDB.P2PData[a].receivedAt or 0) < (GuildThingDB.P2PData[b].receivedAt or 0)
	end)

	local rows = {}
	for i = 1, math.min(limit, #keys) do
		local entry = GuildThingDB.P2PData[keys[i]]
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

local function GetGossipState()
	GuildThingDB.P2PGossipState = GuildThingDB.P2PGossipState or {}
	return GuildThingDB.P2PGossipState
end

local function PickGossipPartner()
	local state = GetGossipState()
	local candidates = {}
	for key, entry in pairs(GuildThingDB.P2PData or {}) do
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

	SafeSendAddonMessage("BULK", "SYN:" .. BuildCombinedHash(), "WHISPER", partner)
end

local function ScheduleGossipHandshake()
	TryGossipHandshake()
	C_Timer.After(GOSSIP_INTERVAL_SECONDS, ScheduleGossipHandshake)
end

-- Someone whispered us their combined hash. Matching means we already
-- have everything they do — reply "same" and stop. Otherwise hand back
-- our own digest so they can spot which of our cached entries differ
-- from theirs (see OnAckDigest for the other half of that exchange).
local function OnSyn(senderName, theirHash)
	if tostring(BuildCombinedHash()) == theirHash then
		SafeSendAddonMessage("BULK", "ACKM", "WHISPER", senderName)
	else
		SafeSendAddonMessage("BULK", "ACKD:" .. BuildDigestRows(DIGEST_ROW_LIMIT), "WHISPER", senderName)
	end
end

-- For every row that doesn't match what we already have cached (missing
-- entirely, or a different hash), ASK the peer who showed it to us —
-- one whisper per gap, ChatThrottleLib paces them same as anything else.
local function OnAckDigest(senderName, rowsStr)
	for _, row in ipairs(ParseDigestRows(rowsStr)) do
		local key = GT.ClubScanKey(row.name, GetRealmName())
		local ownEntry = GuildThingDB.P2PData and GuildThingDB.P2PData[key]
		local ownHash = ownEntry and tostring(EntrySignatureHash(ownEntry))
		if ownHash ~= row.hash then
			SafeSendAddonMessage("BULK", "ASKQ:" .. row.name, "WHISPER", senderName)
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

	local entry = GuildThingDB.P2PData and GuildThingDB.P2PData[GT.ClubScanKey(targetName, GetRealmName())]
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
local function HandleCompletePayload(senderName, blob)
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

	local subjectName = payload.s or senderName
	GuildThingDB.P2PData = GuildThingDB.P2PData or {}
	local key = GT.ClubScanKey(subjectName, GetRealmName())

	local existing = GuildThingDB.P2PData[key]
	local recipeNames = existing and existing.recipeNames or {}
	for _, spellID in ipairs(payload.ids) do
		local name = spellIDToRecipeName[spellID]
		if name then
			recipeNames[name] = true
		end
	end

	GuildThingDB.P2PData[key] = {
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
		HandleCompletePayload(senderName, table.concat(parts))
	end
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
	local data = GuildThingDB.P2PData
	if not data then
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

-- Settings-page button: request a fresh roster from the server AND prune
-- immediately against whatever roster data we have right now. The request
-- is async (server round-trip), so this can't wait for the freshest
-- possible answer before pruning — but the automatic GUILD_ROSTER_UPDATE
-- hook above catches up moments later once the server actually responds,
-- so nothing is missed, just possibly caught one event later than an
-- instant click-to-result would suggest.
function GT.RefreshGuildRosterAndPrunePeers()
	RequestGuildRosterRefresh()
	return GT.PruneDepartedPeers()
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
		TryBroadcastSelfRecipes()
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
	TryBroadcastSelfRecipes()
end)

-----------------------------
-- DEBUG HOOKS --
-----------------------------
-- Thin wrappers so /or debug (Debug.lua) can exercise this file's
-- internals without a second account/client online — everything above
-- is guild-chat/whisper based and otherwise hard to test solo.
function GT.DebugForceBroadcast()
	TryBroadcastSelfRecipes(true)
end

function GT.DebugForceGossip(targetName)
	SafeSendAddonMessage("BULK", "SYN:" .. BuildCombinedHash(), "WHISPER", targetName)
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
