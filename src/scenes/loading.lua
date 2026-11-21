local fonts = require("fonts")
local utils = require("utils")
local languageRegistry = require("language_registry")
local persistence = require("persistence")
local viewportHandler = require("viewport_handler")
local logging = require("logging")
local startupProgress = require("startup_progress")
local liquidFill = require("ui.widgets.liquid_fill")
local loadingTips = require("assets.loading.tips")

local languageTipShown = false

local loadingScene = {}

loadingScene.name = "Loading"

local function getLoadingText(language)
    -- The loading screen deliberately keeps its original English pixel-font presentation.
    return "Loading"
end

function loadingScene:setText(text)
    self.text = tostring(text)
    self.alignment = "left"
    self.textScale = rawget(self, "loadingTextScale") or fonts.fontScale * 2

    local font = rawget(self, "loadingFont") or fonts.font
    self.textOffsetX = (font:getWidth(self.text .. "..") * self.textScale) / 2
    self.textOffsetY = self.quadSize / 2
end

function loadingScene:applyLoadingFont()
    -- Keep the original high-resolution pixel font for the loading text. It intentionally does
    -- not follow the UI label font or the selected language.
    self.loadingFont = fonts.hiresFont
    self.loadingTextScale = 4
end

-- Runs every time the loading scene is entered (opening a map goes through it
-- again), so the loading text always uses the configured font, not whatever
-- zoom based font the editor was using
function loadingScene:enter()
    local configs = require("configs")

    fonts.setUseHires(configs.font.useHiresPixelFont)
    -- Keep the loading text independent from the configurable UI label font.
    self:applyLoadingFont()
    self:setText(getLoadingText(languageRegistry.getLanguage()))
end

function loadingScene:loaded()
    self.spriteSheet = love.graphics.newImage("assets/loading-256.png")
    self.quadSize = 256
    self.quads = {}

    for y = 0, self.spriteSheet:getHeight() - self.quadSize, self.quadSize do
        for x = 0, self.spriteSheet:getWidth() - self.quadSize, self.quadSize do
            table.insert(self.quads, love.graphics.newQuad(x, y, self.quadSize, self.quadSize, self.spriteSheet:getDimensions()))
        end
    end

    -- The sheet starts with an empty frame and a partly rotated one, the last
    -- frame is the fully visible logo. The logo no longer animates, so just
    -- keep that last frame
    self.logoQuad = self.quads[#self.quads]

    -- Faded base logo the liquid is drawn on top of
    self.logoAlpha = 0.35

    -- The logo and the loading text sit slightly above the window center, which
    -- looks more balanced than centering the logo itself
    self.logoOffset = 26

    self.duration = 1
    self.currentTime = 0

    self.birdFrames = {}

    for i = 0, loadingTips.bird.frameCount - 1 do
        local path = string.format("assets/loading/bird/crow%02d.png", i)

        if love.filesystem.getInfo(path, "file") then
            table.insert(self.birdFrames, love.graphics.newImage(path))
        end
    end

    self.birdFrame = 1
    self.birdTime = 0

    -- Load the tip font and measure every tip before the loading screen starts drawing.
    -- The CJK font is loaded lazily by LÖVE; doing that in draw() caused a visible stall
    -- which consumed most of the time a tip was supposed to stay on screen.
    -- Use the same default font family as the editor UI. The previous system-font Text object
    -- went through its own texture/filter path, which made the loading tips look different from
    -- the rest of the interface.
    self.tipFont = fonts.getLoadingTipFont(loadingTips.settings.fontSize)
    self.tipFont:setFilter("linear", "linear")
    self.tipTexts = {}

    for i, tip in ipairs(loadingTips.tips) do
        local text = love.graphics.newText(self.tipFont)
        text:setf(tip, loadingTips.settings.maxWidth, "left")
        self.tipTexts[i] = text
    end

    self:resetTips()
end

function loadingScene:firstEnter()
    local tasks = require("utils.tasks")

    local sandboxUtils = require("utils.sandbox")
    local language = languageRegistry.getLanguage()

    local sceneHandler = require("scene_handler")
    local toolHandler = require("tools")
    local entities = require("entities")
    local triggers = require("triggers")
    local effects = require("effects")
    local libraries = require("libraries")
    local saveSanitizers = require("save_sanitizers")

    local atlases = require("atlases")

    local configs = require("configs")
    local defaultConfig = require("default_config")
    local mods = require("mods")

    local launchArguments = require("launch_arguments")

    local fileLocations = require("file_locations")
    local viewerState = require("loaded_state")

    local userInterfaceDevice = require("ui.ui_device")

    -- The configured font has to be applied before the loading text is
    -- measured. Automatic zoom switching only applies to map text, so the
    -- loading screen always uses the configured font
    fonts.setUseHires(configs.font.useHiresPixelFont)

    self:applyLoadingFont()
    self:setText(getLoadingText(language))

    startupProgress.reset()

    -- A broken shader must not break startup, the logo is drawn plain instead
    local created, liquidLogo = pcall(liquidFill.create, {baseAlpha = self.logoAlpha})

    self.liquidLogo = created and liquidLogo or nil

    if not created then
        logging.warning("[loading] Could not create the liquid fill shader: " .. tostring(liquidLogo))
    end

    -- Microbenchmark to estimate instructions per second
    sandboxUtils.calcIpsAndHookInterval()

    -- Load assets and entity, trigger, effect etc modules
    tasks.newTask(
        function()
            local timings = {}
            local phaseStart = love.timer.getTime()

            local function phaseDone(name)
                local now = love.timer.getTime()

                table.insert(timings, string.format("%s=%.0fms", name, (now - phaseStart) * 1000))

                if configs.debug.logStartupTiming then
                    logging.info(string.format("[startup] %s done at %.0fms (+%.0fms)",
                        name, now * 1000, (now - phaseStart) * 1000))
                end

                phaseStart = now
            end

            startupProgress.beginPhase("celesteAtlases", "Loading atlases")
            atlases.loadCelesteAtlases()
            startupProgress.finishPhase()
            phaseDone("celesteAtlases")

            startupProgress.beginPhase("mountMods", "Loading mods")

            mods.mountMods()

            startupProgress.finishPhase()
            phaseDone("mountMods")

            startupProgress.beginPhase("languages", "Loading languages")
            -- Internal scenes are already loaded, how else would we be here
            sceneHandler.loadExternalScenes()

            languageRegistry.loadExternalFiles()
            languageRegistry.setLanguage(configs.general.language)
            startupProgress.finishPhase()
            phaseDone("scenes+language")

            startupProgress.beginPhase("libraries", "Loading libraries")
            libraries.loadInternalLibraries()
            libraries.loadExternalLibraries()
            startupProgress.finishPhase()
            phaseDone("libraries")

            startupProgress.beginPhase("entities", "Loading entities")
            entities.loadInternalEntities()
            entities.loadExternalEntities()
            startupProgress.finishPhase()
            phaseDone("entities")

            startupProgress.beginPhase("triggers", "Loading triggers")
            triggers.loadInternalTriggers()
            triggers.loadExternalTriggers()
            startupProgress.finishPhase()
            phaseDone("triggers")

            startupProgress.beginPhase("effects", "Loading effects")
            effects.loadInternalEffects()
            effects.loadExternalEffects()
            startupProgress.finishPhase()
            phaseDone("effects")

            startupProgress.beginPhase("tools", "Loading tools")
            toolHandler.loadInternalTools()
            toolHandler.loadExternalTools()
            startupProgress.finishPhase()
            phaseDone("tools")

            startupProgress.beginPhase("saveSanitizers", "Loading save sanitizers")
            saveSanitizers.loadInternalSanitizers()
            saveSanitizers.loadExternalSanitizers()
            startupProgress.finishPhase()
            phaseDone("saveSanitizers")

            startupProgress.beginPhase("userInterface", "Building interface")
            if userInterfaceDevice.initializeDevice then
                userInterfaceDevice.initializeDevice()
            end
            startupProgress.finishPhase()
            phaseDone("userInterface")

            -- This can take a while depending on the amount of installed mods
            -- By default it is lazy loaded
            if not configs.editor.lazyLoadExternalAtlases then
                atlases.loadExternalAtlases()
                phaseDone("externalAtlases")
            end

            require("virtual_fs").report()
            logging.info("[compile_cache] " .. require("compile_cache").report())

            logging.info(string.format("[startup] boot=%.0fms progress=%.0f%% %s",
                love.timer.getTime() * 1000, startupProgress.get() * 100, table.concat(timings, " ")))
        end
    )

    local defaultMapFilename = utils.joinpath(fileLocations.getCelesteDir(), "Content", "Maps", "7-Summit.bin")
    local initialFilename = launchArguments.parsed.initialFilename
    local lastMapFilename = persistence.lastLoadedFilename
    local lastRoomName = persistence.lastSelectedRoomName
    local targetFilename = initialFilename or lastMapFilename or defaultMapFilename

    viewerState.loadFile(targetFilename, lastRoomName)
    viewportHandler.cameraFromPersistence()
    viewerState.initFromPersistence()
end

function loadingScene:resetTips()
    self.tipState = {
        current = nil,
        elapsed = 0,
        index = nil,
        first = true,
    }

    if #loadingTips.tips > 0 then
        local index = love.math.random(#loadingTips.tips)
        local configs = require("configs")

        if not languageTipShown and configs.general and configs.general.language ~= "zh_cn" then
            index = 1
            languageTipShown = true
        end

        self.tipState.index = index
        self.tipState.current = loadingTips.tips[index]
    end
end

function loadingScene:pickTip()
    local tips = loadingTips.tips

    if #tips == 0 then
        return nil
    end

    local index = love.math.random(#tips)

    if #tips > 1 and index == self.tipState.index then
        index = index % #tips + 1
    end

    self.tipState.index = index

    return tips[index]
end

function loadingScene:updateTips(dt)
    if not self.tipState then
        self:resetTips()
    end

    local settings = loadingTips.settings
    local state = self.tipState

    if state.current then
        state.elapsed = state.elapsed + dt

        if state.elapsed >= settings.duration then
            state.first = false
            state.current = self:pickTip()
            state.elapsed = 0
        end

    else
        state.current = self:pickTip()
        state.elapsed = 0
    end
end

function loadingScene:updateBird(dt)
    if #self.birdFrames == 0 then
        return
    end

    self.birdTime = self.birdTime + dt

    if self.birdTime >= loadingTips.bird.frameDuration then
        self.birdTime = self.birdTime - loadingTips.bird.frameDuration
        self.birdFrame = self.birdFrame % #self.birdFrames + 1
    end
end

function loadingScene:drawBird(windowWidth, windowHeight)
    if #self.birdFrames == 0 then
        return
    end

    local image = self.birdFrames[self.birdFrame]
    local scale = loadingTips.bird.scale
    local margin = loadingTips.bird.margin
    local x = margin - loadingTips.bird.visualLeft * scale
    local y = windowHeight - margin - loadingTips.bird.visualBottom * scale

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(image, x, y, 0, scale, scale)
end

function loadingScene:drawTips(windowWidth, windowHeight)
    if not self.tipState then
        self:resetTips()
    end

    local bird = loadingTips.bird
    local settings = loadingTips.settings
    local state = self.tipState

    self:drawBird(windowWidth, windowHeight)

    if not state.current then
        return
    end

    local fadeDuration = settings.fadeDuration
    local alpha = 1

    if not state.first then
        if state.elapsed < fadeDuration then
            alpha = state.elapsed / fadeDuration
        elseif settings.duration - state.elapsed < fadeDuration then
            alpha = (settings.duration - state.elapsed) / fadeDuration
        end
    end

    alpha = math.max(0, math.min(1, alpha))

    local tipText = self.tipTexts and self.tipTexts[state.index]

    if not tipText then
        return
    end

    local textX = bird.margin + bird.visualRight * bird.scale + settings.textGap
    local maxWidth = math.min(settings.maxWidth, windowWidth - textX - settings.rightMargin)

    if maxWidth < 60 then
        return
    end

    local textHeight = tipText:getHeight()
    local birdY = windowHeight - bird.margin - bird.visualBottom * bird.scale
    local birdCenterY = birdY + (bird.visualTop + bird.visualBottom) / 2 * bird.scale
    local textY = birdCenterY - textHeight / 2

    love.graphics.setColor(1, 1, 1, alpha)
    love.graphics.draw(tipText,
        math.floor(textX + 0.5),
        math.floor(textY + 0.5))
end

function loadingScene:draw()
    -- Scenes metatable will make this seem like a function, make sure its actually set
    if type(self.text) == "string" then
        local windowWidth, windowHeight = love.graphics.getWidth(), love.graphics.getHeight()

        -- drawTips changes the current font and leaves a faded text color behind. Reset both
        -- before drawing the loading text, otherwise its opacity follows the tips fade.
        love.graphics.setFont(rawget(self, "loadingFont") or fonts.font)
        love.graphics.setColor(1, 1, 1, 1)

        local dots = string.rep(".", utils.mod1(math.floor(self.currentTime / self.duration * 4) + 1, 4))

        love.graphics.printf(self.text .. dots, windowWidth / 2 - self.textOffsetX, windowHeight / 2 + self.textOffsetY - self.logoOffset, windowWidth, self.alignment, 0, self.textScale)

        local x = (windowWidth - self.quadSize) / 2
        local y = (windowHeight - self.quadSize) / 2 - self.logoOffset

        self:drawLogo(x, y)
        self:drawTips(windowWidth, windowHeight)
    end
end

-- The liquid masks the logo: the part below the surface is drawn at full
-- strength, the rest stays faded
function loadingScene:drawLogo(x, y)
    if not self.liquidLogo then
        love.graphics.setColor(1, 1, 1, self.logoAlpha)
        love.graphics.draw(self.spriteSheet, self.logoQuad, x, y)
        love.graphics.setColor(1, 1, 1, 1)

        return
    end

    liquidFill.drawLogo(self.liquidLogo, self.spriteSheet, self.logoQuad, x, y, self.quadSize, self.quadSize, startupProgress.get())
end

function loadingScene:update(dt)
    self.currentTime = self.currentTime + dt
    while self.currentTime >= self.duration do
        self.currentTime = self.currentTime - self.duration
    end

    if self.liquidLogo then
        liquidFill.update(self.liquidLogo, dt)
    end

    self:updateBird(dt)
    self:updateTips(math.min(dt, 0.2))
end

return loadingScene