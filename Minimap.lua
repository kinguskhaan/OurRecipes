local GT = GuildThing

local ICON = "Interface\\Icons\\INV_Misc_Book_09"

GuildThingDB.minimap = GuildThingDB.minimap or { hide = false, angle = 220 }
local mmDB = GuildThingDB.minimap

local button = CreateFrame("Button", "GuildThingMinimapButton", Minimap)
button:SetSize(31, 31)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
button:RegisterForDrag("LeftButton")
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local overlay = button:CreateTexture(nil, "OVERLAY")
overlay:SetSize(53, 53)
overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
overlay:SetPoint("TOPLEFT")

local icon = button:CreateTexture(nil, "BACKGROUND")
icon:SetSize(18, 18)
icon:SetTexture(ICON)
icon:SetPoint("CENTER", 0, 1)

local function UpdatePosition()
    local angle = math.rad(mmDB.angle or 220)
    local radius = 80
    button:ClearAllPoints()
    button:SetPoint(
        "CENTER", Minimap, "CENTER",
        -radius * math.cos(angle), radius * math.sin(angle)
    )
end

button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        mmDB.angle = math.deg(math.atan2(py - my, px - mx))
        UpdatePosition()
    end)
end)

button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

button:SetScript("OnClick", function(_, mouseButton)
    if mouseButton == "LeftButton" then
        GT.ToggleUI()
    end
end)

button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Our Recipes!")
    GameTooltip:AddLine("|cffffffffLeft-click|r to open", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffffffDrag|r to move", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end)

button:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

UpdatePosition()
button:SetShown(not mmDB.hide)

function GT.ToggleMinimapButton()
    mmDB.hide = not mmDB.hide
    button:SetShown(not mmDB.hide)
    return not mmDB.hide
end
