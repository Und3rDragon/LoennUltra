local timeline = require("structs.timeline")
local configs = require("configs")
local sceneHandler = require("scene_handler")
local logging = require("logging")

local history = {}

-- Diagnostic logging for the "undo needs several presses" / "undo did not repaint" reports.
-- logging.log's 4th argument forces an immediate flush; the default flush level is ERROR only.
local function diagLog(message)
    pcall(logging.log, "INFO", message, nil, true)
end

history.madeChanges = false
history.lastChange = 0
history.timeline = timeline.create()

function history.reset()
    history.madeChanges = false
    history.lastChanged = 0
    history.timeline = timeline.create(configs.editor.historyEntryLimit)

    diagLog(string.format("[diag] history.reset limit=%s", tostring(configs.editor.historyEntryLimit)))
end

function history.undo()
    local ok = history.timeline:backward()

    diagLog(string.format("[diag] history.undo ok=%s index=%s",
        tostring(ok), tostring(history.timeline.index)))

    if ok then
        history.madeChanges = true
        history.lastChange = os.time()

    else
        sceneHandler.sendEvent("editorHistoryUndoEmpty")
    end
end

function history.redo()
    local ok = history.timeline:forward()

    diagLog(string.format("[diag] history.redo ok=%s index=%s",
        tostring(ok), tostring(history.timeline.index)))

    if ok then
        history.madeChanges = true
        history.lastChange = os.time()

    else
        sceneHandler.sendEvent("editorHistoryRedoEmpty")
    end
end

function history.addSnapshot(snapshot)
    diagLog(string.format("[diag] history.push desc=%q index=%s",
        tostring(snapshot and snapshot.description), tostring(history.timeline.index)))

    history.madeChanges = true
    history.lastChange = os.time()

    history.timeline:addSnapshot(snapshot)
end

return history
