local drawableFunction = {}

local function isPrintCenteredText(func)
    local ok, drawing = pcall(require, "utils.drawing")

    return ok and drawing.printCenteredText == func
end

function drawableFunction.fromFunction(func, ...)
    -- Keep the argument count before the values are put in a table. A nil in the middle of an
    -- argument list (for example the optional font before a fontSize) makes #args stop early, so
    -- unpack(args) would silently drop every argument after the nil.
    local args = {...}
    local argCount = select("#", ...)

    -- printCenteredText is the common way mods put a label on a room object. Route it through the
    -- same deferred screen-space pass as trigger labels instead of rasterizing it through the
    -- room/viewport transform. That keeps the selected font and keeps small text crisp.
    if isPrintCenteredText(func) then
        local drawable = {
            _type = "drawableScreenText",
            text = args[1],
            x = args[2],
            y = args[3],
            width = args[4],
            height = args[5],
            font = args[6],
            fontSize = args[7],
            trim = args[8]
        }

        drawable.draw = function(self)
            require("utils.drawing").printCenteredText(self.text, self.x, self.y, self.width,
                self.height, self.font, self.fontSize, self.trim)
        end

        return drawable
    end

    local drawable = {
        _type = "drawableFunction"
    }

    drawable.func = func
    drawable.args = args
    drawable.argCount = argCount
    drawable.draw = function(self)
        local count = math.max(self.argCount or 0, #self.args)
        self.func(unpack(self.args, 1, count))
    end

    return drawable
end

return drawableFunction