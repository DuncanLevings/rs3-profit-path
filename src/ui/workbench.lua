-- Owns the launcher, window frame and navigation. browse_view.lua draws the
-- browser columns; method_view.lua draws the method tabs.
--
-- There are two separate pieces, each with its own lifetime:
--   * the launcher: a small page in the Plugins ribbon with an "Open" button
--   * the workbench: our own resizable window floating over the game
--
-- Inside the window, moving between screens (Browse, a method, Diagnostics) swaps
-- just the content view and keeps the window itself, so it doesn't jump back to its
-- starting position or size every time you click something.
--
-- The one tricky idea here is the "generation" counter. Every time we tear down a
-- view we bump it, and every button callback remembers the generation it was made
-- in. A click that arrives late (say, after we've moved to another screen) sees the
-- number has changed and does nothing, instead of poking UI that no longer exists.
local MethodView = require("src/ui/method_view")
local Diagnostics = require("src/ui/diagnostics")
local BrowseView = require("src/ui/browse_view")
local UI = {}

-- `library` is PrettyUI. `calculator` is main.lua's controller; we just call it and
-- show its results, with no money logic in here.
function UI.new(library, account, inspectQuote, inspectQuest, calculator, browser)
    local self = { active = true, generation = 0, screen = "browse" }
    local diagnostics = Diagnostics.new(account, inspectQuote, inspectQuest)

    -- Re-reads whatever the current screen shows. `reason` says what changed:
    -- "skills", "inventory", or nil for "refresh everything" (e.g. on reopen).
    -- Inventory changes can fire on every action. The method view updates only
    -- item borders for those, keeping skill reads out of that hot path.
    function self:refresh(reason)
        if not self.view or not self.interactive then
            return
        end

        if self.methodRefresh then
            self.methodRefresh(reason)
        elseif self.screen == "diagnostics" then
            diagnostics:refresh()
        end
    end

    -- Removes the current content view but keeps the window. Bumping the generation
    -- comes first, so any callback still in flight is dead before its labels go.
    function self:clearView()
        self.generation = self.generation + 1
        self.interactive = false

        local view = self.view
        self.view = nil
        self.methodRefresh = nil
        self.browseRefresh = nil

        diagnostics:unmount()

        if self.browseUnmount then
            self.browseUnmount()
            self.browseUnmount = nil
        end

        if view then
            view:Destroy()
        end
    end

    -- Fully destroys the window (unlike the window's own Close button, which only hides it).
    function self:destroyWindow()
        self:clearView()

        local window = self.window
        self.window = nil

        if window then
            window:Destroy()
        end
    end

    -- Shutdown: get rid of everything we created. Safe to call more than once.
    function self:destroy()
        if not self.active then
            return
        end

        self.active = false

        local launcher = self.launcher
        self.launcher = nil

        if launcher then
            launcher:Destroy()
        end

        self:destroyWindow()
    end

    -- Builds the current screen (self.screen) inside `parent`, the window body.
    function self:mount(parent)
        self:clearView()

        local generation = self.generation

        -- The anchors make the view stretch with the window when it's resized. The
        -- browser and method screens turn scrolling off here because their child
        -- views scroll themselves; two nested scroll areas would fight each other.
        local view = library.SimpleView.new(parent, {
            width = 0, height = 0, widthAnchor = 1, heightAnchor = 1,
            scrollable = self.screen == "diagnostics",
        })

        self.view = view
        self.interactive = true

        -- Wrap every button/input callback with this. The wrapped callback only runs
        -- if we're still alive, the window is open and this exact view is still the
        -- current one (see the generation note at the top of the file).
        local function guarded(callback)
            return function(...)
                if self.active and self.interactive and self.view == view and self.generation == generation then
                    callback(...)
                end
            end
        end

        -- If anything below throws halfway through, we clean up the half-built view
        -- and re-raise the error, rather than leave a broken screen behind.
        local ok, failure = pcall(function()
            local function navigate(screen)
                self.screen = screen
                self:mount(parent)
            end

            if self.screen == "browse" then
                self.browseUnmount, self.browseRefresh = BrowseView.mount(library, view, browser, guarded, function(method)
                    calculator:select(method)
                    self.method = method
                    navigate("method")
                end)
            else
                local backOptions = { tooltip = "Back to methods", size = 24 }

                -- Detail navigation shares the title row. Diagnostics keeps its
                -- normal flow layout so its temporary probe controls don't overlap.
                if self.screen == "method" then
                    backOptions.absolute = true
                    backOptions.x = 10
                    backOptions.y = 10
                end

                view:AddSpriteButton("ARROW_LEFT", guarded(function()
                    if self.screen == "method" then
                        browser:returnFromMethod(self.method, calculator.quotes)
                    end

                    navigate("browse")
                end), backOptions)

                if self.screen == "method" then
                    -- Update only the button, not the screen: rebuilding here would
                    -- throw away the player's draft rate and selected detail tab.
                    local favouriteButton

                    local function favouriteLabel()
                        return browser.favourites[self.method.id] and "Remove favourite" or "Add favourite"
                    end

                    -- Reload favourites first in case the character changed while this
                    -- method was open. A save error shows on the Income status line.
                    favouriteButton = view:AddSpriteButton("STAR", guarded(function()
                        browser:loadFavourites()
                        browser:toggleFavourite(self.method)

                        favouriteButton:SetTooltip(favouriteLabel())
                        favouriteButton:SetDisabled(not browser.favourites[self.method.id])

                        calculator.message = browser.message
                        self.methodRefresh()
                    end), {
                        absolute = true, x = -36, xAnchor = 1, y = 10, size = 24,
                        tooltip = favouriteLabel(),

                        -- "disabled" is PrettyUI's unlit toggle look, not unclickable.
                        toggleable = true,
                        disabled = not browser.favourites[self.method.id],
                    })

                    self.methodRefresh = MethodView.mount(view, self.method, calculator, guarded)
                elseif self.screen == "diagnostics" then
                    diagnostics:mount(view, guarded)
                else
                    -- A typo in a screen name should be loud, not a silent blank page.
                    error("Unknown Profit Path screen: " .. tostring(self.screen))
                end
            end
        end)

        if not ok then
            self:clearView()
            error(failure, 0)
        end
    end

    -- Shows the workbench window, creating it the first time. Returns true, or
    -- false plus a message the launcher can show to the player.
    function self:openWindow()
        if not self.active then
            return false, "Profit Path has stopped."
        end

        local identified, problem = calculator:useCharacter()

        if not identified then
            return false, problem
        end

        -- Opening is the price-refresh boundary. Hidden windows retain their
        -- controls, draft rate and tab; only captured prices and labels change.
        if self.window then
            local wasHidden = not self.interactive
            self.interactive = true

            if wasHidden then
                if self.screen == "method" then
                    calculator:refreshPrices()
                else
                    browser:refreshEstimates()
                end
            end

            self.window:Show()

            if self.browseRefresh then
                self.browseRefresh()
            else
                self:refresh()
            end

            return true
        end

        -- The window hangs off the game area (the documented TOPLEVEL_V2__GAME_AREA
        -- component), not the ribbon, so it isn't trapped inside the Plugins page.
        local gameArea = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)

        if not gameArea then
            return false, "The game area is unavailable. Enter a game world, then try again."
        end

        -- Aim for 1040x740 but leave a 20px margin all round on small screens.
        local width = math.max(1, math.min(1040, gameArea.width - 40))
        local height = math.max(1, math.min(740, gameArea.height - 40))

        local ok, failure = pcall(function()
            self.window = library.Window.new(gameArea, {
                -- Just the plugin name. Settings still follow the character behind
                -- the scenes; a future account page will show whose they are.
                title = "Profit Path",
                width = width,
                height = height,

                -- Centre on the game area: anchor at its midpoint, offset by half the size.
                xAnchor = 0.5,
                yAnchor = 0.5,
                x = -math.floor(width / 2),
                y = -math.floor(height / 2),

                minWidth = math.min(700, width),
                minHeight = math.min(480, height),
                resizable = true,
                scrollable = false,

                -- The window's own X button only hides it. Stop callbacks while it's
                -- hidden; openWindow turns them back on.
                onClose = function(window)
                    if self.window == window then
                        self.interactive = false
                    end
                end,
            })

            if self.screen == "method" then
                calculator:refreshPrices()
            else
                browser:refreshEstimates()
            end

            self:mount(self.window.content)
            self.window:Show()
        end)

        if not ok then
            self:destroyWindow()
            return false, "Profit Path could not open: " .. tostring(failure)
        end

        return true
    end

    -- Builds the ribbon launcher page. The client can hand us a new parent (e.g.
    -- after a reload), so any old launcher is destroyed first. The window, if open,
    -- is left alone.
    function self:mountLauncher(parent)
        local previous = self.launcher
        self.launcher = nil

        if previous then
            previous:Destroy()
        end

        local launcher = library.SimpleView.new(parent, { width = parent.width, height = parent.height })
        self.launcher = launcher

        local ok, failure = pcall(function()
            launcher:AddTitle("Profit Path")
            launcher:AddText("Browse money-making methods and calculate income in the Profit Path window.")

            -- Shows why opening failed (e.g. not logged in yet); empty otherwise.
            local status = launcher:AddText({ text = "", height = 80 })

            launcher:AddSimpleButton("Open Profit Path", function()
                -- Ignore clicks on a launcher that's already been replaced.
                if self.active and self.launcher == launcher then
                    local opened, problem = self:openWindow()
                    status.content = opened and "" or problem
                end
            end, { width = 220 })

            -- Temporary: the development probes live in the launcher, never in
            -- the player's browsing sidebar. Remove with diagnostics.lua.
            launcher:AddSimpleButton("Diagnostics", function()
                if self.active and self.launcher == launcher then
                    local opened, problem = self:openWindow()
                    status.content = opened and "" or problem

                    if opened then
                        self.screen = "diagnostics"
                        self:mount(self.window.content)
                    end
                end
            end, { width = 120, inline = true })
        end)

        if not ok then
            self.launcher = nil
            launcher:Destroy()
            error(failure, 0)
        end
    end

    return self
end

return UI
