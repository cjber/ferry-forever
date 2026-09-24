---@class SPFNamespace
local ns = select(2, ...)

-- Guide: the arrow and the native user waypoint that steer along the journey's current leg. It borrows the player's
-- waypoint and super tracking, and gives them back when it stops or the player takes them over.
---@class SPFJourneyGuide
local Guide = {}
ns.JourneyGuide = Guide

local guide

local function RefreshTracker()
	ns.journeyVersion = (ns.journeyVersion or 0) + 1
	ns.RefreshTracker()
end

local function SameWaypoint(a, b)
	if a == b then
		return true
	end
	if not (a and b) then
		return false
	end
	-- C_Map.GetUserWaypoint's position is a plain { x, y } table, not a Vector2D (WaypointLocationDataProvider.lua:183).
	if a.uiMapID == b.uiMapID and a.position.x == b.position.x and a.position.y == b.position.y then
		return true
	end
	local aMap, aWorld = C_Map.GetWorldPosFromMapPos(a.uiMapID, CreateVector2D(a.position.x, a.position.y))
	local bMap, bWorld = C_Map.GetWorldPosFromMapPos(b.uiMapID, CreateVector2D(b.position.x, b.position.y))
	-- Map changes can reproject or round the read-back. One yard absorbs that without claiming a different pin.
	return aWorld and bWorld and aMap == bMap and (aWorld.x - bWorld.x) ^ 2 + (aWorld.y - bWorld.y) ^ 2 <= 1
end

local waypointProviders = {}

-- Guide's waypoint only steers the native marker; our own pins already draw the route and destination.
local function HideGuideWaypointPin(provider)
	if provider.pin then
		local owned = guide and (guide.writingWaypoint or guide.waypoint)
		provider.pin:SetShown(not (owned and SameWaypoint(C_Map.GetUserWaypoint(), owned)))
	end
end

local function RefreshWaypointPins()
	-- Events may be deferred; a closed map is unsubscribed and may not have initialized its canvas yet.
	for _, provider in ipairs(waypointProviders) do
		if provider:GetMap():IsVisible() then
			provider:RefreshAllData()
		else
			provider:RemoveAllData()
		end
	end
end

local function ClearOrphanWaypoint()
	local saved = ns.charDB.guideWaypoint
	if guide or not saved then
		return
	end
	-- Journeys do not survive reloads, but the client saves user waypoints independently of this addon.
	ns.charDB.guideWaypoint = nil
	local point = UiMapPoint.CreateFromCoordinates(saved.uiMapID, saved.x, saved.y)
	if SameWaypoint(C_Map.GetUserWaypoint(), point) then
		C_Map.ClearUserWaypoint()
		C_SuperTrack.SetSuperTrackedUserWaypoint(false)
		RefreshWaypointPins()
	end
end

local function RememberTracking(state)
	state.expectedQuest = C_SuperTrack.GetSuperTrackedQuestID()
	state.expectedTrackedWaypoint = C_SuperTrack.IsSuperTrackingUserWaypoint()
	state.expectedTrackingType = C_SuperTrack.GetHighestPrioritySuperTrackingType()
end

local function SameTracking(state)
	return state.expectedQuest == C_SuperTrack.GetSuperTrackedQuestID()
		and state.expectedTrackedWaypoint == C_SuperTrack.IsSuperTrackingUserWaypoint()
		and state.expectedTrackingType == C_SuperTrack.GetHighestPrioritySuperTrackingType()
end

local function StopGuide()
	local previous = guide
	guide = nil
	ns.PointGuideArrow(nil)
	if previous then
		ns.charDB.guideWaypoint = nil
	end
	if
		not previous
		or not previous.hasDriven
		or not SameWaypoint(C_Map.GetUserWaypoint(), previous.expectedWaypoint)
	then
		RefreshWaypointPins()
		return
	end
	local ownsTracking = not previous.yielded and SameTracking(previous)
	local restored = previous.previousWaypoint and C_Map.SetUserWaypoint(previous.previousWaypoint)
	-- A rejected restoration must still remove our bend, rather than leave it behind without an ownership record.
	if not restored and previous.waypoint then
		C_Map.ClearUserWaypoint()
	end
	if ownsTracking then
		local tracked = restored and previous.previousTrackedWaypoint or false
		C_SuperTrack.SetSuperTrackedUserWaypoint(tracked)
		if not tracked then
			C_SuperTrack.SetSuperTrackedQuestID(previous.previousQuest or 0)
		end
	elseif not restored and C_SuperTrack.IsSuperTrackingUserWaypoint() then
		C_SuperTrack.SetSuperTrackedUserWaypoint(false)
	end
	RefreshWaypointPins()
end

local function OwnsWaypoint()
	if not SameWaypoint(C_Map.GetUserWaypoint(), guide.expectedWaypoint) then
		-- A manual replacement or removal ends guidance; never reclaim the player's waypoint.
		StopGuide()
		return false
	end
	return true
end

local function ClearGuideWaypoint()
	-- Synchronous clear events must see an internal write, and deferred events must see the empty expected point.
	guide.writing = true
	C_Map.ClearUserWaypoint()
	C_SuperTrack.SetSuperTrackedUserWaypoint(false)
	guide.waypoint, guide.expectedWaypoint = nil, nil
	ns.charDB.guideWaypoint = nil
	RememberTracking(guide)
	guide.writing = nil
	RefreshWaypointPins()
end

local function YieldGuide()
	-- A quest/map-pin click belongs to the player. Keep the route arrow, but never retake tracking.
	guide.yielded = true
	if guide.waypoint then
		ClearGuideWaypoint()
	end
end

local function GuideWaypoint(point, fading)
	if not guide then
		return false
	end
	-- The bend callback can run before deferred notifications of a player's waypoint or tracking change.
	if not OwnsWaypoint() then
		RefreshTracker()
		return false
	end
	if not guide.yielded and not SameTracking(guide) then
		YieldGuide()
	end
	if guide.yielded then
		return false
	end
	local uiMap = C_Map.GetBestMapForUnit("player")
	local bend = guide.bend
	if
		not bend
		or point.map ~= bend.map
		or point.x ~= bend.x
		or point.y ~= bend.y
		or uiMap ~= guide.uiMap
		or fading ~= guide.fading
	then
		guide.bend, guide.uiMap = { map = point.map, x = point.x, y = point.y }, uiMap
		guide.fading = fading
		local waypoint
		-- The native waypoint has no per-pin alpha; near the goal, use the fading fallback instead of stacking icons.
		if not fading and uiMap and C_Map.CanSetUserWaypointOnMap(uiMap) then
			local projectedMap, position =
				C_Map.GetMapPosFromWorldPos(point.map, CreateVector2D(point.x, point.y), uiMap)
			if projectedMap == uiMap and position then
				local x, y = position:GetXY()
				if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
					waypoint = UiMapPoint.CreateFromVector2D(uiMap, position)
				end
			end
		end
		-- These APIs may dispatch events synchronously. Only our own writes bypass ownership checks.
		guide.writing = true
		guide.writingWaypoint = waypoint
		if waypoint and C_Map.SetUserWaypoint(waypoint) then
			guide.waypoint, guide.expectedWaypoint = waypoint, waypoint
			ns.charDB.guideWaypoint = { uiMapID = waypoint.uiMapID, x = waypoint.position.x, y = waypoint.position.y }
			guide.hasDriven = true
			C_SuperTrack.SetSuperTrackedUserWaypoint(true)
		elseif guide.waypoint then
			-- Never leave a stale native marker pointing at the preceding bend when projection fails.
			ClearGuideWaypoint()
		end
		-- Deferred events from our own writes must also agree with the expected tracking state.
		RememberTracking(guide)
		guide.writing, guide.writingWaypoint = nil, nil
		for _, provider in ipairs(waypointProviders) do
			HideGuideWaypointPin(provider)
		end
	end
	return guide.waypoint ~= nil and C_SuperTrack.IsSuperTrackingUserWaypoint()
end

---@param node table
---@param points table?
---@param goal table?
function Guide.To(node, points, goal)
	if not guide or (guide.target == node and guide.points == points) then
		return
	end
	guide.points = points
	guide.target = node
	local point = node.kind == "dock" and ns.DockPoint(node.id) or node
	ns.PointGuideArrow(points or { point }, GuideWaypoint, node, goal)
end

-- The next Guide.To re-points the arrow even at the same target.
function Guide.Retarget()
	if guide then
		guide.target = nil
	end
end

---@return boolean
function Guide.Active()
	return guide ~= nil
end

function Guide.Start()
	ClearOrphanWaypoint()
	local previous = C_Map.HasUserWaypoint() and C_Map.GetUserWaypoint()
	local saved = previous
		and UiMapPoint.CreateFromCoordinates(previous.uiMapID, previous.position.x, previous.position.y, previous.z)
	guide = {
		previousQuest = C_SuperTrack.GetSuperTrackedQuestID(),
		previousWaypoint = saved,
		expectedWaypoint = previous or nil,
		previousTrackedWaypoint = saved ~= nil and C_SuperTrack.IsSuperTrackingUserWaypoint(),
	}
	RememberTracking(guide)
end

-- A quest the player tracked before the journey is gone; never restore its tracking.
function Guide.QuestGone(questID)
	if guide and guide.previousQuest == questID then
		guide.previousQuest = nil
	end
end

function Guide.TrackingChanged(event)
	if not guide or guide.writing then
		return
	end
	if not OwnsWaypoint() then
		RefreshTracker()
	elseif event == "SUPER_TRACKING_CHANGED" and not SameTracking(guide) then
		YieldGuide()
	end
end

Guide.Stop = StopGuide
Guide.ClearOrphan = ClearOrphanWaypoint
Guide.RefreshTracker = RefreshTracker

ns.Init(function()
	for provider in pairs(WorldMapFrame.dataProviders) do
		if provider.RefreshAllData == WaypointLocationDataProviderMixin.RefreshAllData then
			waypointProviders[#waypointProviders + 1] = provider
			hooksecurefunc(provider, "RefreshAllData", HideGuideWaypointPin)
		end
	end
end)
