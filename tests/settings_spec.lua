-- Settings rows must reach their layout only through Settings.RegisterInitializer, which inserts them from
-- Blizzard's secure attribute delegate. Settings.CreateCheckbox inserts from the caller instead, which taints
-- the settings search, and a restricted button in its results (Social's Discord Sign In) is then blocked and
-- blamed on this addon.
local registered, settings = {}, {}

local category = {
	GetID = function()
		return 1
	end,
}

local env = setmetatable({
	Settings = {
		VarType = { Boolean = "boolean" },
		RegisterVerticalLayoutCategory = function()
			return category,
				{
					AddInitializer = function()
						error("addon code inserted a row into a settings layout; use Settings.RegisterInitializer")
					end,
				}
		end,
		RegisterAddOnSetting = function(_, variable, key, _, varType, _, default)
			local setting = { variable = variable, key = key, varType = varType, default = default }
			function setting:SetValueChangedCallback(callback)
				self.onChanged = callback
			end
			settings[#settings + 1] = setting
			return setting
		end,
		CreateCheckbox = function()
			error("Settings.CreateCheckbox inserts from addon code; use Settings.RegisterInitializer")
		end,
		CreateCheckboxInitializer = function(setting, options, tooltip)
			assert(setting.varType == "boolean" and options == nil)
			return { setting = setting, tooltip = tooltip }
		end,
		RegisterInitializer = function(target, initializer)
			assert(target == category)
			registered[#registered + 1] = initializer
		end,
		RegisterAddOnCategory = function(target)
			assert(target == category and #registered == #settings, "every row registers before the category")
		end,
		OpenToCategory = function() end,
	},
	SlashCmdList = {},
}, { __index = _G })

local refreshed = 0
local ns = {
	db = {},
	-- Core.lua's defaults, which Settings.lua registers.
	Defaults = {
		pins = true,
		transit = true,
		portals = true,
		minimapPins = true,
		mapFlightMasters = true,
		mapRoutes = true,
		otherFaction = true,
		tracker = true,
		alerts = true,
		alertSound = true,
		journey = true,
		share = true,
		guideStops = false,
		compass = false,
	},
	Init = function(fn)
		fn()
	end,
	RefreshMap = function()
		refreshed = refreshed + 1
	end,
}
setfenv(assert(loadfile("Settings.lua")), env)("ShortestPathForever", ns)

assert(#registered == 14, #registered)
for index, initializer in ipairs(registered) do
	assert(initializer.setting == settings[index], "rows keep their setting and order")
end
assert(registered[1].setting.variable == "ShortestPathForever_pins" and registered[1].setting.default)
assert(registered[5].tooltip == "Also under Transport in the minimap's tracking menu.")
assert(registered[12].setting.key == "guideStops" and registered[12].setting.default == false)
registered[1].setting.onChanged()
assert(refreshed == 1, "value callbacks still fire")
print("settings: ok")
