---@meta

-- Public addon-to-addon interface. Coordinates are uiMapID and normalized 0-1 x/y, not world yards.
---@class SPFPublicAPI
---@field version integer 1
---@field Estimate fun(fromMap: integer, fromX: number, fromY: number, toMap: integer, toX: number, toY: number): number? seconds, nil when unknown or in combat
---@field Navigate fun(owner: string, map: integer, x: number, y: number, title?: string): boolean starts/replaces guidance outside combat when journeys are enabled
---@field Cancel fun(owner: string): boolean true only when this owner's current journey was cancelled

---@class SPFPublicAddon
---@field API SPFPublicAPI
ShortestPathForever = {}
