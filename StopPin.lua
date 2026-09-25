---@class SPFNamespace
local ns = select(2, ...)

local GOAL_ATLAS, GOAL_SCALE = "Waypoint-MapPin-Tracked", 0.8
local STOP_ATLAS, STOP_SIZE, MAX_NUMERAL = "adventureguide-ring", 26, 9
-- A lone stop's own mark stands alone at the size of the map's quest marks. A numbered one keeps its ring and wears the
-- mark as a badge over the ring's lower right, as Legacy Forever's entrance pins wear the Legacy shield; the pin's hit
-- rect reaches out over the badge.
local LOOK_SIZE, BADGE_SIZE, BADGE_OFFSET = 22, 16, 4
-- Later stop rings stay stronger than Route.lua's later lines so their numbers remain legible.
local LATER_STOP_ALPHA = 0.55
-- Route.lua groups stops by the ring's size and rings the minimap's stop with the same art.
ns.GoalAtlas, ns.StopAtlas, ns.StopSize = GOAL_ATLAS, STOP_ATLAS, STOP_SIZE

-- A shared ring's corner count: how many more stops it holds past the first, whose number the ring shows.
---@param numbers integer[]
local function StopCount(numbers)
	return #numbers > 1 and "+" .. (#numbers - 1) or ""
end

---@class SPFGoalPin : SPFMapPin
---@field Texture Texture
---@field Icon Texture
---@field Disc Texture
---@field Glow Texture
---@field Numeral Texture
---@field Number FontString
---@field Count FontString
---@field stopTitles? string[]
ShortestPathForeverGoalPinMixin = CreateFromMixins(MapCanvasPinMixin)

function ShortestPathForeverGoalPinMixin:OnLoad()
	-- The user waypoint's level (WaypointLocationDataProvider), above every quest POI, super-tracked ones included.
	self:UseFrameLevelType("PIN_FRAME_LEVEL_WAYPOINT_LOCATION")
	self:SetIgnoreGlobalPinScale(true)
	self:SetScalingLimits(1, 1, 1)
	self.Number = self:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	self.Number:SetPoint("CENTER")
	-- The item stack count's font, where the kind badge would hang.
	self.Count = self:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	self.Count:SetPoint("BOTTOMRIGHT", BADGE_OFFSET, -BADGE_OFFSET)
	self:SetScript("OnHide", self.OnMouseLeave)
end

-- A lone destination wears the waypoint pin; a numbered stop wears the ring the Adventure Guide draws for the same
-- step. Blizzard's numerals (centred in their atlas boxes, unlike font digits) stop at 9; later stops use the font.
-- Stops whose rings would overlap, a place visited twice among them, share one: it shows the first stop's number with
-- the count of the rest (+2) where a badge would hang, and its tooltip names each.
-- A numbered stop whose caller said what stands there wears that mark as a badge on the ring's lower right, so the pin
-- reads as step 3 at the quest giver or flight master; a lone one wears the mark alone, full size.
---@param numbers integer[]? the stops this pin marks, in order; nil for a lone destination
---@param titles string[]
---@param look? SPFAPIStopKind
function ShortestPathForeverGoalPinMixin:OnAcquired(x, y, numbers, titles, later, look)
	self:SetPosition(x, y)
	-- The disc stays opaque, so a faded ring still hides the POI beneath it.
	local alpha = later and LATER_STOP_ALPHA or 1
	self.Texture:SetAlpha(alpha)
	self.Icon:SetAlpha(alpha)
	self.Numeral:SetAlpha(alpha)
	self.Number:SetAlpha(alpha)
	self.Count:SetAlpha(alpha)
	self.Count:SetText(numbers and StopCount(numbers) or "")
	self.stopTitles = titles[1] and titles or nil
	local marked = look ~= nil and ns.SetStopLook(self.Icon, look, numbers and BADGE_SIZE or LOOK_SIZE)
	local badge = marked and numbers ~= nil
	self.Icon:SetShown(marked)
	self.Icon:ClearAllPoints()
	self.Icon:SetPoint(badge and "BOTTOMRIGHT" or "CENTER", badge and BADGE_OFFSET or 0, badge and -BADGE_OFFSET or 0)
	local corner = (badge or numbers ~= nil and #numbers > 1) and -BADGE_OFFSET or 0
	self:SetHitRectInsets(0, corner, 0, corner)
	self.Texture:SetShown(not marked or badge)
	if marked and not badge then
		self:SetSize(LOOK_SIZE, LOOK_SIZE)
		self.Disc:Hide()
		self.Numeral:Hide()
		self.Number:SetText("")
		return
	end
	local number = numbers and numbers[1]
	local numeral = number and number <= MAX_NUMERAL
	self.Disc:SetShown(numbers ~= nil)
	self.Numeral:SetShown(numeral == true)
	self.Number:SetText(number and not numeral and tostring(number) or "")
	if numbers then
		self:SetSize(STOP_SIZE, STOP_SIZE)
		self.Texture:SetAtlas(STOP_ATLAS)
		if numeral then
			self.Numeral:SetAtlas("services-number-" .. number)
		end
	else
		-- The native waypoint pin (SuperTrackedFrame.lua:219) that Guide's marker wears, so map and marker agree.
		local atlas = C_Texture.GetAtlasInfo(GOAL_ATLAS)
		self:SetSize(atlas.width * GOAL_SCALE, atlas.height * GOAL_SCALE)
		self.Texture:SetAtlas(GOAL_ATLAS)
	end
end

function ShortestPathForeverGoalPinMixin:OnMouseEnter()
	local title, rows = ns.JourneyInfo()
	if not title or not rows then
		return
	end
	self.Glow:SetShown(self.Disc:IsShown() or self.Icon:IsShown())
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	-- A shared ring names every stop it marks, in order.
	local stopTitles = self.stopTitles or {}
	GameTooltip_SetTitle(GameTooltip, stopTitles[1] or title)
	for i = 2, #stopTitles do
		GameTooltip_AddColoredLine(GameTooltip, stopTitles[i], HIGHLIGHT_FONT_COLOR)
	end
	for _, row in ipairs(not stopTitles[1] and rows or {}) do
		GameTooltip_AddColoredLine(GameTooltip, row.text, row.current and HIGHLIGHT_FONT_COLOR or NORMAL_FONT_COLOR)
	end
	GameTooltip_AddNormalLine(GameTooltip, "Right-click to clear")
	GameTooltip:Show()
end

function ShortestPathForeverGoalPinMixin:OnMouseLeave()
	self.Glow:Hide()
	if GameTooltip:IsOwned(self) then
		GameTooltip:Hide()
	end
end

-- Pins pass right clicks to the canvas to zoom out (Blizzard_MapCanvas.lua:328); this one clears instead.
function ShortestPathForeverGoalPinMixin.ShouldMouseButtonBePassthrough()
	return false
end

function ShortestPathForeverGoalPinMixin.OnMouseClickAction(_, button)
	if button == "RightButton" then
		ns.ClearJourney()
	end
end

function ShortestPathForeverGoalPinMixin:OnReleased()
	self:OnMouseLeave()
	self.stopTitles = nil
	MapCanvasPinMixin.OnReleased(self)
end
