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

	Checkbox("pins", "Show docks on the world map", nil, ns.RefreshMap)
	Checkbox(
		"otherFaction",
		"Show the other faction's routes",
		"Either faction can ride any boat or zeppelin.",
		function()
			ns.RefreshMap()
			ns.RefreshTracker()
		end
	)
	Checkbox("tracker", "Show the next boats in the objective tracker near a dock", nil, ns.RefreshTracker)
	Checkbox(
		"share",
		"Share boat times with other players",
		"Sends and receives sighting times over guild, party and at the dock. No chat messages are shown."
	)
	Settings.RegisterAddOnCategory(category)
	SLASH_FERRYFOREVER1 = "/ferry"
	SlashCmdList.FERRYFOREVER = function(message)
		if message == "debug" then
			ns.debug = not ns.debug
			ns.Print("debug " .. (ns.debug and "on" or "off"))
			return
		end
		Settings.OpenToCategory(category:GetID())
	end
end)
