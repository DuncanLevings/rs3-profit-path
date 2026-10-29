-- Browser behavior and native-UI boundary tests. The fake client records storage
-- and the fake PrettyUI records controls; neither proves how the game draws them.
return function(test, equal, client, pretty)
    local Browser = require("src/methods/browser")
    local Preferences = require("src/storage/preferences")

    -- Deliberately unsorted, with ties and unknowns. These are test labels, not
    -- researched difficulty assignments for any real boss.
    local function methods()
        return {
            { id = "z", title = "Same", category = "pvm", source_category = "Combat", difficulty = "Hard", intensity = "High" },
            { id = "unknown", title = "Unknown", category = "skilling", source_category = "Gathering", intensity = "Unclassified" },
            { id = "a", title = "Same", category = "pvm", source_category = "Combat", difficulty = "Easy", intensity = "Low", variant = "Solo" },
            { id = "b", title = "Other", category = "production", source_category = "Processing", intensity = "Moderate" },
        }
    end

    -- A compact way to assert an entire ordering, including the last element.
    local function ids(rows)
        local values = {}

        for _, row in ipairs(rows) do
            values[#values + 1] = row.id
        end

        return table.concat(values, ",")
    end

    test("all four browser sorts keep unknowns last in either direction with stable ties", function()
        client()

        local source = methods()
        local browser = Browser.new(source, Preferences.new(PersistentDB), function() end)
        browser.estimates = {
            a = { status = "available", profit = -10, roi = -5 },
            z = { status = "available", profit = -10, roi = 20 },
            b = { status = "available", profit = 0, roi = 0 },
            unknown = { status = "partial", profit = 999999, roi = 999999 },
        }

        browser:setSort("profit", true)
        equal(ids(browser:rows()), "b,a,z,unknown")

        browser:setSort("profit", false)
        equal(ids(browser:rows()), "a,z,b,unknown")

        browser:setSort("roi", true)
        equal(ids(browser:rows()), "z,b,a,unknown")

        browser:setSort("roi", false)
        equal(ids(browser:rows()), "a,b,z,unknown")

        browser:setSort("difficulty", true)
        equal(ids(browser:rows()), "z,a,b,unknown")

        browser:setSort("difficulty", false)
        equal(ids(browser:rows()), "a,z,b,unknown")

        browser:setSort("intensity", true)
        equal(ids(browser:rows()), "z,b,a,unknown")

        browser:setSort("intensity", false)
        equal(ids(browser:rows()), "a,b,z,unknown")

        equal(source[1].id, "z", "Never rearrange source records")
    end)

    test("search category and favourites combine without treating search as a pattern", function()
        client()

        local browser = Browser.new(methods(), Preferences.new(PersistentDB), function() end)
        browser.category = "pvm"
        browser.search = "SOLO"
        equal(ids(browser:rows()), "a")

        browser.search = "["
        equal(#browser:rows(), 0)

        browser.search = "combat"
        browser.section = "favourites"
        browser:toggleFavourite(browser.methods[1])
        equal(ids(browser:rows()), "z")

        browser:toggleFavourite(browser.methods[1])
        equal(#browser:rows(), 0)
    end)

    test("favourites survive reload and profile switches without changing saved rates", function()
        local state = client()
        local prefs = Preferences.new(PersistentDB)
        local steel = require("data/methods").methods[1]

        assert(prefs:saveRate(steel, 1000))
        assert(prefs:saveFavourite(steel.id, true))
        assert(prefs:saveFavourite("future-method", true))

        local reloaded = Preferences.new(PersistentDB)
        assert(reloaded:loadFavourites()[steel.id])
        equal(reloaded:loadRate(steel), 1000)

        assert(reloaded:selectProfile("Other"))
        equal(next(reloaded:loadFavourites()), nil)

        assert(reloaded:selectProfile("Default"))
        assert(reloaded:saveFavourite(steel.id, false))
        assert(reloaded:loadFavourites()["future-method"], "Keep IDs outside the current bundle")
        equal(reloaded:loadRate(steel), 1000)

        assert(next(state.db))
    end)

    test("invalid favourite data recovers valid IDs and protects unknown schemas and failed reads", function()
        local state = client()
        local prefs = Preferences.new(PersistentDB)
        local key = "profit-path.favourites.v1/7:Default"
        state.db[key] = { schema = 1, ids = { good = true, bad = "true", [2] = true } }

        local saved, warning = prefs:loadFavourites()
        assert(saved.good and warning)
        equal(saved.bad, nil)

        assert(prefs:saveFavourite("second", true))
        assert(prefs:loadFavourites().good)

        local unsupported = { schema = 9, ids = { good = true } }
        state.db[key] = unsupported
        equal(prefs:saveFavourite("second", true), false)
        equal(state.db[key], unsupported)

        state.failRead = true
        equal(prefs:saveFavourite("second", true), false)
        equal(state.db[key], unsupported)
    end)

    test("sort restores valid fields independently and failed writes keep the selected state", function()
        local state = client()
        state.db["profit-path.browser.v1"] = { schema = 1, sort = "bad", descending = false }

        local prefs = Preferences.new(PersistentDB)
        local settings, warning = prefs:loadBrowser()
        equal(settings.sort, "profit")
        equal(settings.descending, false)
        assert(warning)

        local browser = Browser.new(methods(), prefs, function() end)
        state.failWrite = true

        equal(browser:setSort("roi", true), false)
        equal(browser.sort, "profit")
        equal(browser.descending, false)
        assert(browser.message:find("could not be saved", 1, true))

        equal(browser:toggleFavourite(browser.methods[1]), false)
        equal(browser.favourites.z, nil)

        state.failWrite = false
        assert(browser:setSort("roi", true))

        local restored = Browser.new(methods(), Preferences.new(PersistentDB), function() end)
        equal(restored.sort, "roi")
        equal(restored.descending, true)
    end)

    -- The list is the rightmost nested view; the header's text field must survive
    -- replacing it, otherwise typing would repeatedly lose keyboard focus.
    local function list(screen)
        return screen.children[#screen.children]
    end

    test("browser keeps filters and scroll on Back and ignores replaced row callbacks", function()
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()

        local browse = prettyui.views[2]
        local header = browse.children[2]
        local original = list(browse)
        local oldOpen = prettyui:findMethod("Smelting steel bars")

        header.fields[1]:SetText("steel", true)
        assert(original.destroyed)
        assert(not header.destroyed)

        oldOpen()
        equal(#prettyui.views, 2, "Discard callbacks from replaced results")

        local filtered = list(browse)
        filtered.scrollY = 123
        prettyui:findMethod("Smelting steel bars")()

        local detail = prettyui.views[3]
        prettyui:findButton("Add favourite")()
        detail.buttons["Back to methods"]()

        local returned = prettyui.views[4]
        equal(returned.children[2].fields[1]:GetText(), "steel")
        equal(list(returned).scrollY, 123)

        prettyui:findButton("Favourites")()
        assert(prettyui:findMethod("Smelting steel bars"))
        assert(not prettyui:findMethod("Cutting elder logs"))

        PluginShutdown()

        for _, child in ipairs(prettyui.allViews) do
            assert(child.destroyed, "Nested browser views must be released")
        end
    end)

    test("opening refreshes estimates while filtering and returning reuse captured prices", function()
        client()
        prettyui = pretty()

        local calls = 0
        gepl = {
            isReady = function() return true end,
            getLatest = function()
                calls = calls + 1
                return { high = 10, low = 20, highTime = 1, lowTime = 1 }
            end,
        }

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        equal(calls, 3)

        local browse = prettyui.views[2]
        local header = browse.children[2]
        header.fields[1]:SetText("steel", true)
        header.nativeLists[1]:SetEntrySelected(2, true)
        Event.Logic.emit({})
        equal(calls, 3)


        prettyui:findMethod("Smelting steel bars")()
        equal(calls, 6)

        local detail = prettyui.views[3]
        detail.tabs[1].pages[1].fields[1]:SetText("1000", true)
        detail.buttons["Back to methods"]()
        equal(calls, 6)

        -- An unsaved draft must not leak into saved-rate list comparisons.
        local text = {}

        for _, label in ipairs(list(prettyui.views[4]):allTexts()) do
            text[#text + 1] = label.content

            if type(label.options) == "table" and label.options.tooltip then
                text[#text + 1] = label.options.tooltip
            end
        end

        assert(table.concat(text):find("2000 smelts/hour", 1, true))

        PluginShutdown()
    end)

    test("character bindings preserve legacy choices and separate later characters", function()
        local state = client()
        local prefs = Preferences.new(PersistentDB)
        local steel = require("data/methods").methods[1]
        assert(prefs:saveRate(steel, 1000))
        assert(prefs:saveFavourite(steel.id, true))
        assert(prefs:bindCharacter("First"))
        equal(prefs:loadRate(steel), 1000)
        assert(prefs:loadFavourites()[steel.id])

        assert(prefs:bindCharacter("Second"))
        equal(prefs:loadRate(steel), steel.income.rate.default)
        equal(next(prefs:loadFavourites()), nil)
        assert(prefs:saveRate(steel, 500))

        assert(prefs:bindCharacter("FIRST"))
        equal(prefs:loadRate(steel), 1000)
        equal(prefs.profile, "Default")

        state.failWrite = true
        equal(prefs:bindCharacter("Third"), false)
        equal(prefs.profile, "Default")
    end)

    test("a profile switch invalidates list rates even when favourites reload before Back", function()
        client()

        local prefs = Preferences.new(PersistentDB)
        local source = methods()
        local browser = Browser.new(source, prefs, function()
            return { status = "available", profit = 5 }
        end)

        browser:refreshEstimates()
        assert(browser.estimates.z)

        assert(prefs:selectProfile("Other"))
        browser:loadFavourites()
        equal(next(browser.estimates), nil)

        browser:returnFromMethod(source[1], {})
        assert(browser.estimates.z)
        equal(browser.estimates.a, nil)
    end)

    test("a failed result rebuild releases partial rows and ignores their old callbacks", function()
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()

        local browse = prettyui.views[2]
        local old = list(browse)
        local callback = prettyui:findMethod("Smelting steel bars")
        prettyui.failTitle = true

        local success, problem = pcall(function()
            browse.children[2].fields[1]:SetText("steel", true)
        end)

        equal(success, false)
        assert(tostring(problem):find("Constructor failure", 1, true))
        assert(old.destroyed and list(browse).destroyed)

        callback()
        equal(#prettyui.views, 2)

        -- The header still works: a subsequent valid rebuild can recover.
        prettyui.failTitle = false
        browse.children[2].fields[1]:SetText("", true)
        assert(not list(browse).destroyed)

        PluginShutdown()
    end)

    test("sidebar highlights match the active section and category independently", function()
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()

        local sidebar = prettyui.views[2].children[1]
        assert(sidebar.buttonControls.Browse.active)
        assert(sidebar.buttonControls["All activities"].active)

        sidebar.buttons.Skilling()
        assert(sidebar.buttonControls.Skilling.active)
        assert(not sidebar.buttonControls["All activities"].active)

        sidebar.buttons.Favourites()
        assert(sidebar.buttonControls.Favourites.active)
        assert(not sidebar.buttonControls.Browse.active)
        assert(sidebar.buttonControls.Skilling.active)

        PluginShutdown()
    end)

    test("money presentation keeps negative values precision and unavailable states distinct", function()
        local Style = require("src/ui/view_style")

        equal(Style.number(1234567.899), "1,234,568")
        equal(Style.number(-1000.125, 1), "-1,000.1")
        equal(Style.number(0), "0")
        equal(Style.number(nil), "Unavailable")
        equal(Style.compact(-38000), "-38.0k/h")
        equal(Style.compact(1200000), "1.2m/h")
        equal(Style.compact(nil), "Not estimated")
        equal(Style.quantity(2000), "2,000")
        equal(Style.quantity(1.25), "1.25")
    end)

    test("native sort reconciles after selection delivery and restores failed saves without looping", function()
        local state = client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()

        local header = prettyui.views[2].children[2]
        local sort = header.nativeLists[1]
        local direction = header.nativeLists[2]
        equal(sort.stylesheetID, id.StyleSheet.DROPDOWN_DEFAULT)

        -- Several hooks can arrive before the native collection catches up.
        sort:SetEntrySelected(4, true)
        sort:SetEntrySelected(3, true)

        sort:SetEntrySelected(2, true)
        direction:SetEntrySelected(2, true)
        Event.Logic.emit({})
        equal(state.db["profit-path.browser.v1"].sort, "roi")
        equal(state.db["profit-path.browser.v1"].descending, false)

        local afterClick = sort.selectionWrites
        sort.callback(sort, 1, ui.SelectionChangeEvent.SELECTED)
        Event.Logic.emit({})
        equal(state.db["profit-path.browser.v1"].sort, "roi", "Ignore stale queued events")
        equal(sort.selectionWrites, afterClick, "A successful click must not reset native selection")
        equal(Event.Logic.count(), 0)

        state.failWrite = true
        sort:SetEntrySelected(3, true)
        Event.Logic.emit({})
        equal(sort.selectedID, 2)
        equal(state.db["profit-path.browser.v1"].sort, "roi")

        state.failWrite = false
        PluginShutdown()
        sort.callback(sort, 3, ui.SelectionChangeEvent.SELECTED)
        equal(state.db["profit-path.browser.v1"].sort, "roi", "Discard late native selection callbacks")
        equal(Event.Logic.count(), 0)
    end)

    test("reopening refreshes prices without resetting a method draft or adding a manual refresh button", function()
        client()
        prettyui = pretty()

        local price = 20
        local calls = 0
        gepl = {
            isReady = function() return true end,
            getLatest = function()
                calls = calls + 1
                return { high = 10, low = price, highTime = 1, lowTime = 1 }
            end,
        }

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findMethod("Smelting steel bars")()

        local detail = prettyui.views[3]
        local income = detail.tabs[1].pages[1]
        local rate = income.fields[1]
        rate:SetText("1000", true)
        equal(calls, 6)
        assert(not income.buttons["Refresh prices"])

        prettyui.windows[1]:Close()
        price = 50
        prettyui:findButton("Open Profit Path")()
        equal(calls, 9)
        equal(rate:GetText(), "1000")

        local lines = {}

        for _, label in ipairs(income:allTexts()) do
            lines[#lines + 1] = label.content
        end

        local text = table.concat(lines, "\n")
        assert(text:find("29,000/hour", 1, true), "Recalculate using fresh quotes and the draft rate")
        assert(not text:find("Trade timestamp", 1, true))
        assert(not text:find("GE sale tax", 1, true))
        assert(not text:find(".00", 1, true))
        assert(text:find("Outputs", 1, true))

        PluginShutdown()
    end)

    test("missing ROI is omitted and item lists use native icons with name tooltips", function()
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findMethod("Cutting elder logs")()

        local detail = prettyui.views[3]
        local income = detail.tabs[1].pages[1]
        equal(#income.fields, 1, "No manual character/profile field in the method")

        for _, label in ipairs(income:allTexts()) do
            assert(not label.content:find("ROI unavailable", 1, true))
            assert(not label.content:find("Perfect plus potion", 1, true))
        end

        local names = {}

        for _, panel in ipairs(income.children) do
            for _, slot in ipairs(panel.items or {}) do
                names[#names + 1] = slot.tooltip
            end
        end

        assert(table.concat(names):find("Perfect plus potion", 1, true))
        assert(table.concat(names):find("Elder logs", 1, true))
        assert(prettyui.windows[1].options.title:find("Fixture", 1, true))

        PluginShutdown()
    end)

    test("item sections share a row only when both required and recommended items exist", function()
        client()
        local library = pretty()
        local base = require("data/methods").methods[1]
        local Requirements = require("src/game/requirements")

        for _, counts in ipairs({ { 1, 1 }, { 1, 0 }, { 0, 1 }, { 0, 0 } }) do
            local method = {}

            for key, value in pairs(base) do
                method[key] = value
            end

            local required = { kind = "all", text = "Required", children = {} }
            local recommended = { kind = "all", text = "Recommended", children = {} }

            for index, group in ipairs({ required, recommended }) do
                if counts[index] == 1 then
                    group.children[1] = { kind = "gear", text = "A suitable tool", equipment_scope = "flexible" }
                end
            end

            method.requirements = { coverage = "partial", access = required, recommended = recommended }
            local calculator = {
                rate = 2000,
                result = require("src/methods/income").calculate(base.income, 2000, {}),
                requirements = function()
                    return Requirements.evaluate(required, {}), Requirements.evaluate(recommended, {})
                end,
                ownership = function() return { counts = {}, complete = false } end,
            }
            local view = library.SimpleView.new({ width = 700, height = 500 }, { width = 700, height = 500 })
            require("src/ui/method_view").mount(view, method, calculator, function(callback) return callback end)
            local panels = {}

            for _, panel in ipairs(view.tabs[1].pages[2].children) do
                panels[panel.texts[1].content] = panel
            end

            local both = counts[1] == 1 and counts[2] == 1

            for index, title in ipairs({ "Required items", "Recommended items" }) do
                equal(panels[title] ~= nil, counts[index] == 1)

                if panels[title] then
                    equal(panels[title].options.widthAnchor, both and 0.5 or nil)
                    equal(panels[title].options.inline == true, both and index == 2)
                end
            end

            view:Destroy()
        end
    end)

    test("requirements show name-only tooltips and honest green red or unknown item borders", function()
        client()
        prettyui = pretty()
        gepl = nil
        local bankAvailable = false
        local owned = true

        Inventory.Find = function(definition)
            if definition.configName == "BANK" and not bankAvailable then
                return nil
            end

            return {
                isValid = true,
                GetTotal = function(_, itemId)
                    return owned and definition.configName == "INV" and itemId == 44550 and 1 or 0
                end,
            }
        end

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findMethod("Cutting elder logs")()

        local detail = prettyui.views[3]
        local requirements = detail.tabs[1].pages[2]
        local items

        for _, section in ipairs(requirements.children) do
            if section.texts[1].content == "Recommended items" then
                items = section
            end
        end

        assert(items)
        local Style = require("src/ui/view_style")
        local definitions = require("data/methods").items
        local graceIndex

        for index, slot in ipairs(items.items) do
            equal(slot.tooltip, definitions[tostring(slot.object.id)].name)

            if slot.object.id == 44548 then
                graceIndex = index
            else
                equal(items.rectangles[index].rgba, Style.muted)
            end
        end

        assert(graceIndex)
        equal(items.rectangles[graceIndex].rgba, Style.good)

        bankAvailable = true
        owned = false
        Event.InventoryUpdated.emit({ inv = config.Inv.INV })

        for _, border in ipairs(items.rectangles) do
            equal(border.rgba, Style.bad)
        end

        PluginShutdown()
    end)

    test("rsprite native icons use PrettyUI buttons and keep callbacks inert after navigation", function()
        local state = client()
        prettyui = pretty()
        gepl = nil
        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findMethod("Cutting elder logs")()
        local detail = prettyui.views[3]
        local income = detail.tabs[1].pages[1]
        local save = income.buttons["Save rate"]
        assert(type(income.buttonControls["Save rate"].sprite) == "number")
        income.fields[1]:SetText("100", true)
        save()

        local preferences = Preferences.new(PersistentDB)
        assert(preferences:bindCharacter("Fixture"))
        local method = require("data/methods").methods[2]
        equal(preferences:loadRate(method), 100)
        assert(state.spriteLookups.COINS)
        assert(state.spriteLookups.WARDROBE_ICON_PRESET_SAVE_24PX_0)
        assert(state.spriteLookups.SKILL_WOODCUTTING)
        assert(state.spriteLookups.INVENTION_ICON_PERKS_TOOLS_HONED)
        assert(state.spriteLookups.INVENTION_ICON_PERKS_TOOLS_FORTUNE)

        income.fields[1]:SetText("200", true)
        detail.buttons["Back to methods"]()
        save()
        equal(preferences:loadRate(method), 100)
        PluginShutdown()
    end)

    test("missing native sprites do not block browsing calculating or saving rates", function()
        local state = client()
        rsprite.Get = function() return nil end
        prettyui = pretty()
        gepl = nil
        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findMethod("Smelting steel bars")()

        local detail = prettyui.views[3]
        local income = detail.tabs[1].pages[1]
        income.fields[1]:SetText("1000", true)
        income.buttons["Save"]()
        local preferences = Preferences.new(PersistentDB)
        assert(preferences:bindCharacter("Fixture"))
        equal(preferences:loadRate(require("data/methods").methods[1]), 1000)

        -- Resolving a sprite later makes the next decoration usable.
        rsprite.Get = function(name)
            equal(name, "COINS")
            return 431
        end
        local icon = require("src/ui/view_style").icon(income, "coins", { size = 20 })
        assert(icon)
        PluginShutdown()
    end)

    test("display-name reads fail safely and character profile collisions stay separate", function()
        local state = client()
        local account = require("src/game/account").new(function() end)
        equal(account:readCharacterName(), "Fixture")

        Player.GetEntity = function() return nil end
        equal(account:readCharacterName(), nil)

        Player.GetEntity = function() return { isValid = false } end
        equal(account:readCharacterName(), nil)
        account:destroy()

        local prefs = Preferences.new(PersistentDB)
        assert(prefs:bindCharacter("First"))
        assert(prefs:bindCharacter("Default"))
        assert(prefs.profile ~= "Default", "Do not reuse the legacy owner's profile")
        local previous = prefs.profile
        state.failRead = true
        equal(prefs:bindCharacter("Third"), false)
        equal(prefs.profile, previous)
    end)

    test("an unexpected native item name never displays an unrelated item icon", function()
        client()
        local library = pretty()
        local parent = library.SimpleView.new({ width = 600, height = 400 }, { width = 600, height = 400 })
        config.Obj.FromID = function(id)
            return { id = id, name = "An unrelated item" }
        end

        local icon, name, verified = require("src/ui/item_icon").add(parent, 2353, {})
        equal(verified, false)
        equal(name, "Steel bar")
        equal(icon.sprite, "INFO")
        equal(parent.items, nil)
        parent:Destroy()
    end)

    test("native display names accept UTF-8 and nonbreaking spaces while preserving saved settings", function()
        equal(utf8, nil, "Run this regression with the client-unavailable library removed")
        client()
        local prefs = Preferences.new(PersistentDB)
        local steel = require("data/methods").methods[1]
        local first = "First\u{00A0}Name"
        local second = "\u{00C9}toile\u{00A0}\u{96EA}"

        assert(prefs:saveRate(steel, 1000))
        assert(prefs:saveFavourite(steel.id, true))
        assert(prefs:bindCharacter(first))
        equal(prefs:loadRate(steel), 1000)
        assert(prefs:loadFavourites()[steel.id])

        assert(prefs:bindCharacter(second))
        assert(prefs:saveRate(steel, 500))

        local restored = Preferences.new(PersistentDB)
        assert(restored:bindCharacter(second))
        equal(restored:loadRate(steel), 500)
        assert(restored:bindCharacter(first))
        equal(restored:loadRate(steel), 1000)
        assert(restored:loadFavourites()[steel.id])

        local profile = restored.profile

        for _, invalid in ipairs({ "", "   ", "Name\n", "Name\0" }) do
            equal(restored:bindCharacter(invalid), false)
            equal(restored.profile, profile)
        end
    end)
end
