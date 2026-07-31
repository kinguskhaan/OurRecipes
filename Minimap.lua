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

-- Which quadrants GetMinimapShape() renders round vs square-cornered.
-- Mirrors LibDBIcon-1.0's table so our button clips to the same edge
-- ElvUI/other square-minimap addons draw, instead of always orbiting a circle.
local minimapShapes = {
    ["ROUND"] = {true, true, true, true},
    ["SQUARE"] = {false, false, false, false},
    ["CORNER-TOPLEFT"] = {false, false, false, true},
    ["CORNER-TOPRIGHT"] = {false, false, true, false},
    ["CORNER-BOTTOMLEFT"] = {false, true, false, false},
    ["CORNER-BOTTOMRIGHT"] = {true, false, false, false},
    ["SIDE-LEFT"] = {false, true, false, true},
    ["SIDE-RIGHT"] = {true, false, true, false},
    ["SIDE-TOP"] = {false, false, true, true},
    ["SIDE-BOTTOM"] = {true, true, false, false},
    ["TRICORNER-TOPLEFT"] = {false, true, true, true},
    ["TRICORNER-TOPRIGHT"] = {true, false, true, true},
    ["TRICORNER-BOTTOMLEFT"] = {true, true, false, true},
    ["TRICORNER-BOTTOMRIGHT"] = {true, true, true, false},
}

local function UpdatePosition()
    local angle = math.rad(mmDB.angle or 220)
    local edgeBuffer = 5
    local x, y = -math.cos(angle), math.sin(angle)

    local minimapShape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local quadTable = minimapShapes[minimapShape]
    local q = 1
    if x < 0 then q = q + 1 end
    if y > 0 then q = q + 2 end

    local w = (Minimap:GetWidth() / 2) + edgeBuffer
    local h = (Minimap:GetHeight() / 2) + edgeBuffer
    if quadTable[q] then
        x, y = x * w, y * h
    else
        local diagRadiusW = math.sqrt(2 * w ^ 2) - 10
        local diagRadiusH = math.sqrt(2 * h ^ 2) - 10
        x = math.max(-w, math.min(x * diagRadiusW, w))
        y = math.max(-h, math.min(y * diagRadiusH, h))
    end

    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
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
