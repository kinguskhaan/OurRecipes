GuildThingDB = GuildThingDB or {}

GuildThing = GuildThing or {}
local GT = GuildThing

-----------------------------
-- CHARACTER STATE (SELF) --
-----------------------------

function GT.CharKey()
    return UnitName("player") .. "-" .. GetRealmName()
end

local function GetCharEntry()
    local key = GT.CharKey()
    GuildThingDB[key] = GuildThingDB[key] or {
        name = UnitName("player"),
        realm = GetRealmName(),
        class = select(2, UnitClass("player")),
        professions = {},
    }
    local entry = GuildThingDB[key]
    entry.class = select(2, UnitClass("player"))
    return entry
end

-- Developer-only reset, wired from Debug.lua's HandleDebugCommand / the
-- Debug page button — clears this character's scanned profession data so
-- the Overview "no imported professions" banner (UI.lua) can be tested
-- without actually forgetting a real profession in-game.
function GT.DebugResetOwnProfessions()
    local entry = GetCharEntry()
    entry.professions = {}
    GT.InvalidateProfessionSummaryCacheFor(entry.name, entry.realm)
end

function GT.SaveProfession(skillName, recipes)
    local entry = GetCharEntry()
    local oldRecipes = entry.professions[skillName]

    -- recipes only ever reflects what's CURRENTLY VISIBLE in the trade skill
    -- window — a search box or "only show craftable" filter (Auctionator's
    -- own, or Blizzard's built-in one) narrows what GetNumTradeSkills/
    -- GetTradeSkillInfo return, and TRADE_SKILL_UPDATE fires on every filter
    -- change too, not just on a real scan. So a scan mid-search must never
    -- overwrite recipes it simply didn't see this time — merge into the
    -- existing set instead of replacing it. Recipes are never unlearned in
    -- classic, so the union is always the correct full picture.
    local merged, seen = {}, {}
    for _, r in ipairs(recipes) do
        table.insert(merged, r)
        seen[r.name] = true
    end
    if oldRecipes then
        for _, r in ipairs(oldRecipes) do
            if not seen[r.name] then
                table.insert(merged, r)
            end
        end
    end

    -- Only diff against a previous scan of this exact profession — on the
    -- very first scan ever (oldRecipes is nil) there's nothing to compare
    -- against, and treating "everything you already know" as newly
    -- learned would spam a wall of messages the first time you open it.
    if oldRecipes then
        local oldNames = {}
        for _, r in ipairs(oldRecipes) do
            oldNames[r.name] = true
        end

        local newNames = {}
        for _, r in ipairs(recipes) do
            if not oldNames[r.name] then
                table.insert(newNames, r.name)
            end
        end

        if #newNames > 0 then
            print(("|cff00ff00New recipe learned, gz!|r %s"):format(table.concat(newNames, ", ")))
            print("|cffffff00Please remember to update your imports on the GuildThing website.|r")
        end
    end

    entry.professions[skillName] = merged
    entry.lastUpdate = time()
    GT.InvalidateProfessionSummaryCacheFor(entry.name, entry.realm)
end

-----------------------------------
-- PROFESSION SCANNING (LIVE) --
-----------------------------------
-- Fires while a Trade Skill / Craft window is open — this is what actually
-- learns what recipes THIS character knows.

-- The old TradeSkill/Craft APIs only ever expose the crafted item's link, not
-- the recipe's spellID — there's no runtime call that returns it (confirmed:
-- GetTradeSkillRecipeLink returns bracket-text with no hyperlink escape, and
-- C_TradeSkillUI's recipe functions don't back this client's profession
-- data). The bundled catalog (Data/Recipes.lua, built by `pnpm addon:catalog`
-- from external recipe data) already has name->spellID for every recipe, so
-- fill it in from there instead.
local function LookupCatalogSpellID(profName, name)
    for _, r in ipairs(GT.GetCatalogForProfession(profName)) do
        if r.name == name and r.kind == "spell" then
            return r.id
        end
    end
    return nil
end

local function ScanTradeSkill()
    local skillName = GetTradeSkillLine()
    if not skillName or skillName == "" then return end
    local recipes = {}
    for i = 1, GetNumTradeSkills() do
        local name, skillType = GetTradeSkillInfo(i)
        if name and skillType ~= "header" and skillType ~= "subheader" then
            local link = GetTradeSkillItemLink(i)
            local itemID = link and tonumber(link:match("item:(%d+)"))
            local spellID = LookupCatalogSpellID(skillName, name)
            table.insert(recipes, { name = name, itemID = itemID, spellID = spellID })
        end
    end
    GT.SaveProfession(skillName, recipes)
end

local function ScanCraft()
    if not GetCraftDisplaySkillLine then return end
    local skillName = GetCraftDisplaySkillLine()
    if not skillName or skillName == "" then return end
    local recipes = {}
    for i = 1, GetNumCrafts() do
        local name, _, craftType = GetCraftInfo(i)
        if name and craftType ~= "header" then
            local link = GetCraftItemLink(i)
            local itemID = link and tonumber(link:match("item:(%d+)"))
            local spellID = link and tonumber(link:match("enchant:(%d+)"))
            if not spellID then
                spellID = LookupCatalogSpellID(skillName, name)
            end
            table.insert(recipes, { name = name, itemID = itemID, spellID = spellID })
        end
    end
    GT.SaveProfession(skillName, recipes)
end

local scanFrame = CreateFrame("Frame")
scanFrame:RegisterEvent("TRADE_SKILL_SHOW")
scanFrame:RegisterEvent("TRADE_SKILL_UPDATE")
scanFrame:RegisterEvent("CRAFT_SHOW")
scanFrame:RegisterEvent("CRAFT_UPDATE")
scanFrame:SetScript("OnEvent", function(_, event)
    if event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" then
        ScanTradeSkill()
    else
        ScanCraft()
    end
end)

-----------------------------------
-- GUILD ROSTER SCAN (C_CLUB) --
-----------------------------------

-- Blizzard's guild roster (C_Club, guilds are "clubs" under the hood) hands
-- out every member's primary-profession skill level for free, no addon or
-- export needed on their end — same mechanism Guild Roster Manager uses.
-- Only covers the two PRIMARY profession slots though: Cooking and First
-- Aid are secondary professions and never appear here, so this can only
-- ever be a partial baseline (skill level, not known recipes) layered under
-- the real recipe data from exports.
local PRIMARY_PROFESSION_ID_TO_NAME = {
    [164] = "Blacksmithing",
    [165] = "Leatherworking",
    [171] = "Alchemy",
    [197] = "Tailoring",
    [202] = "Engineering",
    [333] = "Enchanting",
    [755] = "Jewelcrafting",
}

function GT.ClubScanKey(name, realm)
    return string.lower((name or "") .. "-" .. (realm or ""))
end

function GT.GetClubScanEntry(name, realm)
    local scan = GuildThingDB.ClubScan
    return scan and scan[GT.ClubScanKey(name, realm)]
end

-- Populated by P2PSync.lua from the addon-message mesh — recipe-level
-- data received directly from another GuildThing client, no export
-- needed. Same key convention as ClubScan above.
function GT.GetP2PEntry(name, realm)
    local data = GuildThingDB.P2PData
    return data and data[GT.ClubScanKey(name, realm)]
end

-- True if two ClubScan .professions tables (at most 2 entries — the two
-- primary-profession slots) hold the same profession->rank pairs.
local function ProfessionRanksEqual(a, b)
    for profName, rank in pairs(a) do
        if b[profName] ~= rank then return false end
    end
    for profName, rank in pairs(b) do
        if a[profName] ~= rank then return false end
    end
    return true
end

local function ScanGuildClubProfessions()
    if not C_Club or not IsInGuild() then return end
    local clubId = C_Club.GetGuildClubId and C_Club.GetGuildClubId()
    if not clubId or clubId == 0 then return end

    local ok, members = pcall(C_Club.GetClubMembers, clubId)
    if not ok or not members then return end

    -- Classic guilds are single-realm (no cross-realm guilds under this
    -- ruleset), so every member shares the scanning player's realm.
    local realm = GetRealmName()
    local oldScan = GuildThingDB.ClubScan or {}
    local scan = {}

    for _, memberId in ipairs(members) do
        local infoOk, info = pcall(C_Club.GetMemberInfo, clubId, memberId)
        if infoOk and info and info.name then
            local professions = {}
            local p1Name = PRIMARY_PROFESSION_ID_TO_NAME[info.profession1ID]
            if p1Name and info.profession1Rank then
                professions[p1Name] = info.profession1Rank
            end
            local p2Name = PRIMARY_PROFESSION_ID_TO_NAME[info.profession2ID]
            if p2Name and info.profession2Rank then
                professions[p2Name] = info.profession2Rank
            end

            local classFile
            if info.classID and C_CreatureInfo and C_CreatureInfo.GetClassInfo then
                local classInfo = C_CreatureInfo.GetClassInfo(info.classID)
                classFile = classInfo and classInfo.classFile
            end

            scan[GT.ClubScanKey(info.name, realm)] = {
                name = info.name,
                realm = realm,
                class = classFile,
                professions = professions,
            }
        end
    end

    -- GUILD_ROSTER_UPDATE (this function's trigger) fires on ordinary guild
    -- churn — members logging on/off, officer notes changing — far more
    -- often than anyone's actual profession/rank changes. Only invalidate
    -- the cached summary for characters whose scanned data actually moved,
    -- not the whole guild, every single time.
    for key, newEntry in pairs(scan) do
        local oldEntry = oldScan[key]
        if not oldEntry or not ProfessionRanksEqual(oldEntry.professions, newEntry.professions) then
            GT.InvalidateProfessionSummaryCacheFor(newEntry.name, newEntry.realm)
        end
    end
    for key, oldEntry in pairs(oldScan) do
        if not scan[key] then
            GT.InvalidateProfessionSummaryCacheFor(oldEntry.name, oldEntry.realm)
        end
    end

    GuildThingDB.ClubScan = scan
end

local clubScanFrame = CreateFrame("Frame")
clubScanFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
clubScanFrame:RegisterEvent("PLAYER_GUILD_UPDATE")
clubScanFrame:SetScript("OnEvent", function()
    ScanGuildClubProfessions()
    -- Same signal doubles as "guild membership may have changed" for the
    -- P2P peer cache — piggyback here instead of a separate polling timer
    -- (GT.PruneDepartedPeers is defined in P2PSync.lua, which loads after
    -- this file, but by the time this event actually fires at runtime
    -- every file has already loaded).
    GT.PruneDepartedPeers()
end)

-----------------------------
-- EXPORT REMINDER --
-----------------------------

-- Nudges the player on login if they haven't exported this character to
-- the website in a while — the addon only knows what it's scanned/exported
-- locally, so stale unexported data is otherwise invisible to everyone else.
local REMINDER_THRESHOLD_SECONDS = 14 * 24 * 60 * 60 -- 2 weeks

local function CheckExportReminder()
    local entry = GetCharEntry()
    if not next(entry.professions) then return end -- nothing to export yet

    if not entry.lastImport then
        print("|cffffff00[GuildThing]|r You haven't exported this character to the GuildThing website yet. Type /or to do so!")
        return
    end

    local elapsed = time() - entry.lastImport
    if elapsed >= REMINDER_THRESHOLD_SECONDS then
        local weeks = math.floor(elapsed / (7 * 24 * 60 * 60))
        print(("|cffffff00[GuildThing]|r It's been %d week%s since you updated your GuildThing export. Time to update! Type /or to do so."):format(
            weeks, weeks == 1 and "" or "s"
        ))
    end
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", CheckExportReminder)

-----------------------------
-- WEBSITE EXPORT ENCODING --
-----------------------------

local function JSONEscape(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub("\"", "\\\"")
    s = s:gsub("\n", "\\n")
    return s
end

local function EncodeRecipes(recipes)
    local parts = {}
    for _, r in ipairs(recipes) do
        table.insert(parts, string.format(
            '{"name":"%s","itemID":%s,"spellID":%s}',
            JSONEscape(r.name),
            r.itemID and tostring(r.itemID) or "null",
            r.spellID and tostring(r.spellID) or "null"
        ))
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function EncodeProfessionsMap(professions)
    local parts = {}
    for skillName, recipes in pairs(professions) do
        table.insert(parts, string.format('"%s":%s', JSONEscape(skillName), EncodeRecipes(recipes)))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- name -> {profession, kind, id}, built once across the whole catalog. Only
-- P2P-cached peer data (GuildThingDB.P2PData) needs this — it stores just
-- recipe names with no profession/id attached, unlike a live scan (which
-- already has both from Core.lua's own trade skill window reads).
local recipeCatalogByName
local function CatalogEntryByName(name)
    if not recipeCatalogByName then
        recipeCatalogByName = {}
        for _, profName in ipairs(GT.GetProfessionOrder()) do
            for _, recipe in ipairs(GT.GetCatalogForProfession(profName)) do
                recipeCatalogByName[recipe.name] = { profession = profName, kind = recipe.kind, id = recipe.id }
            end
        end
    end
    return recipeCatalogByName[name]
end

-- Turns a P2P-cached peer's flat recipeNames set back into the same
-- {profession -> recipe[]} shape GT.ExportCurrentCharacter already builds
-- from a live scan, by looking each name up in the catalog. Names with no
-- catalog match (shouldn't happen — they only ever came from the catalog
-- in the first place, via P2PSync.lua's spellID->name table) are skipped.
local function BuildPeerProfessions(recipeNames)
    local professions = {}
    for name in pairs(recipeNames) do
        local info = CatalogEntryByName(name)
        if info then
            professions[info.profession] = professions[info.profession] or {}
            table.insert(professions[info.profession], {
                name = name,
                itemID = info.kind == "item" and info.id or nil,
                spellID = info.kind == "spell" and info.id or nil,
            })
        end
    end
    return professions
end

-----------------------------
-- CATALOG / PROFESSION DATA ACCESS --
-----------------------------

-- This character's catalogued professions (GuildThing_CatalogOrder) that
-- are known but haven't been scanned yet. spellID is looked up live via
-- GetSpellInfo(profName) rather than a hardcoded ID table — confirmed by
-- testing that Anniversary's spell IDs for profession-opening spells
-- don't match old classic/TBC-era numbering at all (e.g. Enchanting is
-- 28029 here, not the original 7411), almost certainly a side effect of
-- running on the same modern shared client build as retail. Resolving by
-- name instead sidesteps needing to know the "right" ID for whatever
-- build this actually is. GetSpellInfo/IsSpellKnown both need the
-- LOCALIZED name to resolve correctly, same as entry.professions'
-- keys — on an English client both line up with these English catalog
-- names; on any other client neither will, so this whole feature and
-- the "already scanned" check both silently no-op there. That's the
-- same underlying locale gap as the recipe/spellID matching elsewhere,
-- not a new one introduced here.
function GT.GetUnscannedPrimaryProfessions()
    local entry = GetCharEntry()
    local names = {}
    for _, profName in ipairs(GuildThing_CatalogOrder or {}) do
        local spellID = select(7, GetSpellInfo(profName))
        if spellID and IsSpellKnown(spellID) and not entry.professions[profName] then
            table.insert(names, { name = profName, spellID = spellID })
        end
    end
    return names
end

-- Professions THIS character has actually scanned locally (may be a subset
-- of the full catalog below).
function GT.GetProfessionNames()
    local entry = GetCharEntry()
    local names = {}
    for skillName in pairs(entry.professions) do
        table.insert(names, skillName)
    end
    table.sort(names)
    return names
end

-- Static catalog loaded from Data/Recipes.lua (every recipe that exists for
-- each profession, generated site-side by `pnpm addon:catalog`) — independent
-- of what's actually been scanned/imported.
function GT.GetProfessionOrder()
    return GuildThing_CatalogOrder or {}
end

-- The full catalog entry list for one profession (name/icon/kind/id per
-- recipe), regardless of whether anyone's actually scanned/known it.
function GT.GetCatalogForProfession(profName)
    return (GuildThing_Catalog or {})[profName] or {}
end

-- Does THIS character (not guildies) know the given recipe?
function GT.IsKnownBySelf(profName, recipeName)
    local recipes = GetCharEntry().professions[profName]
    if not recipes then return false end
    for _, r in ipairs(recipes) do
        if r.name == recipeName then
            return true
        end
    end
    return false
end

-----------------------------
-- CRAFTERS LOOKUP --
-----------------------------

-- Who (self, P2P-mesh peers, and/or imported guildies) can craft the given
-- recipe. Returns a list of { name, realm, class }.
function GT.GetCraftersForRecipe(profName, recipeName)
    local crafters = {}
    local seen = {}

    local function addCrafter(name, realm, class)
        local key = string.lower((name or "") .. "-" .. (realm or ""))
        if seen[key] then return end
        seen[key] = true
        table.insert(crafters, { name = name, realm = realm, class = class })
    end

    if GT.IsKnownBySelf(profName, recipeName) then
        local entry = GetCharEntry()
        addCrafter(entry.name, entry.realm, entry.class)
    end

    for _, peer in pairs(GuildThingDB.P2PData or {}) do
        if peer.recipeNames and peer.recipeNames[recipeName] then
            addCrafter(peer.name, peer.realm, peer.class)
        end
    end

    local guildData = GuildThingDB.GuildData
    if guildData and guildData.recipesByName and guildData.characters then
        local charIndices = guildData.recipesByName[recipeName]
        if charIndices then
            for _, jsIndex in ipairs(charIndices) do
                -- jsIndex is 0-based (position in the JS array the website
                -- exported), Lua tables here are 1-based, hence the +1.
                local char = guildData.characters[jsIndex + 1]
                if char then
                    addCrafter(char.name, char.realm, char.class)
                end
            end
        end
    end

    return crafters
end

-----------------------------
-- GUILD DATA IMPORT LOOKUPS --
-----------------------------
-- Everything here reads GuildThingDB.GuildData, populated by
-- GT.ImportGuildData (GuildData.lua) from a website-exported string.

-- 0-based index (matching the JS array position the website exported,
-- same convention as GetCraftersForRecipe) of a character within the
-- imported guild data, or nil if that name/realm isn't in it.
function GT.FindGuildDataCharacterIndex(name, realm)
    local guildData = GuildThingDB.GuildData
    if not guildData or not guildData.characters then return nil end

    local key = string.lower((name or "") .. "-" .. (realm or ""))

    -- O(1) via the index built at import time. Older saved data from before
    -- this existed won't have it — fall back to the linear scan rather than
    -- breaking until the next re-import.
    if guildData.characterIndexByKey then
        return guildData.characterIndexByKey[key]
    end

    for i, char in ipairs(guildData.characters) do
        if string.lower((char.name or "") .. "-" .. (char.realm or "")) == key then
            return i - 1
        end
    end
    return nil
end

-- Is (name, realm) THIS character, as opposed to some other guildie?
local function IsSelf(name, realm)
    local entry = GetCharEntry()
    return string.lower(name or "") == string.lower(entry.name)
        and string.lower(realm or "") == string.lower(entry.realm)
end

-----------------------------
-- ROSTER & OVERVIEW --
-----------------------------
-- Combines all four data sources (self scan, website import, C_Club scan,
-- P2P mesh) into what the Overview page actually renders.

-- Every character we have any data for — self, everyone from the last
-- guild-data import, everyone picked up by the live C_Club roster scan, AND
-- everyone the P2P mesh has heard from directly (neither of the last two
-- need an export/import round trip at all) — deduped by name+realm (self
-- wins if also present elsewhere, since IsSelf and Roster keys match the
-- same way).
function GT.GetRoster()
    local roster = {}
    local seen = {}

    local function addEntry(name, realm, class, isSelf)
        -- name ultimately comes from network data (P2PData) or a pasted
        -- import (GuildData) — a malformed/corrupt entry (e.g. a non-string
        -- name) would crash the table.sort below (":lower()" on a number)
        -- and isn't displayable anyway, so drop it here rather than at the
        -- crash site.
        if type(name) ~= "string" or name == "" then
            return
        end
        local key = string.lower(name .. "-" .. (realm or ""))
        if seen[key] then return end
        seen[key] = true
        table.insert(roster, { name = name, realm = realm, class = class, isSelf = isSelf })
    end

    local selfEntry = GetCharEntry()
    addEntry(selfEntry.name, selfEntry.realm, selfEntry.class, true)

    local guildData = GuildThingDB.GuildData
    if guildData and guildData.characters then
        for _, char in ipairs(guildData.characters) do
            addEntry(char.name, char.realm, char.class, false)
        end
    end

    for _, entry in pairs(GuildThingDB.ClubScan or {}) do
        addEntry(entry.name, entry.realm, entry.class, false)
    end

    for _, entry in pairs(GuildThingDB.P2PData or {}) do
        addEntry(entry.name, entry.realm, entry.class, false)
    end

    table.sort(roster, function(a, b) return a.name:lower() < b.name:lower() end)
    return roster
end

-- Every recipe name a character knows, self, P2P-mesh, or imported, as a
-- set — resolved ONCE per character instead of once per catalog recipe
-- (catalog-size x guild-size redundant lookups per Overview click
-- otherwise, visible as UI lag). P2P and import are merged (union) rather
-- than one replacing the other — same "recipes only ever get added"
-- reasoning as everywhere else this data is combined, so a stale import
-- can't hide something the live mesh already taught us, or vice versa.
local function GetKnownRecipeNames(name, realm)
    if IsSelf(name, realm) then
        local set = {}
        for _, recipes in pairs(GetCharEntry().professions) do
            for _, r in ipairs(recipes) do
                set[r.name] = true
            end
        end
        return set
    end

    local set = {}

    local p2pEntry = GT.GetP2PEntry(name, realm)
    if p2pEntry then
        for recipeName in pairs(p2pEntry.recipeNames or {}) do
            set[recipeName] = true
        end
    end

    local jsIndex = GT.FindGuildDataCharacterIndex(name, realm)
    if jsIndex ~= nil then
        local guildData = GuildThingDB.GuildData
        if guildData and guildData.recipeNamesByCharIndex then
            for recipeName in pairs(guildData.recipeNamesByCharIndex[jsIndex] or {}) do
                set[recipeName] = true
            end
        elseif guildData and guildData.recipesByName then
            -- Fallback for saved data imported before recipeNamesByCharIndex existed.
            for recipeName, charIndices in pairs(guildData.recipesByName) do
                for _, idx in ipairs(charIndices) do
                    if idx == jsIndex then
                        set[recipeName] = true
                        break
                    end
                end
            end
        end
    end

    return set
end

-- Which professions a character has any data for, with a recipe count and/or
-- a club-scanned skill rank — drives the Overview page's per-character
-- profession list. A profession shows up here if EITHER is true:
--   - count > 0 (they know at least one recipe in it, from an export)
--   - rank is set (C_Club roster scan says they have that primary profession)
-- rank without recipe data means "we know they have the profession, but not
-- what they can craft" — the UI surfaces that gap instead of hiding it.
-- Keyed by ClubScanKey(name, realm). GetCharacterProfessionSummary below
-- walks the whole ~2170-recipe catalog per character it's asked about —
-- fine once, but the Overview roster (UI.lua) calls it for EVERY member on
-- every rebuild, including every roster search keystroke (debounced, but
-- even one guild-size x catalog-size pass synchronously on the UI thread
-- is enough to visibly stutter the whole game).
--
-- Invalidation is per-character (InvalidateProfessionSummaryCacheFor),
-- not wholesale — GUILD_ROSTER_UPDATE (which ScanGuildClubProfessions
-- reacts to) fires on ordinary guild churn (members logging on/off, notes
-- changing) far more often than anyone's actual profession data changes,
-- so wiping everything on every one of those defeated the cache almost
-- entirely for anyone with Overview search open in an active guild.
-- InvalidateProfessionSummaryCache (wholesale) is kept for ImportGuildData,
-- the one path that can plausibly touch most of the roster at once and
-- isn't a hot path anyway (a deliberate, rare user action).
local professionSummaryCache = {}

function GT.InvalidateProfessionSummaryCache()
    professionSummaryCache = {}
end

function GT.InvalidateProfessionSummaryCacheFor(name, realm)
    professionSummaryCache[GT.ClubScanKey(name, realm)] = nil
end

function GT.GetCharacterProfessionSummary(name, realm)
    local key = GT.ClubScanKey(name, realm)
    local cached = professionSummaryCache[key]
    if cached then
        return cached
    end

    local clubEntry = GT.GetClubScanEntry(name, realm)
    local knownNames = GetKnownRecipeNames(name, realm)
    local summary = {}
    for _, profName in ipairs(GT.GetProfessionOrder()) do
        local count = 0
        for _, recipe in ipairs(GT.GetCatalogForProfession(profName)) do
            if knownNames[recipe.name] then
                count = count + 1
            end
        end
        local rank = clubEntry and clubEntry.professions[profName]
        if count > 0 or rank then
            table.insert(summary, { profession = profName, count = count, rank = rank })
        end
    end

    professionSummaryCache[key] = summary
    return summary
end

-- Every recipe in a profession's full catalog, each flagged with whether
-- this specific character knows it — so the Overview drill-down can show
-- what they *don't* have too (greyed out), same visual language as the
-- main profession browser.
function GT.GetCharacterRecipeStatuses(name, realm, profName)
    local knownNames = GetKnownRecipeNames(name, realm)
    local list = {}
    for _, recipe in ipairs(GT.GetCatalogForProfession(profName)) do
        table.insert(list, {
            name = recipe.name,
            icon = recipe.icon,
            kind = recipe.kind,
            id = recipe.id,
            known = knownNames[recipe.name] == true,
        })
    end
    return list
end

-----------------------------
-- WEBSITE EXPORT (PUBLIC API) --
-----------------------------

function GT.GetLastImportText()
    local entry = GetCharEntry()
    if not entry.lastImport then return nil end
    return date("%Y-%m-%d %H:%M", entry.lastImport)
end

-- Builds the export string this character's export box shows — plain JSON,
-- unlike the GuildData import direction (GuildData.lua) which is
-- Base64+zlib-compressed; this one is short enough per-character not to
-- need it.
--
-- peers: everyone this character has picked up via the P2P mesh
-- (GuildThingDB.P2PData), each shaped exactly like the top-level character
-- object — so the website can validate/import them the same way it
-- already does the main export, just looped. Skips anyone with zero
-- catalog-resolvable recipes (nothing usable to send).
function GT.ExportCurrentCharacter()
    local entry = GetCharEntry()
    entry.lastImport = time()

    local peerParts = {}
    for _, peer in pairs(GuildThingDB.P2PData or {}) do
        local professions = BuildPeerProfessions(peer.recipeNames or {})
        if next(professions) then
            table.insert(peerParts, string.format(
                '{"name":"%s","realm":"%s","class":"%s","professions":%s}',
                JSONEscape(peer.name or ""),
                JSONEscape(peer.realm or ""),
                JSONEscape(peer.class or ""),
                EncodeProfessionsMap(professions)
            ))
        end
    end

    return string.format(
        '{"name":"%s","realm":"%s","class":"%s","professions":%s,"peers":[%s]}',
        JSONEscape(entry.name),
        JSONEscape(entry.realm),
        JSONEscape(entry.class),
        EncodeProfessionsMap(entry.professions),
        table.concat(peerParts, ",")
    )
end
