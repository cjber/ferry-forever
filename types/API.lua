---@meta

-- Public addon-to-addon interface. Coordinates are uiMapID and normalized 0-1 x/y, not world yards.
-- Additions keep version 1: a caller checks optional members with type(api.Name) == "function".

---@alias SPFAPIMode "walk"|"flight"|"boat"|"zeppelin"|"lift"|"tram"|"portal"|"passage"
---@alias SPFAPINoRoute "combat"|"invalid"|"unreachable" -- retry after combat; never for bad input; unreachable with what this character knows

---@alias SPFAPIEnded "arrived"|"cleared"|"replaced"|"cancelled" -- reached the last stop; the player cleared it; another journey took over; the owner's own Cancel

---@class SPFAPIStop
---@field map integer -- uiMapID
---@field x number -- normalized 0-1
---@field y number -- normalized 0-1
---@field title? string

---@class SPFAPILeg
---@field mode SPFAPIMode
---@field to string -- where the leg ends, named as SPF's tracker names it
---@field seconds number -- from the previous leg's arrival (the first from the start), waits included
---@field wait? number -- seconds waiting for a boat, zeppelin, lift or tram; present only from 60 up
---@field newFlightPath? boolean -- true on a walk to a flight master this character has not discovered

---@class SPFAPIDetail
---@field seconds number -- equal to Estimate's answer
---@field legs SPFAPILeg[] -- fresh copies on every call, never SPF's own tables

---@class SPFPublicAPI
---@field version integer -- 1
---@field Estimate fun(fromMap: integer, fromX: number, fromY: number, toMap: integer, toX: number, toY: number): seconds: number?, reason: SPFAPINoRoute? -- travel seconds; nil comes with the reason
---@field Navigate fun(owner: string, map: integer, x: number, y: number, title?: string): boolean -- starts/replaces guidance outside combat when journeys are enabled
---@field NavigateRoute fun(owner: string, stops: SPFAPIStop[]): boolean -- starts/replaces guidance through 1-64 stops in order; false leaves the current journey intact
---@field CurrentStop fun(owner: string): integer? -- 1-based current stop, nil unless owner owns the active journey
---@field Cancel fun(owner: string): boolean -- true only when this owner's current journey was cancelled
---@field EstimateDetail fun(fromMap: integer, fromX: number, fromY: number, toMap: integer, toX: number, toY: number): detail: SPFAPIDetail?, reason: SPFAPINoRoute? -- Estimate leg by leg, sharing its cache
---@field Active fun(): boolean -- true while any journey is guiding, whoever started it
---@field Ended fun(owner: string): reason: SPFAPIEnded?, at: number? -- why owner's last journey ended and its GetTime(); nil while it runs, before any, or after a reload

---@class SPFPublicAddon
---@field API SPFPublicAPI
ShortestPathForever = {}
