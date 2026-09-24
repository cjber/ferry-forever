local root = ... or "."
local ns = { db = { journey = true }, charDB = {} }
local now, here, target, shown, click = 0, { map = 1, x = 0, y = 0, z = 0 }
local function noop() end
local frames, events, waypoint, tracked, quest = {}, {}, nil, false, 0
local secret = setmetatable({}, {
	__sub = function()
		error("secret position used")
	end,
})
local function frame()
	local f = setmetatable({}, {
		__index = function(_, key)
			if key:match("^%u") then
				return noop
			end
		end,
	})
	function f:SetScript(name, fn)
		self[name] = fn
	end
	function f:Show()
		self.hidden = false
	end
	function f:Hide()
		self.hidden = true
	end
	function f:SetAlpha(value)
		self.alpha = value
	end
	function f:CreateTexture()
		return setmetatable({}, getmetatable(self))
	end
	f.CreateFontString = f.CreateTexture
	frames[#frames + 1] = f
	return f
end
local function fire(event)
	for _, f in ipairs(frames) do
		if rawget(f, "OnEvent") then
			f:OnEvent(event)
		end
	end
end
local function defer(event)
	events[#events + 1] = event
end
local function vector(x, y)
	return {
		x = x,
		y = y,
		GetXY = function(self)
			return self.x, self.y
		end,
	}
end
local env = setmetatable({
	CreateFrame = frame,
	UnitPosition = function()
		return here.x, here.y, here.z, here.map
	end,
	GetTime = function()
		return now / 1000
	end,
	GetUnitSpeed = function()
		return 0, ns.speed or 7
	end,
	canaccessvalue = function(value)
		return value ~= secret
	end,
	GetPlayerFacing = function()
		return 0
	end,
	C_Navigation = { GetFrame = noop },
	-- A search that throws fails the spec instead of reading as an unreachable walk.
	geterrorhandler = function()
		return error
	end,
	UnitOnTaxi = noop,
	InCombatLockdown = noop,
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
			return map, vector((0.5 - point.y) * 50000, (0.5 - point.x) * 50000)
		end,
		GetBestMapForUnit = function()
			return here.map
		end,
		CanSetUserWaypointOnMap = function()
			return true
		end,
		GetMapPosFromWorldPos = function(map, point)
			return map, vector(0.5 - point.y / 50000, 0.5 - point.x / 50000)
		end,
		HasUserWaypoint = function()
			return waypoint ~= nil
		end,
		GetUserWaypoint = function()
			return waypoint
		end,
		SetUserWaypoint = function(point)
			waypoint = point
			defer("USER_WAYPOINT_UPDATED")
			return true
		end,
		ClearUserWaypoint = function()
			waypoint = nil
			defer("USER_WAYPOINT_UPDATED")
		end,
	},
	CreateVector2D = vector,
	UiMapPoint = {
		CreateFromVector2D = function(map, point)
			return { uiMapID = map, position = point }
		end,
		CreateFromCoordinates = function(map, x, y, z)
			return { uiMapID = map, position = vector(x, y), z = z }
		end,
	},
	C_SuperTrack = {
		GetSuperTrackedQuestID = function()
			return quest
		end,
		IsSuperTrackingUserWaypoint = function()
			return tracked
		end,
		GetHighestPrioritySuperTrackingType = function()
			return tracked and "waypoint" or quest
		end,
		SetSuperTrackedUserWaypoint = function(value)
			tracked = value
			defer("SUPER_TRACKING_CHANGED")
		end,
		SetSuperTrackedQuestID = function(value)
			quest, tracked = value, false
			defer("SUPER_TRACKING_CHANGED")
		end,
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
ns.WakeTravel = noop
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
load("JourneySteps.lua")
load("JourneyCosts.lua")
load("JourneyGuide.lua")
load("Journey.lua")
load("JourneyInput.lua")

local map = {
	GetMapID = function()
		return target.map
	end,
	GetNormalizedCursorPosition = function()
		return 0.5 - target.y / 50000, 0.5 - target.x / 50000
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
	env = env,
	secret = secret,
	fire = fire,
	waypoint = function()
		return waypoint, tracked
	end,
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
		local due = events
		events = {}
		for _, event in ipairs(due) do
			fire(event)
		end
		for _, f in ipairs(frames) do
			if not f.hidden and rawget(f, "OnUpdate") then
				f:OnUpdate(seconds)
			end
		end
	end,
	shown = function()
		return shown
	end,
}
