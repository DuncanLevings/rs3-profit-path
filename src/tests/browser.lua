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

    test("profit and ROI sorts keep unknowns last in either direction with stable ties", function()
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

        equal(source[1].id, "z", "Never rearrange source records")
    end)

    -- Difficulty and intensity are filters now, not sorts. "Moderate" and "Medium"
    -- are the same intensity, and a method with no difficulty never matches one.
    test("difficulty and intensity filters narrow the list and combine", function()
        client()

        local source = methods()
        source[#source + 1] = { id = "m", title = "Medium one", category = "skilling", source_category = "Gathering", intensity = "Medium" }

        local browser = Browser.new(source, Preferences.new(PersistentDB), function() end)
        browser.estimates = {}

        browser.difficulty = "Hard"
        equal(ids(browser:rows()), "z")

        browser.difficulty = "any"
        browser.intensity = "Moderate"
        equal(ids(browser:rows()), "m,b")

        browser.intensity = "Low"
        browser.difficulty = "Easy"
        equal(ids(browser:rows()), "a")

        browser.difficulty = "Hard"
        equal(ids(browser:rows()), "")

        -- Old saved sorts that are now filters fall back to the profit default.
        local state = client()
        state.db["profit-path.browser.v1"] = { schema = 1, sort = "difficulty", descending = false }
        equal(Preferences.new(PersistentDB):loadBrowser().sort, "profit")
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
        local steel = require("src/data/method_data").find("smelting-steel-bars.basic")

        assert(prefs:saveRate(steel, 1000))
        assert(prefs:saveFavourite(steel.id, true))
        assert(prefs:saveFavourite("future-method", true))

        local reloaded = Preferences.new(PersistentDB)
        assert(reloaded:loadFavourites()[steel.id])
        equal(reloaded:loadRate(steel), 1000)

        -- First character keeps Default's favourites; a second character has none.
        assert(reloaded:bindCharacter("First"))
        assert(reloaded:bindCharacter("Other"))
        equal(next(reloaded:loadFavourites()), nil)

        assert(reloaded:bindCharacter("First"))
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

    -- Typing redraws once, after a pause; Enter redraws at once; closing the
    -- screen mid-pause leaves nothing waiting.
    test("search redraws after a pause in typing, or straight away on Enter", function()
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()

        local browse = prettyui.views[2]
        local field = browse.children[2].fields[1]
        local original = list(browse)

        field:SetText("st", true)
        field:SetText("ste", true)
        field:SetText("steel", true)
        assert(not original.destroyed, "No redraw while still typing")

        -- A few ticks isn't a pause yet; a new keystroke restarts the wait.
        for _ = 1, 8 do
            Event.Logic.emit({})
        end

        field:SetText("steel ", true)

        for _ = 1, 8 do
            Event.Logic.emit({})
        end

        assert(not original.destroyed, "Each keystroke restarts the wait")

        settleSearch()
        assert(original.destroyed, "Redraws after the pause")
        assert(prettyui:findMethod("Smelting steel bars"))

        -- Enter doesn't wait.
        local filtered = list(browse)
        field:SetText("elder", true)
        field:Submit()
        assert(filtered.destroyed, "Enter redraws at once")
        assert(prettyui:findMethod("Cutting elder logs"))

        -- Closing mid-pause cancels the wait.
        field:SetText("steel", true)
        PluginShutdown()
        equal(Event.Logic.count(), 0, "Nothing left waiting after shutdown")
    end)

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
        settleSearch()
        assert(original.destroyed)
        assert(not header.destroyed)

        oldOpen()
        equal(#prettyui.views, 2, "Discard callbacks from replaced results")

        local filtered = list(browse)
        filtered.scrollY = 123
        prettyui:findMethod("Smelting steel bars")()

        local detail = prettyui.views[3]
        prettyui:findButton("Add favourite")()
        detail.buttons["Back to activities"]()

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

    -- Hidden methods are per profile, separate from favourites, and stay in every
    -- list. My account lists them in title order, plus IDs this bundle lacks.
    test("hidden methods are saved per profile and stay browsable", function()
        local state = client()
        local prefs = Preferences.new(PersistentDB)
        local browser = Browser.new(methods(), prefs, function() end)

        assert(browser:setHidden("z", true))
        assert(browser:setHidden("a", true))
        assert(prefs:saveHidden("future-method", true))
        browser:loadFavourites()

        -- Still in Browse, and favouriting is untouched.
        equal(ids(browser:rows()), "b,a,z,unknown")
        equal(next(browser.favourites), nil)

        -- Title order ("Same" twice, so ID breaks the tie), unknown IDs last.
        local listed = {}

        for _, entry in ipairs(browser:hiddenMethods()) do
            listed[#listed + 1] = entry.id .. (entry.method and "" or "?")
        end

        equal(table.concat(listed, ","), "a,z,future-method?")

        -- Another character has its own (empty) list.
        assert(prefs:bindCharacter("First"))
        assert(prefs:bindCharacter("Other"))
        browser:loadFavourites()
        equal(next(browser.hidden), nil)

        -- A failed write leaves the list as it was.
        state.failWrite = true
        equal(browser:setHidden("b", true), false)
        equal(browser.hidden.b, nil)
        assert(browser.message:find("could not be saved", 1, true), browser.message)

        -- An unreadable list is never overwritten with an empty one.
        state.failWrite = false
        state.db["profit-path.hidden.v1/5:Other"] = { schema = 2 }
        equal(prefs:saveHidden("b", true), false)
        equal(state.db["profit-path.hidden.v1/5:Other"].schema, 2)
    end)

    -- "Don't recommend" will live on Recommend for me's cards, so for now the
    -- test saves one directly. A Browse row that isn't recommended says so and its
    -- eye puts it back; other rows have no eye. My account has no search or
    -- filters, and lists what to recommend again.
    test("a method that isn't recommended is marked in Browse and listed in My account", function()
        client()
        prettyui = pretty()
        gepl = nil

        assert(Preferences.new(PersistentDB):saveHidden("smelting-steel-bars.basic", true))
        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()

        local returned = prettyui.views[2]
        returned.children[2].fields[1]:SetText("steel", true)
        settleSearch()

        -- The method page has no such button: that's for recommendations.
        prettyui:findMethod("Smelting steel bars")()
        equal(prettyui.views[3].buttons["Don't recommend"], nil)
        prettyui.views[3].buttons["Back to activities"]()
        returned = prettyui.views[4]

        local function row(title)
            for index = #prettyui.allViews, 1, -1 do
                local candidate = prettyui.allViews[index]

                if not candidate.destroyed and candidate.buttons["View activity"] then
                    for _, label in ipairs(candidate.texts) do
                        if label.content == title then
                            return candidate
                        end
                    end
                end
            end
        end

        local function says(view, text)
            for _, label in ipairs(view:allTexts()) do
                if label.content:find(text, 1, true) then
                    return true
                end
            end

            return false
        end

        local steel = row("Smelting steel bars")
        assert(says(steel, "Not recommended"), "A row that isn't recommended says so")
        equal(steel.buttonControls["Not recommended - click to recommend again"].disabled, true)

        -- My account: the header (search, filters) is gone while it's open.
        local header = returned.children[2]
        prettyui:findButton("My account")()
        assert(header.destroyed, "No search or filters on My account")

        local account = list(returned)
        assert(says(account, "My account"))
        prettyui:findButton("Recommend again")()
        assert(says(list(returned), "Nothing here"), "Recommended again, so the list is empty")

        -- An activity from My account opens Browse, with a new header.
        local function liveHeader()
            for index = #returned.children, 1, -1 do
                local child = returned.children[index]

                if not child.destroyed and child.fields[1] then
                    return child
                end
            end
        end

        prettyui:findButton("Skilling")()
        assert(liveHeader(), "The search box is back")
        equal(liveHeader().texts[1].content, "Browse activities")

        -- Back in Browse, the steel row has no eye again.
        prettyui:findButton("All activities")()
        liveHeader().fields[1]:SetText("steel", true)
        settleSearch()
        equal(row("Smelting steel bars").buttons["Not recommended - click to recommend again"], nil)

        PluginShutdown()
    end)

    -- Supplies cost far more than outputs sell for, so every priced method loses
    -- money: its profit and its negative ROI must both be red in Browse.
    test("losses show red profit and red ROI in Browse", function()
        client()
        prettyui = pretty()
        gepl = {
            isReady = function() return true end,
            getLatest = function()
                return { high = 1000, low = 1, highTime = 1, lowTime = 1 }
            end,
        }

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()

        local Style = require("src/ui/view_style")
        local redProfits, redRois = 0, 0

        for _, label in ipairs(prettyui.views[2]:allTexts()) do
            local text = tostring(label.content)

            if text:find(" / h", 1, true) and text:sub(1, 1) == "-" then
                equal(label.options.colour, Style.bad, "Loss colour for " .. text)
                redProfits = redProfits + 1
            end

            if text:find("% ROI", 1, true) and text:sub(1, 1) == "-" then
                equal(label.options.colour, Style.subtleBad, "Negative ROI colour for " .. text)
                redRois = redRois + 1
            end
        end

        assert(redProfits > 0 and redRois > 0, "Expected losses with negative ROI in Browse")
        PluginShutdown()
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
        equal(calls, 30)

        local browse = prettyui.views[2]

        -- Estimated profits use the method page's money colours: green for a
        -- profit, red for a loss.
        local Style = require("src/ui/view_style")
        local coloured = 0

        for _, label in ipairs(browse:allTexts()) do
            local text = tostring(label.content)

            if text:find(" / h", 1, true) then
                local expected = text:sub(1, 1) == "-" and Style.bad or Style.good
                equal(label.options.colour, expected, "Profit colour for " .. text)
                coloured = coloured + 1
            end

            -- ROI retains its sign using the quieter secondary money palette.
            if text:find("% ROI", 1, true) then
                local expected = text:sub(1, 1) == "-" and Style.subtleBad or Style.subtleGood
                equal(label.options.colour, expected, "ROI colour for " .. text)
            end
        end

        assert(coloured > 0, "Expected at least one estimated profit in Browse")

        local header = browse.children[2]
        header.fields[1]:SetText("steel", true)
        settleSearch()
        header.nativeLists[1]:SetEntrySelected(1, true)
        Event.Logic.emit({})
        equal(calls, 30)


        prettyui:findMethod("Smelting steel bars")()
        equal(calls, 33)

        local detail = prettyui.views[3]
        detail.tabs[1].pages[1]:allFields()[1]:SetText("1000", true)
        detail.buttons["Back to activities"]()
        equal(calls, 33)

        -- An unsaved draft must not leak into saved-rate list comparisons.
        local text = {}

        for _, label in ipairs(list(prettyui.views[4]):allTexts()) do
            text[#text + 1] = label.content

            if type(label.options) == "table" and label.options.tooltip then
                text[#text + 1] = label.options.tooltip
            end
        end

        -- The tooltip only adds the rate (with commas); profit and ROI are on the row.
        local joined = table.concat(text, " / ")
        assert(joined:find("2,000 smelts/hour", 1, true), joined)
        assert(not joined:find("GP/hour", 1, true), joined)

        PluginShutdown()
    end)

    test("character bindings preserve legacy choices and separate later characters", function()
        local state = client()
        local prefs = Preferences.new(PersistentDB)
        local steel = require("src/data/method_data").find("smelting-steel-bars.basic")
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
        assert(prefs:bindCharacter("First"))

        local source = methods()
        local browser = Browser.new(source, prefs, function()
            return { status = "available", profit = 5 }
        end)

        browser:refreshEstimates()
        assert(browser.estimates.z)

        -- Switching to a second character changes profile, so old estimates must go.
        assert(prefs:bindCharacter("Other"))
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
            settleSearch()
        end)

        equal(success, false)
        assert(tostring(problem):find("Constructor failure", 1, true))
        assert(old.destroyed and list(browse).destroyed)

        callback()
        equal(#prettyui.views, 2)

        -- The header still works: a subsequent valid rebuild can recover.
        prettyui.failTitle = false
        browse.children[2].fields[1]:SetText("", true)
        settleSearch()
        assert(not list(browse).destroyed)

        PluginShutdown()
    end)

    -- Only the page gets the gold frame; the activity filter is marked by colour
    -- and a lit bar on its left edge (muted and unlit otherwise), so it never
    -- looks like a second page.
    test("sidebar frames the active section and colours the chosen activity", function()
        client()
        prettyui = pretty()
        gepl = nil

        local Style = require("src/ui/view_style")
        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()

        local sidebar = prettyui.views[2].children[1]
        local buttons = sidebar.buttonControls
        assert(buttons.Browse.active)
        assert(not buttons["All activities"].active)
        equal(buttons["All activities"].textColour, Style.text)
        equal(buttons.Skilling.textColour, Style.muted)

        -- One bar per activity, in sidebar order; only the chosen one is lit
        -- (a see-through bar has alpha 0).
        local bars = sidebar.rectangles
        local lit = function()
            local on = {}

            for index, bar in ipairs(bars) do
                if bar.rgba & 0xFF ~= 0 then
                    on[#on + 1] = index
                end
            end

            return table.concat(on, ",")
        end

        equal(#bars, 5, "A bar for each activity")
        equal(lit(), "1", "All activities is lit")

        sidebar.buttons.Skilling()
        assert(not buttons.Skilling.active)
        equal(buttons.Skilling.textColour, Style.categories.skilling)
        equal(buttons["All activities"].textColour, Style.muted)
        equal(lit(), "3", "Only Skilling is lit")
        equal(bars[3].rgba, Style.categories.skilling)

        sidebar.buttons.Favourites()
        assert(buttons.Favourites.active)
        assert(not buttons.Browse.active)
        equal(buttons.Skilling.textColour, Style.categories.skilling)

        PluginShutdown()
    end)

    -- Method titles keep their activity colour in every list, not just under
    -- "All activities".
    test("browse titles keep their activity colour under every activity filter", function()
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()

        local Style = require("src/ui/view_style")
        local sidebar = prettyui.views[2].children[1]
        local titles = {
            ["Smelting steel bars"] = Style.categories.production,
            ["Cutting elder logs"] = Style.categories.skilling,
            ["Killing abyssal demons"] = Style.categories.pvm,
        }

        -- Counts the coloured titles currently shown, checking each one's colour.
        local function checkTitles()
            local seen = 0

            for _, label in ipairs(prettyui.views[2]:allTexts()) do
                local expected = titles[label.content]

                if expected then
                    equal(label.options.colour, expected, "Colour for " .. label.content)
                    seen = seen + 1
                end
            end

            return seen
        end

        equal(checkTitles(), 4)

        -- Each row is its own card: a lighter fill behind everything, then a thin
        -- bar down the left edge in the same activity colour as its title.
        local rows = 0

        for _, row in ipairs(prettyui.allViews) do
            if not row.destroyed and row.buttons["View activity"] then
                local fill, accent = row.rectangles[1], row.rectangles[2]
                local title

                for _, label in ipairs(row.texts) do
                    title = title or titles[label.content]
                end

                equal(fill.width, 0)
                equal(accent.width, 4)
                equal(accent.rgba, title, "Accent bar matches the title colour")

                for _, label in ipairs(row.texts) do
                    if label.content:sub(1, 3) == " - " then
                        equal(label.options.colour, Style.muted)
                        assert(label.size and label.x + label.size.width <= row.content.width - 190,
                            "Variant must stay clear of the profit column")
                    end
                end

                assert(fill.rgba ~= accent.rgba)
                rows = rows + 1
            end
        end

        equal(rows, 4)

        -- Elder logs has two versions, so Skilling shows two rows.
        for category, count in pairs({ PvM = 1, Skilling = 2, Production = 1 }) do
            sidebar.buttons[category]()
            equal(checkTitles(), count, "Rows under " .. category)
        end

        PluginShutdown()
    end)

    -- Resizing: while the window is visible, each logic tick compares its size.
    -- Nothing is rebuilt while the player is still dragging; once the size has held
    -- for 15 ticks (0.3 s) the screen is rebuilt once, keeping the list's scroll.
    -- The check only runs while the window is visible.
    test("resizing rebuilds the screen once after the size settles and keeps the list scroll", function()
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 1200, height = 900 } })
        prettyui:findButton("Open Profit Path")()

        local window = prettyui.windows[1]
        local firstScreen = prettyui.views[#prettyui.views]
        list(firstScreen):SetScrollPosition(120)

        local function ticks(count)
            for _ = 1, count do
                Event.Logic.emit({})
            end
        end

        -- The size check runs while the window is open, and does nothing at the
        -- size we built for.
        equal(Event.Logic.count(), 1)
        ticks(40)
        equal(prettyui.views[#prettyui.views], firstScreen)

        -- Dragging: the size keeps changing, so the countdown keeps restarting.
        window:resize(900, 600)
        ticks(10)
        window:resize(910, 610)
        ticks(15)
        equal(prettyui.views[#prettyui.views], firstScreen, "No rebuild until the size has held for 15 ticks")

        -- One more tick: held still long enough, so one rebuild.
        ticks(1)
        local rebuilt = prettyui.views[#prettyui.views]

        assert(rebuilt ~= firstScreen and firstScreen.destroyed, "The screen should be rebuilt at the new size")
        equal(list(rebuilt).scrollY, 120, "The list keeps its scroll position")

        -- And only once: it now matches the size it was built for.
        ticks(40)
        equal(prettyui.views[#prettyui.views], rebuilt)

        -- Hidden window: the check stops. Reopening starts it again.
        window:Close()
        equal(Event.Logic.count(), 0)
        prettyui:findButton("Open Profit Path")()
        equal(Event.Logic.count(), 1)

        PluginShutdown()
        equal(Event.Logic.count(), 0)
    end)

    -- When a page grows a scrollbar, PrettyUI narrows it, but panels keep the inner
    -- width they were built with. So once a screen is built, every panel is sized
    -- to its page's final width: full width minus the side padding, or half width
    -- minus padding and half the middle gap for side-by-side panels.
    test("panels are sized to their page's final width once the screen is built", function()
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 1200, height = 900 } })
        prettyui:findButton("Open Profit Path")()

        -- Browse rows: the fake list is 600 wide with 10 padding each side.
        local rows = 0

        for _, row in ipairs(prettyui.allViews) do
            if not row.destroyed and row.buttons["View activity"] then
                equal(row.size.width, 580)
                equal(row.size.height, 96)
                rows = rows + 1
            end
        end

        equal(rows, 4)

        -- Method pages: 14 padding each side, 8 between side-by-side panels.
        prettyui:findMethod("Cutting elder logs")()
        local tabs = prettyui.views[#prettyui.views].tabs[1]
        local income = tabs.pages[1]

        -- Top row: the 220-wide rate panel, then the profit panel filling the rest
        -- of the 572 (less the 8 gap between them).
        equal(income.children[1].size.width, 220, "Rate panel keeps its fixed width")
        equal(income.children[2].size.width, 344, "Profit panel fills the rest of the row")
        equal(income.children[3].size.width, 282, "Inputs is half width")
        equal(income.children[4].size.width, 282, "Outputs is half width")

        -- Elder logs has both required and recommended items, side by side.
        local halves, fulls = 0, 0

        settleMethod()
        for _, section in ipairs(tabs.pages[2].children) do
            if section.size.width == 282 then
                halves = halves + 1
            else
                equal(section.size.width, 572)
                fulls = fulls + 1
            end
        end

        equal(halves, 4, "Required and recommended skills and items share their rows")
        assert(fulls > 0)

        PluginShutdown()
    end)

    -- Methods with several versions (same title) get a version dropdown right after
    -- the title on the method page. Picking another version loads that version's
    -- prices and saved rate and rebuilds the page on the same tab. One-version
    -- methods keep the plain "Title - Version" header with no dropdown.
    test("the method page switches between versions of the same method", function()
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 1200, height = 900 } })
        prettyui:findButton("Open Profit Path")()

        -- One version only: plain title, no dropdown.
        prettyui:findMethod("Smelting steel bars")()
        local steel = prettyui.views[#prettyui.views]
        equal(steel.nativeLists, nil)
        steel.buttons["Back to activities"]()

        -- Elder logs has two versions. Open the one without spirits.
        prettyui:findMethod("Without wood spirits")()
        local detail = prettyui.views[#prettyui.views]

        local function headerTitles(screen)
            local titles = {}

            for _, label in ipairs(screen.texts) do
                titles[#titles + 1] = label.content
            end

            return table.concat(titles, "|")
        end

        equal(headerTitles(detail), "Cutting elder logs", "Title without the version; the dropdown shows it")

        local versions = detail.nativeLists[1]
        equal(versions.entries["Without wood spirits"], 0)
        equal(versions.entries["With wood spirits"], 1)
        equal(versions.selectedID, 0)
        equal(detail.tabs[1].pages[1]:allFields()[1]:GetText(), "320")

        -- On the Requirements tab, switch to the wood spirits version.
        detail.tabs[1]:SetActive(2)
        versions:SetEntrySelected(1, true)
        Event.Logic.emit({})

        local switched = prettyui.views[#prettyui.views]
        assert(switched ~= detail and detail.destroyed, "The page is rebuilt for the other version")
        equal(switched.nativeLists[1].selectedID, 1)
        equal(switched.tabs[1].activeIndex, 2, "Same tab after switching")
        equal(switched.tabs[1].pages[1]:allFields()[1]:GetText(), "580", "The other version's own rate")

        -- Its Income table lists the spirits.
        local names = {}

        for _, panel in ipairs(switched.tabs[1].pages[1].children) do
            for _, slot in ipairs(panel.items or {}) do
                names[#names + 1] = slot.tooltip
            end
        end

        assert(table.concat(names, "|"):find("Elder wood spirit", 1, true), "Spirits are an input")

        -- Only the window's size check is still listening; the dropdown's one-off
        -- callback is gone, and the screen has finished drawing.
        settleMethod()
        equal(Event.Logic.count(), 1)

        PluginShutdown()
        equal(Event.Logic.count(), 0)
    end)

    -- A rebuilt method screen comes back on the same tab with the same draft rate,
    -- and its tabs start at x = 0 so both sides get the same padding.
    test("resizing a method screen keeps its tab and draft rate and the tabs are not offset", function()
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 1200, height = 900 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findMethod("Smelting steel bars")()

        local window = prettyui.windows[1]
        local detail = prettyui.views[#prettyui.views]
        local tabs = detail.tabs[1]

        equal(tabs.options.x, 0, "Tabs must not pick up PrettyUI's default left padding")

        -- The player types a draft rate and switches to the Requirements tab.
        tabs.pages[1]:allFields()[1]:SetText("1500", true)
        tabs:SetActive(2)

        window:resize(900, 600)

        for _ = 1, 16 do
            Event.Logic.emit({})
        end

        local rebuilt = prettyui.views[#prettyui.views]
        assert(rebuilt ~= detail and detail.destroyed, "The method screen should be rebuilt")
        equal(rebuilt.tabs[1].activeIndex, 2, "Same tab after the rebuild")
        equal(rebuilt.tabs[1].pages[1]:allFields()[1]:GetText(), "1500", "Draft rate survives")

        -- Opening a different method starts on Income again.
        rebuilt.buttons["Back to activities"]()
        prettyui:findMethod("Cutting elder logs")()
        equal(prettyui.views[#prettyui.views].tabs[1].activeIndex, 1)

        PluginShutdown()
    end)

    test("money presentation keeps negative values precision and unavailable states distinct", function()
        local Style = require("src/ui/view_style")

        equal(Style.number(1234567.899), "1,234,568")
        equal(Style.number(-1000.125, 1), "-1,000.1")
        equal(Style.number(0), "0")
        equal(Style.number(nil), "Unavailable")
        equal(Style.compact(-38000), "-38.0k / h")
        equal(Style.compact(1200000), "1.2m / h")
        equal(Style.compact(nil), "Not estimated")
        equal(Style.quantity(2000), "2,000")
        equal(Style.quantity(1.25), "1.25")
    end)

    test("Requirements stays next to Intensity and filters wrap together on narrow windows", function()
        for _, width in ipairs({ 1000, 700 }) do
            client()
            local library = pretty()
            local view = library.SimpleView.new({ width = width, height = 740 }, { width = width, height = 740 })
            view.content.width = width
            local browser = Browser.new({}, Preferences.new(PersistentDB), function() end)
            local release = require("src/ui/browse_view").mount(library, view, browser, function(callback) return callback end, function() end)
            local header = view.children[2]
            local lists = header.nativeLists
            equal(#lists, 5)
            equal(lists[5].x, lists[4].x + 140)
            equal(lists[5].y, lists[4].y)
            assert(lists[5].x + lists[5].width <= width - 190)

            if width == 1000 then
                equal(lists[5].y, lists[1].y)
            else
                assert(lists[5].y > lists[1].y)
                equal(lists[3].y, lists[5].y)
            end

            release()
            view:Destroy()
            equal(Event.Logic.count(), 0)
        end
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
        sort:SetEntrySelected(3, true)
        sort:SetEntrySelected(2, true)

        sort:SetEntrySelected(1, true)
        direction:SetEntrySelected(1, true)
        Event.Logic.emit({})
        equal(state.db["profit-path.browser.v1"].sort, "roi")
        equal(state.db["profit-path.browser.v1"].descending, false)

        -- Only Profit and ROI to sort by; intensity, requirements and difficulty
        -- (last) are their own filter dropdowns. Entry 3 under difficulty is "Hard" (IDs count from 0), and none of the
        -- bundled methods has a difficulty rating, so the list empties.
        equal(#header.nativeLists, 5)
        equal(sort.entries.Difficulty, nil)
        equal(sort.entries.ROI, 1)

        local difficulty = header.nativeLists[5]
        equal(difficulty.entries.Any, 0)
        equal(difficulty.selectedID, 0, "Filters start on Any")
        equal(header.nativeLists[4].selectedID, 0)
        equal(difficulty.entries.Hard, 3)

        local function shownText()
            local text = {}

            for _, label in ipairs(prettyui.views[2]:allTexts()) do
                text[#text + 1] = tostring(label.content)
            end

            return table.concat(text, "|")
        end

        -- Captions say which group each dropdown belongs to.
        for _, caption in ipairs({ "SORT BY", "DIFFICULTY", "INTENSITY", "REQUIREMENTS" }) do
            assert(shownText():find(caption, 1, true), "Missing caption " .. caption)
        end

        difficulty:SetEntrySelected(3, true)
        Event.Logic.emit({})
        assert(shownText():find("0 matching activities", 1, true), "Hard should filter out every unrated method")

        difficulty:SetEntrySelected(0, true)
        Event.Logic.emit({})
        assert(not shownText():find("0 matching activities", 1, true), "Any brings them back")


        local afterClick = sort.selectionWrites
        sort.callback(sort, 1, ui.SelectionChangeEvent.SELECTED)
        Event.Logic.emit({})
        equal(state.db["profit-path.browser.v1"].sort, "roi", "Ignore stale queued events")
        equal(sort.selectionWrites, afterClick, "A successful click must not reset native selection")

        -- The dropdown's one-off callback is gone; only the window's size check
        -- (which runs while the window is visible) is still listening.
        equal(Event.Logic.count(), 1)

        state.failWrite = true
        sort:SetEntrySelected(0, true)
        Event.Logic.emit({})
        equal(sort.selectedID, 1)
        equal(state.db["profit-path.browser.v1"].sort, "roi")

        state.failWrite = false

        -- Difficulty only rates PvM: it's last, and only on All activities and
        -- PvM. Leaving for Skilling drops it, and the picked difficulty with it.
        local function liveFilters()
            for _, child in ipairs(prettyui.views[2].children) do
                if not child.destroyed and child.nativeLists and #child.nativeLists > 0 then
                    return child
                end
            end
        end

        difficulty:SetEntrySelected(3, true)
        Event.Logic.emit({})
        prettyui:findButton("Skilling")()
        equal(#liveFilters().nativeLists, 4)
        assert(not shownText():find("DIFFICULTY", 1, true), "No Difficulty caption on Skilling")
        assert(not shownText():find("0 matching activities", 1, true), "The hidden difficulty doesn't filter Skilling")

        prettyui:findButton("PvM")()
        equal(#liveFilters().nativeLists, 5)
        equal(liveFilters().nativeLists[5].selectedID, 0, "Back to Any")
        prettyui:findButton("All activities")()

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
        local rate = income:allFields()[1]
        rate:SetText("1000", true)
        equal(calls, 33)
        assert(not income:button("Refresh prices"))

        prettyui.windows[1]:Close()
        price = 50
        prettyui:findButton("Open Profit Path")()
        equal(calls, 36)
        equal(rate:GetText(), "1000")

        local lines = {}

        for _, label in ipairs(income:allTexts()) do
            lines[#lines + 1] = label.content
        end

        local text = table.concat(lines, "\n")
        assert(text:find("29,000 / h", 1, true), "Recalculate using fresh quotes and the draft rate")
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
        equal(#income:allFields(), 1, "No manual character/profile field in the method")

        -- The potion stays an icon; creation-cost explanations are no longer
        -- printed in Notes. Pricing itself is covered by the calculation tests.
        for _, label in ipairs(income:allTexts()) do
            assert(not label.content:find("ROI unavailable", 1, true))
            assert(label.content ~= "Perfect plus potion", "Potion should be an icon, not a text row")
            assert(not label.content:find("can't be traded", 1, true), "Creation-cost prose omitted from Notes")
        end

        local names = {}

        for _, panel in ipairs(income.children) do
            for _, slot in ipairs(panel.items or {}) do
                names[#names + 1] = slot.tooltip
            end
        end

        assert(table.concat(names):find("Perfect plus potion", 1, true))
        assert(table.concat(names):find("Elder logs", 1, true))
        equal(prettyui.windows[1].options.title, "Profit Path", "No character name in the title")

        PluginShutdown()
    end)

    test("requirements pair skills items and quests and hide empty sides", function()
        client()
        local library = pretty()
        local base = require("src/data/method_data").find("smelting-steel-bars.basic")
        local Requirements = require("src/game/requirements")

        for _, fixture in ipairs({
            { category = "items", definition = { kind = "gear", text = "A suitable tool (recommended)", equipment_scope = "flexible" } },
            { category = "skills", definition = { kind = "skill", skill = "WOODCUTTING", level = 90, text = "90 Woodcutting (required)" } },
            { category = "quests", definition = { kind = "quest", quest = "COOKS_ASSISTANT", text = "Cook's Assistant recommended" } },
        }) do
            for _, counts in ipairs({ { 1, 1 }, { 1, 0 }, { 0, 1 }, { 0, 0 } }) do
                local method = {}

                for key, value in pairs(base) do
                    method[key] = value
                end

                local required = { kind = "all", text = "Required", children = {} }
                local recommended = { kind = "all", text = "Recommended", children = {} }

                for index, group in ipairs({ required, recommended }) do
                    if counts[index] == 1 then
                        group.children[1] = fixture.definition
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

                settleMethod()
                for _, panel in ipairs(view.tabs[1].pages[2].children) do
                    panels[panel.texts[1].content] = panel
                end

                local both = counts[1] == 1 and counts[2] == 1

                for index, title in ipairs({ "Required " .. fixture.category, "Recommended " .. fixture.category }) do
                    equal(panels[title] ~= nil, counts[index] == 1)

                    if panels[title] then
                        equal(panels[title].options.widthAnchor, both and 0.5 or nil)
                        equal(panels[title].options.inline == true, both and index == 2)
                        assert(not panels[title].texts[2].content:find("recommended", 1, true))
                        assert(not panels[title].texts[2].content:find("(required)", 1, true))

                        if both then
                            equal(panels[title].size.height, panels["Required " .. fixture.category].size.height)
                        end
                    end
                end

                view:Destroy()
            end
        end
    end)

    -- An either-or line that isn't met says what each part reads as when hovered.
    -- The label is only made again when that text changes, not on every refresh.
    test("an either-or requirement explains its parts on hover", function()
        client()
        local library = pretty()
        local base = require("src/data/method_data").find("smelting-steel-bars.basic")
        local method = {}

        for key, value in pairs(base) do
            method[key] = value
        end

        local line = { kind = "any", text = "Mobile or Shadow's Grace (highly recommended)", children = {
            { kind = "capability", text = "Mobile" },
            { kind = "flag", var = "ARCH_RELIC_SHADOWS_GRACE_UNLOCKED", text = "Shadow's Grace" },
        } }
        local required = { kind = "all", text = "Required", children = {} }
        local recommended = { kind = "all", text = "Recommended", children = { line } }
        method.requirements = { coverage = "partial", access = required, recommended = recommended }

        -- Shadow's Grace isn't unlocked; Mobile can't be checked.
        local account = { flags = { ARCH_RELIC_SHADOWS_GRACE_UNLOCKED = { status = "available", value = 0 } } }
        local Requirements = require("src/game/requirements")
        local calculator = {
            rate = 2000,
            result = require("src/methods/income").calculate(base.income, 2000, {}),
            requirements = function()
                return Requirements.evaluate(required, account), Requirements.evaluate(recommended, account)
            end,
            ownership = function() return { counts = {}, complete = false } end,
        }
        local view = library.SimpleView.new({ width = 700, height = 500 }, { width = 700, height = 500 })
        local refresh = require("src/ui/method_view").mount(view, method, calculator, function(callback) return callback end)
        settleMethod()

        local function label()
            for _, text in ipairs(view.tabs[1].pages[2]:allTexts()) do
                if text.content == "Mobile or Shadow's Grace (highly recommended)" then
                    return text
                end
            end
        end

        local first = label()
        equal(first.options.tooltip, "Either one will do. Mobile: can't be checked in game. "
            .. "Shadow's Grace: not unlocked yet.")

        -- Nothing changed: the same label stays.
        refresh("quests")
        equal(label(), first)

        -- Unlocking the relic meets the line, and a met line needs no hover.
        account.flags.ARCH_RELIC_SHADOWS_GRACE_UNLOCKED.value = 1
        refresh("quests")
        assert(first.destroyed, "The old label is gone")
        equal(label().options.tooltip, nil)
        view:Destroy()
    end)

    test("standalone item icons share rows while box-and-text requirements keep their own line", function()
        client()
        local library = pretty()
        local base = require("src/data/method_data").find("smelting-steel-bars.basic")
        local method = {}

        for key, value in pairs(base) do
            method[key] = value
        end

        local required = { kind = "all", text = "Required", children = {
            { kind = "item", item_id = 440, text = "Iron ore", display_items = { 440 } },
            { kind = "item", item_id = 453, text = "Coal", display_items = { 453 } },
            { kind = "gear", text = "Use your best tool (required)", equipment_scope = "flexible" },
            { kind = "item", item_id = 2353, text = "Steel bar", display_items = { 2353 } },
        } }
        local recommended = { kind = "all", text = "Recommended", children = {} }
        method.requirements = { coverage = "partial", access = required, recommended = recommended }
        local Requirements = require("src/game/requirements")
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
        settleMethod()
        local panel = view.tabs[1].pages[2].children[1]

        equal(panel.items[1].options.y, panel.items[2].options.y)
        assert(panel.items[2].options.x > panel.items[1].options.x)
        local text = panel.texts[2]
        equal(text.content, "Use your best tool")
        assert(text.options.y >= panel.items[1].options.y + 40)
        assert(panel.items[3].options.y >= text.options.y + text.options.height)
        equal(panel.items[3].options.x, panel.items[1].options.x)
        view:Destroy()
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
        settleMethod()
        local requirements = detail.tabs[1].pages[2]
        local items

        for _, section in ipairs(requirements.children) do
            if section.texts[1].content == "Recommended items" then
                items = section
            end
        end

        assert(items)
        local Style = require("src/ui/view_style")
        local definitions = require("src/data/method_data").items
        local graceIndex

        for index, slot in ipairs(items.items) do
            equal(slot.tooltip, definitions[tostring(slot.object.id)].name)

            -- Separate recommended items share a grid, including outfit pieces.
            -- The sixth icon wraps once, rather than every item starting a row.
            equal(slot.options.x, 12 + ((index - 1) % 5) * 44)
            equal(slot.options.y, 34 + math.floor((index - 1) / 5) * 44)

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

        -- Closing the bank keeps its explicit zero counts as last-checked
        -- absence. It must not erase a red border or invent live coverage.
        bankAvailable = false
        Event.InventoryRemoved.emit({ inv = config.Inv.BANK })

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
        settleMethod()
        local detail = prettyui.views[3]
        local income = detail.tabs[1].pages[1]
        local save = income:button("Save rate")
        -- The Save and Reset buttons live in the rate panel at the top of Income.
        local ratePanel = income.children[1]
        assert(type(ratePanel.buttonControls["Save rate"].sprite) == "number")
        income:allFields()[1]:SetText("100", true)
        save()

        local preferences = Preferences.new(PersistentDB)
        assert(preferences:bindCharacter("Fixture"))
        local method = require("src/data/method_data").find("cutting-elder-logs.without-spirits")
        equal(preferences:loadRate(method), 100)

        -- Skills use the small skills-tab style icons, not the round medallions.
        assert(state.spriteLookups.HITMARK_ICON_SKILL_WOODCUTTING)
        equal(state.spriteLookups.SKILL_WOODCUTTING, nil)

        assert(state.spriteLookups.WARDROBE_ICON_PRESET_SAVE_24PX_0)
        assert(state.spriteLookups.INVENTION_ICON_PERKS_TOOLS_HONED)
        assert(state.spriteLookups.INVENTION_ICON_PERKS_TOOLS_FORTUNE)

        -- Reset is a boxed sprite button like Save, not a bare sprite.
        assert(state.spriteLookups.RS3_ICON_STOPWATCH_RESET_0)
        assert(type(ratePanel.buttonControls["Reset to source rate"].sprite) == "number")

        income:allFields()[1]:SetText("200", true)
        detail.buttons["Back to activities"]()
        save()
        equal(preferences:loadRate(method), 100)
        PluginShutdown()
    end)

    test("PvM outputs render shared drops and rate edits reuse the quote snapshot", function()
        client()
        prettyui = pretty()
        local calls = 0
        gepl = {
            isReady = function() return true end,
            getLatest = function()
                calls = calls + 1
                return { high = 1000, highTime = 50, low = 1000, lowTime = 50 }
            end,
        }
        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findMethod("Killing abyssal demons")()
        settleMethod()
        local income = prettyui.views[#prettyui.views].tabs[1].pages[1]
        local outputs = income.children[4]
        equal(#outputs.items, 16)

        for _, label in ipairs(income:allTexts()) do
            assert(not label.content:find("Drop income is not available yet", 1, true))
            assert(not label.content:find("Not estimated", 1, true))
        end

        local capturedCalls = calls
        income:allFields()[1]:SetText("450", true)
        equal(calls, capturedCalls)
        equal(#outputs.items, 16)
        PluginShutdown()
    end)

    -- Drawing a whole method screen in one click could take the client past its
    -- one-second limit. It draws the open tab and the first rows, then the rest a
    -- piece per tick; a tab clicked early is drawn straight away.
    test("a method screen draws in steps and a clicked tab is drawn at once", function()
        client()
        prettyui = pretty()
        gepl = {
            isReady = function() return true end,
            getLatest = function() return { high = 1000, highTime = 50, low = 1000, lowTime = 50 } end,
        }
        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()

        -- Abyssal demons have 16 output rows.
        prettyui:findMethod("Killing abyssal demons")()
        local tabs = prettyui.views[#prettyui.views].tabs[1]
        local outputs = tabs.pages[1].children[4]

        equal(#outputs.items, 6, "First batch of rows only")
        equal(#tabs.pages[2].children, 0, "Requirements wait their turn")
        equal(#tabs.pages[3].texts, 0, "Steps wait their turn")

        -- Each tick draws another batch, and new rows show their numbers at once.
        Event.Logic.emit({})
        equal(#outputs.items, 12)
        Event.Logic.emit({})
        equal(#outputs.items, 16)

        for _, label in ipairs(outputs.texts) do
            assert(label.content ~= "", "Every drawn row has its numbers")
        end

        -- Clicking a tab that isn't drawn yet draws it now.
        tabs:SetActive(3)
        assert(#tabs.pages[3].texts > 0, "Clicked tab is drawn straight away")

        -- The rest arrives, then nothing is left waiting but the window's size check.
        settleMethod()
        assert(#tabs.pages[2].children > 0, "Requirements drawn")
        assert(#tabs.pages[4].texts > 0, "Getting there drawn")
        equal(Event.Logic.count(), 1)

        -- Leaving before it's done stops the drawing.
        prettyui.views[#prettyui.views].buttons["Back to activities"]()
        prettyui:findMethod("Killing abyssal demons")()
        prettyui.views[#prettyui.views].buttons["Back to activities"]()
        equal(Event.Logic.count(), 1)

        PluginShutdown()
        equal(Event.Logic.count(), 0)
    end)

    -- A piece that fails to draw is reported once, not retried 50 times a second.
    test("a method screen that fails to draw a piece stops drawing", function()
        client()
        prettyui = pretty()
        gepl = nil
        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        -- Abyssal demons have 16 output rows, so rows are still waiting after the
        -- first batch; make the next one fail to draw.
        prettyui:findMethod("Killing abyssal demons")()

        local outputs = prettyui.views[#prettyui.views].tabs[1].pages[1].children[4]
        outputs.AddText = function()
            error("fixture draw failure")
        end

        local failures = 0

        for _ = 1, 10 do
            local ok, problem = pcall(Event.Logic.emit, {})

            if not ok then
                failures = failures + 1
                assert(tostring(problem):find("fixture draw failure", 1, true))
            end
        end

        equal(failures, 1)
        equal(Event.Logic.count(), 1, "Only the window's size check is left")

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
        income:allFields()[1]:SetText("1000", true)
        income:button("Save")()
        local preferences = Preferences.new(PersistentDB)
        assert(preferences:bindCharacter("Fixture"))
        equal(preferences:loadRate(require("src/data/method_data").find("smelting-steel-bars.basic")), 1000)

        -- Resolving a sprite later makes the next decoration usable.
        rsprite.Get = function(name)
            equal(name, "COINS")
            return 431
        end
        local icon = require("src/ui/view_style").icon(income, "coins", { size = 20 })
        assert(icon)
        PluginShutdown()
    end)

    -- Coins: one coin per table, by the heading total only (not on every row). It's
    -- the real Coins item at its biggest-pile graphic, and it slides left as the
    -- total gets longer so it always sits right next to the number.
    -- Hovering "Unavailable" says why. The value label is only made again when the
    -- reason changes (prices fetched again), never while typing a rate.
    test("an unavailable income value explains itself on hover", function()
        client()
        prettyui = pretty()

        -- Steel bars sell, but there are no recent instant-sell trades.
        local sells = false
        gepl = {
            isReady = function() return true end,
            getLatest = function(itemId)
                if itemId == 2353 and not sells then
                    return { high = 1200, highTime = 50 }
                end

                return { high = 1000, highTime = 50, low = 1000, lowTime = 50 }
            end,
        }
        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findMethod("Smelting steel bars")()

        local income = prettyui.views[#prettyui.views].tabs[1].pages[1]
        local outputs = income.children[4]

        -- The steel bar's value: the Value column, below the heading row and the
        -- column headings (the total and "Value" sit in the same column).
        local function valueLabel()
            for _, label in ipairs(outputs.texts) do
                if type(label.options) == "table" and label.options.x == -150 and label.options.y > 40 then
                    return label
                end
            end
        end

        local value = valueLabel()
        equal(value.content, "Unavailable")
        assert(value.options.tooltip:find("instant-sell", 1, true), tostring(value.options.tooltip))

        -- The status line names what's missing.
        local named = false

        for _, label in ipairs(income:allTexts()) do
            named = named or label.content:find("No price for Steel bar", 1, true) ~= nil
        end

        assert(named, "Status line names the missing item")

        -- Typing a rate keeps the same label: the reason hasn't changed.
        income:allFields()[1]:SetText("1500", true)
        equal(valueLabel(), value)

        -- Prices come back after a close and reopen: the reason goes, and so
        -- does the tooltip.
        sells = true
        prettyui.windows[#prettyui.windows]:Close()
        prettyui:findButton("Open Profit Path")()

        local priced = valueLabel()
        assert(value.destroyed, "The old label is gone")
        assert(priced.content ~= "Unavailable", priced.content)
        equal(priced.options.tooltip, nil)

        PluginShutdown()
    end)

    -- One unpriced drop among many counts as 0 rather than hiding the profit, and
    -- both the method's status line and the Browse tooltip say so.
    test("one unpriced drop counts as 0 and says so in Browse and on the method", function()
        client()
        prettyui = pretty()

        -- Abyssal wands (30825) have no GE prices; everything else does.
        gepl = {
            isReady = function() return true end,
            getLatest = function(itemId)
                if itemId == 30825 then
                    error("Price not found for itemId: " .. itemId)
                end

                return { high = 1000, highTime = 50, low = 1000, lowTime = 50 }
            end,
        }
        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()

        -- Browse: the row has a profit, and its tooltip names the wand.
        local tooltip

        for index = #prettyui.allViews, 1, -1 do
            local row = prettyui.allViews[index]

            if not row.destroyed and row.buttons["View activity"] then
                local isDemons = false

                for _, label in ipairs(row.texts) do
                    isDemons = isDemons or label.content:find("Killing abyssal demons", 1, true) ~= nil
                end

                for _, label in ipairs(row.texts) do
                    if isDemons and type(label.options) == "table" and type(label.options.tooltip) == "string"
                        and label.options.tooltip:find("Counted as 0", 1, true) then
                        tooltip = label.options.tooltip
                    end
                end
            end
        end

        assert(tooltip and tooltip:find("Abyssal wand", 1, true), tostring(tooltip))

        -- The method: a real profit, with the note on the status line.
        prettyui:findMethod("Killing abyssal demons")()
        settleMethod()

        local income = prettyui.views[#prettyui.views].tabs[1].pages[1]
        local noted, notEstimated = false, false

        for _, label in ipairs(income:allTexts()) do
            noted = noted or label.content:find("Counted as 0 (no price): Abyssal wand.", 1, true) ~= nil
            notEstimated = notEstimated or label.content == "Not estimated"
        end

        assert(noted, "Status line says what was counted as 0")
        assert(not notEstimated, "The profit is shown")

        PluginShutdown()
    end)

    test("income tables show the coin pile only beside each total and keep it next to the number", function()
        client()
        prettyui = pretty()
        gepl = nil
        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findMethod("Smelting steel bars")()

        local income = prettyui.views[3].tabs[1].pages[1]
        local inputs = income.children[3]
        local outputs = income.children[4]

        -- The Coins item at a huge quantity, so the client draws the full pile,
        -- with the quantity number hidden.
        for _, panel in ipairs({ inputs, outputs }) do
            equal(#panel.nativeSprites, 1)
            equal(panel.nativeSprites[1].source.item, 995)
            equal(panel.nativeSprites[1].associatedObjectQuantity, 1000000)
            equal(panel.nativeSprites[1].associatedObjectQuantityMode, ui.ObjectQuantityDisplayMode.NEVER)
            equal(panel.sprites, nil)
        end

        -- Money colours: Inputs (costs) in subtle red, Outputs (earnings) in
        -- subtle green, for both the heading total and each row's value.
        local Style = require("src/ui/view_style")

        local function moneyColours(panel)
            local colours = {}

            for _, label in ipairs(panel:allTexts()) do
                if type(label.options) == "table" and label.options.alignHorizontal == ui.AlignMode.BOTTOMRIGHT and label.options.colour ~= Style.muted then
                    colours[#colours + 1] = label.options.colour
                end
            end

            return colours
        end

        for _, colour in ipairs(moneyColours(inputs)) do
            equal(colour, Style.bad)
        end

        for _, colour in ipairs(moneyColours(outputs)) do
            equal(colour, Style.good)
        end

        assert(#moneyColours(inputs) >= 2, "Expected a total and at least one row value")

        -- No prices: the total reads "Unavailable" (11 chars x 7 = 77 wide in the
        -- fake font), so the coin sits at -20 - 77 - 4 - 20.
        local coin = inputs.nativeSprites[1]
        equal(coin.x, -20 - 77 - 4 - 20)

        -- Two more characters (7 units each) push the coin 14 further left, so the
        -- gap to the number stays the same.

        Style.placeCoin(coin, "1,000/h", { rightEdge = -20, y = 9, size = 20 })
        local shortX = coin.x

        Style.placeCoin(coin, "100,000/h", { rightEdge = -20, y = 9, size = 20 })
        equal(coin.x, shortX - 14)

        PluginShutdown()
    end)

    -- The coin uses only the one-argument SetAssociatedObject plus the quantity
    -- property (the two-argument form doesn't exist on this client), so a normal
    -- draw reports no problems at all.
    test("coin draws the pile without the unsupported two-argument call or any warning", function()
        client()

        local Style = require("src/ui/view_style")
        local printed = {}
        local realPrint = print

        print = function(text)
            printed[#printed + 1] = text
        end

        local coin = Style.coins({ content = { testOwner = {} } }, { size = 20 })

        print = realPrint

        equal(coin.source.item, 995)
        equal(coin.associatedObjectQuantity, 1000000)
        equal(coin.associatedObjectQuantityMode, ui.ObjectQuantityDisplayMode.NEVER)
        equal(coin.hidden, nil)
        equal(#printed, 0)
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
        local steel = require("src/data/method_data").find("smelting-steel-bars.basic")
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
