local GT = GuildThing

-- Flip to true to show the "Settings > Debug" page in the addon UI
-- (buttons for the commands below, see UI.lua's BuildDebugPage). Never
-- ship this on — it's a developer-only escape hatch, not something a
-- regular user should stumble into. Slash commands (/or debug ...) work
-- regardless of this flag either way.
GT.DEBUG_UI_ENABLED = false

-----------------------------
-- P2P DEBUG TOOLS --
-----------------------------
-- `/gt debug <command>` — manual test hooks for the P2P sync mesh
-- (P2PSync.lua). It's guild-chat/whisper based, so with only one
-- account there's no way to have two real clients talking to each
-- other — these commands let you force sends and feed in fake
-- incoming messages to exercise every code path solo.

local function PrintUsage()
	print("|cffffff00[GuildThing debug]|r commands:")
	print("  /gt debug broadcast — force a recipe broadcast now, ignoring the throttle")
	print("  /gt debug gossip <name> — force a gossip handshake against <name>, ignoring online/cooldown checks")
	print("  /gt debug fakemsg <name> <message> — feed a fake GUILD addon message as if <name> sent it")
	print("  /gt debug fakewhisper <name> <message> — same, but as a WHISPER")
	print("  /gt debug fakerecipe <name> <recipe name> — simulate <name> broadcasting that one recipe")
	print("  /gt debug dump — print P2PData and gossip state")
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

-- Called from UI.lua's "/gt" handler when the first word is "debug" —
-- kept as a public GT.* function rather than its own slash command so
-- "/gt debug" stays one discoverable entry point.
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
			print("|cffff0000[GuildThing debug]|r usage: /gt debug gossip <name>")
		else
			GT.DebugForceGossip(targetName)
			print("|cffffff00[GuildThing debug]|r sent SYN to " .. targetName)
		end
	elseif command == "fakemsg" or command == "fakewhisper" then
		local fakeName, message = rest:match("^(%S+)%s+(.+)$")
		if not fakeName then
			print(("|cffff0000[GuildThing debug]|r usage: /gt debug %s <name> <message>"):format(command))
		else
			local channel = command == "fakewhisper" and "WHISPER" or "GUILD"
			GT.DebugSimulateMessage(fakeName, message, channel)
			print(("|cffffff00[GuildThing debug]|r simulated %s from %s: %s"):format(channel, fakeName, message))
		end
	elseif command == "fakerecipe" then
		local fakeName, recipeName = rest:match("^(%S+)%s+(.+)$")
		if not fakeName then
			print("|cffff0000[GuildThing debug]|r usage: /gt debug fakerecipe <name> <recipe name>")
		else
			GT.DebugFakeRecipeBroadcast(fakeName, recipeName)
			print(("|cffffff00[GuildThing debug]|r simulated %s broadcasting: %s"):format(fakeName, recipeName))
		end
	elseif command == "dump" then
		DumpP2PData()
	else
		PrintUsage()
	end
end
