local addonName = ...
---@class SPFNamespace
local ns = select(2, ...)

local settings = {}

-- Change an option from anywhere (the map's filter menu) with the settings panel kept in step.
---@param key string
---@param value boolean
function ns.SetOption(key, value)
	settings[key]:SetValue(value)
end

local function Perf()
	local profiler, metrics = C_AddOnProfiler, Enum.AddOnProfilerMetric
	if profiler and profiler.GetAddOnMetric and metrics and (not profiler.IsEnabled or profiler.IsEnabled()) then
		for _, entry in ipairs({
			{ "RecentAverageTime", "recent average (60 ticks)" },
			{ "SessionAverageTime", "session average" },
			{ "LastTime", "last tick" },
			{ "PeakTime", "session peak" },
		}) do
			if metrics[entry[1]] then
				ns.Print(
					string.format("CPU %s: %.3f ms", entry[2], profiler.GetAddOnMetric(addonName, metrics[entry[1]]))
				)
			end
		end
		if metrics.CountTimeOver5Ms then
			ns.Print(string.format("Ticks over 5 ms: %d", profiler.GetAddOnMetric(addonName, metrics.CountTimeOver5Ms)))
		end
	else
		ns.Print("CPU profiling is unavailable on this client.")
	end
	-- Updating memory walks every addon's allocations, so only do it on this explicit request.
	if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
		collectgarbage("collect")
		UpdateAddOnMemoryUsage()
		local base, nav = GetAddOnMemoryUsage(addonName) or 0, 0
		for _, map in ipairs({ 0, 1, 2991 }) do
			local name = addonName .. "_Nav" .. map
			if not C_AddOns or not C_AddOns.DoesAddOnExist or C_AddOns.DoesAddOnExist(name) then
				nav = nav + (GetAddOnMemoryUsage(name) or 0)
			end
		end
		ns.Print(
			string.format("Memory (collected): %.1f KB addon + %.1f KB walking maps = %.1f KB", base, nav, base + nav)
		)
	else
		ns.Print("Memory accounting is unavailable on this client.")
	end
end

-- Rows go in through Settings.RegisterInitializer, which inserts them from Blizzard's secure delegate.
-- Settings.CreateCheckbox inserts from our code instead, and the settings search reads every layout, so that
-- tainted it: a restricted button in the results (Social's Discord Sign In) was then blocked and blamed on us.
ns.Init(function()
	local category = Settings.RegisterVerticalLayoutCategory("Shortest Path Forever")
	local function Checkbox(key, name, tooltip, onChanged, default)
		local setting = Settings.RegisterAddOnSetting(
			category,
			"ShortestPathForever_" .. key,
			key,
			ns.db,
			Settings.VarType.Boolean,
			name,
			default ~= false
		)
		if onChanged then
			setting:SetValueChangedCallback(onChanged)
		end
		Settings.RegisterInitializer(category, Settings.CreateCheckboxInitializer(setting, nil, tooltip))
		settings[key] = setting
	end

	Checkbox("pins", "Show boats and zeppelins on the world map", nil, ns.RefreshMap)
	Checkbox("transit", "Show lifts and the Deeprun Tram on the world map", nil, ns.RefreshMap)
	Checkbox("portals", "Show portals on the world map", nil, ns.RefreshMap)
	Checkbox("mapFlightMasters", "Show flight masters on the world map", nil, ns.RefreshMap)
	Checkbox(
		"minimapPins",
		"Show docks, lifts, the tram and portals on the minimap",
		"Also under Transport in the minimap's tracking menu.",
		ns.RefreshMinimapPins
	)
	Checkbox(
		"mapRoutes",
		"Show boat and zeppelin routes on the world map",
		"Drawn while you point at a dock.",
		ns.RefreshMap
	)
	Checkbox(
		"otherFaction",
		"Show the other faction's routes",
		"Either faction can ride any boat or zeppelin.",
		function()
			ns.RefreshMap()
			ns.RefreshTracker()
		end
	)
	Checkbox(
		"tracker",
		"Show the next departures in the objective tracker near a dock, lift or tram",
		nil,
		ns.RefreshTracker
	)
	Checkbox(
		"alerts",
		"Alert when a boat is about to arrive",
		"While you wait at a dock or ride a timed boat: a warning on screen and a flashing taskbar icon."
	)
	Checkbox("alertSound", "Play a sound with arrival alerts", "Plays even with the game in the background.")
	Checkbox("journey", "Plan journeys with Shift-click on the world map or minimap", nil, function()
		if not ns.db.journey then
			ns.ClearJourney()
		end
	end)
	Checkbox(
		"guideStops",
		"Guide marks only where each step ends",
		"The next boat, lift, flight master or your destination, rather than each turn of the walk on the way.",
		ns.RefreshGuideStops,
		false
	)
	Checkbox(
		"compass",
		"Show a compass while Guide is on",
		"Your next turns, the next stop and your destination across the top of the screen.",
		ns.RefreshCompass,
		false
	)
	Checkbox(
		"share",
		"Share departure times with other players",
		"Sends and receives sighting times over guild, party and at the dock. No chat messages are shown."
	)
	Settings.RegisterAddOnCategory(category)
	SLASH_SHORTESTPATHFOREVER1 = "/path"
	SLASH_SHORTESTPATHFOREVER2 = "/shortestpath"
	SlashCmdList.SHORTESTPATHFOREVER = function(message)
		if message == "perf" then
			Perf()
			return
		elseif message == "debug" then
			ns.db.debug = not ns.db.debug
			ns.db.trace = ns.db.debug and {} or nil
			ns.WakeTravel()
			ns.Print("debug " .. (ns.db.debug and "on" or "off"))
			return
		end
		Settings.OpenToCategory(category:GetID())
	end
	ShortestPathForever_OnAddonCompartmentClick = function()
		Settings.OpenToCategory(category:GetID())
	end
end)
