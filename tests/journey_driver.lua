local root = ... or "."
local ns = { db = { journey = true } }
local now, here, target, shown, click = 0, { map = 1, x = 0, y = 0, z = 0 }
local function noop() end
local driver = {
	SetScript = function(self, name, fn)
		self[name] = fn
	end,
	RegisterEvent = noop,
	Show = noop,
	Hide = noop,
}
local env = setmetatable({
	CreateFrame = function()
		return driver
	end,
	UnitPosition = function()
		return here.x, here.y, here.z, here.map
	end,
	GetTime = function()
		return now / 1000
	end,
	GetUnitSpeed = function()
		return 0, 7
	end,
	canaccessvalue = function()
		return true
	end,
	UnitOnTaxi = noop,
	UnitFactionGroup = function()
		return ns.faction or "Alliance"
	end,
	IsShiftKeyDown = function()
		return true
	end,
	C_UnitAuras = { GetPlayerAuraBySpellID = noop },
	IsPlayerSpell = function()
		return ns.water
	end,
	C_Map = {
		GetWorldPosFromMapPos = function(map, point)
			return map, point
		end,
		HasUserWaypoint = noop,
		GetUserWaypoint = noop,
	},
	CreateVector2D = function(x, y)
		return {
			GetXY = function()
				return x, y
			end,
		}
	end,
	C_SuperTrack = {
		GetSuperTrackedQuestID = noop,
		IsSuperTrackingUserWaypoint = noop,
		GetHighestPrioritySuperTrackingType = noop,
	},
	WorldMapFrame = {
		dataProviders = {},
		AddCanvasClickHandler = function(_, fn)
			click = fn
		end,
		AddGlobalPinMouseActionHandler = noop,
	},
	Minimap = { HookScript = noop },
	Menu = { ModifyMenu = noop },
}, { __index = _G })
local function load(file)
	setfenv(assert(loadfile(root .. "/" .. file)), env)("ShortestPathForever", ns)
end
ns.Init = function(fn)
	fn()
end
ns.NowMs = function()
	return now
end
ns.CurrentRide, ns.RefreshTracker, ns.PointGuideArrow, ns.Print = noop, noop, noop, noop
ns.KnownTaxiNodes, ns.FreshAnchors = function()
	return ns.known or {}
end, function()
	return {}
end
ns.Locate = function()
	return { zone = "Test" }
end
ns.FormatCountdown = tostring
ns.SetJourneyRoute = function(_, route)
	shown = route
end
load("Model.lua")
load("Planner.lua")
load("Journey.lua")

local map = {
	GetMapID = function()
		return target.map
	end,
	GetNormalizedCursorPosition = function()
		return target.x, target.y
	end,
}
ns.DockTitle = function()
	return "Dock"
end
ns.DockLabel = ns.DockTitle
ns.DockPoint = function(id)
	return ns.Docks[id]
end
return {
	ns = ns,
	load = load,
	begin = function(from, to)
		here, target = from, to
		assert(click(map, "LeftButton"))
	end,
	move = function(point)
		here = point
	end,
	update = function(seconds)
		now = now + seconds * 1000
		driver:OnUpdate(seconds)
	end,
	shown = function()
		return shown
	end,
}
