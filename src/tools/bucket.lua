-- TODO - Consider making the "cursor" rectangle display the tile and how it would connect

local state = require("loaded_state")
local viewportHandler = require("viewport_handler")
local configs = require("configs")
local brushHelper = require("brushes")
local colors = require("consts.colors")
local drawing = require("utils.drawing")
local utils = require("utils")
local snapshotUtils = require("snapshot_utils")
local history = require("history")
local toolUtils = require("tool_utils")
local matrixLib = require("utils.matrix")
local lineStruct = require("structs.line")
local brushToolUtils = require("utils.brush_tool")
local tiles = require("tiles")
local celesteRender = require("celeste_render")

local tool = {}

tool._type = "tool"
tool.name = "bucket"
tool.group = "brush"
tool.order = 4
tool.image = nil

tool.mode = "currentRoom"
tool.modes = {
    "currentRoom",
    "allRooms"
}

tool.layer = "tilesFg"
tool.validLayers = {
    "tilesFg",
    "tilesBg"
}

tool.material = "0"
tool.materialsLookup = {}

local lastTileX, lastTileY = -1, -1
local lastClickX, lastClickY = -1, -1
local lastMouseX, lastMouseY = -1, -1
-- Guards against the click and release callbacks both filling all rooms for one click
local lastAllRoomsClick
local startX, startY
local dragX, dragY
local points = {}
local pointsConnectedLines
local currentFloodMatrix

local function floodFill(matrix, x, y)
    local result = {}
    local roomWidth, roomHeight = matrix:size()

    local tlx, tly, brx, bry = math.huge, math.huge, 0, 0
    local processed
    local targetedTiles

    if x >= 1 and x <= roomWidth and y >= 1 and y <= roomHeight then
        processed = matrixLib.filled(false, roomWidth, roomHeight)
        targetedTiles = matrixLib.filled(false, roomWidth, roomHeight)

        local material = matrix:get(x, y)
        local needsProcessing = {{x, y}}

        while #needsProcessing > 0 do
            local targetX, targetY = unpack(table.remove(needsProcessing))

            if not processed:get(targetX, targetY) then
                local targetMaterial = matrix:get(targetX, targetY)

                processed:set(targetX, targetY, true)

                if material == targetMaterial then
                    table.insert(result, {targetX, targetY})

                    table.insert(needsProcessing, {targetX + 1, targetY})
                    table.insert(needsProcessing, {targetX - 1, targetY})
                    table.insert(needsProcessing, {targetX, targetY + 1})
                    table.insert(needsProcessing, {targetX, targetY - 1})

                    tlx = math.min(targetX, tlx)
                    tly = math.min(targetX, tlx)
                    brx = math.max(targetX, brx)
                    bry = math.max(targetY, brx)

                    targetedTiles:set(targetX, targetY, true)
                end
            end
        end
    end

    return result, targetedTiles, tlx, tly, brx, bry
end

local function updatePoints(x, y)
    local room = state.getSelectedRoom()

    -- All Rooms mode fills by tile id, it does not preview a connected region
    if tool.mode == "allRooms" then
        return
    end

    if room and x and y then
        -- Part of the same flooded region
        if currentFloodMatrix and currentFloodMatrix:get(x, y) then
            return
        end

        local tiles = room[tool.layer]
        local tilesMatrix = tiles.matrix

        points, currentFloodMatrix = floodFill(tilesMatrix, x, y)
        pointsConnectedLines = brushToolUtils.connectEdgesFromPoints(points)
    end
end

-- Fills every tile of the clicked id in all rooms
local function handleAllRoomsClick(clickedMaterial)
    local snapshots = {}
    local rooms = state.map and state.map.rooms or {}

    for _, targetRoom in ipairs(rooms) do
        local layerTiles = targetRoom[tool.layer]

        if layerTiles then
            local width, height = layerTiles.matrix:size()
            local matrix = matrixLib.filled(" ", width, height)
            local changed = false

            for ty = 1, height do
                for tx = 1, width do
                    if layerTiles.matrix:get(tx, ty) == clickedMaterial and clickedMaterial ~= tool.material then
                        matrix:set(tx, ty, tool.material)
                        changed = true
                    end
                end
            end

            if changed then
                local before = tiles.getRoomTileSnapshotValue(targetRoom, tool.layer)

                brushHelper.placeTile(targetRoom, 1, 1, matrix, tool.layer)

                -- Other rooms are cached in canvases: redraw them right away instead of waiting
                -- for the next time the room gets selected
                celesteRender.forceRedrawRoom(targetRoom, state, targetRoom == state.getSelectedRoom())

                local after = tiles.getRoomTileSnapshotValue(targetRoom, tool.layer)

                table.insert(snapshots, snapshotUtils.roomTilesSnapshot(targetRoom, tool.layer, "Bucket", before, after))
            end
        end
    end

    if #snapshots > 0 then
        history.addSnapshot(snapshotUtils.multiSnapshot("Bucket", snapshots))
    end
end

local function handleActionClick(x, y, force)
    local room = state.getSelectedRoom()

    if room then
        local px, py = viewportHandler.getRoomCoordinates(room, x, y)
        local tx, ty = viewportHandler.pixelToTileCoordinates(px, py)

        local tiles = room[tool.layer]
        local tilesMatrix = tiles.matrix
        local roomWidth, roomHeight = tilesMatrix:size()
        local matrix = matrixLib.filled(" ", roomWidth, roomHeight)

        if tool.mode == "allRooms" then
            local clickedMaterial = tilesMatrix:get(tx + 1, ty + 1)

            if clickedMaterial and clickedMaterial ~= "" then
                local signature = string.format("%d|%d|%s|%s", tx, ty, tostring(clickedMaterial), tostring(tool.material))

                -- The click and release callbacks both run for one click: only fill once
                if signature ~= lastAllRoomsClick then
                    lastAllRoomsClick = signature

                    handleAllRoomsClick(clickedMaterial)
                end
            end

            points, currentFloodMatrix, pointsConnectedLines = nil, nil, nil

            return
        end

        if #points > 0 then
            for _, point in ipairs(points) do
                matrix:set(point[1], point[2], tool.material)
            end

            brushHelper.placeTile(room, 1, 1, matrix, tool.layer)
            brushToolUtils.toolMadeChanges(tool)
        end

        points, currentFloodMatrix = nil, nil
        pointsConnectedLines = nil

        updatePoints(tx + 1, ty + 1)
    end
end

function tool.getMaterials()
    return brushToolUtils.getPlacements(tool)
end

function tool.setMaterial(material)
    brushToolUtils.setMaterial(tool, material)
end

function tool.setLayer(layer)
    brushToolUtils.setLayer(tool, layer)
end

function tool.mouseclicked(x, y, button, istouch, pressed)
    local actionButton = configs.editor.toolActionButton
    local cloneButton = configs.editor.objectCloneButton

    if button == actionButton then
        handleActionClick(x, y)

    elseif button == cloneButton then
        brushToolUtils.handleCloneClick(tool, x, y)
    end
end

function tool.mousemoved(x, y, dx, dy, istouch)
    local actionButton = configs.editor.toolActionButton
    local room = state.getSelectedRoom()

    if room then
        local px, py = viewportHandler.getRoomCoordinates(room, x, y)
        local tx, ty = viewportHandler.pixelToTileCoordinates(px, py)

        if lastMouseX ~= tx or lastMouseY ~= ty then
            updatePoints(tx + 1, ty + 1)
            lastAllRoomsClick = nil
        end

        lastMouseX, lastMouseY = tx + 1, ty + 1
    end
end

function tool.mousepressed(x, y, button, istouch, pressed)
    local actionButton = configs.editor.toolActionButton

    if button == actionButton then
        local room = state.getSelectedRoom()

        -- The all rooms fill creates its own multi room snapshot
        if tool.mode ~= "allRooms" then
            brushToolUtils.startTileSnapshot(tool)
        end
    end
end

function tool.mousereleased(x, y, button)
    local actionButton = configs.editor.toolActionButton

    if button == actionButton then
        local room = state.getSelectedRoom()

        if room then
            handleActionClick(x, y)
        end

        if tool.mode ~= "allRooms" then
            brushToolUtils.stopTileSnapshot(tool)
        end
    end
end

function tool.draw()
    local room = state.getSelectedRoom()

    if room then
        viewportHandler.drawRelativeTo(room.x, room.y, function()
            drawing.callKeepOriginalColor(function()
                love.graphics.setColor(colors.brushColor)

                brushToolUtils.drawConnectedLines(pointsConnectedLines, -8, -8)
            end)
        end)
    end
end

function tool.editorMapTargetChanged()
    brushToolUtils.clearTileSnapshot(tool)
end

return tool