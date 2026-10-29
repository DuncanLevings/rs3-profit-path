-- Entry point for Profit Path. This file wires everything together: account reads,
-- saved rates and the income calculator, and it owns the ribbon subscription plus
-- shutdown. Screen ownership lives in ui/workbench.lua instead.
local Account = require("src/game/account")
local Income = require("src/methods/income")
local Requirements = require("src/game/requirements")
local Preferences = require("src/storage/preferences")
local catalogue = require("src/data/method_data")
local UI = require("src/ui/workbench")
local Browser = require("src/methods/browser")
local Snapshot = require("src/storage/account_snapshot")

local App = {}

-- Each enable gets fresh state, even if the client has cached this module.
function App.start()
    -- Flips to false on shutdown so late callbacks know to do nothing.
    local active = true

    -- Created further down; the account callback below needs to see it, so declare it early.
    local view, calculator
    local snapshot = Snapshot.new(PersistentDB)

    -- When the account changes, refresh whatever's on screen. A game-state change
    -- (login, logout, world hop) is different: the game area our window hangs off may
    -- have been replaced, so we throw the window away instead of trusting it.
    local account = Account.new(function(reason)
        if not view then
            return
        end

        if reason == "game_state" then
            calculator.evidence = nil
            calculator.ownershipEvidence = nil
            view:destroyWindow()
        elseif view.interactive then
            calculator:refreshEvidence(reason)
            view:refresh(reason)
        end
    end, snapshot, catalogue.toolbelt)

    local preferences = Preferences.new(PersistentDB)

    -- The calculator is the state behind the method view: which method is open, the
    -- current rate, the captured prices and the latest result. The UI reads these
    -- fields and calls the methods below; it never does the maths itself.
    calculator = { profile = preferences.profile, quotes = {} }

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
        account:bindProfile(preferences.profile)
        self:refreshEvidence()
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

    -- Collect the bounded set needed by this catalogue. Extra tool candidates
    -- are included so a basic hatchet can satisfy 'your highest-tier hatchet'.
    local wanted, skillNames, questNames = {}, {}, {}
    local equipment = catalogue.equipment or {}

    -- Include charged/worn IDs as ownership aliases, but keep the display ID stable.
    local function wantItem(itemId)
        local item = catalogue.items[tostring(itemId)]
        wanted[itemId] = true

        for _, alias in ipairs(item.ownership_ids or {}) do
            wanted[alias] = true
        end
    end

    -- Walk both requirement trees once at startup, including nested alternatives.
    local function collect(requirement)
        if requirement.kind == "skill" then
            skillNames[requirement.skill] = true
        elseif requirement.kind == "quest" then
            questNames[requirement.quest] = true
        elseif requirement.kind == "item" then
            wantItem(requirement.itemId)
        elseif requirement.equipment_group then
            for _, candidate in ipairs(equipment[requirement.equipment_group].candidates) do
                wantItem(candidate.item_id)

                for skill in pairs(candidate.skills) do
                    skillNames[skill] = true
                end
            end
        end

        for _, itemId in ipairs(requirement.display_items or {}) do
            wantItem(itemId)
        end

        for _, child in ipairs(requirement.children or {}) do
            collect(child)
        end
    end

    for _, method in ipairs(catalogue.methods) do
        collect(method.requirements.access)
        collect(method.requirements.recommended)
    end

    -- Refresh only the evidence that changed. Inventory activity never re-reads
    -- skills/quests, and no persistence or native scans run in the resize watcher.
    function calculator:refreshEvidence(reason)
        local evidence = self.evidence or { skills = {}, quests = {}, items = {}, equipment = equipment }

        if reason == nil or reason == "skills" then
            evidence.skills = account:readSkills(skillNames)
        end

        if reason == nil or reason == "quests" then
            for name in pairs(questNames) do
                evidence.quests[name] = account:readQuest(name)
            end
        end

        -- A live total and a historical hint are separate fields all the way to
        -- the UI. Aliases may add current quantities, but saved counts use a max.
        if reason == nil or reason == "inventory" then
            self.ownershipEvidence = account:readOwnership(wanted)
            evidence.items = {}

            for key, item in pairs(catalogue.items) do
                local itemId = tonumber(key)

                if wanted[itemId] then
                    local quantity = self.ownershipEvidence.counts[itemId] or 0
                    local savedQuantity = (self.ownershipEvidence.savedCounts or {})[itemId] or 0
                    local beltCounts = self.ownershipEvidence.toolbelt and self.ownershipEvidence.toolbelt.counts or {}
                    local onToolbelt = (beltCounts[itemId] or 0) > 0
                    local absent = self.ownershipEvidence.lastKnownAbsent or {}
                    local lastKnownAbsent = absent[itemId] == true

                    for _, alias in ipairs(item.ownership_ids or {}) do
                        quantity = quantity + (alias ~= itemId and self.ownershipEvidence.counts[alias] or 0)
                        savedQuantity = math.max(savedQuantity, (self.ownershipEvidence.savedCounts or {})[alias] or 0)
                        onToolbelt = onToolbelt or (beltCounts[alias] or 0) > 0
                        lastKnownAbsent = lastKnownAbsent and absent[alias] == true
                    end

                    -- Native name verification prevents a wrong catalogue ID from
                    -- qualifying an item or a supposedly higher-tier tool.
                    local ok, name = pcall(function()
                        local object = config.Obj.FromID(itemId)
                        return object and object.name
                    end)

                    local verified = ok and type(name) == "string" and name:lower() == item.name:lower()

                    evidence.items[itemId] = {
                        status = verified and (quantity > 0 or self.ownershipEvidence.complete) and "available" or "unknown",
                        quantity = quantity, savedQuantity = savedQuantity, toolbelt = onToolbelt,
                        complete = verified and self.ownershipEvidence.complete,
                        lastKnownAbsent = verified and lastKnownAbsent,
                    }
                end
            end
        end

        self.evidence = evidence
        self.accessChanged = false

        -- Browse consumes these same verdicts. Source coverage is separate from
        -- account evidence: passing known checks cannot fill an unmapped setup.
        for _, method in ipairs(catalogue.methods) do
            local checked = Requirements.evaluate(method.requirements.access, evidence)

            if checked.status == "met" and method.requirements.coverage ~= "complete" then
                checked.status = "unknown"
                checked.reason = "Some access requirements still need verification."
            end

            local previous = browser.readiness[method.id]
            self.accessChanged = self.accessChanged or not previous or previous.status ~= checked.status
            browser.readiness[method.id] = checked
        end
    end

    -- The UI reads the same evidence used by Browse. A saved bank hint isn't added
    -- to live counts and can never turn an unknown requirement into a pass.
    function calculator:ownership()
        local result = self.ownershipEvidence or { counts = {}, complete = false }
        result.message = snapshot.message or (result.toolbelt and result.toolbelt.message)
        return result
    end

    function calculator:requirements()
        return Requirements.evaluate(self.method.requirements.access, self.evidence or {}),
            Requirements.evaluate(self.method.requirements.recommended, self.evidence or {})
    end

    -- Save historical evidence at meaningful UI checkpoints, not per XP drop.
    function calculator:checkpoint()
        snapshot:flush()
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
