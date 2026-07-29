GuildThingDB = GuildThingDB or {}

GuildThing = GuildThing or {}
local GT = GuildThing

local function CharKey()
    return UnitName("player") .. "-" .. GetRealmName()
end

local function GetCharEntry()
    local key = CharKey()
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

function GT.SaveProfession(skillName, recipes)
    local entry = GetCharEntry()
    local oldRecipes = entry.professions[skillName]

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

    entry.professions[skillName] = recipes
    entry.lastUpdate = time()
end

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

-- Nudges the player on login if they haven't exported this character to
-- the website in a while — the addon only knows what it's scanned/exported
-- locally, so stale unexported data is otherwise invisible to everyone else.
local REMINDER_THRESHOLD_SECONDS = 14 * 24 * 60 * 60 -- 2 weeks

local function CheckExportReminder()
    local entry = GetCharEntry()
    if not next(entry.professions) then return end -- nothing to export yet

    if not entry.lastImport then
        print("|cffffff00[GuildThing]|r You haven't exported this character to the GuildThing website yet. Type /gt to do so!")
        return
    end

    local elapsed = time() - entry.lastImport
    if elapsed >= REMINDER_THRESHOLD_SECONDS then
        local weeks = math.floor(elapsed / (7 * 24 * 60 * 60))
        print(("|cffffff00[GuildThing]|r It's been %d week%s since you updated your GuildThing export. Time to update! Type /gt to do so."):format(
            weeks, weeks == 1 and "" or "s"
        ))
    end
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", CheckExportReminder)

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

function GT.GetCatalogForProfession(profName)
    return (GuildThing_Catalog or {})[profName] or {}
end

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

-- Who (self and/or imported guildies) can craft the given recipe.
-- Returns a list of { name, realm, class }.
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

-- 0-based index (matching the JS array position the website exported,
-- same convention as GetCraftersForRecipe) of a character within the
-- imported guild data, or nil if that name/realm isn't in it.
function GT.FindGuildDataCharacterIndex(name, realm)
    local guildData = GuildThingDB.GuildData
    if not guildData or not guildData.characters then return nil end

    local key = string.lower((name or "") .. "-" .. (realm or ""))
    for i, char in ipairs(guildData.characters) do
        if string.lower((char.name or "") .. "-" .. (char.realm or "")) == key then
            return i - 1
        end
    end
    return nil
end

local function IsSelf(name, realm)
    local entry = GetCharEntry()
    return string.lower(name or "") == string.lower(entry.name)
        and string.lower(realm or "") == string.lower(entry.realm)
end

-- Does this specific character (self or an imported guildie) know the
-- given recipe? Unlike GetCraftersForRecipe (which lists everyone), this
-- checks one character — used to drive the per-character profession
-- drill-down in the Overview page.
function GT.CharacterKnowsRecipe(name, realm, profName, recipeName)
    if IsSelf(name, realm) and GT.IsKnownBySelf(profName, recipeName) then
        return true
    end

    local jsIndex = GT.FindGuildDataCharacterIndex(name, realm)
    if jsIndex == nil then return false end

    local guildData = GuildThingDB.GuildData
    local charIndices = guildData and guildData.recipesByName and guildData.recipesByName[recipeName]
    if not charIndices then return false end

    for _, idx in ipairs(charIndices) do
        if idx == jsIndex then return true end
    end
    return false
end

-- Every character we have any data for — self plus everyone from the last
-- guild-data import, deduped by name+realm (self wins if also present in
-- the import, since IsSelf and Roster keys match the same way).
function GT.GetRoster()
    local roster = {}
    local seen = {}

    local function addEntry(name, realm, class, isSelf)
        local key = string.lower((name or "") .. "-" .. (realm or ""))
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

    table.sort(roster, function(a, b) return a.name:lower() < b.name:lower() end)
    return roster
end

-- Which professions a character knows at least one recipe in, with a count
-- for each — drives the Overview page's per-character profession list.
function GT.GetCharacterProfessionSummary(name, realm)
    local summary = {}
    for _, profName in ipairs(GT.GetProfessionOrder()) do
        local count = 0
        for _, recipe in ipairs(GT.GetCatalogForProfession(profName)) do
            if GT.CharacterKnowsRecipe(name, realm, profName, recipe.name) then
                count = count + 1
            end
        end
        if count > 0 then
            table.insert(summary, { profession = profName, count = count })
        end
    end
    return summary
end

-- Every recipe in a profession's full catalog, each flagged with whether
-- this specific character knows it — so the Overview drill-down can show
-- what they *don't* have too (greyed out), same visual language as the
-- main profession browser.
function GT.GetCharacterRecipeStatuses(name, realm, profName)
    local list = {}
    for _, recipe in ipairs(GT.GetCatalogForProfession(profName)) do
        table.insert(list, {
            name = recipe.name,
            icon = recipe.icon,
            kind = recipe.kind,
            id = recipe.id,
            known = GT.CharacterKnowsRecipe(name, realm, profName, recipe.name),
        })
    end
    return list
end

function GT.GetLastImportText()
    local entry = GetCharEntry()
    if not entry.lastImport then return nil end
    return date("%Y-%m-%d %H:%M", entry.lastImport)
end

function GT.ExportCurrentCharacter()
    local entry = GetCharEntry()
    entry.lastImport = time()
    local profParts = {}
    for skillName, recipes in pairs(entry.professions) do
        table.insert(profParts, string.format('"%s":%s', JSONEscape(skillName), EncodeRecipes(recipes)))
    end
    return string.format(
        '{"name":"%s","realm":"%s","class":"%s","professions":{%s}}',
        JSONEscape(entry.name),
        JSONEscape(entry.realm),
        JSONEscape(entry.class),
        table.concat(profParts, ",")
    )
end
