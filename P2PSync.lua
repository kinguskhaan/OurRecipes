local GT = GuildThing

-----------------------------
-- P2P RECIPE SYNC --
-----------------------------
---
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
-- 1-2 are built, 3-5 are planned.
--
-- knownPeers = a table of everyone we've heard from before. Hearing
-- any message proves they have the addon, so that's the whole
-- discovery mechanism.
--
-- On throttling: the WoW server disconnects a client for sending too
-- much of its OWN output too fast — it doesn't care how many other
-- people are also sending, only your own connection's rate.
-- ChatThrottleLib (the community-standard guard most addons use)
-- allows bursts up to 4000 bytes, then throttles to 800 bytes/sec
-- sustained. Worst realistic broadcast size here — the two biggest
-- professions, Blacksmithing + Leatherworking, ~770 recipes — compresses
-- to ~9 chunks / ~2KB, comfortably under that burst limit even sent
-- all at once. So a single player's own broadcast is never the risk.
-- The actual risk is many outgoing WHISPERS firing from the SAME
-- client back to back (e.g. 3's reactive hello, if a bunch of
-- strangers all broadcast during the same login) — that stacks
-- against that one client's own budget. That's why 3-4 queue/stagger
-- instead of firing everything at once.

-- 1. BROADCAST — on login, or when own recipes changed, compress own
--    known recipes and send to guild chat. Skip if unchanged and sent
--    recently (24h, longer once knownPeers has ~10 people). This is
--    mainly for onboarding new people, not for freshness.

-- 2. RECEIVE — rebuild the compressed data, save it, add sender to
--    knownPeers. We fill in the new recipes, never overwrite, so we
--    don't risk writing over stuff with old data.

-- 3. REACTIVE HELLO [planned] — hear someone new for the first time ->
--    put them in a queue, and whisper them one by one, a few seconds
--    apart, regardless of how many piled up (a fresh login can hear a
--    bunch of strangers broadcast at once). Whispering them your own
--    stuff also adds you to their knownPeers, no reply needed back.

-- 4. GOSSIP HANDSHAKE [planned] — every so often, whisper one known
--    peer, compare a quick hash first. Only exchange more if it
--    doesn't match.

-- 5. ASK [planned] — whisper someone directly for one specific
--    person's data, merge it in (recipes only ever get added, so
--    merging is always safe).

local ADDON_PREFIX = "GT_RECIPES"
local CHUNK_BODY_LIMIT = 230 -- addon messages cap at 255 chars; header eats ~16-25
local RESEND_INTERVAL_SECONDS = 24 * 60 * 60
local SEQ_WRAP = 100 -- seq is a single-digit-friendly rolling counter, not a unique ID

-----------------------------
-- REVERSE CATALOG INDEX --
-----------------------------
-- spellID -> recipe name, built once from the bundled catalog so a
-- received flat ID list can be turned back into recipe names without
-- ever transmitting the names themselves. Only kind == "spell" entries
-- are covered (2 of ~2170 catalog entries are kind == "item" and are a
-- deliberately accepted gap here — still covered by manual export/import).
local spellIDToRecipeName = {}
for _, profName in ipairs(GT.GetProfessionOrder()) do
	for _, recipe in ipairs(GT.GetCatalogForProfession(profName)) do
		if recipe.kind == "spell" and recipe.id then
			spellIDToRecipeName[recipe.id] = recipe.name
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

-- seq rolls 0-99 per broadcast (not per chunk) so a receiver can tell a
-- fresh send apart from a stale one still trickling in from before.
local sendSeq = 0

-- ChatThrottleLib paces and bursts these safely on its own (shared budget
-- with every other addon using it) — no need for our own delay/stagger.
local function SendChunks(chunks)
	sendSeq = (sendSeq + 1) % SEQ_WRAP
	local seq = sendSeq
	local total = #chunks
	for i, chunk in ipairs(chunks) do
		local header = string.format("%d:%d:%d:", seq, i, total)
		ChatThrottleLib:SendAddonMessage("BULK", ADDON_PREFIX, header .. chunk, "GUILD")
	end
end

-- Throttle state lives in GuildThingDB alongside the other per-character
-- fields (entry.professions, entry.lastImport) — signature is just the
-- sorted, comma-joined spellID list, cheap to compare as a plain string.
local function TryBroadcastSelfRecipes()
	if not IsInGuild() then
		return
	end

	local ids = CollectSelfKnownSpellIDs()
	if #ids == 0 then
		return
	end
	table.sort(ids)
	local signature = table.concat(ids, ",")

	local key = GT.CharKey()
	GuildThingDB[key] = GuildThingDB[key] or {}
	local entry = GuildThingDB[key]

	local unchanged = entry.p2pLastSentSignature == signature
	local recentlySent = entry.p2pLastSentAt and (time() - entry.p2pLastSentAt) < RESEND_INTERVAL_SECONDS
	if unchanged and recentlySent then
		return
	end

	local payload = { c = select(2, UnitClass("player")), ids = ids }
	local json = GuildThing_JSON:encode(payload)
	local compressed = LibDeflate:CompressZlib(json)
	local blob = GuildThing_Base64.encode(compressed)

	local chunks = {}
	for i = 1, #blob, CHUNK_BODY_LIMIT do
		table.insert(chunks, blob:sub(i, i + CHUNK_BODY_LIMIT - 1))
	end

	SendChunks(chunks)

	entry.p2pLastSentSignature = signature
	entry.p2pLastSentAt = time()
end

-----------------------------
-- RECEIVING --
-----------------------------

-- In-memory only, keyed by sender name — no need to survive a reload. A
-- chunk with a new seq resets that sender's buffer, superseding whatever
-- broadcast was previously in-flight from them.
local pendingChunks = {}

-- Reverse of TryBroadcastSelfRecipes' send pipeline: Base64 -> zlib ->
-- JSON -> spellID list -> recipe names, then stored under the sender's
-- name-realm key. Any step failing (corrupt/partial data) just drops
-- the payload silently, never touches our own saved data.
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

	local recipeNames = {}
	for _, spellID in ipairs(payload.ids) do
		local name = spellIDToRecipeName[spellID]
		if name then
			recipeNames[name] = true
		end
	end

	GuildThingDB.P2PData = GuildThingDB.P2PData or {}
	local key = GT.ClubScanKey(senderName, GetRealmName())
	GuildThingDB.P2PData[key] = {
		name = senderName,
		realm = GetRealmName(),
		class = payload.c,
		recipeNames = recipeNames,
		receivedAt = time(),
	}
end

-- Buffers chunks per sender until all of them have arrived, then hands
-- the reassembled blob to HandleCompletePayload. Every other GT_RECIPES
-- message (broadcast or otherwise) funnels through here.
local function OnAddonMessage(prefix, message, _, sender)
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
	end
end)

-- Re-check the throttle whenever a fresh scan completes too (not just on
-- login) — hooking GT.SaveProfession rather than the TRADE_SKILL_UPDATE
-- events directly since that's the single choke point both ScanTradeSkill
-- and ScanCraft already funnel through.
hooksecurefunc(GT, "SaveProfession", TryBroadcastSelfRecipes)
