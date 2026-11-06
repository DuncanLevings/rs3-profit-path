-- Owns the ribbon launcher, floating window and screen navigation. Changing
-- screens replaces the content, keeping the window in place.
-- Callbacks remember the screen generation so late clicks cannot reach destroyed
-- controls.
local MethodView = require("src/ui/method_view")
local BrowseView = require("src/ui/browse_view")
local MethodEditor = require("src/ui/method_editor")
local ShareView = require("src/ui/share_view")
local Draft = require("src/methods/custom_draft")
local Style = require("src/ui/view_style")
local UI = {}

-- Watch the content size while the window is visible and rebuild after resizing
-- settles. The native ONRESIZE hook does not fire for PrettyUI window resizes in
-- this client.
local RESIZE_EVENT = "profit-path-resize"

-- How long the size must stay put before we rebuild: 15 logic ticks is 0.3 s
-- (the client runs a fixed 50 logic ticks per second).
local RESIZE_SETTLE_TICKS = 15

-- `library` is PrettyUI. `calculator` is main.lua's controller; we just call it and
-- show its results, with no money logic in here.
function UI.new(library, account, calculator, browser)
    local self = { active = true, generation = 0, screen = "browse" }

    -- Refresh the visible screen after account evidence changes. Activity pages
    -- update their controls in place; lists redraw when a requirement filter or
    -- recommendation may have changed.
    function self:refresh(reason)
        if not self.view or not self.interactive then
            return
        end

        if self.methodRefresh then
            self.methodRefresh(reason)
        elseif self.browseRefresh and calculator.accessChanged
            and (browser.availability ~= "any" or browser.section == "recommend") then
            -- A requirement changing can change what's recommended, so the card
            -- follows account reads too (it keeps its suggestion while that still fits).
            self.browseRefresh()
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

        -- Remember which method tab was open, so a rebuild (e.g. after a resize
        -- or switching version) comes back to the same tab. Picking a different
        -- method from Browse clears it.
        if self.methodActiveTab then
            self.methodTab = self.methodActiveTab()
            self.methodActiveTab = nil
        end

        -- Cancel the version dropdown's pending callback, if any.
        if self.methodRelease then
            self.methodRelease()
            self.methodRelease = nil
        end

        if self.browseUnmount then
            self.browseUnmount()
            self.browseUnmount = nil
        end

        -- The editor's nested views go before the view itself (see method_editor.lua).
        if self.editorUnmount then
            self.editorUnmount()
            self.editorUnmount = nil
        end

        -- The same for the Export and Import screens (share_view.lua).
        if self.shareUnmount then
            self.shareUnmount()
            self.shareUnmount = nil
        end

        if view then
            view:Destroy()
        end
    end

    -- Fully destroys the window (unlike the window's own Close button, which only hides it).
    function self:destroyWindow()
        self:clearView()

        -- No window, nothing to watch.
        self:stopResizeWatch()

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

        -- The size we built for, so the resize check knows when it's out of date.
        self.mountedWidth, self.mountedHeight = parent.width, parent.height

        -- Stretch with the window. Child views handle scrolling, so keep
        -- scrolling off here to avoid competing scroll areas.
        local view = library.SimpleView.new(parent, {
            width = 0, height = 0, widthAnchor = 1, heightAnchor = 1,
            scrollable = false,
        })

        self.view = view
        self.interactive = true

        -- Ignore input from an old screen, a hidden window or a plugin that has
        -- shut down.
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

                    -- A different method starts on its Income tab.
                    self.methodTab = nil

                    navigate("method")
                end, {
                    onNewCustom = function()
                        self.editor = MethodEditor.state()
                        self.editorReturn = "browse"
                        navigate("editor")
                    end,

                    -- A fresh, empty paste box each time.
                    onImport = function()
                        self.importState = ShareView.importState()
                        navigate("import")
                    end,

                    onAccount = function()
                        self.accountState = { scroll = 0 }
                        navigate("account")
                    end,
                })
            else
                local backOptions = { tooltip = "Back to activities", size = 24 }

                -- Back shares the title row with the method's (or editor's) name.
                if self.screen ~= "browse" then
                    backOptions.absolute = true
                    backOptions.x = 10
                    backOptions.y = 10
                end

                -- From the editor, Back leaves without saving: to the activity
                -- it was opened from, or to the list it was started from.
                if self.screen == "editor" then
                    backOptions.tooltip = "Back without saving"
                elseif self.screen == "export" then
                    backOptions.tooltip = "Back to the activity"
                end

                view:AddSpriteButton("ARROW_LEFT", guarded(function()
                    if self.screen == "method" then
                        browser:returnFromMethod(self.method, calculator.quotes)
                    elseif self.screen == "editor" and self.editorReturn == "method" or self.screen == "export" then
                        -- Back to the activity this was opened from.
                        self.editor = nil
                        navigate("method")
                        return
                    end

                    self.editor = nil
                    self.importState = nil
                    navigate("browse")
                end), backOptions)

                if self.screen == "method" then
                    -- Update only the button, not the screen: rebuilding here would
                    -- throw away the player's draft rate and selected detail tab.
                    local favouriteButton

                    local function favouriteLabel()
                        return browser.favourites[self.method.id] and "Remove favourite" or "Add favourite"
                    end

                    -- The star changes from silver to gold when favourited.
                    -- PrettyUI cannot swap a drawn button's icon, so replace the
                    -- button in the same position.
                    local drawFavourite

                    -- Reload favourites first in case the character changed while this
                    -- method was open. A save error shows on the Income status line.
                    local function toggleFavourite()
                        browser:loadFavourites()
                        browser:toggleFavourite(self.method)

                        favouriteButton:Destroy()
                        drawFavourite()

                        calculator.message = browser.message
                        self.methodRefresh()
                    end

                    drawFavourite = function()
                        local favourite = browser.favourites[self.method.id] == true

                        favouriteButton = Style.iconButton(view, favourite and "star_filled" or "star_empty",
                            favourite and "Unstar" or "Star", favouriteLabel(), guarded(toggleFavourite),
                            { right = MethodView.FAVOURITE_RIGHT, y = MethodView.HEADER_ICON_Y, absolute = true })
                    end

                    drawFavourite()

                    -- Bundled activities with the same title are versions of one
                    -- activity. Switching versions reloads its prices and rate
                    -- while keeping the current tab.
                    local versions = {}

                    for _, candidate in ipairs(browser.methods) do
                        -- Only bundled activities have versions. A custom activity
                        -- stands alone, even when it shares a title with a bundled
                        -- one or with another custom activity (a second copy).
                        if candidate == self.method or self.method.origin ~= "custom"
                            and candidate.origin ~= "custom" and candidate.title == self.method.title then
                            versions[#versions + 1] = candidate
                        end
                    end

                    self.methodRefresh, self.methodActiveTab, self.methodRelease = MethodView.mount(view, self.method, calculator, guarded, {
                        activeTab = self.methodTab,
                        versions = versions,
                        onVersion = function(version)
                            calculator:select(version)
                            self.method = version
                            navigate("method")
                        end,

                        -- Custom activities keep their saved record on the method.
                        onEdit = self.method.record and function()
                            self.editor = MethodEditor.state({ draft = self.method.record })
                            self.editorReturn = "method"
                            navigate("editor")
                        end,

                        -- Deleted: back to the list, which no longer has it.
                        onDelete = self.method.record and function()
                            local deleted, problem = calculator:deleteCustom(self.method.record.id)

                            if not deleted then
                                return problem or "Couldn't delete it. Try again."
                            end

                            navigate("browse")
                        end,

                        -- Custom activities: show the line to copy and share.
                        onExport = self.method.record and function()
                            navigate("export")
                        end,

                        onDuplicate = function()
                            local draft, skipped = Draft.fromMethod(self.method, calculator.quotes)

                            if draft then
                                self.editor = MethodEditor.state({ draft = draft, skipped = skipped })
                                self.editorReturn = "method"
                                navigate("editor")
                            end
                        end,
                    })
                elseif self.screen == "account" then
                    self.browseUnmount, self.browseRefresh = BrowseView.mount(library, view, browser, guarded, nil, {
                        accountState = self.accountState,
                    })
                elseif self.screen == "editor" then
                    self.editorUnmount = MethodEditor.mount(library, view, self.editor, guarded, {
                        rebuild = function()
                            navigate("editor")
                        end,

                        quote = function(itemId)
                            return calculator:quote(itemId)
                        end,

                        save = function(draft)
                            return calculator:saveCustom(draft)
                        end,

                        delete = function(customId)
                            return calculator:deleteCustom(customId)
                        end,

                        -- Saved: open the activity's page. Deleted: back to the list.
                        done = function(saved)
                            self.editor = nil

                            local method = saved and browser:findMethod(saved.id)

                            if method then
                                calculator:select(method)
                                self.method = method
                                self.methodTab = nil
                                navigate("method")
                            else
                                navigate("browse")
                            end
                        end,
                    })
                elseif self.screen == "export" then
                    self.shareUnmount = ShareView.export(library, view, self.method.record, guarded)
                elseif self.screen == "import" then
                    self.shareUnmount = ShareView.import(library, view, self.importState, guarded, {
                        rebuild = function()
                            navigate("import")
                        end,

                        -- No ID, so it's saved as a new activity.
                        add = function(record)
                            return calculator:saveCustom(record)
                        end,

                        -- Added: open its page, like a save from the editor.
                        done = function(saved)
                            self.importState = nil

                            local method = browser:findMethod(saved.id)

                            if method then
                                calculator:select(method)
                                self.method = method
                                self.methodTab = nil
                                navigate("method")
                            else
                                navigate("browse")
                            end
                        end,
                    })
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

    -- Check the visible window once per logic tick. Rebuild only after its size
    -- has stayed unchanged for RESIZE_SETTLE_TICKS.
    function self:checkSize()
        local window = self.window

        if not window or not self.view or not self.interactive then
            return
        end

        local width, height = window.content.width, window.content.height

        -- Still changing (or first look): restart the countdown.
        if width ~= self.seenWidth or height ~= self.seenHeight then
            self.seenWidth, self.seenHeight = width, height
            self.stableTicks = 0
            return
        end

        -- Same size we built for: nothing to do. This is the usual case.
        if width == self.mountedWidth and height == self.mountedHeight then
            return
        end

        self.stableTicks = self.stableTicks + 1

        if self.stableTicks >= RESIZE_SETTLE_TICKS then
            self:mount(window.content)
        end
    end

    -- Starts the per-tick size check, if it isn't running already.
    function self:startResizeWatch()
        if self.watchingResize then
            return
        end

        self.watchingResize = true
        self.seenWidth, self.seenHeight = nil, nil

        Event.Logic.Subscribe(RESIZE_EVENT, function()
            self:checkSize()
        end)
    end

    -- Stops it again: the window is hidden, closed or gone.
    function self:stopResizeWatch()
        if not self.watchingResize then
            return
        end

        self.watchingResize = false
        Event.Logic.Unsubscribe(RESIZE_EVENT)
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
            self:startResizeWatch()

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
                -- Keep the title short; My account shows the character/profile
                -- binding.
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
                        calculator:checkpoint()
                        self.interactive = false
                        self:stopResizeWatch()
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
            self:startResizeWatch()
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
            -- Leave the ribbon clear unless opening fails. The message belongs
            -- below the button, without an empty gap above the action.
            local status

            -- SimpleButton uses a fixed width; it does not apply widthAnchor.
            -- Measure the ribbon content instead of passing a negative offset.
            local buttonWidth = math.max(1, launcher.content.width - 20)

            launcher:AddSimpleButton("Open Profit Path", function()
                -- Ignore clicks on a launcher that's already been replaced.
                if self.active and self.launcher == launcher then
                    local opened, problem = self:openWindow()

                    if not opened then
                        if not status then
                            status = launcher:AddText({ text = "", x = 10, y = 82, width = -20, widthAnchor = 1, height = 100 })
                        end

                        status.content = problem
                    elseif status then
                        status.content = ""
                    end
                end
            end, { x = 10, y = 10, width = buttonWidth, height = 60 })
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
