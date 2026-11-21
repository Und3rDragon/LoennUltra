local osUtils = require("utils.os")

local threadHandler = {}

threadHandler._threads = {}

-- Threads have their own Lua state and therefore load C libraries themselves.
-- A bare require("nfd") is resolved relative to the working directory, which
-- Lönn changes temporarily for file operations, so give every thread an
-- absolute cpath for the directories the executable and the game live in.
local function cpathPrologue()
    local directories = {}

    local successBase, sourceBase = pcall(love.filesystem.getSourceBaseDirectory)

    if successBase and sourceBase then
        table.insert(directories, (sourceBase:gsub("\\", "/")))
    end

    local successSource, source = pcall(love.filesystem.getSource)

    if successSource and source then
        table.insert(directories, (source:gsub("\\", "/")))
    end

    if #directories == 0 then
        return ""
    end

    local extension = (osUtils.getOS() ~= "Windows") and "so" or "dll"

    local quoted = {}

    for _, directory in ipairs(directories) do
        table.insert(quoted, string.format("%q", directory))
    end

    return string.format(
        "for _, dir in ipairs({%s}) do package.cpath = package.cpath .. \";\" .. dir .. \"/?." .. extension .. "\" end\n",
        table.concat(quoted, ", "))
end

function threadHandler.createStartWithCallback(threadCode, callback, ...)
    local thread = love.thread.newThread(cpathPrologue() .. threadCode)
    local channel = love.timer.getTime()

    threadHandler._threads[channel] = {thread = thread, callback = callback, channel = channel}
    thread:start(channel, ...)

    return channel, thread
end

function threadHandler.release(channelName)
    if threadHandler._threads[channelName] then
        local channel = love.thread.getChannel(channelName)
        local thread = threadHandler._threads[channelName].thread

        channel:release()
        thread:release()

        threadHandler._threads[channelName] = nil
    end
end

local function runFunctionOnData(channel, func)
    while true do
        local res = channel:pop()

        if res ~= nil then
            func(res)

        else
            break
        end
    end
end

function threadHandler.update(dt)
    local removed = {}

    for channelName, data <- threadHandler._threads do
        local thread = data.thread
        local callback = data.callback or function() end
        local channel = love.thread.getChannel(channelName)

        runFunctionOnData(channel, callback)

        if not thread:isRunning() then
            table.insert(removed, channelName)
        end
    end

    for i, channelName <- removed do
        threadHandler.release(channelName)
    end
end

return threadHandler