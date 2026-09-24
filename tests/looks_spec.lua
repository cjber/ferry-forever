-- A stop's kind draws as the game's own mark for it, fitted to the pin; art the client lacks leaves the plain pin.
local checks = 0
local function check(value, label)
	checks = checks + 1
	assert(value, label)
end
local secret = {}
-- The Forever build's sizes (UiTextureAtlasMember, 1.60.1.69913); questobjective is withheld to test the fallback.
local atlases = {
	QuestNormal = { width = 64, height = 64 },
	QuestTurnin = { width = 32, height = 32 },
	SideInProgressquesticon = { width = 16, height = 18 },
	taxinode_horde = { width = 32, height = 32 },
	taxinode_neutral = { width = 32, height = 32 },
}
local lookups = {}
local faction = "Horde"
local transports = {}
local ns = {
	SetTransportIcon = function(texture, kind, size)
		transports[#transports + 1] = { texture = texture, kind = kind, size = size }
	end,
}
local env = setmetatable({
	canaccessvalue = function(value)
		return value ~= secret
	end,
	UnitFactionGroup = function()
		return faction
	end,
	C_Texture = {
		GetAtlasInfo = function(atlas)
			lookups[atlas] = (lookups[atlas] or 0) + 1
			return atlases[atlas]
		end,
	},
}, { __index = _G })
setfenv(assert(loadfile("Looks.lua")), env)("ShortestPathForever", ns)

local function texture()
	local t = {}
	function t:SetAtlas(atlas)
		self.atlas, self.file = atlas, nil
	end
	function t:SetTexture(file)
		self.file, self.atlas = file, nil
	end
	function t:SetTexCoord(...)
		self.coords = { ... }
	end
	function t:SetSize(width, height)
		self.width, self.height = width, height
	end
	return t
end

for _, kind in ipairs({ "pickup", "turnin", "objective", "trainer", "flightmaster", "boat", "portal", "dungeon" }) do
	check(ns.StopKind(kind) == kind, "known kind " .. kind)
end
for _, value in ipairs({ "mailbox", "hub", "", 1, true, secret }) do
	check(ns.StopKind(value) == nil, "unknown kind " .. tostring(value))
end
check(ns.StopKind(nil) == nil, "no kind")

local pin = texture()
check(ns.SetStopLook(pin, "pickup", 18), "a quest giver's mark")
check(pin.atlas == "QuestNormal" and pin.width == 18 and pin.height == 18, "the stock '!' fitted to the pin")
check(ns.SetStopLook(pin, "turnin", 18) and pin.atlas == "QuestTurnin", "a hand-in's '?'")
check(ns.SetStopLook(pin, "objective", 18), "an objective falls back to the in-progress mark")
check(pin.atlas == "SideInProgressquesticon" and pin.height == 18 and pin.width == 16, "keeps the atlas's shape")
check(ns.SetStopLook(pin, "flightmaster", 18) and pin.atlas == "taxinode_horde", "the player's own flight master")
check(ns.SetStopLook(pin, "trainer", 18), "a trainer")
check(pin.file == "Interface\\Minimap\\Tracking\\Class" and pin.coords[2] == 1, "the tracking menu's icon, uncropped")
check(ns.SetStopLook(pin, "zeppelin", 18), "a zeppelin")
check(transports[1].texture == pin and transports[1].kind == "zeppelin" and transports[1].size == 18, "the map's icon")

-- No art: the texture keeps what it had, and the caller draws the plain pin.
local plain = texture()
plain:SetAtlas("Waypoint-MapPin-Tracked")
check(not ns.SetStopLook(plain, "innkeeper", 18), "no innkeeper art in this client")
check(not ns.SetStopLook(plain, "dungeon", 18), "no dungeon art in this client")
check(plain.atlas == "Waypoint-MapPin-Tracked" and plain.width == nil, "the texture is left alone")

-- Each kind asks the client once.
ns.SetStopLook(pin, "pickup", 18)
ns.SetStopLook(plain, "innkeeper", 18)
check(lookups.QuestNormal == 1 and lookups.innkeeper == 1, "art looked up once per kind")
check(lookups.questobjective == 1, "the missing objective atlas asked once")

print(string.format("looks_spec: %d checks passed", checks))
