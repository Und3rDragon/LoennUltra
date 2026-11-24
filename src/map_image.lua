local loadedState = require("loaded_state")
local utils = require("utils")
local celesteRender = require("celeste_render")
local mapItemUtils = require("map_item_utils")
local logging = require("logging")

local mapImageGenerator = {}

-- The map is rendered in tiles of this size so that huge maps do not need a
-- single canvas, which would exceed the maximum texture size
local maxTileSize = 2048

local function getImageState(map, resolutionScale, bounds)
    local imageState = utils.deepcopy(loadedState)

    imageState.map = map
    imageState.viewport = {
        visible = true,
        scale = resolutionScale,
        x = bounds.x * resolutionScale,
        y = bounds.y * resolutionScale,
        width = bounds.width * resolutionScale,
        height = bounds.height * resolutionScale
    }
    imageState.selectedItemType = "table"
    imageState.selectedItem = {}
    imageState.showRoomBackground = false
    imageState.showRoomBorders = false
    imageState.skipTriggerScreenText = true

    function imageState.getLayerShouldRender(layer)
        return layer ~= "triggers"
    end

    return imageState
end

-- Renders the whole map into an ImageData. The room canvases are rendered at a
-- higher resolution when the hi-res font is in use, so the image is rendered at
-- that resolution as well: downscaling it to the map resolution would resample
-- the text and break the glyphs
function mapImageGenerator.getMapImageData(map)
    map = map or loadedState.map

    if not map then
        return nil, "no map is loaded"
    end

    local tlx, tly, brx, bry = mapItemUtils.getMapBounds(map)
    local width, height = brx - tlx, bry - tly

    if width <= 0 or height <= 0 then
        return nil, "the map has no visible room bounds"
    end

    local resolutionScale = celesteRender.getCanvasResolutionScale()
    local bounds = {x = tlx, y = tly, width = width, height = height}

    local imageWidth = math.max(1, math.floor(width * resolutionScale))
    local imageHeight = math.max(1, math.floor(height * resolutionScale))
    local success, imageData = pcall(love.image.newImageData, imageWidth, imageHeight)

    if not success then
        return nil, string.format("could not allocate a %dx%d image (%s)", imageWidth, imageHeight, tostring(imageData))
    end

    local imageState = getImageState(map, resolutionScale, bounds)

    -- Redraw all rooms with new state info
    for _, room in ipairs(map.rooms) do
        local redrawSuccess, redrawError = pcall(celesteRender.forceRedrawRoom, room, imageState, false)

        if not redrawSuccess then
            celesteRender.invalidateRoomCache()
            return nil, "failed to redraw a room: " .. tostring(redrawError)
        end
    end

    local viewport = imageState.viewport

    for tileY = 0, height - 1, maxTileSize do
        for tileX = 0, width - 1, maxTileSize do
            local tileWidth = math.min(maxTileSize, width - tileX)
            local tileHeight = math.min(maxTileSize, height - tileY)

            viewport.x = (tlx + tileX) * resolutionScale
            viewport.y = (tly + tileY) * resolutionScale
            viewport.width = tileWidth * resolutionScale
            viewport.height = tileHeight * resolutionScale

            local canvasSuccess, canvasOrError = pcall(love.graphics.newCanvas,
                math.max(1, math.floor(tileWidth * resolutionScale)),
                math.max(1, math.floor(tileHeight * resolutionScale)))

            if not canvasSuccess then
                celesteRender.invalidateRoomCache()
                return nil, "could not create a map tile canvas: " .. tostring(canvasOrError)
            end

            local canvas = canvasOrError
            local drawSuccess, drawError = pcall(canvas.renderTo, canvas, function()
                local selectedItem, selectedItemType = imageState.getSelectedItem()

                celesteRender.drawFillers(imageState.map.fillers, imageState, selectedItem, selectedItemType)
                celesteRender.drawRooms(imageState.map.rooms, imageState, selectedItem, selectedItemType)
                celesteRender.drawScreenTexts(imageState.map.rooms, imageState)
            end)

            if not drawSuccess then
                canvas:release()
                celesteRender.invalidateRoomCache()
                return nil, "could not draw a map tile: " .. tostring(drawError)
            end

            local copySuccess, tileData = pcall(canvas.newImageData, canvas)

            if not copySuccess or not tileData then
                canvas:release()
                celesteRender.invalidateRoomCache()
                return nil, "could not copy a map tile: " .. tostring(tileData)
            end

            local pasteSuccess, pasteError = pcall(imageData.paste, imageData, tileData,
                tileX * resolutionScale, tileY * resolutionScale)

            if not pasteSuccess then
                canvas:release()
                celesteRender.invalidateRoomCache()
                return nil, "could not compose the map image: " .. tostring(pasteError)
            end

            canvas:release()
        end
    end

    celesteRender.invalidateRoomCache()

    return imageData
end

function mapImageGenerator.saveMapImage(filename, map)
    pcall(logging.log, "INFO", "[diag] mapImage.begin file=" .. tostring(filename), nil, true)

    local imageData, imageError = mapImageGenerator.getMapImageData(map)

    pcall(logging.log, "INFO", string.format("[diag] mapImage.generated ok=%s err=%s",
        tostring(imageData ~= nil), tostring(imageError)), nil, true)

    if not imageData then
        return false, imageError or "could not generate the map image"
    end

    local success, encodedOrError = pcall(imageData.encode, imageData, "png")

    if not success then
        return false, "could not encode the image as PNG: " .. tostring(encodedOrError)
    end

    local fh, openError = io.open(filename, "wb")

    if not fh then
        return false, "could not open the output file: " .. tostring(openError)
    end

    local data = encodedOrError:getString()
    local writeSuccess, writeError = pcall(fh.write, fh, data)

    fh:close()

    if not writeSuccess then
        return false, "could not write the output file: " .. tostring(writeError)
    end

    -- Validate that the png is valid. LÖVE's filesystem only sees its own
    -- directories, so the written file is fed back as FileData instead
    local success, validationError = pcall(function()
        return love.image.newImageData(love.filesystem.newFileData(data, "map_image.png"))
    end)

    if not success then
        pcall(logging.log, "INFO", "[diag] mapImage.fail stage=readback err=" .. tostring(validationError), nil, true)

        return false, "the generated PNG could not be read back: " .. tostring(validationError)
    end

    pcall(logging.log, "INFO", string.format("[diag] mapImage.done bytes=%d file=%s",
        #data, tostring(filename)), nil, true)

    return true
end

return mapImageGenerator
