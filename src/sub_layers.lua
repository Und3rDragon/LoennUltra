local loadedState = require("loaded_state")

local subLayers = {}

-- Parse layer name with sublayer baked in
function subLayers.parseLayerName(layerName)
    local layer, subLayerString = string.match(layerName, "(%w*)_(-?%d*)")

    if layer then
        return layer, tonumber(subLayerString)
    end

    return layerName, -1
end

function subLayers.formatLayerName(layer, subLayer)
    if subLayer and subLayer ~= -1 then
        return string.format("%s_%s", layer, subLayer)
    end

    return layer
end

function subLayers.getShouldLayerRender(layer, subLayer)
    subLayer = subLayer or -1

    if not loadedState.getLayerShouldRender(layer) then
        return false
    end

    if subLayer == -1 then
        return true
    end

    return loadedState.getLayerVisible(subLayers.formatLayerName(layer, subLayer))
end

function subLayers.getLayerVisible(layer, subLayer)
    local layerName = subLayers.formatLayerName(layer, subLayer or -1)

    return loadedState.getLayerVisible(layerName)
end

function subLayers.setLayerVisible(layer, subLayer, visible, silent)
    local layerName = subLayers.formatLayerName(layer, subLayer or -1)

    return loadedState.setLayerVisible(layerName, visible, silent)
end

function subLayers.getLayerName(layer, subLayer)
    local layerName = subLayers.formatLayerName(layer, subLayer)

    return loadedState.getLayerName(layerName)
end

function subLayers.setLayerName(layer, subLayer, name)
    local layerName = subLayers.formatLayerName(layer, subLayer)

    return loadedState.setLayerName(layerName, name)
end

return subLayers