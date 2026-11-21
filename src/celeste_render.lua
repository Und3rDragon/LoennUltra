local autotiler = require("autotiler")
local drawing = require("utils.drawing")
local fileLocations = require("file_locations")
local colors = require("consts.colors")
local tasks = require("utils.tasks")
local utils = require("utils")
local atlases = require("atlases")
local smartDrawingBatch = require("structs.smart_drawing_batch")
local drawableRectangle = require("structs.drawable_rectangle")
local viewportHandler = require("viewport_handler")
local matrix = require("utils.matrix")
local configs = require("configs")
local bit = require("bit")
local modHandler = require("mods")
local virtualFs = require("virtual_fs")
local depths = require("consts.object_depths")
local logging = require("logging")
local modificationWarner = require("modification_warner")
local textLayout = require("text_layout")

local entityHandler = require("entities")
local triggerHandler = require("triggers")
local decalHandler = require("decals")
local fonts = require("fonts")

local celesteRender = {}

local tilesetFileFg = utils.joinpath(fileLocations.getCelesteDir(), "Content", "Graphics", "ForegroundTiles.xml")
local tilesetFileBg = utils.joinpath(fileLocations.getCelesteDir(), "Content", "Graphics", "BackgroundTiles.xml")

celesteRender.tilesMetaFgVanilla = autotiler.loadTilesetXML(tilesetFileFg)
celesteRender.tilesMetaBgVanilla = autotiler.loadTilesetXML(tilesetFileBg)

celesteRender.tilesMetaFg = celesteRender.tilesMetaFgVanilla
celesteRender.tilesMetaBg = celesteRender.tilesMetaBgVanilla

celesteRender.tilesSpriteMetaCache = {}
celesteRender.tilesSceneryMetaCache = {}

local tilesFgDepth = depths.fgTerrain
local tilesBgDepth = depths.bgTerrain

local tilesetState = {
    pathFg = nil,
    pathBg = nil,
    signatureFg = nil,
    signatureBg = nil,
    sources = nil,
    imageSignatures = {}
}

local function getTilesetXMLSignature(filename)
    if not filename or filename == "" then
        return nil
    end

    local commonFilename = modHandler.commonModContent .. "/" .. utils.convertToUnixPath(filename)
    local info = love.filesystem.getInfo(commonFilename)

    if not info then
        return commonFilename .. ":missing"
    end

    return string.format("%s:%s:%s", commonFilename, tostring(info.modtime), tostring(info.size))
end

local function getTilesetImageFilename(source, tileset)
    local path = tileset.path

    if not path then
        return nil
    end

    local relative = "Graphics/Atlases/Gameplay/" .. path .. ".png"

    if source.modFolder then
        return "$" .. source.modFolder .. "$/" .. relative
    end

    return modHandler.commonModContent .. "/" .. relative
end

local function getTilesetImageSignature(filename)
    if not filename then
        return "missing"
    end

    local info = love.filesystem.getInfo(filename)

    if not info then
        return "missing"
    end

    return string.format("%s:%s", tostring(info.modtime), tostring(info.size))
end

local function hasChangedTilesetImages(tilesetSources)
    local gameplay = atlases.gameplay

    for _, source in ipairs(tilesetSources or {}) do
        for _, tileset in pairs(source.tiles or {}) do
            local path = tileset.path

            if path then
                local filename = getTilesetImageFilename(source, tileset)
                local signature = getTilesetImageSignature(filename)

                if not gameplay or not rawget(gameplay, path)
                    or signature ~= tilesetState.imageSignatures[path] then
                    return true
                end
            end
        end
    end

    return false
end

-- True when the Metadata form should reload the tile XML/atlases. Unchanged saves skip the
-- expensive room cache invalidation and visible-room redraw entirely.
function celesteRender.tilesetXMLChanged(state)
    local meta = state and state.side and state.side.meta

    if not meta then
        return false
    end

    local pathFg = meta.ForegroundTiles
    local pathBg = meta.BackgroundTiles

    if pathFg ~= tilesetState.pathFg or pathBg ~= tilesetState.pathBg then
        return true
    end

    return getTilesetXMLSignature(pathFg) ~= tilesetState.signatureFg
        or getTilesetXMLSignature(pathBg) ~= tilesetState.signatureBg
end

function celesteRender.customTilesetChanged(state)
    return celesteRender.tilesetXMLChanged(state) or hasChangedTilesetImages(tilesetState.sources)
end

local decalsFgDepth = depths.fgDecals
local decalsBgDepth = depths.bgDecals

local triggersDepth = depths.triggers

-- TODO - Figure out good number
local YIELD_RATE = 100
local PRINT_BATCHING_DURATION = false
local ALWAYS_REDRAW_UNSELECTED_ROOMS = configs.editor.alwaysRedrawUnselectedRooms
local ALLOW_NON_VISIBLE_BACKGROUND_DRAWING = configs.editor.prepareRoomRenderInBackground

local SCENERY_GAMEPLAY_PATH = "tilesets/scenery"

local roomCache = {}
local roomTextOverlays = {}
local roomTextReady = {}
local roomRandomMatrixCache = {}

local batchingTasks = {}

local function loadCustomAutotiler(filename)
    if filename and filename ~= ""  then
        local commonFilename = modHandler.commonModContent .. "/" .. utils.convertToUnixPath(filename)
        local loaded, tilesMeta = pcall(autotiler.loadTilesetXML, commonFilename)
        local modFolderName = virtualFs.getOwner(commonFilename)

        return loaded, tilesMeta, modFolderName
    end
end

-- Reloads every image referenced by the custom tileset XML. Only the paths listed in the XML are
-- touched, so a changed PNG does not require walking the whole mod folder again.
function celesteRender.loadTilesetImages(tilesetSources)
    if not tilesetSources or #tilesetSources == 0 then
        return 0
    end

    local loaded = 0
    local seen = {}

    for _, source in ipairs(tilesetSources) do
        for _, tileset in pairs(source.tiles or {}) do
            local path = tileset.path

            if path and not seen[path] then
                seen[path] = true

                local filename = getTilesetImageFilename(source, tileset)
                local sprite = filename and atlases.reloadResourceFromFile(path, filename, "Gameplay")

                tilesetState.imageSignatures[path] = getTilesetImageSignature(filename)

                if sprite then
                    loaded = loaded + 1
                end
            end
        end
    end

    if loaded > 0 then
        celesteRender.clearTileSpriteQuadCache()
        logging.info(string.format("[tileset] Reloaded %d tileset image(s)", loaded))
    end

    return loaded
end

function celesteRender.loadCustomTilesetAutotiler(state)
    celesteRender.tilesMetaFg = celesteRender.tilesMetaFgVanilla
    celesteRender.tilesMetaBg = celesteRender.tilesMetaBgVanilla

    local tilesetSources = {}

    if state and state.side and state.side.meta then
        local pathFg = state.side.meta.ForegroundTiles
        local pathBg = state.side.meta.BackgroundTiles

        local loadedFg, tilesMetaFg, modFolderNameFg = loadCustomAutotiler(pathFg)
        local loadedBg, tilesMetaBg, modFolderNameBg = loadCustomAutotiler(pathBg)

        if loadedFg then
            celesteRender.tilesMetaFg = tilesMetaFg
            table.insert(tilesetSources, {tiles = tilesMetaFg, modFolder = modFolderNameFg})

        else
            if tilesMetaFg then
                logging.warning(string.format("Loading custom foreground tile XML failed: %s", tilesMetaFg))
            end
        end

        if loadedBg then
            celesteRender.tilesMetaBg = tilesMetaBg
            table.insert(tilesetSources, {tiles = tilesMetaBg, modFolder = modFolderNameBg})

        else
            if tilesMetaBg then
                logging.warning(string.format("Loading custom background tile XML failed: %s", tilesMetaBg))
            end
        end
    end

    celesteRender.clearTileSpriteQuadCache()
    celesteRender.clearScenerySpriteQuadCache()

    local meta = state and state.side and state.side.meta

    tilesetState.pathFg = meta and meta.ForegroundTiles or nil
    tilesetState.pathBg = meta and meta.BackgroundTiles or nil
    tilesetState.signatureFg = getTilesetXMLSignature(tilesetState.pathFg)
    tilesetState.signatureBg = getTilesetXMLSignature(tilesetState.pathBg)
    tilesetState.sources = tilesetSources
    tilesetState.imageSignatures = {}

    for _, source in ipairs(tilesetSources) do
        for _, tileset in pairs(source.tiles or {}) do
            local path = tileset.path

            if path then
                tilesetState.imageSignatures[path] = getTilesetImageSignature(
                    getTilesetImageFilename(source, tileset)
                )
            end
        end
    end

    return tilesetSources
end

local function getOrCreateSmartBatch(batches, key)
    batches[key] = batches[key] or smartDrawingBatch.createOrderedBatch()

    return batches[key]
end

-- Text is drawn in screen space after the room batches. This keeps custom TTF labels out of the
-- fixed-sized room canvas, so their glyphs are not resampled with the canvas.
-- Stable depth order for text overlays. Lua's table.sort is not stable, so drawables without an
-- explicit depth (many entity labels) would otherwise swap places every frame.
local function sortTextDrawables(drawables)
    local order = {}

    for index, drawable in ipairs(drawables) do
        order[drawable] = index
    end

    table.sort(drawables, function(a, b)
        local aDepth = a.depth or 0
        local bDepth = b.depth or 0

        if aDepth ~= bDepth then
            return aDepth > bDepth
        end

        return (order[a] or 0) < (order[b] or 0)
    end)
end

local function addDrawableToBatchOrText(batches, textDrawables, drawable, depth)
    if drawable._type == "drawableScreenText" then
        table.insert(textDrawables, drawable)

        return
    end

    if drawable._type == "drawableText" then
        local displayFont = fonts.getTriggerFont()
        local labelFontSize = fonts.size(configs.font.textSize or 1)

        if drawable.font ~= displayFont then
            local layoutFont = drawable.layoutFont or drawable.font or fonts.font

            drawable.font = displayFont
            drawable.fontSize = 1
            drawable.layoutFont = layoutFont
            -- Entity handlers may pass arbitrary pixel-font sizes (fontSize=8, etc.). The screen
            -- renderer uses one uniform label size so those values can not turn into huge text.
            drawable.layoutFontSize = labelFontSize
        end

        if not drawable.layoutFont then
            drawable.layoutFont = fonts.font
            drawable.layoutFontSize = labelFontSize
        end

        table.insert(textDrawables, drawable)

        return
    end

    local batchDepth = drawable.depth or depth or 0
    local batch = getOrCreateSmartBatch(batches, batchDepth)

    batch:addFromDrawable(drawable)
end

function celesteRender.sortBatchingTasks(state, taskList)
    local visibleTasks = {}
    local nonVisibileTasks = {}

    local roomNames = {}

    for _, r in ipairs(state.map.rooms) do
        roomNames[r.name] = true
    end

    for i = #taskList, 1, -1 do
        local task = taskList[i]
        local viewport = state.viewport
        local room = task.data.room

        if not task.done and roomNames[room.name] then
            if viewport.visible and viewportHandler.roomVisible(room, viewport) then
                table.insert(visibleTasks, task)

            else
                table.insert(nonVisibileTasks, task)
            end

        else
            table.remove(taskList, i)
        end
    end

    return visibleTasks, nonVisibileTasks
end

function celesteRender.processTasks(state, calcTime, maxTasks, backgroundTime, backgroundTasks)
    local visible, notVisible = celesteRender.sortBatchingTasks(state, batchingTasks)

    backgroundTime = backgroundTime or calcTime
    backgroundTasks = backgroundTasks or maxTasks

    local success, timeSpent, tasksDone = tasks.processTasks(calcTime, maxTasks, visible)
    tasks.processTasks(backgroundTime - timeSpent, backgroundTasks - tasksDone, notVisible)
end

function celesteRender.clearBatchingTasks()
    -- TODO - Check if this should release the ongoing tasks or if Lua GC is good enough
    batchingTasks = {}
end

function celesteRender.clearBatchTask(roomName, key)
    if roomCache[roomName] and roomCache[roomName][key] then
        local task = roomCache[roomName][key]
        local target = task.result

        if target then
            if utils.typeof(target) == "table" then
                for _, depthTarget in pairs(target) do
                    if depthTarget.release then
                        depthTarget:release()
                    end
                end

            else
                if target.release then
                    target:release()
                end
            end
        end

        task.done = true
        roomCache[roomName][key] = nil
    end
end

function celesteRender.invalidateRoomCache(roomName, key)
    if roomName then
        if utils.typeof(roomName) == "room" then
            roomName = roomName.name
        end

        if key then
            local keys = type(key) == "table" and key or {key}
            local overlays = roomTextOverlays[roomName]

            for _, layerKey in ipairs(keys) do
                if layerKey == "entities" or layerKey == "triggers" or layerKey == "complete" then
                    roomTextReady[roomName] = nil
                end

                if overlays then
                    if layerKey == "entities" then
                        overlays.entities = nil

                    elseif layerKey == "triggers" then
                        overlays.triggers = nil
                    end

                    if not overlays.entities and not overlays.triggers then
                        roomTextOverlays[roomName] = nil
                        overlays = nil
                    end
                end

                celesteRender.clearBatchTask(roomName, layerKey)
            end

        else
            roomTextOverlays[roomName] = nil
            roomTextReady[roomName] = nil

            if roomCache[roomName] then
                for name, _ in pairs(roomCache[roomName]) do
                    celesteRender.clearBatchTask(roomName, name)
                end
            end
        end

    else
        for name, _ in pairs(roomCache) do
            celesteRender.invalidateRoomCache(name)
        end

        roomCache = {}
        roomTextOverlays = {}
        roomTextReady = {}
    end
end

function celesteRender.getRoomRandomMatrix(room, key)
    local roomName = room.name
    local tileWidth, tileHeight = room[key].matrix:size()
    local regen = false

    if roomRandomMatrixCache[roomName] and roomRandomMatrixCache[roomName][key] then
        local m = roomRandomMatrixCache[roomName][key]
        local randWidth, randHeight = m:size()

        regen = tileWidth ~= randWidth or tileHeight ~= randHeight

    else
        regen = true
    end

    if regen then
        utils.setRandomSeed(roomName)

        local m = matrix.fromFunction(function()
            return math.random()
        end, tileWidth, tileHeight)

        roomRandomMatrixCache[roomName] = roomRandomMatrixCache[roomName] or {}
        roomRandomMatrixCache[roomName][key] = m
    end

    return roomRandomMatrixCache[roomName][key]
end

function celesteRender.getRoomCache(roomName, key)
    if utils.typeof(roomName) == "room" then
        roomName = roomName.name
    end

    if roomCache[roomName] and roomCache[roomName][key] then
        return roomCache[roomName][key]
    end

    return false
end

function celesteRender.getRoomBackgroundColor(room, selected, state)
    if not state.showRoomBackground then
        return nil
    end

    local roomColor = room.color or 0
    local color = colors.roomBackgroundDefault

    if roomColor >= 0 and roomColor < #colors.roomBackgroundColors then
        color = colors.roomBackgroundColors[roomColor + 1]
    end

    local r, g, b = color[1], color[2], color[3]
    local a = selected and 1.0 or 0.3

    return {r, g, b, a}
end

function celesteRender.getRoomBorderColor(room, selected, state)
    if not state.showRoomBorders then
        return nil
    end

    local roomColor = room.color or 0
    local color = colors.roomBorderDefault

    if roomColor >= 0 and roomColor < #colors.roomBorderColors then
        color = colors.roomBorderColors[roomColor + 1]
    end

    return color
end

function celesteRender.getSceneryMeta()
    return atlases.gameplay[SCENERY_GAMEPLAY_PATH]
end

function celesteRender.clearTileSpriteQuadCache()
    -- TODO - Does this need to release quads? Should be small enough to just wait for Lua GC

    celesteRender.tilesSpriteMetaCache = {}
end

function celesteRender.clearScenerySpriteQuadCache()
    -- TODO - Does this need to release quads? Should be small enough to just wait for Lua GC

    celesteRender.tilesSceneryMetaCache = nil
end

function celesteRender.getOrCacheTileSpriteQuad(cache, tile, texture, quad, fg)
    if not cache[tile] then
        local tilesetSpriteMeta = atlases.gameplay[texture]
        local tilesetSpriteWidth, tilesetSpriteHeight = tilesetSpriteMeta.realWidth, tilesetSpriteMeta.realHeight
        local width, height = math.ceil(tilesetSpriteWidth / 8), math.ceil(tilesetSpriteHeight / 8)

        cache[tile] = {
            [false] = matrix.filled(nil, width, height),
            [true] = matrix.filled(nil, width, height)
        }
    end

    local quadCache = cache[tile][fg]
    local quadX, quadY = quad[1], quad[2]

    local cachedQuad = quadCache:get0(quadX, quadY, false)

    if not cachedQuad then
        local spriteMeta = atlases.gameplay[texture]
        local spritesWidth, spritesHeight = spriteMeta.image:getDimensions()
        local res = love.graphics.newQuad(spriteMeta.x - spriteMeta.offsetX + quadX * 8, spriteMeta.y - spriteMeta.offsetY + quadY * 8, 8, 8, spritesWidth, spritesHeight)

        quadCache:set0(quadX, quadY, res)

        return res
    end

    return cachedQuad
end

function celesteRender.getOrCacheScenerySpriteQuad(index)
    local sceneryMeta = celesteRender.getSceneryMeta()
    local sceneryWidth, sceneryHeight = math.ceil(sceneryMeta.realWidth / 8), math.ceil(sceneryMeta.realHeight / 8)
    local quadX, quadY = index % sceneryWidth, math.floor(index / sceneryWidth)

    if not celesteRender.tilesSceneryMetaCache then
        celesteRender.tilesSceneryMetaCache = matrix.filled(nil, sceneryWidth, sceneryHeight)
    end

    local quadCache = celesteRender.tilesSceneryMetaCache

    if not quadCache:get0(quadX, quadY) then
        local spritesWidth, spritesHeight = sceneryMeta.image:getDimensions()
        local quad = love.graphics.newQuad(sceneryMeta.x - sceneryMeta.offsetX + quadX * 8, sceneryMeta.y - sceneryMeta.offsetY + quadY * 8, 8, 8, spritesWidth, spritesHeight)

        quadCache:set0(quadX, quadY, quad)

        return quad
    end

    return quadCache:get0(quadX, quadY)
end

function celesteRender.drawInvalidTiles(batch, missingTiles, fg)
    if #missingTiles > 0 then
        local batchType = utils.typeof(batch)

        if batchType == "gridCanvasDrawingBatch" then
            local color = fg and colors.tileFGMissingColor or colors.tileBGMissingColor

            local canvas = love.graphics.getCanvas()
            local r, g, b, a = love.graphics.getColor()

            love.graphics.setCanvas(batch._canvas)
            love.graphics.setColor(color)

            for _, missing in ipairs(missingTiles) do
                local x, y = missing[1], missing[2]

                love.graphics.rectangle("fill", x * 8 - 8, y * 8 - 8, 8, 8)
            end

            love.graphics.setCanvas(canvas)
            love.graphics.setColor(r, g, b, a)

        elseif batchType == "matrixDrawingBatch" then
            local pixelTexture = atlases.addInternalPrefix(drawableRectangle.tintingPixelTexture)
            local pixelMeta = atlases.getResource(pixelTexture, "Gameplay")
            local color = fg and colors.tileFGMissingColor or colors.tileBGMissingColor
            local defaultColor = {1.0, 1.0, 1.0, 1.0}

            for _, missing in ipairs(missingTiles) do
                local x, y = missing[1], missing[2]
                local drawX, drawY = x * 8 - 8, y * 8 - 8

                batch:setColor(pixelMeta, color)
                batch:set(x, y, pixelMeta, pixelMeta.quad, drawX, drawY, 0, 8, 8)
            end

            batch:setColor(pixelMeta, defaultColor)
        end
    end
end

local function getTilesBatchFromMode(width, height, mode)
    if mode == "gridCanvasDrawingBatch" then
        return smartDrawingBatch.createGridCanvasBatch(false, width, height, 8, 8)

    elseif mode == "matrixDrawingBatch" then
        return smartDrawingBatch.createMatrixBatch(width, height, 8, 8)

    elseif mode == "table" then
        return {}
    end
end

-- randomMatrix is for custom randomness, mostly to give the correct "slice" of the matrix when making fake tiles
function celesteRender.getTilesBatch(room, tiles, meta, scenery, fg, randomMatrix, batchMode, shouldYield)
    batchMode = batchMode or "matrixDrawingBatch"

    local tilesMatrix = tiles.matrix

    -- Getting upvalues
    local tileCache = celesteRender.tilesSpriteMetaCache
    local autotiler = autotiler
    local meta = meta
    local checkTile = autotiler.checkTile
    local lshift = bit.lshift
    local bxor = bit.bxor
    local band = bit.band

    local canvasOrMatrixBatch = batchMode == "gridCanvasDrawingBatch" or batchMode == "matrixDrawingBatch"
    local tableBatch = batchMode == "table"

    local airTile = "0"
    local emptyTile = " "
    local wildcard = "*"

    local defaultQuad = {{0, 0}}

    local width, height = tilesMatrix:size()
    local batch = getTilesBatchFromMode(width, height, batchMode)

    local random = randomMatrix or celesteRender.getRoomRandomMatrix(room, fg and "tilesFg" or "tilesBg")

    local sceneryMatrix = scenery and scenery.matrix
    local sceneryMeta = celesteRender.getSceneryMeta()
    local sceneryWidth, sceneryHeight = sceneryMeta.realWidth, sceneryMeta.realHeight

    local gameplayAtlas = atlases.gameplay

    local missingTiles = {}

    for x = 1, width do
        for y = 1, height do
            local tile = tilesMatrix:getInbounds(x, y)
            local sceneryTile = sceneryMatrix and sceneryMatrix:getInbounds(x, y, -1) or -1

            if sceneryTile > -1 then
                local quad = celesteRender.getOrCacheScenerySpriteQuad(sceneryTile)

                if quad then
                    if canvasOrMatrixBatch then
                        batch:set(x, y, sceneryMeta, quad, x * 8 - 8, y * 8 - 8)

                    elseif tableBatch then
                        table.insert(batch, {sceneryMeta, quad, x * 8 - 8, y * 8 - 8})
                    end
                end

            elseif tile and tile ~= airTile then
                local tileMeta = meta[tile]
                local texture = tileMeta and tileMeta.path

                if texture then
                    -- TODO - Render overlay sprites
                    local quads, sprites = autotiler.getQuads(x, y, tilesMatrix, tileMeta, airTile, emptyTile, wildcard, defaultQuad, defaultSprite, checkTile, lshift, bxor, band)
                    local quadCount = #quads

                    if quadCount > 0 then
                        local rng = random:getInbounds(x, y)
                        local randQuad = quads[1 + math.floor(rng * quadCount)]

                        local spriteMeta = gameplayAtlas[texture]

                        if spriteMeta then
                            local quad = celesteRender.getOrCacheTileSpriteQuad(tileCache, tile, texture, randQuad, fg)

                            if canvasOrMatrixBatch then
                                batch:set(x, y, spriteMeta, quad, x * 8 - 8, y * 8 - 8)

                            elseif tableBatch then
                                table.insert(batch, {spriteMeta, quad, x * 8 - 8, y * 8 - 8})
                            end

                        else
                            -- Missing texture, not found on disk
                            table.insert(missingTiles, {x, y})
                        end
                    end

                else
                    -- Unknown tileset id
                    table.insert(missingTiles, {x, y})
                end
            end
        end

        if shouldYield ~= false then
            tasks.yield()
        end
    end

    celesteRender.drawInvalidTiles(batch, missingTiles, fg)

    if shouldYield ~= false then
        tasks.update(batch)
    end

    return batch, missingTiles
end

local function getRoomTileBatch(room, tiles, fg)
    local key = fg and "tilesFg" or "tilesBg"
    local meta = fg and celesteRender.tilesMetaFg or celesteRender.tilesMetaBg
    local scenery = fg and room.sceneryFg or room.sceneryBg

    local roomName = room.name
    local cache = roomCache[roomName]

    if not cache then
        cache = {}
        roomCache[roomName] = cache
    end

    if not cache[key]then
        cache[key] = tasks.newTask(
            (-> celesteRender.getTilesBatch(room, tiles, meta, scenery, fg)),
            (task -> PRINT_BATCHING_DURATION and logging.info(string.format("Batching '%s' in '%s' took %s ms", key, room.name, task.timeTotal * 1000))),
            batchingTasks,
            {room = room}
        )
    end

    return cache[key].result
end

function celesteRender.getTilesFgBatch(room, tiles, viewport)
    return getRoomTileBatch(room, tiles, true)
end

function celesteRender.getTilesBgBatch(room, tiles, viewport)
    return getRoomTileBatch(room, tiles, false)
end

local function getObjectTilesBatchTaskFunc(room, objectTiles)
    local objectMatrix = objectTiles and objectTiles.matrix
    local sceneryMeta = celesteRender.getSceneryMeta()

    if not objectMatrix or not sceneryMeta then
        return getTilesBatchFromMode(1, 1, "matrixDrawingBatch")
    end

    local width, height = objectMatrix:size()

    if width <= 0 or height <= 0 then
        return getTilesBatchFromMode(1, 1, "matrixDrawingBatch")
    end

    local batch = getTilesBatchFromMode(width, height, "matrixDrawingBatch")

    for x = 1, width do
        for y = 1, height do
            local tile = objectMatrix:getInbounds(x, y, -1)

            if tile and tile >= 0 then
                local quad = celesteRender.getOrCacheScenerySpriteQuad(tile)

                if quad then
                    batch:set(x, y, sceneryMeta, quad, x * 8 - 8, y * 8 - 8)
                end
            end
        end
    end

    return batch
end

function celesteRender.getObjectTilesBatch(room, objectTiles, viewport)
    local objectMatrix = objectTiles and objectTiles.matrix

    if not objectMatrix then
        return nil
    end

    local width, height = objectMatrix:size()

    if width <= 0 or height <= 0 then
        return nil
    end

    local cache = roomCache[room.name]

    if not cache then
        cache = {}
        roomCache[room.name] = cache
    end

    if not cache.sceneryObj then
        cache.sceneryObj = {
            result = getObjectTilesBatchTaskFunc(room, objectTiles)
        }
    end

    return cache.sceneryObj.result
end

local function getDecalsBatchTaskFunc(decals, room, fg, viewport)
    local batches = {}

    for i, decal in ipairs(decals) do
        local renderDecal = decalHandler.renderFilterPredicate(room, decal, fg)

        if renderDecal then
            local texture = decal.texture
            local drawable, depth = decalHandler.getDrawable(texture, nil, room, decal, viewport)

            if drawable then
                local defaultDepth = fg and decalsFgDepth or decalsBgDepth
                local batchDepth = depth or defaultDepth
                local batch = getOrCreateSmartBatch(batches, batchDepth)

                batch:addFromDrawable(drawable)
            end
        end

        if i % YIELD_RATE == 0 then
            tasks.yield()
        end
    end

    tasks.update(batches)

    return batches
end

local function getRoomDecalsBatch(room, decals, fg, viewport)
    local key = fg and "decalsFg" or "decalsBg"

    local roomName = room.name
    local cache = roomCache[roomName]

    if not cache then
        cache = {}
        roomCache[roomName] = cache
    end

    if not cache[key]then
        cache[key] = tasks.newTask(
            (-> getDecalsBatchTaskFunc(decals, room, fg, viewport)),
            (task -> PRINT_BATCHING_DURATION and logging.info(string.format("Batching '%s' in '%s' took %s ms", key, room.name, task.timeTotal * 1000))),
            batchingTasks,
            {room = room}
        )
    end

    return cache[key].result
end

function celesteRender.getDecalsFgBatch(room, decals, viewport)
    return getRoomDecalsBatch(room, decals, true)
end

function celesteRender.getDecalsBgBatch(room, decals, viewport)
    return getRoomDecalsBatch(room, decals, false)
end

function celesteRender.drawDecalsFg(room, decals)
    local batch = celesteRender.getDecalsFgBatch(room, decals)

    if batch then
        love.graphics.draw(batch, 0, 0)
    end
end

function celesteRender.drawDecalsBg(room, decals)
    local batch = celesteRender.getDecalsBgBatch(room, decals)

    if batch then
        love.graphics.draw(batch, 0, 0)
    end
end

local function getEntityBatchTaskFunc(room, entities, viewport, registeredEntities)
    local batches = {}
    local textDrawables = {}

    for i, entity in ipairs(entities) do
        local name = entity._name
        local handler = registeredEntities[name]

        if handler then
            local renderEntity = entityHandler.renderFilterPredicate(room, entity)

            if renderEntity then
                local drawable, depth = entityHandler.getDrawable(name, handler, room, entity, viewport)

                -- Special case for multiple drawable sprites
                -- Maybe handle this better later
                if drawable then
                    if utils.typeof(drawable) ~= "table" then
                        addDrawableToBatchOrText(batches, textDrawables, drawable, depth)

                    else
                        for _, drawableItem in ipairs(drawable) do
                            addDrawableToBatchOrText(batches, textDrawables, drawableItem, depth)
                        end
                    end
                end

                if i % YIELD_RATE == 0 then
                    tasks.yield()
                end
            end
        end
    end

    tasks.update(batches)

    local overlays = roomTextOverlays[room.name] or {}
    sortTextDrawables(textDrawables)
    overlays.entities = textDrawables
    roomTextOverlays[room.name] = overlays

    return batches
end

function celesteRender.getEntityBatch(room, entities, viewport, registeredEntities, forceRedraw)
    registeredEntities = registeredEntities or entityHandler.registeredEntities

    local roomName = room.name
    local cache = roomCache[roomName]

    if not cache then
        cache = {}
        roomCache[roomName] = cache
    end

    if forceRedraw and cache.entities.result ~= nil then
        cache.entities = nil
    end

    if not cache.entities then
        cache.entities = tasks.newTask(
            (-> getEntityBatchTaskFunc(room, entities, viewport, registeredEntities)),
            (task -> PRINT_BATCHING_DURATION and logging.info(string.format("Batching 'entities' in '%s' took %s ms", room.name, task.timeTotal * 1000))),
            batchingTasks,
            {room = room}
        )
    end

    return cache.entities.result
end

local function getTriggerBatchTaskFunc(room, triggers, viewport, registeredTriggers)
    local batches = {}
    local textDrawables = {}

    for i, trigger in ipairs(triggers) do
        local name = trigger._name
        local handler = registeredTriggers[name]

        if handler then
            local renderTrigger = triggerHandler.renderFilterPredicate(room, trigger)

            if renderTrigger then
                local drawable, depth = triggerHandler.getDrawable(name, handler, room, trigger, viewport)

                -- Special case for multiple drawable sprites
                -- Maybe handle this better later
                if drawable then
                    if utils.typeof(drawable) ~= "table" then
                        addDrawableToBatchOrText(batches, textDrawables, drawable, depth)

                    else
                        for _, drawableItem in ipairs(drawable) do
                            addDrawableToBatchOrText(batches, textDrawables, drawableItem, depth)
                        end
                    end
                end

                if i % YIELD_RATE == 0 then
                    tasks.yield()
                end
            end
        end
    end

    tasks.update(batches)

    local overlays = roomTextOverlays[room.name] or {}
    sortTextDrawables(textDrawables)
    overlays.triggers = textDrawables
    roomTextOverlays[room.name] = overlays

    return batches
end

function celesteRender.getTriggerBatch(room, triggers, viewport, registeredTriggers, forceRedraw)
    registeredTriggers = registeredTriggers or triggerHandler.registeredTriggers

    -- Lay out the trigger labels for this room (cached until the triggers change)
    require("trigger_text").updateRoom(room, triggers)

    local roomName = room.name
    local cache = roomCache[roomName]

    if not cache then
        cache = {}
        roomCache[roomName] = cache
    end

    if forceRedraw and cache.triggers.result ~= nil then
        cache.triggers = nil
    end

    if not cache.triggers then
        cache.triggers = tasks.newTask(
            (-> getTriggerBatchTaskFunc(room, triggers, viewport, registeredTriggers)),
            (task -> PRINT_BATCHING_DURATION and logging.info(string.format("Batching 'triggers' in '%s' took %s ms", roomName, task.timeTotal * 1000))),
            batchingTasks,
            {room = room}
        )
    end

    return cache.triggers.result
end

local depthBatchingFunctions = {
    {"Background Tiles", "tilesBg", celesteRender.getTilesBgBatch, tilesBgDepth},
    {"Background Decals", "decalsBg", celesteRender.getDecalsBgBatch},
    {"Entities", "entities", celesteRender.getEntityBatch},
    {"Foreground Tiles", "tilesFg", celesteRender.getTilesFgBatch, tilesFgDepth},
    {"Objects", "sceneryObj", celesteRender.getObjectTilesBatch, depths.fgTerrain - 1},
    {"Foreground Decals", "decalsFg", celesteRender.getDecalsFgBatch},
    {"Triggers", "triggers", celesteRender.getTriggerBatch}
}

-- Force all non finished room batch tasks to finish
function celesteRender.forceRoomBatchRender(room, state)
    local viewport = state.viewport

    for i, data in ipairs(depthBatchingFunctions) do
        local description, key, func, depth = data[1], data[2], data[3], data[4]
        local layerVisible = state.getLayerShouldRender(key)
        local result = func(room, room[key], viewport)
        local task = roomCache[room.name][key]

        if layerVisible and not result and task then
            tasks.processTask(task)
        end
    end
end

local function addBatch(depthBatches, depth, batches)
    local batchTarget = depthBatches[depth]
    local batchesIsTable = utils.typeof(batches) == "table"

    if batchTarget then
        if batchesIsTable then
            for _, sprite in ipairs(batches) do
                table.insert(batchTarget, sprite)
            end

        else
            table.insert(batchTarget, batches)
        end

    else
        if batchesIsTable then
            depthBatches[depth] = batches

        else
            depthBatches[depth] = {batches}
        end
    end
end

function celesteRender.getRoomBatches(room, state)
    local roomName = room.name
    local cache = roomCache[roomName]
    local viewport = state.viewport

    if not cache then
        cache = {}
        roomCache[roomName] = cache
    end

    if not cache.complete then
        local depthBatches = {}
        local done = true

        for i, data in ipairs(depthBatchingFunctions) do
            local description, key, func, depth = data[1], data[2], data[3], data[4]
            local layerVisible = state.getLayerShouldRender(key)
            local batches

            if layerVisible then
                batches = func(room, room[key], viewport)
            end

            if batches then
                local batchesIsTable = utils.typeof(batches) == "table"

                if not batchesIsTable then
                    addBatch(depthBatches, depth or 0, batches)

                else
                    for d, batch in pairs(batches) do
                        addBatch(depthBatches, d, batch)
                    end
                end

            else
                local optionalObjectLayer = key == "sceneryObj"

                if optionalObjectLayer then
                    local objectMatrix = room[key] and room[key].matrix
                    local width, height = objectMatrix and objectMatrix:size()

                    optionalObjectLayer = not width or width <= 0 or not height or height <= 0
                end

                if layerVisible and not optionalObjectLayer then
                    done = false
                end
            end
        end

        -- Not done, but all the tasks have been started
        -- Attempt to render other rooms while we wait
        if not done then
            return false
        end

        local orderedBatches = {}

        for depth, batches in pairs(depthBatches) do
            table.insert(orderedBatches, {depth, batches})
        end

        table.sort(orderedBatches, function(lhs, rhs)
            return lhs[1] > rhs[1]
        end)

        for i, pair in ipairs(orderedBatches) do
            orderedBatches[i] = pair[2]
        end

        cache.complete = orderedBatches
        roomTextReady[roomName] = true
    end

    return cache.complete
end

local function drawRoomFromBatches(room, state, selected)
    local orderedBatches = celesteRender.getRoomBatches(room, state)

    if orderedBatches then
        for _, batch in ipairs(orderedBatches) do
            for _, drawable in ipairs(batch) do
                drawable:draw()
            end
        end
    end
end

-- Unselected rooms are cached in a canvas at room resolution. The hi-res font
-- is drawn at half scale, which would be sampled unevenly at 1:1, so the canvas
-- is rendered at the inverse scale and drawn back at the font scale: an exact
-- 2x downsample, which keeps text as crisp as the selected rooms.
local function canvasResolutionScale()
    local pixelFactor = fonts.pixelFactor or 1

    if pixelFactor <= 0 or pixelFactor >= 1 then
        return 1
    end

    return math.max(1, math.floor(1 / pixelFactor + 0.5))
end

-- Resolution the room canvases are rendered at, 1 unless the hi-res font is used
function celesteRender.getCanvasResolutionScale()
    return canvasResolutionScale()
end

-- Return the canvas if it is ready, otherwise make a task for it
local function getRoomCanvas(room, state, selected)
    local viewport = state.viewport
    local orderedBatches = celesteRender.getRoomBatches(room, state)
    local roomName = room.name

    local cache = roomCache[roomName]

    if not cache then
        cache = {}
        roomCache[roomName] = cache
    end

    if orderedBatches and not cache.canvas then
        local resolutionScale = canvasResolutionScale()

        cache.canvas = tasks.newTask(
            function(task)
                local canvas = love.graphics.newCanvas((room.width or 0) * resolutionScale, (room.height or 0) * resolutionScale)

                canvas:renderTo(function()
                    if resolutionScale ~= 1 then
                        love.graphics.push()
                        love.graphics.scale(resolutionScale, resolutionScale)
                    end

                    for depth, batch in ipairs(orderedBatches) do
                        for _, drawable in ipairs(batch) do
                            drawable:draw()
                        end
                    end

                    if resolutionScale ~= 1 then
                        love.graphics.pop()
                    end
                end)

                tasks.update(canvas)
            end,
            nil,
            batchingTasks,
            {room = room}
        )
    end

    return cache.canvas and cache.canvas.result, cache.canvas
end

-- Force the rooms canvas cache to be rendered
function celesteRender.forceRoomCanvasRender(room, state, selected)
    -- Selected rooms are drawn from their live batches, not from the canvas cache.
    if selected then
        return
    end

    local canvas, task = getRoomCanvas(room, state, selected)

    if not canvas and task then
        tasks.processTask(task)
    end
end

function celesteRender.forceRedrawRoom(room, state, selected)
    local viewport = state.viewport

    celesteRender.invalidateRoomCache(room, {"canvas", "complete"})
    celesteRender.forceRoomBatchRender(room, state)
    celesteRender.forceRoomCanvasRender(room, state, selected)
end

function celesteRender.forceRedrawVisibleRooms(rooms, state, selectedItem, selectedItemType)
    local viewport = state.viewport

    for _, room in ipairs(rooms) do
        local roomVisible = viewportHandler.roomVisible(room, viewport)
        local roomVisibleWidth, roomVisibleHeight = viewportHandler.getRoomVisibleSize(room, viewport)
        local selected = room == selectedItem

        if selectedItemType == "table" then
            selected = selectedItem[room]
        end

        -- No need to redraw immidietly if only the borders are visible
        if roomVisible and roomVisibleWidth > 2 and roomVisibleHeight > 2 then
            celesteRender.forceRoomBatchRender(room, state)
            celesteRender.forceRoomCanvasRender(room, state, selected)
        end
    end
end

function celesteRender.drawRooms(rooms, state, selectedItem, selectedItemType)
    local viewport = state.viewport

    for _, room in ipairs(rooms) do
        local roomVisible = viewportHandler.roomVisible(room, viewport)
        local selected = room == selectedItem

        if selectedItemType == "table" then
            selected = selectedItem[room]
        end

        if ALLOW_NON_VISIBLE_BACKGROUND_DRAWING or roomVisible then
            celesteRender.drawRoom(room, state, selected, roomVisible)
        end
    end
end

-- Screen-space text rendering for the smooth TTF option. The label is positioned from its room
-- coordinates, but the font is rasterized at the final screen size instead of being drawn through
-- the viewport transform or into a room canvas.
local function drawScreenText(drawable, room, viewport)
    if drawable._type == "drawableScreenText" then
        -- A mod called printCenteredText through a drawable function. Preserve its font and
        -- relative size, but lay it out and rasterize it in this screen-space pass.
        drawable.font = drawable.font or fonts.getTriggerFont()
        drawable.layoutFont = drawable.layoutFont or drawable.font
        drawable.layoutFontSize = drawable.layoutFontSize or drawable.fontSize or 1

        if configs.font.addShadowToFont and not drawable._screenShadow then
            -- Match the trigger-label shadow: draw the same text offset by one label pixel, in
            -- black, behind the main drawable. Placement previews use draw() directly and do not
            -- get this pass.
            local shadow = {}

            for key, value in pairs(drawable) do
                shadow[key] = value
            end

            local offset = math.max(1, drawable.fontSize or 1)

            shadow._screenShadow = true
            shadow.x = drawable.x + offset
            shadow.y = drawable.y + offset
            shadow.color = {0, 0, 0, 1}

            drawScreenText(shadow, room, viewport)
        end
    end

    local scale = viewport.scale or 1
    local font = drawable.font
    local fontSize = drawable.fontSize or 1

    if not font or font == fonts.font then
        font = fonts.getTriggerFont()
    end

    local layoutFont = drawable.layoutFont or fonts.font
    local layoutFontSize = drawable.layoutFontSize or fontSize
    local drawX, drawY, drawWidth, drawHeight = drawable.x, drawable.y, drawable.width,
        drawable.height

    if drawable._type == "drawableScreenText" then
        -- Keep whole words visible instead of letting getWrap split them. This is the same
        -- center-stretching layout trigger labels use; extrusion is intentionally not applied.
        drawX, drawY, drawWidth, drawHeight = textLayout.stretchRect(drawX, drawY, drawWidth,
            drawHeight, drawable.text, layoutFontSize, layoutFont)
    end

    local x = ((room.x or 0) + drawX) * scale - viewport.x
    local y = ((room.y or 0) + drawY) * scale - viewport.y
    local width = drawWidth * scale
    local height = drawHeight * scale
    local screenSize = math.max(1, math.floor(
        layoutFont:getHeight() * layoutFontSize * scale + 0.5))
    local layoutLines = drawable.layoutLines

    if drawable._type == "drawableScreenText" or not layoutLines then
        layoutLines = {}

        for index, line in ipairs(textLayout.getLines(drawable.text, drawWidth, layoutFont,
            layoutFontSize)) do
            layoutLines[index] = {
                text = utils.trim(line)
            }
        end

        drawable.layoutLines = layoutLines
    end

    local screenFont = fonts.getScreenFont(screenSize, font)
    local lineHeight = screenFont:getHeight() * screenFont:getLineHeight()
    local textHeight = (#layoutLines - 1) * lineHeight + screenFont:getHeight()
    local offsetY = math.floor((height - textHeight) / 2 + 0.5)

    drawing.callKeepOriginalColor(function()
        if drawable.color then
            love.graphics.setColor(drawable.color)
        end

        local previousFont = love.graphics.getFont()

        love.graphics.setFont(screenFont)

        for index, line in ipairs(layoutLines) do
            local lineWidth = screenFont:getWidth(line.text)
            local lineX = math.floor((width - lineWidth) / 2 + 0.5)
            local lineY = math.floor(y + offsetY + (index - 1) * lineHeight + 0.5)

            love.graphics.print(line.text, math.floor(x + lineX + 0.5), lineY)
        end

        love.graphics.setFont(previousFont)
    end)
end

-- Draw all labels as one final screen-space pass, above every room and room border. This is the
-- UI-like part: labels are not attached to a room canvas or room draw order.
local function isTextOnScreen(drawable, room, viewport, selected)
    local drawWidth = drawable.width or 0
    local drawHeight = drawable.height or 0
    local screenWidth = drawWidth * viewport.scale
    local screenHeight = drawHeight * viewport.scale
    local screenX = ((room.x or 0) + drawable.x) * viewport.scale - viewport.x
    local screenY = ((room.y or 0) + drawable.y) * viewport.scale - viewport.y

    if screenX + screenWidth < 0 or screenY + screenHeight < 0
        or screenX > viewport.width or screenY > viewport.height then
        return false
    end

    -- Unselected rooms are already clipped by the room scissor. Requiring the whole label to
    -- stay inside the room bounds made extruded labels disappear while their offset shadow
    -- could still intersect the room, so only visibility in the viewport matters here.
    return true
end

local function drawScreenTexts(rooms, state)
    local viewport = state.viewport
    local selectedItem, selectedItemType = state.getSelectedItem()

    local function isSelected(room)
        return selectedItem == room
            or (selectedItemType == "table" and selectedItem and selectedItem[room] ~= nil)
    end

    -- This pass is in screen coordinates. A mod entity or room drawable may have leaked a
    -- transform/scale; isolate the pass so labels cannot inherit it and become enormous.
    love.graphics.push("all")
    love.graphics.origin()

    for _, room in ipairs(rooms) do
        local overlays = roomTextOverlays[room.name]

        if overlays and roomTextReady[room.name] then
            local selected = isSelected(room)
            local roomVisible = selected or viewportHandler.roomVisible(room, viewport)

            if roomVisible then
                local scissorX, scissorY, scissorWidth, scissorHeight
                local useScissor = not selected

                if useScissor then
                    scissorX = math.floor((room.x or 0) * viewport.scale - viewport.x)
                    scissorY = math.floor((room.y or 0) * viewport.scale - viewport.y)
                    scissorWidth = math.ceil((room.width or 0) * viewport.scale)
                    scissorHeight = math.ceil((room.height or 0) * viewport.scale)
                    love.graphics.setScissor(scissorX, scissorY, scissorWidth, scissorHeight)
                end

                local screenTextLayers = state.skipTriggerScreenText and {"entities"} or {"entities", "triggers"}

                for _, layerName in ipairs(screenTextLayers) do
                    for _, drawable in ipairs(overlays[layerName] or {}) do
                        if isTextOnScreen(drawable, room, viewport, selected) then
                            drawScreenText(drawable, room, viewport)
                        end
                    end
                end

                if useScissor then
                    love.graphics.setScissor()
                end
            end
        end
    end

    love.graphics.pop()
end

function celesteRender.drawRoom(room, state, selected, visible)
    -- Getting the canvas starts background drawing tasks
    -- This should start regardless of the room being visible or not
    local redrawRoom = selected or ALWAYS_REDRAW_UNSELECTED_ROOMS
    local viewport = state.viewport
    local canvas = not redrawRoom and getRoomCanvas(room, state, selected)

    if visible or selected then
        local roomX = room.x or 0
        local roomY = room.y or 0

        local width = room.width or 40 * 8
        local height = room.height or 23 * 8

        local roomVisibleWidth, roomVisibleHeight = viewportHandler.getRoomVisibleSize(room, viewport)

        local backgroundColor = celesteRender.getRoomBackgroundColor(room, selected, state)
        local borderColor = celesteRender.getRoomBorderColor(room, selected, state)

        viewportHandler.drawRelativeTo(roomX, roomY, function()
            if backgroundColor then
                drawing.callKeepOriginalColor(function()
                    love.graphics.setColor(backgroundColor)
                    love.graphics.rectangle("fill", 0, 0, width, height)
                end)
            end

            if redrawRoom then
                drawRoomFromBatches(room, state, selected)

            else
                if canvas then
                    -- No need to draw the canvas if we can only see the border
                    if roomVisibleWidth > 2 and roomVisibleHeight > 2 then
                        local resolutionScale = canvasResolutionScale()

                        love.graphics.draw(canvas, 0, 0, 0, 1 / resolutionScale, 1 / resolutionScale)
                    end
                end
            end

            if borderColor then
                drawing.callKeepOriginalColor(function()
                    love.graphics.setColor(borderColor)
                    love.graphics.rectangle("line", 0, 0, width, height)
                end)
            end
        end, viewport)
    end
end

-- Iterate over twice
-- Batch draw all selected and unselected fillers
function celesteRender.drawFillers(fillers, state, selectedItem, selectedItemType)
    local pr, pb, pg, pa = love.graphics.getColor()
    local multipleSelections = selectedItemType == "table"
    local viewport = state.viewport

    -- Unselected fillers
    love.graphics.setColor(colors.fillerColor)

    for i, filler in ipairs(fillers) do
        if not (multipleSelections and selectedItem[filler] or selectedItem == filler) then
            if viewportHandler.fillerVisible(filler, viewport) then
                celesteRender.drawFiller(filler, viewport)
            end
        end
    end

    -- Selected fillers
    love.graphics.setColor(colors.fillerSelectedColor)

    for i, filler in ipairs(fillers) do
        if multipleSelections and selectedItem[filler] or selectedItem == filler then
            if viewportHandler.fillerVisible(filler, viewport) then
                celesteRender.drawFiller(filler, viewport)
            end
        end
    end

    love.graphics.setColor(pr, pb, pg, pa)
end

function celesteRender.drawFiller(filler, viewport)
    local x = filler.x * 8
    local y = filler.y * 8

    local width = filler.width * 8
    local height = filler.height * 8

    viewportHandler.drawRelativeTo(x, y, function()
        love.graphics.rectangle("fill", 0, 0, width, height)
    end, viewport)
end

function celesteRender.drawMap(state)
    if state and state.map then
        local map = state.map
        local viewport = state.viewport

        if viewport.visible then
            local selectedItem, selectedItemType = state.getSelectedItem()

            celesteRender.drawFillers(map.fillers, state, selectedItem, selectedItemType)
            celesteRender.drawRooms(map.rooms, state, selectedItem, selectedItemType)
            drawScreenTexts(map.rooms, state)
        end
    end
end

celesteRender.drawScreenTexts = drawScreenTexts

modificationWarner.addModificationWarner(celesteRender)

return celesteRender