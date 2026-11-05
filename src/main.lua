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
local CustomMethods = require("src/methods/custom_methods")
local ItemNames = require("src/data/item_names")

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
    -- `shared` is Browse's price snapshot for the whole refresh (see Browser).
    local function estimateMethod(method, quotes, shared)
        if method.income.coverage ~= "complete" then
            return { status = "partial" }
        end

        local rate, _, warning = preferences:loadRate(method)
        local captured = quotes or Income.captureQuotes(gepl, method.income, shared)
        local result = Income.calculate(method.income, rate, captured)
        result.rate = rate
        result.message = warning or result.message

        return result
    end

    -- Browse gets the bundled catalogue plus the player's custom activities. The
    -- customs are shared by every profile, so they load once here. A damaged save
    -- just means no customs (with a message); the bundled ones still work.
    local methods = {}

    for _, method in ipairs(catalogue.methods) do
        methods[#methods + 1] = method
    end

    local customs = CustomMethods.store(PersistentDB)
    local records, customWarning = customs:load()

    for _, record in ipairs(records) do
        methods[#methods + 1] = CustomMethods.toMethod(record)
    end

    -- Kept for the custom activities screen (slice 3), which will show the warning.
    calculator.customs = customs
    calculator.customWarning = customWarning

    local browser = Browser.new(methods, preferences, estimateMethod)

    -- For the Custom activities list: its empty state and load warning.
    browser.customCount = #records
    browser.customWarning = customWarning

    -- Resolve account context only when the window is opened. A failed name read
    -- blocks opening rather than saving this character's choices under another one.
    function calculator:useCharacter()
        -- Settings are keyed by display name. (The tracking ID would survive a
        -- rename, but reading it crashes this client; see preferences.lua.)
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

    -- One GE quote, for the custom activity editor's rows.
    function calculator:quote(itemId)
        return Income.inspectQuote(gepl, itemId)
    end

    -- Saves a custom activity draft (new or edited) and puts it in the lists.
    -- Returns the saved record, or nil plus a message or a list of problems.
    function calculator:saveCustom(draft)
        local saved, problem

        if draft.id then
            saved, problem = customs:update(draft)
        else
            saved, problem = customs:create(draft)
        end

        if saved then
            local method = CustomMethods.toMethod(saved)
            browser:putCustom(method)

            -- Start reading whatever its requirements ask about (defined below,
            -- next to the startup walk).
            self:watchRequirements(method)
        end

        return saved, problem
    end

    function calculator:deleteCustom(customId)
        local deleted, problem = customs:delete(customId)

        if deleted then
            browser:removeCustom(customId)
        end

        return deleted, problem
    end

    function calculator:refreshPrices()
        self.quotes = Income.captureQuotes(gepl, self.method.income)
        self:recalculate()
    end

    -- Collect the bounded set needed by this catalogue. Extra tool candidates
    -- are included so a basic hatchet can satisfy 'your highest-tier hatchet'.
    local wanted, skillNames, questNames = {}, {}, {}

    -- Unlock flags (game variable names) and achievement IDs that requirements check.
    local flagNames, achievementIds = {}, {}

    -- Whether any method has a combat level requirement (then we read it with skills).
    local needsCombat = false
    local equipment = catalogue.equipment or {}

    -- Each equipment group's candidates by slot, so a weapon check skips armour.
    for _, group in pairs(equipment) do
        group.bySlot = {}

        for _, candidate in ipairs(group.candidates) do
            if candidate.slot then
                group.bySlot[candidate.slot] = group.bySlot[candidate.slot] or {}
                table.insert(group.bySlot[candidate.slot], candidate)
            end
        end
    end

    -- Groups whose items are already wanted (many checks share one group).
    local collectedGroups = {}

    -- GE items a custom activity's requirements name that the bundled catalogue
    -- doesn't have, by ID: { name = ... } (from the GE item names).
    local extraItems = {}

    -- Include charged/worn IDs as ownership aliases, but keep the display ID stable.
    local function wantItem(itemId)
        local item = catalogue.items[tostring(itemId)]
        wanted[itemId] = true

        if not item then
            local name = ItemNames.label(itemId)

            if name then
                extraItems[itemId] = { name = name }
            end

            return
        end

        for _, alias in ipairs(item.ownership_ids or {}) do
            wanted[alias] = true
        end
    end

    -- Walk both requirement trees once at startup, including nested alternatives.
    local function collect(requirement)
        if requirement.kind == "skill" then
            skillNames[requirement.skill] = true
        elseif requirement.kind == "combat_level" then
            needsCombat = true
        elseif requirement.kind == "flag" then
            flagNames[requirement.var] = true
        elseif requirement.kind == "achievement" then
            for _, achievementId in ipairs(requirement.ids) do
                achievementIds[achievementId] = true
            end
        elseif requirement.kind == "quest" then
            questNames[requirement.quest] = true
        elseif requirement.kind == "item" then
            wantItem(requirement.itemId)
        elseif requirement.equipment_group and not collectedGroups[requirement.equipment_group] then
            collectedGroups[requirement.equipment_group] = true

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

    -- Custom activities included, so their levels, quests and items are read too.
    for _, method in ipairs(methods) do
        collect(method.requirements.access)
        collect(method.requirements.recommended)
    end

    -- Starts reading anything new a just-saved custom activity's requirements ask
    -- about. `wanted` is replaced, not changed in place: readOwnership remembers
    -- which set it last checked the bank against, and a new item needs a fresh look.
    function calculator:watchRequirements(method)
        local before = wanted
        wanted = {}

        for itemId in pairs(before) do
            wanted[itemId] = true
        end

        collect(method.requirements.access)
        collect(method.requirements.recommended)

        -- Only once the window has read the account; opening it reads everything.
        if self.evidence then
            self:refreshEvidence()
        end
    end

    -- Whether each catalogue item's ID really is that item in this client, by name.
    -- Names never change, so a successful check is kept for the session: with the
    -- full catalogue there are hundreds of items, and inventory changes are frequent.
    -- A failed read (e.g. config not loaded yet) isn't kept, so it's tried again.
    local nameChecks = {}

    local function nameMatches(itemId, expected)
        if nameChecks[itemId] == nil then
            local ok, name = pcall(function()
                local object = config.Obj.FromID(itemId)
                return object and object.name
            end)

            -- A failed read is "can't tell" (nil), not a mismatch (false).
            if not ok or type(name) ~= "string" then
                return nil
            end

            nameChecks[itemId] = name:lower() == expected:lower()
        end

        return nameChecks[itemId]
    end

    -- Refresh only the evidence that changed. Inventory activity never re-reads
    -- skills/quests, and no persistence or native scans run in the resize watcher.
    function calculator:refreshEvidence(reason)
        local evidence = self.evidence or { skills = {}, quests = {}, items = {}, equipment = equipment }

        if reason == nil or reason == "skills" then
            evidence.skills = account:readSkills(skillNames)

            -- Combat level only changes when a combat skill levels up.
            if needsCombat then
                evidence.combat = account:readCombatLevel()
            end
        end

        if reason == nil or reason == "quests" then
            for name in pairs(questNames) do
                evidence.quests[name] = account:readQuest(name)
            end

            -- Relics and achievements change rarely; read them with quests and on
            -- every full refresh (opening the window).
            evidence.flags = account:readFlags(flagNames)
            evidence.achievements = account:readAchievements(achievementIds)
        end

        -- A live total and a historical hint are separate fields all the way to
        -- the UI. Aliases may add current quantities, but saved counts use a max.
        if reason == nil or reason == "inventory" then
            self.ownershipEvidence = account:readOwnership(wanted)
            evidence.items = {}

            -- One item's evidence, from what readOwnership saw.
            local function observe(itemId, item)
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
                    local verified = nameMatches(itemId, item.name)

                    evidence.items[itemId] = {
                        -- false when the client's name for this ID isn't the catalogue's.
                        verified = verified,
                        status = verified and (quantity > 0 or self.ownershipEvidence.complete) and "available" or "unknown",
                        quantity = quantity, savedQuantity = savedQuantity, toolbelt = onToolbelt,
                        complete = verified and self.ownershipEvidence.complete,
                        lastKnownAbsent = verified and lastKnownAbsent,
                    }
                end
            end

            for key, item in pairs(catalogue.items) do
                observe(tonumber(key), item)
            end

            for itemId, item in pairs(extraItems) do
                observe(itemId, item)
            end
        end

        self.evidence = evidence
        self.accessChanged = false

        -- Browse filters the listed requirements, using the same verdicts as
        -- the method page. A source's research status isn't a failed player check;
        -- individual checks with missing evidence still stay unknown on their own.
        for _, method in ipairs(browser.methods) do
            local checked = Requirements.evaluateAccess(method.requirements, evidence)

            local previous = browser.readiness[method.id]
            self.accessChanged = self.accessChanged or not previous or previous.status ~= checked.status
            browser.readiness[method.id] = checked
        end
    end

    -- The UI reads the same evidence used by Browse. (A closed bank counts as it
    -- was last seen open; see readOwnership.) A saved backpack hint isn't added
    -- to live counts and can never turn an unknown requirement into a pass.
    function calculator:ownership()
        local result = self.ownershipEvidence or { counts = {}, complete = false }
        result.message = snapshot.message or (result.toolbelt and result.toolbelt.message)
        return result
    end

    function calculator:requirements()
        return Requirements.evaluateAccess(self.method.requirements, self.evidence or {}),
            Requirements.evaluate(self.method.requirements.recommended, self.evidence or {})
    end

    -- Save historical evidence at meaningful UI checkpoints, not per XP drop.
    function calculator:checkpoint()
        snapshot:flush()
    end

    view = UI.new(prettyui, account, calculator, browser)

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
