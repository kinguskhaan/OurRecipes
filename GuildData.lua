local GT = GuildThing

-- Decodes a guild.exportRoster string (base64(zlib(json)), same pipeline as
-- Gargul's SoftRes import) and stores it in GuildThingDB.GuildData. Returns
-- true on success, or false plus a human-readable error message.
--
-- Expected JSON shape — matching only matters on recipe.name and
-- recipe.chars below, everything else is carried through as-is:
-- {
--   guild = "GuildName-Realm",
--   exportedAt = 1234567890,
--   characters = { { name = "...", realm = "...", class = "..." }, ... },
--   recipes = { { name = "...", chars = { 0, 3, 7 } }, ... },
-- }
function GT.ImportGuildData(str)
    str = (str or ""):gsub("%s+", "")
    if str == "" then
        return false, "Paste the export string from the website first."
    end

    local decodeOk, decoded = pcall(GuildThing_Base64.decode, str)
    if not decodeOk or not decoded then
        return false, "Couldn't base64-decode that — make sure you copied the whole string."
    end

    local zlibOk, decompressed = pcall(function()
        return LibDeflate:DecompressZlib(decoded)
    end)
    if not zlibOk or not decompressed then
        return false, "Couldn't decompress that — make sure you copied the whole string."
    end

    local jsonOk, data = pcall(function()
        return GuildThing_JSON:decode(decompressed)
    end)
    if not jsonOk or type(data) ~= "table" then
        return false, "Couldn't parse that as guild data."
    end

    if type(data.characters) ~= "table" or type(data.recipes) ~= "table" then
        return false, "That doesn't look like guild export data."
    end

    local recipesByName = {}
    -- Reverse of recipesByName: jsIndex -> set of recipe names that
    -- character knows. Built once here instead of re-scanning
    -- recipesByName's char-index arrays on every Overview lookup — with a
    -- full guild roster (via the C_Club scan) that rescan happened once per
    -- recipe per guild member and was the source of very visible UI lag.
    local recipeNamesByCharIndex = {}
    for _, recipe in ipairs(data.recipes) do
        if recipe.name and type(recipe.chars) == "table" then
            recipesByName[recipe.name] = recipe.chars
            for _, idx in ipairs(recipe.chars) do
                recipeNamesByCharIndex[idx] = recipeNamesByCharIndex[idx] or {}
                recipeNamesByCharIndex[idx][recipe.name] = true
            end
        end
    end

    -- name-realm key -> 0-based jsIndex, same lookup FindGuildDataCharacterIndex
    -- used to do with a linear scan every call.
    local characterIndexByKey = {}
    for i, char in ipairs(data.characters) do
        local key = string.lower((char.name or "") .. "-" .. (char.realm or ""))
        characterIndexByKey[key] = i - 1
    end

    GuildThingDB.GuildData = {
        guild = data.guild,
        exportedAt = tonumber(data.exportedAt) or 0,
        importedAt = time(),
        characters = data.characters,
        recipesByName = recipesByName,
        recipeNamesByCharIndex = recipeNamesByCharIndex,
        characterIndexByKey = characterIndexByKey,
    }

    return true
end

function GT.GetGuildDataSummary()
    local guildData = GuildThingDB.GuildData
    if not guildData then return nil end

    return string.format(
        "%s — %d character(s), imported %s",
        guildData.guild or "?",
        #(guildData.characters or {}),
        date("%Y-%m-%d %H:%M", guildData.importedAt)
    )
end
