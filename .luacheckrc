std = "lua51"
max_line_length = 120
exclude_files = { "tools/.cache/**", ".types/**", "types/**", ".release/**", "ShortestPathForever_Nav*/**" }
ignore = { "212/_.*" } -- unused args prefixed with _
globals = {
	"ShortestPathForever",
	"ShortestPathForeverCharDB",
	"ShortestPathForeverDB",
	"ShortestPathForeverDockPinMixin",
	"ShortestPathForeverGoalPinMixin",
	"ShortestPathForever_OnAddonCompartmentClick",
	"ShortestPathForeverPortalPinMixin",
	"ShortestPathForeverRoutePinMixin",
	"SLASH_SHORTESTPATHFOREVER1",
	"SLASH_SHORTESTPATHFOREVER2",
	"SlashCmdList",
}
read_globals = {
	"AM_PIN_SCALE_STYLE_WITH_TERRAIN",
	"Ambiguate",
	"C_ChatInfo",
	"Clamp",
	"Lerp",
	"Menu",
	"MenuUtil",
	"Saturate",
	"C_Map",
	"C_Texture",
	"C_Timer",
	"CreateFrame",
	"CreateFromMixins",
	"CreateVector2D",
	"Enum",
	"GameTooltip",
	"GameTooltip_AddColoredDoubleLine",
	"GameTooltip_AddColoredLine",
	"GameTooltip_AddInstructionLine",
	"GameTooltip_AddNormalLine",
	"GameTooltip_SetTitle",
	"geterrorhandler",
	"GetNormalizedRealmName",
	"GetRealmName",
	"GetServerTime",
	"GetTime",
	"GRAY_FONT_COLOR",
	"HIGHLIGHT_FONT_COLOR",
	"hooksecurefunc",
	"IsInGroup",
	"IsInGuild",
	"IsInInstance",
	"IsInRaid",
	"LE_PARTY_CATEGORY_INSTANCE",
	"MapCanvasDataProviderMixin",
	"MapCanvasPinMixin",
	"Mixin",
	"NORMAL_FONT_COLOR",
	"ObjectiveTrackerFrame",
	"ObjectiveTrackerManager",
	"OpenWorldMap",
	"ORANGE_FONT_COLOR",
	"Settings",
	"RaidWarningUtil",
	"PlaySoundFile",
	"FlashClientIcon",
	"ChatTypeInfo",
	"UIParent",
	"UiMapPoint",
	"IsShiftKeyDown",
	"IsModifierKeyDown",
	"GetUnitSpeed",
	"GetTaxiMapID",
	"NumTaxiNodes",
	"TaxiNodeGetType",
	"TaxiGetNodeSlot",
	"GetNumRoutes",
	"TaxiFrame",
	"TaxiRouteMap",
	"NUM_TAXI_ROUTES",
	"TAXIROUTE_LINEFACTOR",
	"DrawOneHopLines",
	"DrawLine",
	"C_TaxiMap",
	"C_SuperTrack",
	"UnitFactionGroup",
	"UnitName",
	"UnitOnTaxi",
	"UnitPosition",
	"UnitIsGhost",
	"C_DeathInfo",
	"UNKNOWN",
	"WorldMapFrame",
	"Minimap",
	"GetPlayerFacing",
	"GetCVar",
	"GetMinimapShape",
	"C_Minimap",
}
files["tests/"] = { std = "+luajit", globals = { "arg" } }

-- Native flight pins, tracker colours and context menus.
globals[#globals + 1] = "ShortestPathForeverFlightPinMixin"
globals[#globals + 1] = "ShortestPathForeverTransportPinMixin"
read_globals[#read_globals + 1] = "FlightPointPinMixin"
read_globals[#read_globals + 1] = "FlightPointDataProviderMixin"
read_globals[#read_globals + 1] = "OBJECTIVE_TRACKER_COLOR"
-- Shared-workspace arrow: Blizzard_QuestNavigation/SuperTrackedFrame.lua:291.
read_globals[#read_globals + 1] = "C_Navigation"
-- Blizzard_SharedXMLBase/Color.lua:3, saturated route colours.
read_globals[#read_globals + 1] = "CreateColor"
-- Native quest menus, locations and MapCanvas's consuming pin-click handler.
read_globals[#read_globals + 1] = "C_QuestLog"
read_globals[#read_globals + 1] = "GetQuestUiMapID"
read_globals[#read_globals + 1] = "GetMouseFoci"
read_globals[#read_globals + 1] = "MapCanvasMixin"
read_globals[#read_globals + 1] = "POIButtonUtil"
-- Path.lua: its per-frame CPU clock, and the per-continent walking-map addons it loads on demand.
read_globals[#read_globals + 1] = "debugprofilestop"
read_globals[#read_globals + 1] = "ShortestPathForeverPathData"
read_globals[#read_globals + 1] = "C_AddOns"
read_globals[#read_globals + 1] = "canaccessvalue"
read_globals[#read_globals + 1] = "WaypointLocationDataProviderMixin"
-- Journey.lua: water walking from its buffs, or a spell to cast.
read_globals[#read_globals + 1] = "C_UnitAuras"
read_globals[#read_globals + 1] = "IsPlayerSpell"
read_globals[#read_globals + 1] = "C_Spell"
read_globals[#read_globals + 1] = "GetCursorPosition"

read_globals[#read_globals + 1] = "IsPlayerMoving"
read_globals[#read_globals + 1] = "InCombatLockdown"
read_globals[#read_globals + 1] = "C_AddOnProfiler"
read_globals[#read_globals + 1] = "UpdateAddOnMemoryUsage"
read_globals[#read_globals + 1] = "GetAddOnMemoryUsage"
-- Teleports.lua: which teleports this character can cast, and where it is bound.
read_globals[#read_globals + 1] = "C_Item"
read_globals[#read_globals + 1] = "C_SpellBook"
read_globals[#read_globals + 1] = "GetBindLocation"
