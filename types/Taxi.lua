---@meta

-- Gethe/wow-ui-source classic_era: Blizzard_UIPanels_Game/Classic/TaxiFrame.lua and
-- Blizzard_SharedXML/MixinUtil.lua. The pinned Ketho library leaves the hop queries untyped.
---@type Frame
TaxiFrame = nil
---@type Frame
TaxiRouteMap = nil
---@type number
NUM_TAXI_ROUTES = nil
---@type number
TAXIROUTE_LINEFACTOR = nil

---@return number
function NumTaxiNodes() end
---@param slot number
---@return number
function GetNumRoutes(slot) end
---@param destination number
---@param hop number
---@param source boolean
---@return number
function TaxiGetNodeSlot(destination, hop, source) end

function DrawOneHopLines() end
---@param texture Texture
---@param canvas Frame|string
---@param startX number
---@param startY number
---@param endX number
---@param endY number
---@param width number
---@param factor number
---@param relativePoint? FramePoint
function DrawLine(texture, canvas, startX, startY, endX, endY, width, factor, relativePoint) end
