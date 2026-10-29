-- Entry point for Profit Path. This file wires everything together: account reads,
-- saved rates and the income calculator, and it owns the ribbon subscription plus
-- shutdown. Screen ownership lives in ui/workbench.lua instead.
local Account = require("src/game/account")
local Income = require("src/methods/income")
local Requirements = require("src/game/requirements")
local Preferences = require("src/storage/preferences")
local catalogue = require("data/methods")
local UI = require("src/ui/workbench")
local Browser = require("src/methods/browser")

local App = {}

-- Each enable gets fresh state, even if the client has cached this module.
function App.start()
    -- Flips to false on shutdown so late callbacks know to do nothing.
    local active = true

    -- Created further down; the account callback below needs to see it, so declare it early.
    local view

    -- When the account changes, refresh whatever's on screen. A game-state change
    -- (login, logout, world hop) is different: the game area our window hangs off may
    -- have been replaced, so we throw the window away instead of trusting it.
    local account = Account.new(function(reason)
        if not view then
            return
        end

        if reason == "game_state" then
            view:destroyWindow()
        else
            view:refresh(reason)
        end
    end)

    local preferences = Preferences.new(PersistentDB)

    -- The calculator is the state behind the method view: which method is open, the
    -- current rate, the captured prices and the latest result. The UI reads these
    -- fields and calls the methods below; it never does the maths itself.
    local calculator = { profile = preferences.profile, quotes = {} }

    -- List estimates use saved rates, not the unsaved draft in an open method.
    -- Partial recipes aren't priceable yet, so don't make needless quote requests.
    local function estimateMethod(method, quotes)
        if method.income.coverage ~= "complete" then
            return { status = "partial" }
        end

        local rate, _, warning = preferences:loadRate(method)
        local captured = quotes or Income.captureQuotes(gepl, method.income)
        local result = Income.calculate(method.income, rate, captured)
        result.rate = rate
        result.message = warning or result.message

        return result
    end

    local browser = Browser.new(catalogue.methods, preferences, estimateMethod)

    -- Resolve account context only when the window is opened. A failed name read
    -- blocks edits rather than saving this character's choices under another one.
    function calculator:useCharacter()
        local name, problem = account:readCharacterName()

        if not name then
            return false, problem
        end

        local previous = preferences.profile
        local ok, message = preferences:bindCharacter(name)

        if not ok then
            return false, message
        end

        self.characterName = name
        account.ownershipCache = {}
        self.profile = preferences.profile
        browser:loadFavourites()

        if self.method and previous ~= preferences.profile then
            self:loadRate()
        end

        return true
    end

    function calculator:recalculate()
        self.result = Income.calculate(self.method.income, self.rate, self.quotes)
    end

    -- Loads the saved rate for this method (or the source default) and recalculates.
    function calculator:loadRate()
        self.rate, self.saved, self.message = preferences:loadRate(self.method)
        self.message = self.message or preferences.warning

        -- committedRate is "what's saved right now", so we can tell if a draft differs.
        self.committedRate = self.rate
        self.dirty = false

        self:recalculate()
    end

    -- Opening a method grabs one fresh set of prices; rate edits reuse them after that.
    function calculator:select(method)
        self.method = method
        self.quotes = Income.captureQuotes(gepl, method.income)
        self:loadRate()
    end

    -- Tries a typed rate without saving it. Bad input keeps the last good estimate on
    -- screen and just sets a message, so the numbers never flicker to garbage.
    function calculator:preview(text)
        local rate, problem = Income.parseRate(text)

        if not rate then
            self.message = problem .. " Keeping the last valid estimate."
            return false
        end

        local result = Income.calculate(self.method.income, rate, self.quotes)

        if result.status == "invalid" then
            self.message = result.message .. " Keeping the last valid estimate."
            return false
        end

        -- Typing back the saved value counts as "not dirty", so no extra save is needed.
        self.dirty = rate ~= self.committedRate
        self.rate = rate
        self.result = result
        self.message = nil

        return true
    end

    -- Saves only if the text is a valid rate. Storage errors come back as the message.
    function calculator:save(text)
        if not self:preview(text) then
            return false
        end

        local ok, problem = preferences:saveRate(self.method, self.rate)
        self.message = problem

        if ok then
            self.saved = true
            self.dirty = false
            self.committedRate = self.rate
        end

        return ok
    end

    -- Deletes the saved override and goes back to the source's default rate.
    function calculator:reset()
        local ok, problem = preferences:resetRate(self.method)
        self.message = problem

        if ok then
            self.rate = self.method.income.rate.default
            self.committedRate = self.rate
            self.saved = false
            self.dirty = false

            self:recalculate()
        end

        return ok
    end

    function calculator:refreshPrices()
        self.quotes = Income.captureQuotes(gepl, self.method.income)
        self:recalculate()
    end

    -- Icon borders use exact item-presence evidence, never gear readiness.
    function calculator:ownership(wanted)
        return account:readOwnership(wanted)
    end

    -- Checks the open method's requirements against the player. Right now only skill
    -- levels are read live, so we walk the requirement tree to find which skills matter
    -- and read just those, rather than every skill in the game.
    function calculator:requirements()
        local names = {}

        local function collect(requirement)
            if requirement.kind == "skill" then
                names[requirement.skill] = true
            end

            for _, child in ipairs(requirement.children or {}) do
                collect(child)
            end
        end

        collect(self.method.requirements.access)
        collect(self.method.requirements.recommended)

        local evidence = { skills = account:readSkills(names) }

        -- Access (can you do it at all) and recommended (should you) are checked separately.
        return Requirements.evaluate(self.method.requirements.access, evidence),
            Requirements.evaluate(self.method.requirements.recommended, evidence)
    end

    -- Temporary diagnostics callbacks; remove them with diagnostics.lua.
    local function inspectChronotesQuote()
        -- The verified GEPL example identifies chronotes as item 49430.
        return Income.inspectQuote(gepl, 49430)
    end

    local function inspectQuestRequirement(name)
        local quest = account:inspectQuest(name)
        if quest.status == "available" then
            quest.requirement = Requirements.evaluate({
                kind = "quest", quest = name, text = "Complete " .. quest.name,
            }, { quests = { [name] = quest } })
        end
        return quest
    end

    view = UI.new(prettyui, account, inspectChronotesQuote, inspectQuestRequirement, calculator, browser)

    -- The client tells us when our ribbon page is ready; that's where the launcher goes.
    -- This can fire more than once (e.g. after a reload), and mountLauncher handles that.
    Event.ContentLayerReady.Subscribe("profit-path-content", function(event)
        if active then
            view:mountLauncher(event.component)
        end
    end)

    -- Called by the client when the plugin is disabled or reloaded. Order matters: stop
    -- listening to events first, so nothing tries to update UI we're about to destroy.
    local function shutdown()
        if not active then
            return
        end

        active = false

        Event.ContentLayerReady.Unsubscribe("profit-path-content")
        account:destroy()
        view:destroy()
    end

    return shutdown
end

return App
