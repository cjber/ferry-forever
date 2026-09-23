local _, ns = ...

local module
local ModuleMixin = { headerText = "Boats" }
local HEADER = { boat = "Boats", zeppelin = "Boats", lift = "Lifts", tram = "Deeprun Tram" }

local function OpenDockMap(dockID)
	local location = dockID and ns.DockLocation(dockID)
	OpenWorldMap(location and location.uiMap)
end

function ModuleMixin:OnBlockHeaderClick(block, button)
	if block.id == "journey" then
		if button == "LeftButton" then
			ns.ToggleJourneyGuide()
		elseif button == "RightButton" then
			MenuUtil.CreateContextMenu(block, function(_, root)
				root:CreateCheckbox("Guide me", ns.IsJourneyGuided, ns.ToggleJourneyGuide)
				root:CreateButton("Show on map", ns.ShowJourneyMap)
				root:CreateButton("Clear journey", ns.ClearJourney)
			end)
		end
	elseif button == "LeftButton" then
		OpenDockMap(self.mapDock)
	end
end

local function DepartureText(departure)
	local text = ns.DockLabel(departure.to[1]) .. "   " .. ns.DepartureStatus(departure)
	return departure.known and text or GRAY_FONT_COLOR:WrapTextInColorCode(text)
end

local function RowColor(row)
	return row.grey and GRAY_FONT_COLOR
		or row.current and OBJECTIVE_TRACKER_COLOR.NormalHighlight
		or OBJECTIVE_TRACKER_COLOR.Normal
end

function ModuleMixin:LayoutContents()
	for _, entry in ipairs(self.blocks) do
		local block = self:GetBlock(entry.key)
		block:SetHeader(entry.title)
		block.headerHeight = block.HeaderText:GetHeight()
		for _, row in ipairs(entry.rows) do
			block:AddObjective(row.key, row.text, nil, true, nil, RowColor(row))
		end
		if not self:LayoutBlock(block) then
			return
		end
	end
end

-- Waiting at a dock: its departures, one line per destination.
local function DockRows(dockID)
	local departures = ns.ByDestination(ns.DockDepartures(dockID))
	local rows = {}
	for _, departure in ipairs(departures) do
		rows[#rows + 1] = { key = departure.route, text = DepartureText(departure) }
	end
	return rows, departures[1] and departures[1].kind
end

-- On board, out of sight of any dock: where the boat calls next.
local function RideRows(routeID)
	local dockID, arriveIn = ns.NextStop(routeID)
	if not dockID then
		return nil
	end
	local kind = ns.Routes[routeID].kind
	local text = "arrives " .. ns.FormatCountdown(arriveIn)
	return { { key = routeID, text = text } }, kind, dockID
end

local function JourneyDistance(result, index)
	local cache = module.distance
	if not cache or cache.result ~= result or cache.version ~= ns.journeyVersion then
		cache = { result = result, version = ns.journeyVersion, legs = {} }
		local total = 0
		for legIndex = #result.legs, index, -1 do
			local leg = result.legs[legIndex]
			local points = ns.Planner.LegPoints(leg, ns.Routes)
			local after, lengths = {}, {}
			local yards = 0
			for pointIndex = #points, 1, -1 do
				local a, b = points[pointIndex], points[pointIndex + 1]
				local length = 0
				-- Loading screens and portals connect unrelated world coordinates, not walkable yards.
				if b and a.map == b.map and not a.jump and leg.mode ~= "portal" then
					length = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
				end
				yards = yards + length
				after[pointIndex], lengths[pointIndex] = yards, length
			end
			cache.legs[legIndex] = { points = points, after = after, lengths = lengths, yards = yards, later = total }
			total = total + yards
		end
		module.distance = cache
	end
	local leg, path = result.legs[index], cache.legs[index]
	if not path then
		return 0
	end
	local yards = path.yards
	local active = leg.mode == "walk"
		or leg.aboard
		or (leg.route and ns.CurrentRide() == leg.route)
		or (leg.mode == "flight" and UnitOnTaxi("player"))
	if active and leg.mode ~= "portal" then
		local x, y, z, map = UnitPosition("player")
		local nearest
		for pointIndex, a in ipairs(path.points) do
			if x and map == a.map then
				local b, length = path.points[pointIndex + 1], path.lengths[pointIndex]
				local t, px, py, pz = 0, a.x, a.y, a.z
				if length > 0 then
					local dx, dy = b.x - a.x, b.y - a.y
					t = math.max(0, math.min(1, ((x - a.x) * dx + (y - a.y) * dy) / length ^ 2))
					px, py = a.x + t * dx, a.y + t * dy
					pz = a.z and b.z and a.z + t * (b.z - a.z)
				end
				local off = (x - px) ^ 2 + (y - py) ^ 2
				if not (z and pz and math.abs(z - pz) > 30) and (not nearest or off < nearest) then
					nearest = off
					yards = path.after[pointIndex] - t * length
					if leg.mode == "walk" then
						yards = yards + math.sqrt(off)
					end
				end
			end
		end
	end
	return math.max(0, yards + path.later)
end

local function JourneyHeader(result, index, loading)
	if not result or loading then
		module.distance = nil
		return "Journey"
	end
	local yards = JourneyDistance(result, index)
	local distance = yards >= 999.5 and string.format("%.1fk yd", yards / 1000)
		or string.format("%d yd", math.floor(yards + 0.5))
	return "Journey  " .. ns.FormatCountdown(result.arrive - ns.NowMs()) .. " · " .. distance
end

local function RefreshTracker(dockID, yards)
	if not module or InCombatLockdown() then
		return
	end
	local rows, kind, title, blockKey, mapDock
	if ns.db.tracker then
		local radius = module.dockID and 160 or 120
		if not yards or yards > radius then
			dockID = nil
		end
	else
		dockID = nil
	end
	local riding = ns.db.tracker and ns.CurrentRide()
	local journey = ns.HasJourney()
	local second = (dockID or riding or journey) and math.floor(GetTime()) or 0
	-- Compare scalar render inputs before allocating blocks or formatting rows. Unrelated tracker
	-- layouts can replay the saved blocks; they never need to query timetables or rebuild the model.
	if
		module.dockID == dockID
		and module.riding == riding
		and module.second == second
		and module.journeyVersion == ns.journeyVersion
		and module.sightingVersion == ns.sightingVersion
		and module.tracker == ns.db.tracker
		and module.otherFaction == ns.db.otherFaction
	then
		return
	end
	module.riding, module.second = riding, second
	module.journeyVersion, module.sightingVersion = ns.journeyVersion, ns.sightingVersion
	module.tracker, module.otherFaction = ns.db.tracker, ns.db.otherFaction
	if dockID then
		rows, kind = DockRows(dockID)
		title, blockKey, mapDock = ns.DockTitle(dockID), "dock" .. dockID, dockID
	elseif riding then
		rows, kind, mapDock = RideRows(riding)
		if rows then
			title, blockKey = "On board to " .. ns.DockTitle(mapDock), "ride" .. mapDock
		end
	end
	local blocks = {}
	local journeyTitle, journeyRows, journeyResult, journeyIndex, loading = ns.JourneyInfo()
	if journeyTitle then
		blocks[#blocks + 1] = { key = "journey", title = journeyTitle, rows = journeyRows }
	end
	if blockKey then
		blocks[#blocks + 1] = { key = blockKey, title = title, rows = rows }
	end
	module.dockID, module.mapDock = dockID, mapDock
	module.hasDisplayPriority = journeyTitle ~= nil
	local section = journeyTitle and "Journey" or kind and HEADER[kind] or ModuleMixin.headerText
	local header = journeyTitle and JourneyHeader(journeyResult, journeyIndex, loading) or section
	if not journeyTitle then
		module.distance = nil
	end
	module.Spinner:SetShown(loading == true)
	if loading then
		if not module.Spinner.animation:IsPlaying() then
			module.Spinner.animation:Play()
		end
	else
		module.Spinner.animation:Stop()
	end
	-- The section's identity affects layout; its live totals only change the header's single text line.
	local changed = #blocks ~= #module.blocks or section ~= module.section
	module.section = section
	for index, entry in ipairs(blocks) do
		local previous = module.blocks[index]
		if not previous or entry.key ~= previous.key or #entry.rows ~= #previous.rows then
			changed = true
		else
			for rowIndex, row in ipairs(entry.rows) do
				local old = previous.rows[rowIndex]
				changed = changed or row.key ~= old.key or row.current ~= old.current
			end
		end
	end
	module.blocks = blocks
	if header ~= module.headerText then
		module.headerText = header
		module:SetHeader(header)
	end
	if changed then
		module:MarkDirty()
		return
	end
	if module:IsDirty() then
		return
	end
	-- Countdown ticks reuse Blizzard's lines; only changed wrapping needs a new layout.
	local resized = false
	for _, entry in ipairs(blocks) do
		local block = module:GetExistingBlock(entry.key)
		if block and block.used then
			if block.HeaderText:GetText() ~= entry.title then
				local height = block:SetStringText(
					block.HeaderText,
					entry.title,
					nil,
					OBJECTIVE_TRACKER_COLOR.Header,
					block.isHighlighted
				)
				resized = resized or height ~= block.headerHeight
				block.headerHeight = height
			end
			for _, row in ipairs(entry.rows) do
				local line = block:GetExistingLine(row.key)
				if line and line.used and line.Text:GetText() ~= row.text then
					local height = block:SetStringText(line.Text, row.text, true, RowColor(row), block.isHighlighted)
					resized = resized or height ~= line:GetHeight()
				end
			end
		end
	end
	if resized then
		module:MarkDirty()
	end
end

function ns.RefreshTracker()
	RefreshTracker(ns.NearestDock())
end

local function Attach()
	if ObjectiveTrackerManager:GetContainerForModule(module) ~= ObjectiveTrackerFrame then
		ObjectiveTrackerManager:SetModuleContainer(module, ObjectiveTrackerFrame)
	end
end

ns.Init(function()
	if not (ObjectiveTrackerManager and ObjectiveTrackerFrame) then
		ns.Print("The objective tracker is unavailable.")
		return
	end
	module = CreateFrame("Frame", "ShortestPathForeverObjectiveTracker", UIParent, "ObjectiveTrackerModuleTemplate")
	Mixin(module, ModuleMixin)
	module.blocks = {}
	-- Blizzard_SharedXML/SecureUIPanelTemplates.xml uses this atlas and rotation for its loading spinner.
	module.Spinner = module.Header:CreateTexture(nil, "OVERLAY")
	module.Spinner:SetAtlas("common-loadingspinnercircle")
	module.Spinner:SetSize(12, 12)
	module.Spinner:SetPoint("LEFT", module.Header.Text, "RIGHT", 6, 0)
	local animation = module.Spinner:CreateAnimationGroup()
	animation:SetLooping("REPEAT")
	local rotation = animation:CreateAnimation("Rotation")
	rotation:SetDuration(1)
	rotation:SetDegrees(-360)
	module.Spinner.animation = animation
	module.Spinner:Hide()
	module.section = ModuleMixin.headerText
	module:SetHeader(ModuleMixin.headerText)
	-- Above quests, below SkillUp Forever (-2) and Legacy Here (0, -1): each needs its own slot.
	module.uiOrder = -3
	module.Header:EnableMouse(true)
	module.Header:SetScript("OnMouseUp", function(_, button)
		if button == "LeftButton" then
			if ns.JourneyInfo() then
				ns.ToggleJourneyGuide()
			else
				OpenDockMap(module.mapDock)
			end
		end
	end)
	-- The manager's Init is deferred through a closure; AddContainer remains hookable.
	hooksecurefunc(ObjectiveTrackerManager, "AddContainer", function(_, container)
		if container == ObjectiveTrackerFrame then
			Attach()
		end
	end)
	Attach()
	ns.OnChange(ns.RefreshTracker)
	ns.OnTravelTick(RefreshTracker)
	ns.RefreshTracker()
end)
