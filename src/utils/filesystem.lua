local lfs = require("lib.lfs_ffi")
local physfs = require("lib.physfs")
local requireUtils = require("utils.require")
local threadHandler = require("utils.threads")
local osUtils = require("utils.os")
local logging = require("logging")

local hasRequest, request = requireUtils.tryrequire("lib.luajit-request.luajit-request")

local function toUnixPath(path)
    return (path:gsub("\\", "/"))
end

-- Candidate directories for nfd.dll: the directory the executable lives in and
-- the game source directory. Absolute on purpose, because relative lookups
-- depend on the working directory, which Lönn changes temporarily for file
-- operations (and threads inherit it).
local function dialogDirectories()
    local directories = {}

    local successBase, sourceBase = pcall(love.filesystem.getSourceBaseDirectory)

    if successBase and sourceBase then
        table.insert(directories, toUnixPath(sourceBase))
    end

    local successSource, source = pcall(love.filesystem.getSource)

    if successSource and source then
        table.insert(directories, toUnixPath(source))
    end

    return directories
end

local nfd

-- Loads nfd from an absolute path so it does not depend on the working
-- directory. Threads get the same absolute cpath from utils/threads.lua.
local function prepareNfd()
    if nfd then
        return nfd
    end

    local originalCpath = package.cpath
    local nfdExtension = (osUtils.getOS() ~= "Windows") and "so" or "dll"

    for _, directory in ipairs(dialogDirectories()) do
        package.cpath = package.cpath .. ";" .. directory .. "/?." .. nfdExtension
    end

    local success, module = pcall(require, "nfd")

    package.cpath = originalCpath

    if success and type(module) == "table" then
        nfd = module
    else
        logging.warning("Could not load 'nfd', file dialogs will not work: " .. tostring(module))
    end

    return nfd
end

prepareNfd()

local filesystem = {}

function filesystem.supportWindowsInThreads()
    return osUtils.getOS() ~= "OS X"
end

function filesystem.filename(path, sep)
    sep = sep or physfs.getDirSeparator()

    return path:match("[^" .. sep .. "]+$")
end

function filesystem.dirname(path, sep)
    sep = sep or physfs.getDirSeparator()

    return path:match("(.*" .. sep .. ")")
end

function filesystem.joinpath(...)
    local paths = {...}
    local sep = physfs.getDirSeparator()

    local userOS = osUtils.getOS()
    local usingWindows = userOS == "Windows"

    -- Check for table argument
    if type(paths[1]) == "table" then
        paths = paths[1]
    end

    local result = ""

    -- table.concat fails for unknown reasons, manually build
    for i, part in pairs(paths) do
        result ..= part

        if i ~= #paths then
            result ..= sep
        end
    end

    -- Replace unix separator with Windows ones
    -- This is just to aid double separator removal, and because Windows accepts both
    if usingWindows then
        result = result:gsub("/", "\\")
    end

    -- Remove double separators
    result = result:gsub(sep .. sep, sep)

    return result
end

function filesystem.splitpath(path, sep)
    sep = sep or physfs.getDirSeparator()

    return string.split(path, sep)()
end

function filesystem.convertToUnixPath(path)
    return path:gsub("\\", "/")
end

function filesystem.samePath(path1, path2, useUnixSeparator, ignoreTrailingSeparator)
    local parts1
    local parts2

    local userOS = osUtils.getOS()
    local usingWindows = userOS == "Windows"
    local separator = physfs.getDirSeparator()

    if path1 == path2 then
        return true
    end

    if usingWindows and useUnixSeparator ~= false then
        path1 = filesystem.convertToUnixPath(path1)
        path2 = filesystem.convertToUnixPath(path2)

        separator = "/"

        if path1 == path2 then
            return true
        end
    end

    if ignoreTrailingSeparator ~= false then
        if path1:sub(-#separator, -1) == separator then
            path1 = path1:sub(1, #path1 - #separator)
        end

        if path2:sub(-#separator, -1) == separator then
            path2 = path2:sub(1, #path2 - #separator)
        end
    end

    if path1 == path2 then
        return true
    end

    return false
end

-- Maunal iteration for performance
-- String matching is expensive
function filesystem.fileExtension(path)
    for i = #path, 1, -1 do
        if path:byte(i, i) == 46 then
            return path:sub(i + 1, #path)
        end
    end

    return path
end

-- Maunal iteration for performance
-- String matching or getting ext just to sub is expensive
function filesystem.stripExtension(path)
    for i = #path, 1, -1 do
        if path:byte(i, i) == 46 then
            return path:sub(1, i - 1)
        end
    end

    return path
end

-- Maunal iteration for performance
-- String matching or getting ext just to sub is expensive
-- Extension is returned without the dot
function filesystem.splitExtension(path)
    for i = #path, 1, -1 do
        if path:byte(i, i) == 46 then
            return path:sub(1, i - 1), path:sub(i + 1)
        end
    end

    return path, nil
end

function filesystem.mkdir(path, mode)
    return lfs.mkdir(path, mode or 493) -- octal mode 755
end

function filesystem.mkpath(path, mode)
    local isWindows = osUtils.getOS() == "Windows"
    local parts = filesystem.splitpath(path)
    local seenParts = {}

    local startIndex = 1
    local endIndex = #parts

    -- Don't attempt to create directory with empty string name or Windows drive letters
    if parts[1] == "" or (isWindows and parts[1]:sub(-1) == ":") then
        table.insert(seenParts, parts[1])

        startIndex = 2
    end

    -- Skip trailing slashes
    if parts[endIndex] == "" then
        endIndex -= 1
    end

    for i = startIndex, endIndex do
        local part = parts[i]
        table.insert(seenParts, part)
        local subPath = filesystem.joinpath(seenParts)

        if not filesystem.isDirectory(subPath) then
            local success, message = filesystem.mkdir(subPath, mode)

            if not success then
                return success, message
            end
        end
    end

    return true
end

filesystem.chdir = lfs.chdir
filesystem.dir = lfs.dir
filesystem.rmdir = lfs.rmdir

-- Remove and rename must cd to correct path to prevent issues with non ascii characters in path
function filesystem.changeDirectoryThenCallback(func, path, ...)
    local previousCwd = filesystem.currentDirectory()
    local dirname = filesystem.dirname(path)
    local filename = filesystem.filename(path)

    filesystem.chdir(dirname)

    -- pcall so the working directory is restored even when the callback fails:
    -- a stuck working directory breaks every relative path lookup afterwards
    local results = {pcall(func, filename, ...)}

    filesystem.chdir(previousCwd)

    if not results[1] then
        error(results[2], 0)
    end

    return unpack(results, 2)
end

function filesystem.remove(path)
    return filesystem.changeDirectoryThenCallback(function(filename)
        return os.remove(filename)
    end, path)
end

-- Only works if both files are in same directory
function filesystem.rename(from, to)
    return filesystem.changeDirectoryThenCallback(function(filename)
        return os.rename(filename, filesystem.filename(to))
    end, from)
end

-- Removes a file or a whole directory tree. Returns true when the target is
-- gone afterwards.
function filesystem.removeDirectoryRecursive(path)
    if not path then
        return false
    end

    local attributes = lfs.attributes(path)

    if not attributes then
        return true
    end

    if attributes.mode ~= "directory" then
        return filesystem.remove(path)
    end

    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local target = path .. "/" .. entry
            local targetAttributes = lfs.attributes(target)

            if targetAttributes and targetAttributes.mode == "directory" then
                filesystem.removeDirectoryRecursive(target)

            else
                filesystem.remove(target)
            end
        end
    end

    return filesystem.rmdir(path)
end

-- Use Unix paths
local ffi = require("ffi")
local utf8 = require("utf8")
local bit = require("bit")

local isWindowsReparsePoint

if ffi.os == "Windows" then
    local hasFFI, _ = pcall(ffi.cdef, [[
        unsigned int GetFileAttributesW(const uint16_t *lpFileName);
    ]])

    if hasFFI then
        local kernel32 = ffi.load("kernel32")
        local FILE_ATTRIBUTE_REPARSE_POINT = 0x400
        local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF

        local function utf8ToUtf16(path)
            local codepoints = {}

            for _, codepoint in utf8.codes(path) do
                if codepoint <= 0xFFFF then
                    table.insert(codepoints, codepoint)

                else
                    codepoint = codepoint - 0x10000
                    table.insert(codepoints, 0xD800 + math.floor(codepoint / 0x400))
                    table.insert(codepoints, 0xDC00 + (codepoint % 0x400))
                end
            end

            local buffer = ffi.new("uint16_t[?]", #codepoints + 1)

            for index, codepoint in ipairs(codepoints) do
                buffer[index - 1] = codepoint
            end

            return buffer
        end

        isWindowsReparsePoint = function(path)
            local attributes = kernel32.GetFileAttributesW(utf8ToUtf16(path))

            return attributes ~= INVALID_FILE_ATTRIBUTES
                and bit.band(attributes, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0
        end
    end
end

local function isDirectoryLink(path)
    if isWindowsReparsePoint then
        return isWindowsReparsePoint(path)
    end

    local attributes = lfs.symlinkattributes and lfs.symlinkattributes(path)

    return attributes and attributes.mode == "link" or false
end

local function normalizeVisitedPath(path)
    local normalized = path:gsub("\\", "/")

    if ffi.os == "Windows" then
        normalized = normalized:lower()
    end

    return normalized
end

local function findRecursive(filenames, path, recursive, predicate, useYields)
    local visited = {}
    local stack = {path}
    local counter = 0

    while #stack > 0 do
        local currentPath = table.remove(stack)
        local normalizedPath = normalizeVisitedPath(currentPath)

        -- A directory can be reachable through more than one path (junctions, symlinks, hard-linked
        -- directories). Track every directory once to prevent revisiting the same tree.
        if not visited[normalizedPath] then
            visited[normalizedPath] = true

            local entries = love.filesystem.getDirectoryItems(currentPath)

            -- Push directories in reverse so the traversal keeps the same order as the old
            -- depth-first recursive implementation.
            for index = #entries, 1, -1 do
                local filename = entries[index]
                local fullPath = currentPath .. "/" .. filename
                local fileInfo = love.filesystem.getInfo(fullPath)

                if useYields and counter % 100 == 0 then
                    coroutine.yield()
                end

                if fileInfo then
                    if fileInfo.type == "file" then
                        if predicate then
                            if predicate(filename) then
                                table.insert(filenames, fullPath)
                            end

                        else
                            table.insert(filenames, fullPath)
                        end

                        counter += 1

                    elseif recursive and not isDirectoryLink(fullPath) then
                        -- Do not follow directory links/junctions: a link back to an ancestor makes
                        -- the scan loop forever. The visited-path check also handles other aliases.
                        table.insert(stack, fullPath)
                    end
                end
            end
        end
    end

    return filenames
end

function filesystem.getFilenames(path, recursive, filenames, predicate, useYields)
    useYields = useYields ~= false
    recursive = recursive ~= false
    filenames = filenames or {}

    findRecursive(filenames, path, recursive, predicate, useYields)

    return filenames
end

function filesystem.pathAttributes(path)
    return lfs.attributes(path)
end

function filesystem.listDir(path)
    return lfs.dir(path)
end

function filesystem.isFile(path)
    local attrs = lfs.attributes(path)

    return attrs and attrs.mode == "file" or false
end

function filesystem.isDirectory(path)
    local attrs = lfs.attributes(path)

    return attrs and attrs.mode == "directory" or false
end

function filesystem.mtime(path)
    local attrs = lfs.attributes(path)

    return attrs and attrs.modification or -1
end

function filesystem.currentDirectory()
    return lfs.currentdir()
end

-- TODO - Test
function filesystem.copy(from, to)
    local fromFh = io.open(from, "rb")

    if not fromFh then
        return false, "Target file not found"
    end

    local toFh = io.open(to, "wb")

    if not toFh then
        return false, "Couldn't create destination file"
    end

    toFh:write(fromFh:read("*a"))
    toFh:close()
    fromFh:close()

    return true
end

-- Crashes on Windows if using / as path separator
local function fixNFDPath(path)
    if not path then
        return
    end

    local userOS = osUtils.getOS()

    if userOS == "Windows" then
        return filesystem.joinpath(filesystem.splitpath(path, "/"))

    else
        return path
    end
end

filesystem.dialogDirectories = dialogDirectories

function filesystem.prepareDialogs()
    return prepareNfd() ~= nil
end

-- Return thread if called with callback
-- Otherwise block and return the selected file
function filesystem.saveDialog(path, filter, callback)
    path = fixNFDPath(path)

    local nfd = prepareNfd()

    if not nfd then
        return false
    end

    if callback then
        if filesystem.supportWindowsInThreads() then
            local code = [[
                local args = {...}
                local channelName, path, filter = unpack(args)
                local channel = love.thread.getChannel(channelName)

                local nfd = require("nfd")

                local res = nfd.save(filter, nil, path)
                channel:push(res)
            ]]

            return threadHandler.createStartWithCallback(code, callback, path, filter)

        else
            callback(nfd.save(filter, nil, path))

            return false, false
        end

    else
        return nfd.save(filter, nil, path)
    end
end

-- Return thread if called with callback
-- Otherwise block and return the selected file
function filesystem.openDialog(path, filter, callback)
    path = fixNFDPath(path)

    local nfd = prepareNfd()

    if not nfd then
        return false
    end

    if callback then
        if filesystem.supportWindowsInThreads() then
            local code = [[
                local args = {...}
                local channelName, path, filter = unpack(args)
                local channel = love.thread.getChannel(channelName)

                local nfd = require("nfd")

                local res = nfd.open(filter, path)
                channel:push(res)
            ]]

            return threadHandler.createStartWithCallback(code, callback, path, filter)

        else
            local result = nfd.open(filter, path)

            if result then
                callback(result)
            end

            return false, false
        end

    else
        return nfd.open(filter, path)
    end
end

-- Return thread if called with callback
-- Otherwise block and return the selected file
function filesystem.openFolderDialog(path, callback)
    path = fixNFDPath(path)

    local nfd = prepareNfd()

    if not nfd then
        return false
    end

    if callback then
        if filesystem.supportWindowsInThreads() then
            local code = [[
                local args = {...}
                local channelName, path = unpack(args)
                local channel = love.thread.getChannel(channelName)

                local nfd = require("nfd")

                local res = nfd.openFolder(path)
                channel:push(res)
            ]]

            return threadHandler.createStartWithCallback(code, callback, path)

        else
            local result = nfd.openFolder(path)

            if result then
                callback(result)
            end

            return false, false
        end

    else
        return nfd.openFolder(path)
    end
end

function filesystem.downloadURL(url, filename, headers)
    if not hasRequest then
        return false, nil
    end

    local response = request.send(url, {
        headers = headers or {
            ["User-Agent"] = "curl/7.78.0",
            ["Accept"] = "*/*"
        }
    })

    if response then
        local body, code = response.body, response.code

        if body and code == 200 then
            filesystem.mkdir(filesystem.dirname(filename))
            local fh = io.open(filename, "wb")

            if fh then
                fh:write(body)
                fh:close()

                return true
            end

        elseif code >= 300 and code <= 399 then
            local responseHeaders = response.headers
            local redirect = (responseHeaders["location"] or responseHeaders["Location"]):match("^%s*(.*)%s*$")
            local newHeaders = table.shallowcopy(headers)

            newHeaders["Referer"] = url

            return filesystem.downloadURL(redirect, filename, newHeaders)
        end
    end

    return false
end

function filesystem.copyFromLoveFilesystem(mountPoint, output, folder)
    local filesTablePath = folder and filesystem.joinpath(mountPoint, folder) or mountPoint
    local filesTable = love.filesystem.getDirectoryItems(filesTablePath)

    local outputTarget = folder and filesystem.joinpath(output, folder) or output
    filesystem.mkdir(outputTarget)

    for i, file <- filesTable do
        local path = folder and filesystem.joinpath(folder, file) or file
        local mountPath = filesystem.joinpath(mountPoint, path)
        local info = love.filesystem.getInfo(mountPath)

        if info.type == "file" then
            local fh = io.open(filesystem.joinpath(output, path), "wb")

            if fh then
                local data = love.filesystem.read(mountPath)

                fh:write(data)
                fh:close()
            end

        elseif info.type == "directory" then
            filesystem.copyFromLoveFilesystem(mountPoint, output, path)
        end
    end
end

-- Unzip using phyfs unsandboxed mount system, and then manually copying out files
function filesystem.unzip(zipPath, outputDir)
    love.filesystem.mountUnsandboxed(zipPath, "temp/", 0)

    filesystem.copyFromLoveFilesystem("temp", outputDir)

    love.filesystem.unmount("temp")
end

return filesystem
