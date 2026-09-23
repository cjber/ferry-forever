---@meta

-- Public addon-to-addon interface. Coordinates are uiMapID and normalized 0-1 x/y, not world yards.
---@class SPFAPIStop
---@field map integer uiMapID
---@field x number normalized 0-1
---@field y number normalized 0-1
---@field title? string

---@alias SPFAPINoRoute "combat"|"invalid"|"unreachable"

---@class SPFPublicAPI
---@field version integer 1
---@field Estimate fun(fromMap: integer, fromX: number, fromY: number, toMap: integer, toX: number, toY: number): seconds: number?, reason: SPFAPINoRoute? nil seconds come with the reason
---@field Navigate fun(owner: string, map: integer, x: number, y: number, title?: string): boolean starts/replaces guidance outside combat when journeys are enabled
---@field NavigateRoute fun(owner: string, stops: SPFAPIStop[]): boolean starts/replaces guidance through 1-64 stops in order; false leaves the current journey intact
---@field CurrentStop fun(owner: string): integer? 1-based current stop, nil unless owner owns the active journey
---@field Cancel fun(owner: string): boolean true only when this owner's current journey was cancelled

---@class SPFPublicAddon
---@field API SPFPublicAPI
ShortestPathForever = {}
