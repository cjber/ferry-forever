-- The client the UI checks run against: stub frames and client APIs. tests/ui_map.lua follows it in one chunk,
-- so the checks appended after both share their locals.
local BLIZZARD_UI = (os.getenv("SPF_BLIZZARD_UI") or "tools/.cache/blizzard-ui") .. "/Interface/AddOns/"
-- Loads the addon in toc order against stubs, fires ADDON_LOADED, runs tickers and a fake ride.
local T, frames, tickers = 0, {}, {}
local uiScale = 1
local shiftDown, mouseFoci = true, {}
local arrowFrame, arrowPoints, navigationFrame, trailFrame
local mouselook = false
local arrowCalls = 0
local posX, posY, posMap = -1005.6, -3841.6, 1
local posZ = 0
local sent = {}
local errors, lineCreations, waypointCalls = {}, 0, 0
local waypoint, supertracked, cleared = nil, false, 0
local trackedQuest, playerUiMap = 0, nil
local onTaxi, facing, minimapShape = false, 0, nil
local moving, combat = false, false
_G.IsPlayerMoving = function()
	return moving
end
_G.InCombatLockdown = function()
	return combat
end
local cvars = { rotateMinimap = "0" }
local function noop() end
local mt = {
	__index = function(t, k)
		if k:match("^%u") then
			return noop
		end
	end,
}
local function animationGroup(owner)
	local group = { owner = owner, animations = {}, plays = 0 }
	function group:CreateAnimation(kind)
		local animation = { kind = kind }
		for _, key in ipairs({ "Duration", "Degrees", "FromAlpha", "ToAlpha", "Smoothing", "Order", "Target" }) do
			animation["Set" .. key] = function(self, value)
				self[key] = value
			end
		end
		self.animations[#self.animations + 1] = animation
		return animation
	end
	function group:SetLooping(value)
		self.looping = value
	end
	function group:Play()
		self.playing = true
		self.plays = self.plays + 1
	end
	function group:Restart()
		self:Play()
	end
	function group:Stop()
		self.playing = false
	end
	function group:IsPlaying()
		return self.playing == true
	end
	return group
end
local function visibilityChanged(frame, shown)
	local script = frame.scripts[shown and "OnShow" or "OnHide"]
	if script then
		script(frame)
	end
	for _, child in ipairs(frame.children or {}) do
		if child:IsShown() then
			visibilityChanged(child, shown)
		end
	end
end
local function font()
	local f = { text = "" }
	function f:EnableMouse(value)
		self.mouseEnabled = value
	end
	function f:SetText(v)
		self.text = v
	end
	function f:GetText()
		return self.text
	end
	function f:GetStringWidth()
		return #self.text * 6
	end
	function f:GetHeight()
		return 12
	end
	return setmetatable(f, mt)
end
local fontmt = {
	__index = function(t, k)
		if k == "SetFormattedText" then
			return function(self, fmt, ...)
				self.text = string.format(fmt, ...)
			end
		end
		if k == "GetStringHeight" then
			return function()
				return 12
			end
		end
		if k == "SetText" then
			return function(self, v)
				self.text = v
			end
		end
		return noop
	end,
}
local function stubframe()
	local f = setmetatable({ scripts = {} }, mt)
	function f:CreateFontString()
		return setmetatable({}, fontmt)
	end
	function f:GetEffectiveScale()
		return (self.parent and self.parent.GetEffectiveScale and self.parent:GetEffectiveScale() or uiScale)
			* (self.scale or 1)
	end
	function f:SetAlpha(v)
		self.alpha = v
	end
	function f:CreateAnimationGroup()
		return animationGroup(self)
	end
	function f:CreateTexture()
		local texture = setmetatable({ parent = self }, mt)
		function texture:SetAtlas(v)
			self.atlas = v
			if v == "Navigation-Tracked-Arrow" then
				arrowFrame = f
			end
		end
		function texture:CreateAnimationGroup()
			return animationGroup(self)
		end
		function texture:SetSize(w, h)
			self.width, self.height = w, h
		end
		function texture:SetAllPoints(owner)
			self.allPoints = owner
		end
		function texture:SetBlendMode(value)
			self.blendMode = value
		end
		function texture:SetRotation(v)
			self.rotation = v
		end
		function texture:SetTexCoord(...)
			self.coords = { ... }
		end
		function texture:SetAlpha(v)
			self.alpha = v
		end
		function texture:SetShown(v)
			self.hidden = not v
		end
		function texture:SetPoint(...)
			self.anchor = { ... }
		end
		function texture:Show()
			self.hidden = false
		end
		function texture:Hide()
			self.hidden = true
		end
		self.textures = self.textures or {}
		self.textures[#self.textures + 1] = texture
		return texture
	end
	function f:SetScript(n, fn)
		self.scripts[n] = fn
	end
	function f:RegisterEvent(event)
		self.events = self.events or {}
		self.events[event] = true
	end
	function f:RegisterUnitEvent(event, unit)
		self:RegisterEvent(event)
		self.units = self.units or {}
		self.units[event] = unit
	end
	function f:UnregisterEvent(event)
		if self.events then
			self.events[event] = nil
		end
	end
	function f:SetSize(w, h)
		self.width, self.height = w, h
	end
	function f:EnableMouse(value)
		self.mouseEnabled = value
	end
	function f:SetText(v)
		self.text = v
	end
	function f:SetAllPoints(owner)
		if owner == WorldFrame then
			trailFrame = f
		end
		self.width, self.height = owner:GetWidth(), owner:GetHeight()
	end
	function f:CreateMaskTexture()
		return setmetatable({}, mt)
	end
	function f:SetWidth(w)
		self.width = w
	end
	function f:SetHeight(h)
		self.height = h
	end
	function f:GetWidth()
		return self.width
	end
	function f:GetHeight()
		return self.height
	end
	function f:SetPoint(...)
		self.anchor = { ... }
	end
	function f:IsShown()
		return not self.hidden
	end
	function f:IsVisible()
		return not self.hidden and (not self.parent or not self.parent.IsVisible or self.parent:IsVisible())
	end
	function f:SetShown(value)
		if value then
			self:Show()
		else
			self:Hide()
		end
	end
	function f:Show()
		local wasVisible = self:IsVisible()
		self.hidden = false
		if not wasVisible and self:IsVisible() then
			visibilityChanged(self, true)
		end
	end
	function f:Hide()
		if self.hidden then
			return
		end
		local wasVisible = self:IsVisible()
		self.hidden = true
		if wasVisible then
			visibilityChanged(self, false)
		end
	end
	function f:CreateLine(_, layer, _, sublevel)
		lineCreations = lineCreations + 1
		local line = { parent = self, layer = layer, sublevel = sublevel or 0 }
		function line:SetColorTexture(...)
			self.textureColor = { ... }
		end
		function line:SetTexture(path)
			self.texture = path
		end
		function line:SetAlpha(v)
			self.alpha = v
		end
		function line:SetAtlas(v)
			self.atlas = v
		end
		function line:SetVertexColor(...)
			self.color = { ... }
		end
		function line:SetThickness(v)
			self.thickness = v
		end
		function line:SetStartPoint(point, owner, x, y)
			assert(point == "TOPLEFT" and x >= -0.0001 and x <= owner:GetWidth() + 0.0001)
			assert(y <= 0.0001 and y >= -owner:GetHeight() - 0.0001)
			self.start = { x, y }
		end
		function line:SetEndPoint(point, owner, x, y)
			assert(point == "TOPLEFT" and x >= -0.0001 and x <= owner:GetWidth() + 0.0001)
			assert(y <= 0.0001 and y >= -owner:GetHeight() - 0.0001)
			self.finish = { x, y }
		end
		function line:Show()
			self.shown = true
		end
		function line:Hide()
			self.shown = false
		end
		return line
	end
	f.Header = {
		SetScript = noop,
		EnableMouse = noop,
		CreateTexture = function()
			return f:CreateTexture()
		end,
	}
	frames[#frames + 1] = f
	return f
end
_G.CreateFrame = function(_, name, parent, template)
	local f = stubframe()
	f.parent, f.template = parent, template
	if parent then
		parent.children = parent.children or {}
		parent.children[#parent.children + 1] = f
	end
	if name then
		_G[name] = f
	end
	if template == "SpinnerTemplate" then
		-- Read the client template and run its real visibility scripts, rather than assuming the artwork.
		local ui = BLIZZARD_UI .. "Blizzard_SharedXML/"
		assert(loadfile(ui .. "Spinner.lua"))()
		Mixin(f, SpinnerMixin)
		f.Shadow = false
		local file = assert(io.open(ui .. "Spinner.xml"))
		local xml = file:read("*a")
		file:close()
		for attrs in xml:gmatch("<Texture (.-)/>") do
			local key, atlas = attrs:match('parentKey="(.-)"'), attrs:match('atlas="(.-)"')
			local texture = f:CreateTexture()
			texture:SetAtlas(atlas)
			texture:SetAllPoints(f)
			texture:SetBlendMode(attrs:match('alphaMode="(.-)"') or "BLEND")
			f[key] = texture
		end
		f.Anim = f:CreateAnimationGroup()
		f.Anim:SetLooping(xml:match('<AnimationGroup.-looping="(.-)"'))
		for attrs in xml:gmatch("<Rotation (.-)>") do
			local rotation = f.Anim:CreateAnimation("Rotation")
			rotation:SetTarget(f[attrs:match('childKey="(.-)"')])
			rotation:SetDuration(tonumber(attrs:match('duration="(.-)"')))
			rotation:SetDegrees(tonumber(attrs:match('degrees="(.-)"')))
			rotation:SetOrder(tonumber(attrs:match('order="(.-)"')))
		end
		f:SetScript("OnShow", f.OnShow)
		f:SetScript("OnHide", f.OnHide)
		f:OnShow()
	end
	if template == "ObjectiveTrackerModuleTemplate" then
		f.liveBlocks, f.layoutOrder = {}, {}
		f.Header.Text = font()
		function f:SetHeader(text)
			self.Header.Text:SetText(text)
		end
		function f:GetBlock(id)
			local b = self.liveBlocks[id]
			if not b then
				b = { id = id, HeaderText = font(), lines = {} }
				function b:SetHeader(text)
					self.HeaderText:SetText(text)
				end
				function b:SetStringText(fs, text, full, color, highlight)
					fs:SetText(text)
					fs.colorStyle = color
					return fs:GetHeight()
				end
				function b:AddObjective(key, text, template, full, dash, color)
					local line = {
						Text = font(),
						used = true,
						GetHeight = function()
							return 12
						end,
					}
					line.Text:SetText(text)
					line.Text.colorStyle = color
					self.lines[key] = line
					return line
				end
				function b:GetExistingLine(key)
					return self.lines[key]
				end
				self.liveBlocks[id] = b
			end
			b.used = true
			return b
		end
		function f:GetExistingBlock(id)
			return self.liveBlocks[id]
		end
		function f:IsDirty()
			return false
		end
		function f:LayoutBlock(b)
			self.layoutOrder[#self.layoutOrder + 1] = b.id
			return true
		end
		function f:MarkDirty()
			self.layoutOrder = {}
			for _, b in pairs(self.liveBlocks) do
				b.used = false
				b.lines = {}
			end
			self:LayoutContents()
		end
	end
	return f
end
_G.GetTime = function()
	return T
end
_G.GetServerTime = function()
	return math.floor(1790000000 + T)
end
-- Translation files (Locales/<locale>.lua) ask for the client's language.
_G.GetLocale = function()
	return "enUS"
end
_G.GetRealmName = function()
	return "Test"
end
_G.GetNormalizedRealmName = function()
	return "Test"
end
_G.UnitPosition = function()
	return posX, posY, posZ, posMap
end
_G.UnitOnTaxi = function()
	return onTaxi
end
_G.UnitIsGhost = function()
	return false
end
_G.GetPlayerFacing = function()
	return facing
end
_G.C_Navigation = {
	GetFrame = function()
		return navigationFrame
	end,
	HasValidScreenPosition = function()
		return navigationFrame and navigationFrame.GetCenter ~= nil
	end,
	WasClampedToScreen = function()
		return false
	end,
}
_G.GetCameraZoom = function()
	return 15
end
_G.IsMouselooking = function()
	return mouselook
end
_G.GetMinimapShape = function()
	return minimapShape
end
_G.GetCVar = function(k)
	return cvars[k]
end
_G.Minimap = stubframe()
Minimap:SetSize(200, 200)
_G.C_Minimap = {
	GetViewRadius = function()
		return 200
	end,
}
_G.UnitName = function()
	return "Me"
end
_G.Ambiguate = function(s)
	return (s:gsub("%-.*", ""))
end
_G.IsInGuild = function()
	return true
end
_G.IsInGroup = function()
	return false
end
_G.IsInRaid = function()
	return false
end
_G.IsInInstance = function()
	return false
end
local function color(r, g, b)
	return {
		GetRGBA = function()
			return r, g, b, 1
		end,
		GetRGB = function()
			return r, g, b
		end,
		WrapTextInColorCode = function(_, s)
			return s
		end,
	}
end
_G.OBJECTIVE_TRACKER_COLOR = { Normal = {}, NormalHighlight = {}, Header = {} }
_G.CreateColor = color
_G.NORMAL_FONT_COLOR = color(1, 0.82, 0)
_G.LIGHTBLUE_FONT_COLOR = color(0.53, 0.67, 0.93)
_G.ORANGE_FONT_COLOR = color(1, 0.5, 0)
_G.EPIC_PURPLE_COLOR = color(0.64, 0.21, 0.93)
_G.AM_PIN_SCALE_STYLE_WITH_TERRAIN = 3
_G.GRAY_FONT_COLOR = _G.NORMAL_FONT_COLOR
_G.HIGHLIGHT_FONT_COLOR = color(1, 1, 1)
_G.ChatTypeInfo = { RAID_WARNING = {} }
_G.RaidWarningFrame = {}
_G.RaidWarningUtil = { AddMessage = noop }
_G.RaidNotice_AddMessage = noop
_G.PlaySound = noop
_G.PlaySoundFile = noop
-- A character with a hearthstone and no recorded bind point: no teleport edges, as after a fresh install.
_G.GetBindLocation = function()
	return "Auberdine"
end
_G.C_SpellBook = {
	IsSpellKnown = function()
		return false
	end,
}
_G.C_Item = {
	GetItemCount = function(id)
		return id == 6948 and 1 or 0
	end,
	GetItemCooldown = function()
		return 0, 0, 1
	end,
}
_G.FlashClientIcon = noop
_G.SOUNDKIT = { RAID_WARNING = 1 }
_G.UNKNOWN = "Unknown"
_G.geterrorhandler = function()
	return function(e)
		errors[#errors + 1] = e
		print("ERROR", e)
	end
end
_G.GetUnitSpeed = function()
	return 0, 7, 7, 4.7
end
_G.IsShiftKeyDown = function()
	return shiftDown
end
_G.GetMouseFoci = function()
	return mouseFoci
end
_G.GetQuestUiMapID = function()
	return 0
end
_G.C_QuestLog = {
	GetQuestsOnMap = function()
		return {}
	end,
	GetNextWaypoint = noop,
	GetNextWaypointForMap = noop,
	GetTitleForQuestID = noop,
	IsComplete = function()
		return false
	end,
}
_G.MapCanvasMixin = { MouseAction = { Up = 1, Down = 2, Click = 3 } }
_G.POIButtonUtil = { Style = { Waypoint = 1 }, Type = { Quest = 1, Content = 2, AreaPOI = 3, Vignette = 4 } }
_G.GetTaxiMapID = function()
	return nil
end
local taxiReports = {}
_G.C_Texture = {
	GetAtlasInfo = function()
		return { width = 36, height = 44 }
	end,
}
_G.C_TaxiMap = {
	ShouldMapShowTaxiNodes = function()
		return false
	end,
	GetTaxiNodesForMap = function(id)
		return taxiReports[id] or {}
	end,
	GetAllTaxiNodes = function()
		return {}
	end,
}
local function fireEvent(event, ...)
	for _, f in ipairs(frames) do
		if
			f.events
			and f.events[event]
			and (not f.units or not f.units[event] or f.units[event] == (...))
			and f.scripts.OnEvent
		then
			f.scripts.OnEvent(f, event, ...)
		end
	end
end
-- Water walking: which buff is up and which spells are known.
waterAura, knownSpell = nil, nil
_G.C_UnitAuras = {
	GetPlayerAuraBySpellID = function(id)
		return id == waterAura and {} or nil
	end,
}
_G.IsPlayerSpell = function(id)
	return id == knownSpell
end
_G.C_Spell = {
	GetSpellName = function(id)
		return ({ [546] = "Water Walking", [1706] = "Levitate" })[id]
	end,
}
_G.C_SuperTrack = {
	SetSuperTrackedUserWaypoint = function(v)
		supertracked = v
		fireEvent("SUPER_TRACKING_CHANGED")
	end,
	IsSuperTrackingUserWaypoint = function()
		return supertracked
	end,
	GetSuperTrackedQuestID = function()
		return trackedQuest
	end,
	GetHighestPrioritySuperTrackingType = function()
		return supertracked and "UserWaypoint" or trackedQuest ~= 0 and "Quest" or nil
	end,
	SetSuperTrackedQuestID = function(id)
		trackedQuest = id
		supertracked = false
		fireEvent("SUPER_TRACKING_CHANGED")
	end,
	IsSuperTrackingAnything = function()
		return supertracked or trackedQuest ~= 0
	end,
}
_G.UiMapPoint = {
	CreateFromCoordinates = function(m, x, y, z)
		return { uiMapID = m, position = CreateVector2D(x, y), z = z }
	end,
	CreateFromVector2D = function(m, v, z)
		return { uiMapID = m, position = v, z = z }
	end,
}
_G.Enum = {
	FlightPathFaction = { Neutral = 0, Horde = 1, Alliance = 2 },
	FlightPathState = { Current = 0, Reachable = 1, Unreachable = 2 },
	UIMapType = { Continent = 2, Zone = 3 },
	SendAddonMessageResult = {
		Success = 0,
		InvalidPrefix = 1,
		AddonMessageThrottle = 3,
		InvalidChatType = 4,
		InvalidChannel = 7,
		ChannelThrottle = 8,
	},
}
_G.CreateVector2D = function(x, y)
	return {
		x = x,
		y = y,
		GetXY = function(self)
			return self.x, self.y
		end,
	}
end
_G.C_Map = {
	GetBestMapForUnit = function()
		return playerUiMap or (posMap == 0 and 1415 or 1414)
	end,
	HasUserWaypoint = function()
		return waypoint ~= nil
	end,
	GetMapPosFromWorldPos = function(cont, v, override)
		local x, y = v:GetXY()
		local m = cont == 0 and 1415 or 1414
		if override and override ~= m then
			return nil
		end
		return m, CreateVector2D(0.5 - y / 25000, 0.5 - x / 25000)
	end,
	GetMapInfo = function(id)
		return { mapID = id, mapType = id >= 1400 and 2 or 3, parentMapID = 0, name = "Map" .. id }
	end,
	GetMapInfoAtPosition = function()
		return nil
	end,
	GetWorldPosFromMapPos = function(m, v)
		local x, y = v:GetXY()
		return m == 1415 and 0 or 1, CreateVector2D((0.5 - y) * 25000, (0.5 - x) * 25000)
	end,
	CanSetUserWaypointOnMap = function()
		return true
	end,
	SetUserWaypoint = function(p)
		waypointCalls = waypointCalls + 1
		waypoint = p
		fireEvent("USER_WAYPOINT_UPDATED")
		return true
	end,
	GetUserWaypoint = function()
		return waypoint
			and {
				uiMapID = waypoint.uiMapID,
				position = { x = waypoint.position.x, y = waypoint.position.y },
				z = waypoint.z,
			}
	end,
	GetUserWaypointPositionForMap = function(m)
		if not waypoint then
			return
		end
		local continent, world =
			C_Map.GetWorldPosFromMapPos(waypoint.uiMapID, CreateVector2D(waypoint.position.x, waypoint.position.y))
		if not world then
			return
		end
		local projected, position = C_Map.GetMapPosFromWorldPos(continent, world, m)
		if projected == m then
			return position
		end
	end,
	ClearUserWaypoint = function()
		waypoint = nil
		cleared = cleared + 1
		fireEvent("USER_WAYPOINT_UPDATED")
	end,
}
local pending = {}
_G.C_Timer = {
	After = function(s, fn)
		pending[#pending + 1] = { at = T + s, fn = fn }
	end,
	NewTicker = function(s, fn)
		local ticker = { every = s, fn = fn, next = T + s }
		function ticker:Cancel()
			self.cancelled = true
		end
		tickers[#tickers + 1] = ticker
		return ticker
	end,
}
_G.C_ChatInfo = {
	RegisterAddonMessagePrefix = noop,
	SendAddonMessage = function(p, m, c)
		sent[#sent + 1] = c .. " " .. m
		return 0
	end,
}
_G.Settings = setmetatable({
	VarType = {},
	RegisterVerticalLayoutCategory = function()
		return {
			GetID = function()
				return 1
			end,
		}
	end,
	RegisterAddOnSetting = function(_, _, key, db, _, _, default)
		if db[key] == nil then
			db[key] = default
		end
		local st = {}
		function st:SetValueChangedCallback(fn)
			st.cb = fn
		end
		function st:SetValue(v)
			db[key] = v
			if st.cb then
				st.cb()
			end
		end
		return st
	end,
}, mt)
local menus, context = {}, {}
_G.MenuUtil = {
	CreateContextMenu = function(owner, generator)
		context = {}
		local tag
		local root = {
			SetTag = function(_, v)
				tag = v
			end,
			CreateTitle = noop,
			CreateCheckbox = function(_, text, get, set)
				context[text] = { get = get, click = set }
			end,
			CreateButton = function(_, text, click)
				context[text] = { click = click }
				return { SetEnabled = noop }
			end,
		}
		generator(owner, root)
		if menus[tag] then
			menus[tag](owner, root)
		end
		return stubframe()
	end,
}
local openedMap, openCalls
_G.OpenWorldMap = function(id)
	openedMap = id
	openCalls = (openCalls or 0) + 1
end
_G.Menu = {
	ModifyMenu = function(tag, fn)
		menus[tag] = fn
	end,
}
_G.UnitFactionGroup = function()
	return "Alliance"
end
_G.Lerp = function(a, b, t)
	return a + (b - a) * t
end
_G.Saturate = function(v)
	return math.max(0, math.min(1, v))
end
_G.Clamp = function(v, a, b)
	return math.max(a, math.min(b, v))
end
_G.math.atan2 = math.atan2 or function(y, x)
	return math.atan(y, x)
end
local tip = {}
_G.GameTooltip_SetTitle = function(_, t)
	tip = { "# " .. t }
end
_G.GameTooltip_AddColoredLine = function(_, t)
	tip[#tip + 1] = "  " .. t
end
_G.GameTooltip_AddNormalLine = function(_, t)
	tip[#tip + 1] = "  " .. t
end
_G.GameTooltip_AddInstructionLine = function(_, t)
	tip[#tip + 1] = "  " .. t
end
_G.GameTooltip_AddColoredDoubleLine = function(_, l, r)
	tip[#tip + 1] = "  " .. l .. " | " .. r
end
_G.SlashCmdList = {}
_G.CreateFromMixins = function(...)
	local t = {}
	for _, m in ipairs({ ... }) do
		for k, v in pairs(m) do
			t[k] = v
		end
	end
	return t
end
_G.Mixin = function(t, ...)
	for _, m in ipairs({ ... }) do
		for k, v in pairs(m) do
			t[k] = v
		end
	end
	return t
end
