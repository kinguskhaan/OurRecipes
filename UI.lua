local GT = GuildThing

local frame

local ROW_HEIGHT = 20
local VISIBLE_ROWS = 13
local SIDEBAR_WIDTH = 150
local TEXTBOX_WIDTH = 440

-----------------------------
-- SHARED HELPERS --
-----------------------------

local function GetClassColor(class)
    local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if color then
        return color.r, color.g, color.b
    end
    return 1, 1, 1
end

-- Fills GameTooltip with the real item/spell tooltip (stats, flavor text,
-- everything) via the native APIs rather than reassembling it by hand from
-- GetItemInfo — addon code can still AddLine() more onto it afterwards.
-- Returns whether it managed to set anything.
local function SetNativeTooltip(kind, id)
    if not id then return false end
    if kind == "item" then
        GameTooltip:SetItemByID(id)
        return true
    elseif kind == "spell" then
        GameTooltip:SetSpellByID(id)
        return true
    end
    return false
end

-- fzf-style fuzzy match: every character of query must appear in text, in
-- order, but not necessarily contiguous ("twk" matches "Tankkingen"). Returns
-- a score (higher = better) or nil if query doesn't match at all. Contiguous
-- runs and word-start hits score higher, same rough shape as fzf's own
-- ranking, so tighter/earlier matches float to the top of the results.
local function FuzzyMatch(text, query)
    if query == "" then return 0 end
    text, query = text:lower(), query:lower()

    local score, textPos, consecutive = 0, 1, 0
    for i = 1, #query do
        local matchPos = text:find(query:sub(i, i), textPos, true)
        if not matchPos then return nil end

        if matchPos == textPos then
            consecutive = consecutive + 1
            score = score + 10 + consecutive * 2
        else
            consecutive = 0
            score = score + 1
        end
        if matchPos == 1 or text:sub(matchPos - 1, matchPos - 1) == " " then
            score = score + 5
        end
        textPos = matchPos + 1
    end

    -- Tiebreak toward tighter matches (less unmatched slack in text).
    return score - (#text - #query) * 0.1
end

local function FormatCrafters(crafters)
    if #crafters == 0 then return "no one yet" end

    local names = {}
    for _, c in ipairs(crafters) do
        table.insert(names, c.name)
    end

    if #names > 2 then
        return string.format("%s, %s +%d more", names[1], names[2], #names - 2)
    end
    return table.concat(names, ", ")
end

-- A single scrollable editBox used both for the own-character export and
-- the guild-data paste box. Width is explicit (not read back via
-- GetWidth()) since the scrollFrame's anchors aren't set until after this
-- returns — reading its width before that would just see 0.
--
-- Wrapped in a visible bordered panel — a bare EditBox+ScrollFrame has no
-- background/border of its own, so without this it's easy to miss that
-- there's a real, click-to-type text field there at all.
local RIGHT_PADDING_FOR_SCROLLBAR = 34

-- readOnly: still focusable/selectable (so Ctrl+C works right after it's
-- populated) but typed characters get reverted — for the export box, which
-- otherwise silently accepts edits that clobber the generated string.
local function CreateTextBox(parent, width, height, readOnly)
    local border = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    border:SetSize(width + 6 + RIGHT_PADDING_FOR_SCROLLBAR, height + 12)
    border:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    border:SetBackdropColor(0, 0, 0, 0.85)

    local scrollFrame = CreateFrame("ScrollFrame", nil, border, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 6, -6)
    scrollFrame:SetSize(width, height)

    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(width)
    -- Must be set explicitly — without it the box starts at zero height
    -- (only OnTextChanged below ever grows it) and looks unresponsive:
    -- focus can still be acquired programmatically, but there's no visible
    -- cursor or typed text to show for it until the height is non-zero.
    editBox:SetHeight(height)
    editBox:EnableMouse(true)
    editBox:SetAutoFocus(false)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    if readOnly then
        editBox.lastSetText = ""
        editBox:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                -- Revert: this box is for copying an already-generated
                -- string, not editing it.
                self:SetText(self.lastSetText)
                self:HighlightText()
                return
            end
            local _, lineCount = (self:GetText() or ""):gsub("\n", "\n")
            self:SetHeight(math.max((lineCount + 2) * 14, height))
            scrollFrame:UpdateScrollChildRect()
        end)
    else
        editBox:SetScript("OnTextChanged", function(self)
            local _, lineCount = (self:GetText() or ""):gsub("\n", "\n")
            self:SetHeight(math.max((lineCount + 2) * 14, height))
            scrollFrame:UpdateScrollChildRect()
        end)
    end
    scrollFrame:SetScrollChild(editBox)

    -- Clicking anywhere in the bordered area (not just directly on the
    -- text) focuses the box. Bound at every layer (border, scrollFrame,
    -- editBox itself) since the scrollFrame — a child drawn above border,
    -- and mouse-enabled by its own template for wheel-scroll support —
    -- was silently absorbing clicks before they ever reached border's
    -- handler, which is why this previously did nothing when clicked.
    local function FocusEditBox() editBox:SetFocus() end
    border:EnableMouse(true)
    border:SetScript("OnMouseDown", FocusEditBox)
    scrollFrame:EnableMouse(true)
    scrollFrame:SetScript("OnMouseDown", FocusEditBox)
    editBox:SetScript("OnMouseDown", FocusEditBox)

    return border, editBox
end

-----------------------------
-- IMPORT / EXPORT PAGE --
-----------------------------

local function BuildImportExportPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    -- Own character export (unchanged behavior, just relocated)
    local exportLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    exportLabel:SetPoint("TOPLEFT", 4, -4)
    exportLabel:SetText("Export this character")

    local hint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", exportLabel, "BOTTOMLEFT", 0, -4)
    hint:SetText("Open a profession, then click Export.")

    local status = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -4)
    status:SetTextColor(0, 1, 0)
    status:SetJustifyH("LEFT")

    local lastImport = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lastImport:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -4)

    local exportBox, exportEditBox = CreateTextBox(page, TEXTBOX_WIDTH, 90, true)
    exportBox:SetPoint("TOPLEFT", lastImport, "BOTTOMLEFT", 0, -8)

    local exportBtn = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    exportBtn:SetSize(100, 22)
    exportBtn:SetPoint("TOPLEFT", exportBox, "BOTTOMLEFT", 0, -8)
    exportBtn:SetText("Export")

    local function RefreshOwnStatus()
        local lines = {}
        for _, skillName in ipairs(GT.GetProfessionNames()) do
            table.insert(lines, skillName .. " known")
        end
        status:SetText(table.concat(lines, ", "))

        local lastImportText = GT.GetLastImportText()
        lastImport:SetText(lastImportText and ("Last export: " .. lastImportText) or "")
    end
    page.RefreshOwnStatus = RefreshOwnStatus

    exportBtn:SetScript("OnClick", function()
        local json = GT.ExportCurrentCharacter()
        exportEditBox.lastSetText = json
        exportEditBox:SetText(json)
        exportEditBox:HighlightText()
        exportEditBox:SetFocus()
        RefreshOwnStatus()
    end)

    -- Guild-wide data import
    local importLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    importLabel:SetPoint("TOPLEFT", exportBtn, "BOTTOMLEFT", 0, -16)
    importLabel:SetText("Import guild data")

    local importHint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    importHint:SetPoint("TOPLEFT", importLabel, "BOTTOMLEFT", 0, -4)
    importHint:SetText("Paste the export string from the website, then click Import.")

    local importBox, importEditBox = CreateTextBox(page, TEXTBOX_WIDTH, 70)
    importBox:SetPoint("TOPLEFT", importHint, "BOTTOMLEFT", 0, -8)

    local importBtn = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    importBtn:SetSize(100, 22)
    importBtn:SetPoint("TOPLEFT", importBox, "BOTTOMLEFT", 0, -8)
    importBtn:SetText("Import")

    local importStatus = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    importStatus:SetPoint("TOPLEFT", importBtn, "TOPRIGHT", 12, -4)
    importStatus:SetPoint("RIGHT", page, "RIGHT", -32, 0)
    importStatus:SetJustifyH("LEFT")

    local function RefreshImportStatus()
        local summary = GT.GetGuildDataSummary()
        if summary then
            importStatus:SetTextColor(0.6, 0.6, 0.6)
            importStatus:SetText("Loaded: " .. summary)
        else
            importStatus:SetTextColor(0.6, 0.6, 0.6)
            importStatus:SetText("No guild data imported yet.")
        end
    end
    page.RefreshImportStatus = RefreshImportStatus

    importBtn:SetScript("OnClick", function()
        local ok, err = GT.ImportGuildData(importEditBox:GetText())
        if ok then
            importEditBox:SetText("")
            importStatus:SetTextColor(0, 1, 0)
            importStatus:SetText("Import successful! " .. (GT.GetGuildDataSummary() or ""))
            if frame and frame.RefreshProfessionPage then
                frame.RefreshProfessionPage()
            end
        else
            importStatus:SetTextColor(1, 0.2, 0.2)
            importStatus:SetText(err or "Import failed.")
        end
    end)

    page.Refresh = function()
        RefreshOwnStatus()
        RefreshImportStatus()
    end

    return page
end

-----------------------------
-- PROFESSION BROWSER PAGE --
-----------------------------
-- Browse one of YOUR known professions' full recipe list.

local function CreateProfessionRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 2, 0)
    row.icon = icon

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetJustifyH("LEFT")
    row.nameText = name

    local crafters = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    crafters:SetPoint("RIGHT", -4, 0)
    crafters:SetJustifyH("RIGHT")
    row.craftersText = crafters

    name:SetPoint("RIGHT", crafters, "LEFT", -6, 0)

    row:SetScript("OnEnter", function(self)
        if not self.data then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if not SetNativeTooltip(self.data.kind, self.data.id) then
            GameTooltip:SetText(self.data.name, 1, 1, 1)
        end
        GameTooltip:AddLine(" ")
        if #self.data.crafters == 0 then
            GameTooltip:AddLine("No one in the guild can craft this yet.", 0.6, 0.6, 0.6)
        else
            GameTooltip:AddLine("Can be crafted by:", 0.7, 0.7, 0.7)
            for _, c in ipairs(self.data.crafters) do
                local r, g, b = GetClassColor(c.class)
                local label = c.name
                if c.realm and c.realm ~= "" then
                    label = label .. "-" .. c.realm
                end
                GameTooltip:AddLine(label, r, g, b)
            end
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

local function BuildProfessionPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    page.currentProfession = nil
    page.filtered = {}

    local searchBox = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
    searchBox:SetHeight(20)
    searchBox:SetPoint("TOPLEFT", 12, -8)
    searchBox:SetPoint("RIGHT", page, "RIGHT", -12, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    page.searchBox = searchBox

    local scrollFrame = CreateFrame("ScrollFrame", "GuildThingProfessionScrollFrame", page, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -28, 4)
    page.scrollFrame = scrollFrame

    local rows = {}
    for i = 1, VISIBLE_ROWS do
        local row = CreateProfessionRow(page)
        row:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:SetPoint("RIGHT", scrollFrame, "RIGHT", 0, 0)
        rows[i] = row
    end
    page.rows = rows

    local function UpdateRows()
        local data = page.filtered
        FauxScrollFrame_Update(scrollFrame, #data, VISIBLE_ROWS, ROW_HEIGHT)
        local offset = FauxScrollFrame_GetOffset(scrollFrame)

        for i = 1, VISIBLE_ROWS do
            local row = rows[i]
            local recipe = data[i + offset]
            if recipe then
                row.data = recipe
                row.icon:SetTexture("Interface\\Icons\\" .. recipe.icon)
                row.nameText:SetText(recipe.name)
                row.craftersText:SetText(FormatCrafters(recipe.crafters))

                local known = #recipe.crafters > 0
                if known then
                    row.icon:SetAlpha(1)
                    row.nameText:SetTextColor(1, 1, 1)
                else
                    row.icon:SetAlpha(0.35)
                    row.nameText:SetTextColor(0.5, 0.5, 0.5)
                end

                row:Show()
            else
                row.data = nil
                row:Hide()
            end
        end
    end
    page.UpdateRows = UpdateRows

    scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, UpdateRows)
    end)

    local function Rebuild()
        if not page.currentProfession then
            page.filtered = {}
            UpdateRows()
            return
        end

        local query = (searchBox:GetText() or ""):lower()
        local catalog = GT.GetCatalogForProfession(page.currentProfession)
        local filtered = {}
        for _, recipe in ipairs(catalog) do
            if query == "" or recipe.name:lower():find(query, 1, true) then
                table.insert(filtered, {
                    name = recipe.name,
                    icon = recipe.icon,
                    kind = recipe.kind,
                    id = recipe.id,
                    crafters = GT.GetCraftersForRecipe(page.currentProfession, recipe.name),
                })
            end
        end
        page.filtered = filtered
        UpdateRows()
    end
    page.Rebuild = Rebuild

    searchBox:SetScript("OnTextChanged", Rebuild)

    page.ShowProfession = function(profName)
        page.currentProfession = profName
        searchBox:SetText("")
        Rebuild()
    end

    return page
end

-----------------------------
-- OVERVIEW PAGE --
-----------------------------
-- Browse the whole guild roster, drilling down into any character's
-- professions and known recipes.

-- Simpler row for the Overview drill-down (roster / per-character
-- profession list / per-character recipe list) — no crafters tooltip like
-- CreateProfessionRow, just an optional icon + name + right-aligned subtext.

local function CreateOverviewRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:EnableMouse(true)
    row:RegisterForClicks("LeftButtonUp")

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 2, 0)
    row.icon = icon

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetJustifyH("LEFT")
    row.nameText = name

    local sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("RIGHT", -4, 0)
    sub:SetJustifyH("RIGHT")
    row.subText = sub

    name:SetPoint("RIGHT", sub, "LEFT", -6, 0)

    -- Only roster/profession-list rows lack kind+id (no icon there either),
    -- so this naturally only fires for the per-character recipe list.
    row:SetScript("OnEnter", function(self)
        if not self.data or not self.data.kind or not self.data.id then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        SetNativeTooltip(self.data.kind, self.data.id)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

-- Overview page: drill down guild roster -> a character's known
-- professions -> that profession's full recipe list for them (known ones
-- highlighted, the rest greyed out same as the main profession browser).
local function BuildOverviewPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    page.items = {}

    local breadcrumb = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    breadcrumb:SetPoint("TOPLEFT", 12, -8)
    breadcrumb:SetJustifyH("LEFT")

    local backBtn = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    backBtn:SetSize(70, 20)
    backBtn:SetPoint("TOPRIGHT", -12, -6)
    backBtn:SetText("< Back")
    backBtn:Hide()
    page.backBtn = backBtn

    -- Roster-only fuzzy search (fzf-style, see FuzzyMatch) — same top-right
    -- slot backBtn uses, since the two are never shown at the same time
    -- (this is level 1 only, backBtn is level 2+).
    local rosterSearchLabel = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    rosterSearchLabel:SetText("Find:")

    local rosterSearchBox = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
    rosterSearchBox:SetSize(140, 20)
    rosterSearchBox:SetPoint("TOPRIGHT", -12, -6)
    rosterSearchBox:SetAutoFocus(false)
    rosterSearchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)

    rosterSearchLabel:SetPoint("RIGHT", rosterSearchBox, "LEFT", -6, 0)

    -- Forward decls: filter buttons / checkboxes below close over these.
    local ShowRoster, ShowCharacter, ShowCharacterProfession
    local RebuildRoster, RebuildCharacterProfession
    -- Set of active profession names (not a single value) — multiple can
    -- be toggled on at once, OR'd together in RebuildRoster below.
    local activeProfessionFilters = {}
    -- Pseudo-filter alongside the real profession names — characters with
    -- no profession data at all are hidden by default (see RebuildRoster);
    -- toggling this is the only way to bring them back.
    local NO_PROFESSION_LABEL = "No profession"

    -- Live-updates as you type, same as the level-3 recipe search box below.
    rosterSearchBox:SetScript("OnTextChanged", function() RebuildRoster() end)

    -- Profession filter row — roster only (level 1). Plain clickable text,
    -- not buttons: normal color when off, a highlight color when toggled
    -- on. Click again to toggle back off; several can be active together.
    local filterBar = CreateFrame("Frame", nil, page)
    filterBar:SetPoint("TOPLEFT", breadcrumb, "BOTTOMLEFT", 0, -6)
    filterBar:SetPoint("RIGHT", page, "RIGHT", -12, 0)

    local filterLabels = {}
    local function StyleFilterLabel(label)
        if activeProfessionFilters[label.profName] then
            label:SetTextColor(0.35, 1, 0.35)
        else
            label:SetTextColor(1, 1, 1)
        end
    end
    local function UpdateFilterLabelStyles()
        for _, label in ipairs(filterLabels) do
            StyleFilterLabel(label)
        end
    end

    do
        local maxRowWidth = TEXTBOX_WIDTH
        local rowHeight, spacing = 14, 12
        local x, y = 0, 0

        local filterOptions = {}
        for _, profName in ipairs(GT.GetProfessionOrder()) do
            table.insert(filterOptions, profName)
        end
        table.insert(filterOptions, NO_PROFESSION_LABEL)

        for _, profName in ipairs(filterOptions) do
            local hitbox = CreateFrame("Button", nil, filterBar)
            hitbox:SetHeight(rowHeight)

            local label = hitbox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            label:SetPoint("LEFT", 0, 0)
            label:SetText(profName)
            label.profName = profName

            -- Sized to fit the label itself, since profession names range
            -- from "Cooking" to "Leatherworking".
            local textWidth = label:GetStringWidth()
            hitbox:SetWidth(textWidth)

            if x > 0 and x + textWidth > maxRowWidth then
                x = 0
                y = y - (rowHeight + 6)
            end
            hitbox:SetPoint("TOPLEFT", x, y)
            x = x + textWidth + spacing

            hitbox:SetScript("OnEnter", function()
                if not activeProfessionFilters[profName] then
                    label:SetTextColor(1, 1, 0.6)
                end
            end)
            hitbox:SetScript("OnLeave", function() StyleFilterLabel(label) end)
            hitbox:SetScript("OnClick", function()
                if activeProfessionFilters[profName] then
                    activeProfessionFilters[profName] = nil
                else
                    activeProfessionFilters[profName] = true
                end
                StyleFilterLabel(label)
                RebuildRoster()
            end)

            table.insert(filterLabels, label)
        end
        filterBar:SetHeight(-y + rowHeight)
    end

    -- Search + sort toolbar — only shown for the per-character recipe list
    -- (character -> profession drill-down), where there's actually a known/
    -- unknown split worth searching and sorting.
    local toolbar = CreateFrame("Frame", nil, page)
    toolbar:SetPoint("TOPLEFT", breadcrumb, "BOTTOMLEFT", 0, -6)
    toolbar:SetPoint("RIGHT", page, "RIGHT", -12, 0)
    toolbar:SetHeight(20)
    toolbar:Hide()

    local searchBox = CreateFrame("EditBox", nil, toolbar, "InputBoxTemplate")
    searchBox:SetSize(150, 20)
    searchBox:SetPoint("LEFT", 6, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnTextChanged", function() RebuildCharacterProfession() end)

    local sortKnownCheck = CreateFrame("CheckButton", nil, toolbar, "UICheckButtonTemplate")
    sortKnownCheck:SetSize(20, 20)
    sortKnownCheck:SetPoint("LEFT", searchBox, "RIGHT", 14, 0)

    local sortKnownLabel = toolbar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sortKnownLabel:SetPoint("LEFT", sortKnownCheck, "RIGHT", 2, 0)
    sortKnownLabel:SetText("Known first")

    local sortUnknownCheck = CreateFrame("CheckButton", nil, toolbar, "UICheckButtonTemplate")
    sortUnknownCheck:SetSize(20, 20)
    sortUnknownCheck:SetPoint("LEFT", sortKnownLabel, "RIGHT", 10, 0)

    local sortUnknownLabel = toolbar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sortUnknownLabel:SetPoint("LEFT", sortUnknownCheck, "RIGHT", 2, 0)
    sortUnknownLabel:SetText("Unknown first")

    -- page.sortMode: "none" (default — catalog order, i.e. alphabetical),
    -- "known", or "unknown". The two checkboxes are mutually exclusive;
    -- unchecking either (or the currently active one) goes back to "none".
    page.sortMode = "none"

    sortKnownCheck:SetScript("OnClick", function(self)
        if self:GetChecked() then
            page.sortMode = "known"
            sortUnknownCheck:SetChecked(false)
        else
            page.sortMode = "none"
        end
        RebuildCharacterProfession()
    end)

    sortUnknownCheck:SetScript("OnClick", function(self)
        if self:GetChecked() then
            page.sortMode = "unknown"
            sortKnownCheck:SetChecked(false)
        else
            page.sortMode = "none"
        end
        RebuildCharacterProfession()
    end)

    local scrollFrame = CreateFrame("ScrollFrame", "GuildThingOverviewScrollFrame", page, "FauxScrollFrameTemplate")

    -- Level 1 (roster) anchors the list below the profession filter row;
    -- level 2 (character's profession list) has neither bar, straight
    -- below the breadcrumb; level 3 drops the search/sort toolbar in
    -- between and anchors below that instead.
    local function AnchorScrollBelow(anchor, gap)
        scrollFrame:ClearAllPoints()
        scrollFrame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -gap)
        scrollFrame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -28, 4)
    end

    local rows = {}
    for i = 1, VISIBLE_ROWS do
        local row = CreateOverviewRow(page)
        row:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:SetPoint("RIGHT", scrollFrame, "RIGHT", 0, 0)
        rows[i] = row
    end

    local function UpdateRows()
        local data = page.items
        FauxScrollFrame_Update(scrollFrame, #data, VISIBLE_ROWS, ROW_HEIGHT)
        local offset = FauxScrollFrame_GetOffset(scrollFrame)

        for i = 1, VISIBLE_ROWS do
            local row = rows[i]
            local item = data[i + offset]
            if item then
                row:Show()
                row.data = item
                row:SetScript("OnClick", item.onClick)

                if item.icon then
                    row.icon:Show()
                    row.icon:SetTexture("Interface\\Icons\\" .. item.icon)
                    row.icon:SetAlpha(item.dim and 0.35 or 1)
                else
                    row.icon:Hide()
                end

                row.nameText:SetText(item.name)
                if item.dim then
                    row.nameText:SetTextColor(0.5, 0.5, 0.5)
                else
                    row.nameText:SetTextColor(item.r or 1, item.g or 1, item.b or 1)
                end
                row.subText:SetText(item.sub or "")
            else
                row.data = nil
                row:Hide()
                row:SetScript("OnClick", nil)
            end
        end
    end

    scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, UpdateRows)
    end)

    -- "Engineering 375", or "Engineering 375 (no data)" when we know the
    -- skill level (via C_Club) but have no export telling us what they can
    -- actually craft. Secondary professions (Cooking, First Aid) never get a
    -- level here — C_Club only reports the two primary-profession slots —
    -- so those just show the name.
    local function FormatProfessionTag(s)
        local tag = s.profession
        if s.rank then
            tag = tag .. " " .. s.rank
        end
        if s.count == 0 then
            tag = tag .. " (no data)"
        end
        return tag
    end

    RebuildRoster = function()
        local items = {}
        local hasNoFilters = not next(activeProfessionFilters)
        local query = (rosterSearchBox:GetText() or ""):match("^%s*(.-)%s*$")
        for _, char in ipairs(GT.GetRoster()) do
            local summary = GT.GetCharacterProfessionSummary(char.name, char.realm)
            local profTags = {}
            local matchesFilter = false

            -- Highest rank among the professions actually relevant to the
            -- current view (the active filters, or all of them if none are
            -- set) — drives the sort below, highest first.
            local sortRank = 0

            if #summary > 0 then
                -- Default (no filters active) shows anyone with at least
                -- one profession; explicit filters narrow that down.
                matchesFilter = hasNoFilters
                for _, s in ipairs(summary) do
                    table.insert(profTags, FormatProfessionTag(s))
                    local isRelevant = hasNoFilters or activeProfessionFilters[s.profession]
                    if isRelevant then
                        matchesFilter = true
                        if s.rank and s.rank > sortRank then
                            sortRank = s.rank
                        end
                    end
                end
            else
                -- No profession data at all — hidden by default, only
                -- shown when that's explicitly toggled on.
                matchesFilter = activeProfessionFilters[NO_PROFESSION_LABEL] == true
            end

            local searchScore = 0
            if matchesFilter and query ~= "" then
                searchScore = FuzzyMatch(char.name, query)
                if not searchScore then
                    matchesFilter = false
                end
            end

            if matchesFilter then
                local r, g, b = GetClassColor(char.class)
                table.insert(items, {
                    name = char.name .. (char.isSelf and " (you)" or ""),
                    sub = #profTags > 0 and table.concat(profTags, ", ") or "no professions known",
                    r = r, g = g, b = b,
                    sortRank = sortRank,
                    searchScore = searchScore,
                    onClick = function() ShowCharacter(char) end,
                })
            end
        end

        if query ~= "" then
            -- Searching: best fuzzy match first, alphabetical tiebreak —
            -- profession rank stops mattering once you're hunting a name.
            table.sort(items, function(a, b)
                if a.searchScore ~= b.searchScore then
                    return a.searchScore > b.searchScore
                end
                return a.name:lower() < b.name:lower()
            end)
        else
            -- No search: highest rank first (relevant-to-current-filter
            -- rank, see above), alphabetical as a tiebreak / for those with
            -- no rank at all.
            table.sort(items, function(a, b)
                if a.sortRank ~= b.sortRank then
                    return a.sortRank > b.sortRank
                end
                return a.name:lower() < b.name:lower()
            end)
        end

        page.items = items
        UpdateRows()
    end

    ShowRoster = function()
        breadcrumb:SetText("All guild members")
        backBtn:Hide()
        toolbar:Hide()
        filterBar:Show()
        rosterSearchLabel:Show()
        rosterSearchBox:Show()
        AnchorScrollBelow(filterBar, 8)
        RebuildRoster()
    end

    ShowCharacter = function(char)
        breadcrumb:SetText((char.name or "?") .. "'s professions")
        backBtn:Show()
        rosterSearchLabel:Hide()
        rosterSearchBox:Hide()
        backBtn:SetScript("OnClick", ShowRoster)
        filterBar:Hide()
        toolbar:Hide()
        AnchorScrollBelow(breadcrumb, 8)

        -- Whether we have (or ever had) an actual export for this character,
        -- as opposed to just a live C_Club skill-level scan — determines
        -- which of the two "no recipe data" messages below applies.
        local hasAnyExport = char.isSelf or GT.FindGuildDataCharacterIndex(char.name, char.realm) ~= nil

        local items = {}
        for _, s in ipairs(GT.GetCharacterProfessionSummary(char.name, char.realm)) do
            local sub, clickable
            if s.count > 0 then
                sub = tostring(s.count) .. " known"
                clickable = true
            elseif hasAnyExport then
                sub = ("Level %d — recipe data may be outdated"):format(s.rank)
            else
                sub = ("Level %d — hasn't exported to GuildThing yet"):format(s.rank)
            end
            table.insert(items, {
                name = s.profession,
                sub = sub,
                dim = not clickable,
                onClick = clickable and function() ShowCharacterProfession(char, s.profession) end or nil,
            })
        end
        if #items == 0 then
            table.insert(items, { name = "No known professions yet.", sub = "" })
        end
        page.items = items
        UpdateRows()
    end

    RebuildCharacterProfession = function()
        if not page.currentChar or not page.currentProfName then return end

        local query = searchBox:GetText() or ""
        local items = {}
        for _, status in ipairs(GT.GetCharacterRecipeStatuses(page.currentChar.name, page.currentChar.realm, page.currentProfName)) do
            if query == "" or FuzzyMatch(status.name, query) then
                table.insert(items, {
                    name = status.name,
                    icon = status.icon,
                    kind = status.kind,
                    id = status.id,
                    known = status.known,
                    dim = not status.known,
                })
            end
        end

        if page.sortMode == "known" then
            table.sort(items, function(a, b)
                if a.known ~= b.known then return a.known end
                return a.name < b.name
            end)
        elseif page.sortMode == "unknown" then
            table.sort(items, function(a, b)
                if a.known ~= b.known then return not a.known end
                return a.name < b.name
            end)
        end
        -- sortMode == "none": leave in catalog order (already alphabetical).

        page.items = items
        UpdateRows()
    end

    ShowCharacterProfession = function(char, profName)
        breadcrumb:SetText((char.name or "?") .. " — " .. profName)
        backBtn:Show()
        backBtn:SetScript("OnClick", function() ShowCharacter(char) end)
        filterBar:Hide()

        page.currentChar = char
        page.currentProfName = profName
        page.sortMode = "none"
        searchBox:SetText("")
        sortKnownCheck:SetChecked(false)
        sortUnknownCheck:SetChecked(false)
        toolbar:Show()
        AnchorScrollBelow(toolbar, 8)

        RebuildCharacterProfession()
    end

    page.ShowRoster = function()
        activeProfessionFilters = {}
        UpdateFilterLabelStyles()
        ShowRoster()
    end

    return page
end

-----------------------------
-- DEBUG PAGE --
-----------------------------
-- Only reachable if GT.DEBUG_UI_ENABLED is flipped on in Debug.lua (see
-- CreateGTFrame below, which gates the sidebar entry on it). Every button
-- here just forwards a string to GT.HandleDebugCommand — the exact same
-- entry point /or debug already uses — so a button click is always 1:1
-- with typing the equivalent command, never a second code path to drift
-- out of sync with the real thing.

-- First `count` catalog recipes (that resolve to a real spellID) for
-- profName, comma-joined — same trick as the /run snippet used to solo-test
-- multi-chunk reassembly without hand-typing dozens of recipe names.
local function BuildSampleRecipeList(profName, count)
    local names = {}
    for _, recipe in ipairs(GT.GetCatalogForProfession(profName)) do
        if recipe.kind == "spell" then
            table.insert(names, recipe.name)
            if #names >= count then break end
        end
    end
    return table.concat(names, ",")
end

local function BuildDebugPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    local title = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 4, -4)
    title:SetText("P2P debug tools")

    local hint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    hint:SetText("Developer only. Output prints to chat, same as /or debug.")

    local previousAnchor = hint
    local function AddButton(label, onClick)
        local btn = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
        btn:SetSize(220, 22)
        btn:SetPoint("TOPLEFT", previousAnchor, "BOTTOMLEFT", 0, -8)
        btn:SetText(label)
        btn:SetScript("OnClick", onClick)
        previousAnchor = btn
        return btn
    end

    AddButton("Force broadcast", function()
        GT.HandleDebugCommand("broadcast")
    end)

    AddButton("Dump P2PData", function()
        GT.HandleDebugCommand("dump")
    end)

    AddButton("Simulate testkingen (2 recipes)", function()
        GT.HandleDebugCommand("fakerecipe testkingen Adept's Elixir")
        GT.HandleDebugCommand("fakerecipe testkingen Arcane Elixir")
    end)

    AddButton("Simulate multi-chunk (40 recipes)", function()
        local list = BuildSampleRecipeList("Engineering", 40)
        GT.HandleDebugCommand("fakerecipe multichunktest " .. list)
    end)

    AddButton("SYN self-hash (same branch)", function()
        GT.HandleDebugCommand("fakewhisper testkingen SYN:" .. tostring(GT.DebugGetCombinedHash()))
    end)

    -- Freeform command row — same 255-char chat cap never applies here,
    -- since this never goes through the chat edit box at all.
    local cmdLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cmdLabel:SetPoint("TOPLEFT", previousAnchor, "BOTTOMLEFT", 0, -16)
    cmdLabel:SetText("Freeform: /or debug ...")

    local cmdBox = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
    cmdBox:SetSize(TEXTBOX_WIDTH - 90, 20)
    cmdBox:SetAutoFocus(false)
    cmdBox:SetPoint("TOPLEFT", cmdLabel, "BOTTOMLEFT", 8, -8)

    local runBtn = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    runBtn:SetSize(80, 22)
    runBtn:SetPoint("LEFT", cmdBox, "RIGHT", 8, 0)
    runBtn:SetText("Run")

    local function RunCmdBox()
        local text = cmdBox:GetText()
        if text and text ~= "" then
            GT.HandleDebugCommand(text)
            cmdBox:SetText("")
        end
    end
    runBtn:SetScript("OnClick", RunCmdBox)
    cmdBox:SetScript("OnEnterPressed", RunCmdBox)

    return page
end

-----------------------------
-- MAIN FRAME / CHROME --
-----------------------------
-- The window itself: sidebar tabs + the pages built above.

local function CreateSidebarButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(22)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.12)
    bg:Hide()
    btn.bg = bg

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", 8, 0)
    label:SetPoint("RIGHT", -8, 0)
    label:SetJustifyH("LEFT")
    btn.label = label

    btn:SetScript("OnEnter", function(self) self.bg:Show() end)
    btn:SetScript("OnLeave", function(self)
        if not self.isSelected then self.bg:Hide() end
    end)

    return btn
end

local function CreateGTFrame()
    local f = CreateFrame("Frame", "GuildThingFrame", UIParent, "BackdropTemplate")
    f:SetSize(700, 480)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetFrameStrata("DIALOG")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Our Recipes!")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    -- Sidebar
    local sidebar = CreateFrame("Frame", nil, f)
    sidebar:SetPoint("TOPLEFT", 16, -44)
    sidebar:SetPoint("BOTTOMLEFT", 16, 16)
    sidebar:SetWidth(SIDEBAR_WIDTH)

    -- Subtle panel behind the whole sidebar so it reads as a distinct menu
    -- instead of floating text directly on the dialog's translucent backdrop.
    local sidebarBg = sidebar:CreateTexture(nil, "BACKGROUND")
    sidebarBg:SetPoint("TOPLEFT", -6, 6)
    sidebarBg:SetPoint("BOTTOMRIGHT", 6, -6)
    sidebarBg:SetColorTexture(0, 0, 0, 0.25)

    -- Thin divider between the sidebar and the content pane.
    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 6, 0)
    divider:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMRIGHT", 6, 0)
    divider:SetWidth(1)
    divider:SetColorTexture(1, 1, 1, 0.15)

    local sidebarButtons = {}

    local overviewBtn = CreateSidebarButton(sidebar)
    overviewBtn:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 0, 0)
    overviewBtn:SetPoint("RIGHT", sidebar, "RIGHT", 0, 0)
    overviewBtn.label:SetText("Overview")
    table.insert(sidebarButtons, overviewBtn)

    -- Plain section label, not a button — muted grey so it doesn't read as
    -- a selectable (or selected) item like the gold GameFontNormal color would.
    local header = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", overviewBtn, "BOTTOMLEFT", 8, -10)
    header:SetTextColor(0.6, 0.6, 0.6)
    header:SetText("Professions")

    local previousAnchor = header
    for i, profName in ipairs(GT.GetProfessionOrder()) do
        local btn = CreateSidebarButton(sidebar)
        -- First entry under a header sits at x=-8 (compensating the
        -- header's own +8 inset); every entry after that just chains off
        -- the previous button at x=0 — same convention used below for
        -- Settings.
        btn:SetPoint("TOPLEFT", previousAnchor, "BOTTOMLEFT", i == 1 and -8 or 0, -4)
        btn:SetPoint("RIGHT", sidebar, "RIGHT", 0, 0)
        btn.label:SetText(profName)
        btn.profession = profName
        table.insert(sidebarButtons, btn)
        previousAnchor = btn
    end

    -- Settings section — Import/Export always lives here; Debug only if
    -- GT.DEBUG_UI_ENABLED (Debug.lua) is manually flipped on.
    local settingsHeader = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    settingsHeader:SetPoint("TOPLEFT", previousAnchor, "BOTTOMLEFT", 8, -10)
    settingsHeader:SetTextColor(0.6, 0.6, 0.6)
    settingsHeader:SetText("Settings")

    local importExportBtn = CreateSidebarButton(sidebar)
    importExportBtn:SetPoint("TOPLEFT", settingsHeader, "BOTTOMLEFT", -8, -4)
    importExportBtn:SetPoint("RIGHT", sidebar, "RIGHT", 0, 0)
    importExportBtn.label:SetText("Import / Export")
    table.insert(sidebarButtons, importExportBtn)
    previousAnchor = importExportBtn

    local debugBtn
    if GT.DEBUG_UI_ENABLED then
        debugBtn = CreateSidebarButton(sidebar)
        debugBtn:SetPoint("TOPLEFT", previousAnchor, "BOTTOMLEFT", 0, -4)
        debugBtn:SetPoint("RIGHT", sidebar, "RIGHT", 0, 0)
        debugBtn.label:SetText("Debug")
        table.insert(sidebarButtons, debugBtn)
    end

    -- Content pane
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 16, 0)
    content:SetPoint("BOTTOMRIGHT", -20, 16)

    local importExportPage = BuildImportExportPage(content)
    local professionPage = BuildProfessionPage(content)
    local overviewPage = BuildOverviewPage(content)
    local debugPage = GT.DEBUG_UI_ENABLED and BuildDebugPage(content) or nil

    local function SelectSidebar(selectedBtn)
        for _, btn in ipairs(sidebarButtons) do
            btn.isSelected = (btn == selectedBtn)
            btn.bg:SetShown(btn.isSelected)
        end
    end

    local function ShowPage(page)
        importExportPage:Hide()
        professionPage:Hide()
        overviewPage:Hide()
        if debugPage then debugPage:Hide() end
        page:Show()
    end

    importExportBtn:SetScript("OnClick", function()
        SelectSidebar(importExportBtn)
        ShowPage(importExportPage)
        importExportPage.Refresh()
    end)

    overviewBtn:SetScript("OnClick", function()
        SelectSidebar(overviewBtn)
        ShowPage(overviewPage)
        overviewPage.ShowRoster()
    end)

    for _, btn in ipairs(sidebarButtons) do
        if btn.profession then
            btn:SetScript("OnClick", function()
                SelectSidebar(btn)
                ShowPage(professionPage)
                professionPage.ShowProfession(btn.profession)
            end)
        end
    end

    if debugBtn then
        debugBtn:SetScript("OnClick", function()
            SelectSidebar(debugBtn)
            ShowPage(debugPage)
        end)
    end

    f.RefreshProfessionPage = function()
        if professionPage.currentProfession then
            professionPage.Rebuild()
        end
    end

    f:SetScript("OnShow", function()
        SelectSidebar(overviewBtn)
        ShowPage(overviewPage)
        overviewPage.ShowRoster()
    end)

    -- Frames are shown by default on creation; without this the very first
    -- `/or` would create-then-immediately-hide (ToggleGTFrame sees it as
    -- already shown and hides it), needing a second press to actually open.
    f:Hide()

    return f
end

local function ToggleGTFrame()
    if not frame then
        local ok, result = pcall(CreateGTFrame)
        if not ok then
            print("|cffff0000GuildThing error:|r " .. tostring(result))
            return
        end
        frame = result
    end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end

GT.ToggleUI = ToggleGTFrame

SLASH_GUILDTHING1 = "/or"
SLASH_GUILDTHING2 = "/ourrecipes"
SlashCmdList["GUILDTHING"] = function(msg)
	local debugArgs = (msg or ""):match("^debug%s*(.-)%s*$")
	if debugArgs then
		GT.HandleDebugCommand(debugArgs)
		return
	end
	ToggleGTFrame()
end
