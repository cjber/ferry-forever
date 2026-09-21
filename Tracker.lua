local _, ns = ...

local module
local ModuleMixin = { headerText = "Boats" }

local function OpenDockMap(dockID)
	local location = dockID and ns.DockLocation(dockID)
	OpenWorldMap(location and location.uiMap)
end

function ModuleMixin:OnBlockHeaderClick(_block, button)
	if button == "LeftButton" then
		OpenDockMap(self.dockID)
	end
end

local function DepartureText(departure)
	local text = ns.DockZone(departure.to[1]) .. "   " .. ns.DepartureStatus(departure)
	return departure.known and text or GRAY_FONT_COLOR:WrapTextInColorCode(text)
end

function ModuleMixin:LayoutContents()
	if not self.dockID then
		return
	end
	local block = self:GetBlock(self.dockID)
	block:SetHeader(ns.DockZone(self.dockID))
	for _, departure in ipairs(self.departures) do
		block:AddObjective(departure.route, DepartureText(departure), nil, true)
	end
	self:LayoutBlock(block)
end

function ns.RefreshTracker()
	if not module then
		return
	end
	local dockID, yards
	if ns.db.tracker then
		dockID, yards = ns.NearestDock()
		local radius = module.dockID and 160 or 120
		if not yards or yards > radius then
			dockID = nil
		end
	end
	local departures = dockID and ns.DockDepartures(dockID) or {}
	local changed = dockID ~= module.dockID or #departures ~= #module.departures
	for index, departure in ipairs(departures) do
		local previous = module.departures[index]
		if not previous or departure.route ~= previous.route then
			changed = true
		end
	end
	module.dockID, module.departures = dockID, departures
	if changed then
		module:MarkDirty()
		return
	end
	if not dockID or module:IsDirty() then
		return
	end
	local block = module:GetExistingBlock(dockID)
	if not (block and block.used) then
		return
	end
	-- Countdown ticks reuse Blizzard's lines; only changed wrapping needs a new layout.
	local resized = false
	for _, departure in ipairs(departures) do
		local line = block:GetExistingLine(departure.route)
		local text = DepartureText(departure)
		if line and line.used and line.Text:GetText() ~= text then
			local height = block:SetStringText(line.Text, text, true, nil, block.isHighlighted)
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
	module.departures = {}
	module:SetHeader(ModuleMixin.headerText)
	module.uiOrder = -2
	module.Header:EnableMouse(true)
	module.Header:SetScript("OnMouseUp", function(_, button)
		if button == "LeftButton" then
			OpenDockMap(module.dockID)
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
