local _, ns = ...

local settings = {}

-- Change an option from anywhere (the map's filter menu) with the settings panel kept in step.
function ns.SetOption(key, value)
	settings[key]:SetValue(value)
end

ns.Init(function()
	local category = Settings.RegisterVerticalLayoutCategory("Ferry Forever")
	local function Checkbox(key, name, tooltip, onChanged)
		local setting = Settings.RegisterAddOnSetting(
			category,
			"FerryForever_" .. key,
			key,
			ns.db,
			Settings.VarType.Boolean,
			name,
			true
		)
		if onChanged then
			setting:SetValueChangedCallback(onChanged)
		end
		Settings.CreateCheckbox(category, setting, tooltip)
		settings[key] = setting
	end

	Checkbox("pins", "Show boats and zeppelins on the world map", nil, ns.RefreshMap)
	Checkbox("transit", "Show lifts and the Deeprun Tram on the world map", nil, ns.RefreshMap)
	Checkbox("portals", "Show portals on the world map", nil, ns.RefreshMap)
	Checkbox("mapFlightMasters", "Show flight masters on the world map", nil, ns.RefreshMap)
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
	Checkbox("journey", "Plan journeys with Shift-click on the world map")
	Checkbox(
		"trail",
		"Draw Guide's route on the ground ahead of you (experimental)",
		"Dots along the next 40 yards of the walk, placed using the game's navigation marker."
	)
	Checkbox(
		"share",
		"Share departure times with other players",
		"Sends and receives sighting times over guild, party and at the dock. No chat messages are shown."
	)
	Settings.RegisterAddOnCategory(category)
	SLASH_FERRYFOREVER1 = "/ferry"
	SlashCmdList.FERRYFOREVER = function(message)
		if message == "debug" then
			ns.db.debug = not ns.db.debug
			ns.db.trace = ns.db.debug and {} or nil
			ns.Print("debug " .. (ns.db.debug and "on" or "off"))
			return
		end
		Settings.OpenToCategory(category:GetID())
	end
end)
