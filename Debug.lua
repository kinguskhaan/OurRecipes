local GT = GuildThing

-- Persisted toggle for the "Developer" sidebar section in the addon UI
-- (Debug + Peer data pages, see UI.lua) — flipped from Settings, off by
-- default. Slash commands (/or debug ...) work regardless of this either
-- way; this only gates whether the UI section is visible.
GuildThingDB.developerMode = GuildThingDB.developerMode or false

function GT.IsDeveloperModeEnabled()
	return GuildThingDB.developerMode
end

function GT.SetDeveloperMode(enabled)
	GuildThingDB.developerMode = enabled and true or false
end

-----------------------------
-- P2P DEBUG TOOLS --
-----------------------------
-- `/or debug <command>` — manual test hooks for the P2P sync mesh
-- (P2PSync.lua). It's guild-chat/whisper based, so with only one
-- account there's no way to have two real clients talking to each
-- other — these commands let you force sends and feed in fake
-- incoming messages to exercise every code path solo.

local function PrintUsage()
	print("|cffffff00[GuildThing debug]|r commands:")
	print("  /or debug broadcast — force a recipe broadcast now, ignoring the throttle")
	print("  /or debug gossip <name> — force a gossip handshake against <name>, ignoring online/cooldown checks")
	print("  /or debug fakemsg <name> <message> — feed a fake GUILD addon message as if <name> sent it")
	print("  /or debug fakewhisper <name> <message> — same, but as a WHISPER")
	print("  /or debug fakerecipe <name> <recipe name> — simulate <name> broadcasting that one recipe")
	print("  /or debug dump — print P2PData and gossip state")
	print("  /or debug resetprofessions — clear this character's scanned professions")
end

local function DumpP2PData()
	print("|cffffff00[GuildThing debug]|r P2PData:")
	local data = GuildThingDB.P2PData or {}
	local count = 0
	for key, entry in pairs(data) do
		count = count + 1
		local recipeCount = 0
		for _ in pairs(entry.recipeNames or {}) do
			recipeCount = recipeCount + 1
		end
		print(
			("  %s (%s) — %d recipes, last %s"):format(
				entry.name or key,
				entry.class or "?",
				recipeCount,
				date("%H:%M:%S", entry.receivedAt or 0)
			)
		)
	end
	if count == 0 then
		print("  (empty)")
	end

	print("|cffffff00[GuildThing debug]|r gossip state:")
	local state = GuildThingDB.P2PGossipState or {}
	local stateCount = 0
	for key, lastSynced in pairs(state) do
		stateCount = stateCount + 1
		print(("  %s — last synced %s"):format(key, date("%H:%M:%S", lastSynced)))
	end
	if stateCount == 0 then
		print("  (empty)")
	end
end

-- Plain-data snapshot of the P2P cache — shared by the in-UI peer
-- visualizer (UI.lua's BuildPeerVisualizerPage), so it reads the same
-- shape as this file's own dump above instead of a second copy drifting
-- out of sync.
local function FormatTimestamp(ts)
	return ts and date("%Y-%m-%d %H:%M:%S", ts) or nil
end

function GT.BuildP2PDataSnapshot()
	local peers = {}
	for key, entry in pairs(GuildThingDB.P2PData or {}) do
		local recipeNames = {}
		for name in pairs(entry.recipeNames or {}) do
			table.insert(recipeNames, name)
		end
		table.sort(recipeNames)
		table.insert(peers, {
			key = key,
			name = entry.name,
			class = entry.class,
			receivedAt = entry.receivedAt and date("%Y-%m-%d %H:%M:%S", entry.receivedAt) or nil,
			recipeCount = #recipeNames,
			recipes = recipeNames,
		})
	end
	table.sort(peers, function(a, b) return (a.name or a.key) < (b.name or b.key) end)

	local gossipState = {}
	for key, lastSynced in pairs(GuildThingDB.P2PGossipState or {}) do
		gossipState[key] = FormatTimestamp(lastSynced)
	end

	-- Own broadcast: a threshold, not a schedule (see GT.GetSelfBroadcastInfo)
	-- — earliestNextBroadcastAt is when a broadcast becomes *eligible*
	-- again, not when one will actually fire.
	local selfBroadcast = GT.GetSelfBroadcastInfo()
	selfBroadcast.lastSentAt = FormatTimestamp(selfBroadcast.lastSentAt)
	selfBroadcast.earliestNextBroadcastAt = FormatTimestamp(selfBroadcast.earliestNextBroadcastAt)

	-- Gossip: this one IS a real recurring timer (hourly), so nextRoundAt
	-- is an actual prediction, not just a threshold.
	local gossip = GT.GetGossipRuntimeInfo()
	gossip.lastRoundAt = FormatTimestamp(gossip.lastRoundAt)
	gossip.nextRoundAt = FormatTimestamp(gossip.nextRoundAt)

	-- Raw + completed message logs, newest last. isHello on a completed
	-- entry means it arrived as a WHISPER of someone's own (non-relayed)
	-- data — see HandleCompletePayload in P2PSync.lua.
	local trafficLog = GT.GetP2PTrafficLog()
	local raw = {}
	for _, entry in ipairs(trafficLog.raw) do
		table.insert(raw, { at = FormatTimestamp(entry.at), from = entry.from, channel = entry.channel })
	end
	local completed = {}
	for _, entry in ipairs(trafficLog.completed) do
		table.insert(completed, {
			at = FormatTimestamp(entry.at),
			from = entry.from,
			channel = entry.channel,
			subject = entry.subject,
			isHello = entry.isHello,
		})
	end

	return {
		peerCount = #peers,
		peers = peers,
		gossipPartnerCooldowns = gossipState,
		selfBroadcast = selfBroadcast,
		gossip = gossip,
		helloQueue = GT.GetHelloQueueSnapshot(),
		traffic = { raw = raw, completed = completed },
	}
end

-- Called from UI.lua's "/or" handler when the first word is "debug" —
-- kept as a public GT.* function rather than its own slash command so
-- "/or debug" stays one discoverable entry point.
function GT.HandleDebugCommand(argsStr)
	argsStr = argsStr or ""
	local command, rest = argsStr:match("^(%S*)%s*(.-)%s*$")
	command = command or ""

	if command == "broadcast" then
		GT.DebugForceBroadcast()
		print("|cffffff00[GuildThing debug]|r forced broadcast")
	elseif command == "gossip" then
		local targetName = rest:match("^(%S+)")
		if not targetName then
			print("|cffff0000[GuildThing debug]|r usage: /or debug gossip <name>")
		else
			GT.DebugForceGossip(targetName)
			print("|cffffff00[GuildThing debug]|r sent SYN to " .. targetName)
		end
	elseif command == "fakemsg" or command == "fakewhisper" then
		local fakeName, message = rest:match("^(%S+)%s+(.+)$")
		if not fakeName then
			print(("|cffff0000[GuildThing debug]|r usage: /or debug %s <name> <message>"):format(command))
		else
			local channel = command == "fakewhisper" and "WHISPER" or "GUILD"
			GT.DebugSimulateMessage(fakeName, message, channel)
			print(("|cffffff00[GuildThing debug]|r simulated %s from %s: %s"):format(channel, fakeName, message))
		end
	elseif command == "fakerecipe" then
		local fakeName, recipeName = rest:match("^(%S+)%s+(.+)$")
		if not fakeName then
			print("|cffff0000[GuildThing debug]|r usage: /or debug fakerecipe <name> <recipe name>")
		else
			GT.DebugFakeRecipeBroadcast(fakeName, recipeName)
			print(("|cffffff00[GuildThing debug]|r simulated %s broadcasting: %s"):format(fakeName, recipeName))
		end
	elseif command == "dump" then
		DumpP2PData()
	elseif command == "resetprofessions" then
		GT.DebugResetOwnProfessions()
		print("|cffffff00[GuildThing debug]|r cleared this character's scanned professions")
	else
		PrintUsage()
	end
end
