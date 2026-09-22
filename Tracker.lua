local _, ns = ...

local module
local ModuleMixin = { headerText = "Boats" }
local HEADER = { boat = "Boats", zeppelin = "Boats", lift = "Lifts", tram = "Deeprun Tram" }

local function OpenDockMap(dockID)
	local location = dockID and ns.DockLocation(dockID)
	OpenWorldMap(location and location.uiMap)
end

function ModuleMixin:OnBlockHeaderClick(_block, button)
	if button == "LeftButton" then
		OpenDockMap(self.mapDock)
	end
end

local function DepartureText(departure)
	local text = ns.DockLabel(departure.to[1]) .. "   " .. ns.DepartureStatus(departure)
	return departure.known and text or GRAY_FONT_COLOR:WrapTextInColorCode(text)
end

function ModuleMixin:LayoutContents()
	if not self.blockKey then
		return
	end
	local block = self:GetBlock(self.blockKey)
	block:SetHeader(self.title)
	for _, row in ipairs(self.rows) do
		block:AddObjective(row.key, row.text, nil, true)
	end
	self:LayoutBlock(block)
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
	rows = rows or {}
	local changed = blockKey ~= module.blockKey or title ~= module.title or #rows ~= #module.rows
	for index, row in ipairs(rows) do
		local previous = module.rows[index]
		if not previous or row.key ~= previous.key then
			changed = true
		end
	end
	module.dockID, module.mapDock, module.blockKey, module.title, module.rows = dockID, mapDock, blockKey, title, rows
	local header = kind and HEADER[kind] or ModuleMixin.headerText
	if header ~= module.headerText then
		module.headerText = header
		module:SetHeader(header)
		changed = true
	end
	if changed then
		module:MarkDirty()
		return
	end
	if not blockKey or module:IsDirty() then
		return
	end
	local block = module:GetExistingBlock(blockKey)
	if not (block and block.used) then
		return
	end
	-- Countdown ticks reuse Blizzard's lines; only changed wrapping needs a new layout.
	local resized = false
	for _, row in ipairs(rows) do
		local line = block:GetExistingLine(row.key)
		if line and line.used and line.Text:GetText() ~= row.text then
			local height = block:SetStringText(line.Text, row.text, true, nil, block.isHighlighted)
			resized = resized or height ~= line:GetHeight()
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
	module.rows = {}
	module:SetHeader(ModuleMixin.headerText)
	module.uiOrder = -2
	module.Header:EnableMouse(true)
	module.Header:SetScript("OnMouseUp", function(_, button)
		if button == "LeftButton" then
			OpenDockMap(module.mapDock)
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
