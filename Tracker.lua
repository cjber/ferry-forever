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
	return row.current and OBJECTIVE_TRACKER_COLOR.NormalHighlight or OBJECTIVE_TRACKER_COLOR.Normal
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

function ns.RefreshTracker()
	if not module then
		return
	end
	local dockID, yards, rows, kind, title, blockKey, mapDock
	if ns.db.tracker then
		dockID, yards = ns.NearestDock()
		local radius = module.dockID and 160 or 120
		if not yards or yards > radius then
			dockID = nil
		end
	end
	if dockID then
		rows, kind = DockRows(dockID)
		title, blockKey, mapDock = ns.DockTitle(dockID), "dock" .. dockID, dockID
	elseif ns.db.tracker and ns.CurrentRide() then
		rows, kind, mapDock = RideRows(ns.CurrentRide())
		if rows then
			title, blockKey = "On board to " .. ns.DockTitle(mapDock), "ride" .. mapDock
		end
	end
	local blocks = {}
	local journeyTitle, journeyRows = ns.JourneyInfo()
	if journeyTitle then
		blocks[#blocks + 1] = { key = "journey", title = journeyTitle, rows = journeyRows }
	end
	if blockKey then
		blocks[#blocks + 1] = { key = blockKey, title = title, rows = rows }
	end
	module.dockID, module.mapDock = dockID, mapDock
	module.hasDisplayPriority = journeyTitle ~= nil
	local header = journeyTitle and "Journey" or kind and HEADER[kind] or ModuleMixin.headerText
	local changed = #blocks ~= #module.blocks or header ~= module.headerText
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
	module = CreateFrame("Frame", "FerryForeverObjectiveTracker", UIParent, "ObjectiveTrackerModuleTemplate")
	Mixin(module, ModuleMixin)
	module.blocks = {}
	module:SetHeader(ModuleMixin.headerText)
	module.uiOrder = -2
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
	C_Timer.NewTicker(1, ns.RefreshTracker)
	ns.RefreshTracker()
end)
