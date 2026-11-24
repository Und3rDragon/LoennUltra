local utils = require("utils")
local language = require("utils.lang")
local pluginLoader = require("plugin_loader")
local modHandler = require("mods")
local configs = require("configs")

local languageRegistry = {}

languageRegistry.languages = {}
languageRegistry.language = {}
languageRegistry.currentLanguageName = nil
languageRegistry.fallbackLanguage = {}
languageRegistry.fallbackLanguageName = nil

function languageRegistry.setLanguage(name)
    languageRegistry.currentLanguageName = name
    languageRegistry.language = languageRegistry.languages[name]
end

function languageRegistry.getLanguage()
    -- If language is completely missing
    if not languageRegistry.language then
        return languageRegistry.fallbackLanguage or {}
    end

    -- A partial language (for example a standalone UI language without the core scenes
    -- section) must not crash the loading scene. Fall back to the core language.
    if languageRegistry.language.scenes == nil
        and languageRegistry.fallbackLanguage
        and languageRegistry.fallbackLanguage.scenes ~= nil then
        return languageRegistry.fallbackLanguage
    end

    return languageRegistry.language
end

function languageRegistry.getLanguageDisplayName(name, data)
    data = data or languageRegistry.languages[name]

    -- Keep the built-in English aliases presented as one language even if a settings reset or a
    -- mod language file leaves one of them without language.name metadata.
    if name == "en" or name == "en_gb" then
        return "English"
    end

    if data and data.language and data.language.name and data.language.name._exists then
        return tostring(data.language.name)
    end

    return name
end

function languageRegistry.getLanguageOptions()
    local options = {}
    local seenNames = {}
    local seenLabels = {}
    local canonicalNames = {
        en = "en_gb",
        en_gb = "en_gb"
    }

    for name, data in pairs(languageRegistry.languages or {}) do
        local canonicalName = canonicalNames[name] or name
        local displayName = languageRegistry.getLanguageDisplayName(name, data)

        local skipEnglishAlias = displayName == "English"
            and name ~= "en_gb"
            and languageRegistry.languages.en_gb ~= nil

        if not skipEnglishAlias and not seenNames[canonicalName] and not seenLabels[displayName] then
            seenNames[canonicalName] = true
            seenLabels[displayName] = true

            -- Prefer the complete en_gb language data when both en and en_gb are present.
            local optionName = canonicalName == "en_gb" and "en_gb" or name

            if optionName == "en_gb" and not languageRegistry.languages.en_gb then
                optionName = name
            end

            table.insert(options, {
                displayName,
                optionName
            })
        end
    end

    table.sort(options, function(a, b)
        return string.lower(a[1]) < string.lower(b[1])
    end)

    return options
end

function languageRegistry.setFallbackLanguage(name)
    languageRegistry.fallbackLanguageName = name
    languageRegistry.fallbackLanguage = languageRegistry.languages[name]

    language.setFallback(languageRegistry.fallbackLanguage)

    do
        local ok, logging = pcall(require, "logging")

        if ok then
            pcall(logging.log, "INFO", string.format("[diag] language.setFallback name=%s exists=%s",
                tostring(name), tostring(languageRegistry.fallbackLanguage ~= nil)), nil, true)
        end
    end
end

function languageRegistry.loadLanguageFile(filename)
    local name = utils.stripExtension(utils.filename(filename, "/"))
    local languageData = languageRegistry.languages[name]

    languageRegistry.languages[name] = language.loadFile(filename, languageData)
end

function languageRegistry.unloadFiles()
    languageRegistry.languages = {}
end

function languageRegistry.loadInternalFiles()
    pluginLoader.loadPlugins("lang", nil, languageRegistry.loadLanguageFile, false, "lang")
    pluginLoader.loadPlugins("ui/lang", nil, languageRegistry.loadLanguageFile, false, "lang")
end

function languageRegistry.loadExternalFiles()
    local filenames = modHandler.findLanguageFiles("lang")

    pluginLoader.loadPlugins(filenames, nil, languageRegistry.loadLanguageFile, true, "lang")
end

return languageRegistry