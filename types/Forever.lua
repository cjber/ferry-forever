---@meta

-- FrameXML is empty at the pinned Ketho revision. These signatures describe the Forever
-- UI sources (Gethe/wow-ui-source, forever), not replacements loaded by the addon.

---@type string
UNKNOWN = nil
---@type number
LE_PARTY_CATEGORY_INSTANCE = nil
---@type number
AM_PIN_SCALE_STYLE_WITH_TERRAIN = nil
---@type table<string, fun(message: string, editBox: EditBox)>
SlashCmdList = nil
---@type table<string, {r: number, g: number, b: number}>
ChatTypeInfo = nil
---@type {AddMessage: fun(message: string, color: {r: number, g: number, b: number})}
RaidWarningUtil = nil
---@type {Normal: ColorMixin, NormalHighlight: ColorMixin, Header: ColorMixin}
OBJECTIVE_TRACKER_COLOR = nil

---@param value number
---@param minimum number
---@param maximum number
---@return number
function Clamp(value, minimum, maximum) end
---@param value number
---@return number
function Saturate(value) end
---@param start number
---@param finish number
---@param amount number
---@return number
function Lerp(start, finish, amount) end
---@param uiMapID? number
function OpenWorldMap(uiMapID) end

-- LibDBIcon and minimap addons supply this optional shared shape query.
---@type (fun(): string)?
GetMinimapShape = nil

---@param tooltip GameTooltip
---@param title string
---@param color? ColorMixin
---@param wrap? boolean
function GameTooltip_SetTitle(tooltip, title, color, wrap) end
---@param tooltip GameTooltip
---@param text string
---@param wrap? boolean
function GameTooltip_AddNormalLine(tooltip, text, wrap) end
---@param tooltip GameTooltip
---@param text string
---@param wrap? boolean
function GameTooltip_AddInstructionLine(tooltip, text, wrap) end
---@param tooltip GameTooltip
---@param text string
---@param color ColorMixin
---@param wrap? boolean
function GameTooltip_AddColoredLine(tooltip, text, color, wrap) end
---@param tooltip GameTooltip
---@param left string
---@param right string
---@param leftColor ColorMixin
---@param rightColor ColorMixin
function GameTooltip_AddColoredDoubleLine(tooltip, left, right, leftColor, rightColor) end

---@class SPFMapCanvas : Frame
---@field dataProviders table<SPFMapProvider, boolean>
---@field ScrollContainer Frame
---@field AddDataProvider fun(self: SPFMapCanvas, provider: SPFMapProvider)
---@field RemoveDataProvider fun(self: SPFMapCanvas, provider: SPFMapProvider)
---@field GetMapID fun(self: SPFMapCanvas): number
---@field SetMapID fun(self: SPFMapCanvas, mapID: number)
---@field GetCanvas fun(self: SPFMapCanvas): Frame
---@field GetGlobalPinScale fun(self: SPFMapCanvas): number
---@field GetCanvasScale fun(self: SPFMapCanvas): number
---@field GetCanvasZoomPercent fun(self: SPFMapCanvas): number
---@field GetNormalizedCursorPosition fun(self: SPFMapCanvas): number, number
---@field AcquirePin fun(self: SPFMapCanvas, template: string, ...): SPFMapPin
---@field RemoveAllPinsByTemplate fun(self: SPFMapCanvas, template: string)
---@field EnumeratePinsByTemplate fun(self: SPFMapCanvas, template: string): fun(): SPFMapPin
---@field AddCanvasClickHandler fun(self: SPFMapCanvas, handler: fun(map: SPFMapCanvas, button: string): boolean)
---@field AddGlobalPinMouseActionHandler fun(self: SPFMapCanvas, handler: fun(map: SPFMapCanvas, action: number, button: string): boolean)
---@field GetPinFrameLevelsManager fun(self: SPFMapCanvas): SPFFrameLevels
---@field IsMaxZoom fun(self: SPFMapCanvas): boolean
---@field SetAreaLabel fun(self: SPFMapCanvas, labelType: number, name: string, description?: string)
---@class SPFFrameLevels
---@field AddFrameLevel fun(self: SPFFrameLevels, name: string)
---@field InsertFrameLevelAbove fun(self: SPFFrameLevels, name: string, relative: string)
---@type SPFMapCanvas
WorldMapFrame = nil
---@type {MouseAction: {Click: number}}
MapCanvasMixin = nil
---@type {Style: {Waypoint: number}}
POIButtonUtil = nil

---@class SPFMapPin : Frame
---@field pinTemplate string
---@field GetMap fun(self: SPFMapPin): SPFMapCanvas
---@field OnLoad fun(self: SPFMapPin)
---@field OnReleased fun(self: SPFMapPin)
---@field SetIgnoreGlobalPinScale fun(self: SPFMapPin, ignore: boolean)
---@field SetScaleStyle fun(self: SPFMapPin, style: number)
---@field SetPosition fun(self: SPFMapPin, x: number, y: number)
---@field UseFrameLevelType fun(self: SPFMapPin, frameLevelType: string)
---@field SetScalingLimits fun(self: SPFMapPin, style: number, minScale: number, maxScale: number)
---@field SetAlphaLimits fun(self: SPFMapPin, style: number, minAlpha: number, maxAlpha: number)
---@field SetFixedFrameLevel fun(self: SPFMapPin, level: number)
---@field GetPosition fun(self: SPFMapPin): number, number
---@field SetNumLoops fun(self: SPFMapPin, loops: number)
---@field PlayAt fun(self: SPFMapPin, x: number, y: number)
---@type SPFMapPin
MapCanvasPinMixin = nil

---@class SPFMapProvider
---@field GetMap fun(self: SPFMapProvider): SPFMapCanvas
---@field OnAdded fun(self: SPFMapProvider, map: SPFMapCanvas)
---@field OnRemoved fun(self: SPFMapProvider, map: SPFMapCanvas)
---@field RefreshAllData fun(self: SPFMapProvider, fromOnShow?: boolean)
---@field RemoveAllData fun(self: SPFMapProvider)
---@type SPFMapProvider
MapCanvasDataProviderMixin = nil
---@type SPFMapProvider
WaypointLocationDataProviderMixin = nil
---@class SPFFlightProvider : SPFMapProvider
---@field ShouldShowTaxiNode fun(self: SPFFlightProvider, faction: string, info: TaxiNodeInfo): boolean
---@type SPFFlightProvider
FlightPointDataProviderMixin = nil
---@class SPFFlightPin : SPFMapPin
---@field name string
---@field poiInfo {nodeID: number, name: string, isUndiscovered: boolean}
---@type SPFFlightPin
FlightPointPinMixin = nil

---@class SPFQuestPin : SPFMapPin
---@field GetQuestID fun(self: SPFQuestPin): number?
---@field GetStyle fun(self: SPFQuestPin): number
---@class SPFQuestMenuOwner : Frame
---@field questID? number

---@class SPFTrackerLine : Frame
---@field Text FontString
---@field used boolean
---@class SPFTrackerBlock : Frame
---@field id number|string
---@field HeaderButton Button
---@field HeaderText FontString
---@field headerHeight number
---@field parentModule SPFTrackerModule
---@field isHighlighted boolean
---@field used boolean
---@field SetHeader fun(self: SPFTrackerBlock, text: string)
---@field AddObjective fun(self: SPFTrackerBlock, id: number|string, text: string, template?: string, wrap?: boolean, dashStyle?: number, color?: ColorMixin)
---@field GetExistingLine fun(self: SPFTrackerBlock, id: number|string): SPFTrackerLine?
---@field SetStringText fun(self: SPFTrackerBlock, font: FontString, text: string, wrap: boolean?, color: ColorMixin, highlight?: boolean): number
---@class SPFTrackerHeader : Frame
---@field Text FontString
---@class SPFTrackerModule : Frame
---@field Header SPFTrackerHeader
---@field headerText string
---@field uiOrder number
---@field hasDisplayPriority boolean
---@field GetBlock fun(self: SPFTrackerModule, id: number|string): SPFTrackerBlock
---@field GetExistingBlock fun(self: SPFTrackerModule, id: number|string): SPFTrackerBlock?
---@field LayoutBlock fun(self: SPFTrackerModule, block: SPFTrackerBlock): boolean
---@field SetHeader fun(self: SPFTrackerModule, text: string)
---@field MarkDirty fun(self: SPFTrackerModule)
---@field IsDirty fun(self: SPFTrackerModule): boolean
---@field GetContextMenuParent fun(self: SPFTrackerModule): Frame
---@type Frame
ObjectiveTrackerFrame = nil
---@class SPFTrackerManager
---@field GetContainerForModule fun(self: SPFTrackerManager, module: SPFTrackerModule): Frame?
---@field SetModuleContainer fun(self: SPFTrackerManager, module: SPFTrackerModule, container: Frame)
---@type SPFTrackerManager
ObjectiveTrackerManager = nil

---@class SPFSetting
---@field SetValue fun(self: SPFSetting, value: boolean)
---@field SetValueChangedCallback fun(self: SPFSetting, callback: fun(setting: SPFSetting, value: boolean))
---@class SPFSettingsCategory
---@field GetID fun(self: SPFSettingsCategory): number
---@class SPFSettings
---@field VarType {Boolean: string}
---@field RegisterVerticalLayoutCategory fun(name: string): SPFSettingsCategory
---@field RegisterAddOnSetting fun(category: SPFSettingsCategory, variable: string, key: string, storage: SPFDatabase, variableType: string, name: string, default: boolean): SPFSetting
---@field CreateCheckbox fun(category: SPFSettingsCategory, setting: SPFSetting, tooltip?: string)
---@field RegisterAddOnCategory fun(category: SPFSettingsCategory)
---@field OpenToCategory fun(id: number)
---@type SPFSettings
Settings = nil

---@class SPFUiMapPointFactory
---@field CreateFromVector2D fun(uiMapID: number, position: Vector2DMixin): UiMapPoint
---@field CreateFromCoordinates fun(uiMapID: number, x: number, y: number, z?: number): UiMapPoint
---@type SPFUiMapPointFactory
UiMapPoint = nil
