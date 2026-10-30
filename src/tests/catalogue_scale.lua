-- Full-catalogue tests: the plugin with the real shipped data/methods.lua (hundreds
-- of methods), not the 4 curated ones the behaviour tests use. src/tests/run.lua
-- clears its module cache first, so every plugin module reloads with this data.
--
-- These check that the catalogue still works at full size: Browse pages, prices
-- are looked up once per item, and Wiki imports are labelled. The timings printed
-- are desktop Lua, a rough guide only; the client's own speed needs checking in game.
return function(test, equal, client, pretty)
    local catalogue = require("src/data/method_data")

    -- A fake GEPL that counts every call and answers with the same prices for any
    -- item, so every method can be estimated.
    local function countingLibrary()
        local counts = { calls = 0, items = {} }

        local library = {
            isReady = function()
                counts.calls = counts.calls + 1
                return true
            end,
            getLatest = function(itemId)
                counts.calls = counts.calls + 1
                counts.items[itemId] = true
                return { high = 110, highTime = 1, low = 100, lowTime = 1 }
            end,
            getOneHourAverage = function()
                counts.calls = counts.calls + 1
                return { avgHighPrice = 105, highPriceVolume = 10, avgLowPrice = 95, lowPriceVolume = 10 }
            end,
        }

        return library, counts
    end

    local function liveRows()
        local rows = {}

        for _, view in ipairs(prettyui.allViews) do
            if not view.destroyed and view.buttons["View method"] then
                rows[#rows + 1] = view
            end
        end

        return rows
    end

    test("the full catalogue loads, prices each item once and shows Browse a page at a time", function()
        assert(#catalogue.methods > 500, "Expected the full Wiki catalogue, got " .. #catalogue.methods)

        client()
        prettyui = pretty()
        local counts
        gepl, counts = countingLibrary()

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1200, height = 900 } })

        local started = os.clock()
        prettyui:findButton("Open Profit Path")()
        local seconds = os.clock() - started

        -- Each distinct item costs a handful of calls (readiness checks, the latest
        -- trade, the hourly average), however many methods use it.
        local distinct = 0

        for _ in pairs(counts.items) do
            distinct = distinct + 1
        end

        assert(counts.calls <= distinct * 4, "Price calls should be per item: " .. counts.calls .. " for " .. distinct)
        print(string.format("[catalogue scale] %d methods: %d price-library calls for %d distinct items; "
            .. "opening Browse took %.0f ms (desktop Lua).", #catalogue.methods, counts.calls, distinct, seconds * 1000))

        -- Only one page of rows is drawn.
        equal(#liveRows(), 25)
        prettyui:findButton("Next page")()
        equal(#liveRows(), 25)
        prettyui:findButton("Previous page")()

        PluginShutdown()
    end)

    test("wiki imports are labelled and open with their pace, steps note and sprites", function()
        client()
        prettyui = pretty()
        gepl = countingLibrary()

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1200, height = 900 } })
        prettyui:findButton("Open Profit Path")()

        -- A per-hour Wiki guide: steel bars' neighbour on the Wiki, from the snapshot.
        local imported

        for _, method in ipairs(catalogue.methods) do
            if method.research and method.research.income == "wiki" and method.income.rate.unit == "% of guide pace" then
                imported = method
                break
            end
        end

        assert(imported, "Expected a per-hour Wiki guide in the catalogue")

        -- Find it through search, so its row is on the first page.
        local browse = prettyui.views[#prettyui.views]
        browse.children[2].fields[1]:SetText(imported.title, true)

        local labels = {}

        for _, row in ipairs(liveRows()) do
            for _, label in ipairs(row.texts) do
                labels[#labels + 1] = tostring(label.content)
            end
        end

        assert(table.concat(labels, " / "):find("Partly researched", 1, true), "Browse row should say Partly researched")

        prettyui:findMethod(imported.title)()
        local detail = prettyui.views[#prettyui.views]
        local pages = detail.tabs[1].pages
        local texts = {}

        for index = 1, 3 do
            for _, label in ipairs(pages[index]:allTexts()) do
                texts[#texts + 1] = tostring(label.content)
            end
        end

        local all = table.concat(texts, " / ")
        assert(all:find("Pace (% of guide)", 1, true), "Pace label")
        assert(all:find("Partly researched: imported from the Wiki guide", 1, true), "Research note")
        assert(all:find("Steps haven't been written", 1, true), "Steps note")
        equal(pages[1]:allFields()[1]:GetText(), "100")

        PluginShutdown()
    end)

    test("mapped quests are real quest checks, tips sit on their own lines and there's no See also", function()
        client()
        prettyui = pretty()
        gepl = countingLibrary()

        -- A method with tips and a mapped quest.
        local chosen

        for _, method in ipairs(catalogue.methods) do
            local hasQuest = false

            for _, child in ipairs(method.requirements.access.children) do
                hasQuest = hasQuest or child.kind == "quest"
            end

            if hasQuest and #(method.requirements.tips or {}) > 0 then
                chosen = method
                break
            end
        end

        assert(chosen, "Expected a method with both tips and a quest check")

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1200, height = 900 } })
        prettyui:findButton("Open Profit Path")()
        prettyui.views[#prettyui.views].children[2].fields[1]:SetText(chosen.title, true)
        prettyui:findMethod(chosen.title)()

        local requirements = prettyui.views[#prettyui.views].tabs[1].pages[2]
        local texts = {}

        for _, label in ipairs(requirements:allTexts()) do
            texts[#texts + 1] = tostring(label.content)
        end

        local all = table.concat(texts, " / ")
        assert(not all:find("See also on the Wiki", 1, true), "Advice section is gone")

        -- Recommended things the plugin can't check show as tips, not grey checks.
        if #(chosen.requirements.tips or {}) > 0 then
            assert(all:find("Also helps", 1, true), "Tips section")
            assert(all:find(chosen.requirements.tips[1].text, 1, true), "First tip")
        end

        -- Each tip starts its own line: a tip without icons never sits inline after
        -- the previous one.
        local plainTips = {}

        for _, tip in ipairs(chosen.requirements.tips or {}) do
            if not tip.icons then
                plainTips[tip.text] = true
            end
        end

        for _, label in ipairs(requirements:allTexts()) do
            if plainTips[label.content] then
                assert(not label.options.inline, "Tip shares a line: " .. label.content)
            end
        end

        PluginShutdown()
    end)

    test("required things only the player can judge are listed under Check yourself", function()
        client()
        prettyui = pretty()
        gepl = countingLibrary()

        local chosen

        for _, method in ipairs(catalogue.methods) do
            if #(method.requirements.notes or {}) > 0 then
                chosen = method
                break
            end
        end

        assert(chosen, "Expected a method with Check yourself notes")

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1200, height = 900 } })
        prettyui:findButton("Open Profit Path")()
        prettyui.views[#prettyui.views].children[2].fields[1]:SetText(chosen.title, true)
        prettyui:findMethod(chosen.title)()

        local requirements = prettyui.views[#prettyui.views].tabs[1].pages[2]
        local found = {}

        for _, label in ipairs(requirements:allTexts()) do
            found[tostring(label.content)] = label
        end

        assert(found["Check yourself"], "Check yourself section")

        -- Each note is its own line.
        for _, note in ipairs(chosen.requirements.notes) do
            assert(found[note], "Missing note: " .. note)
            assert(not found[note].options.inline, "Note shares a line: " .. note)
        end

        PluginShutdown()
    end)

    test("any-one tiered gear shows one slot per option with a short label", function()
        client()
        prettyui = pretty()
        gepl = countingLibrary()

        -- A method whose required items include "any one" of several gear tiers.
        local chosen, group

        for _, method in ipairs(catalogue.methods) do
            for _, child in ipairs(method.requirements.access.children) do
                local allGear = child.kind == "any" and #child.children > 1

                for _, option in ipairs(allGear and child.children or {}) do
                    allGear = allGear and option.kind == "gear"
                end

                if allGear then
                    chosen, group = method, child
                end
            end

            if chosen then
                break
            end
        end

        assert(chosen, "Expected a method with any-one tiered gear")

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1200, height = 900 } })
        prettyui:findButton("Open Profit Path")()
        prettyui.views[#prettyui.views].children[2].fields[1]:SetText(chosen.title, true)
        prettyui:findMethod(chosen.title)()

        local found = {}

        for _, label in ipairs(prettyui.views[#prettyui.views].tabs[1].pages[2]:allTexts()) do
            found[tostring(label.content)] = true
        end

        -- The joined link text is gone; each option has its own short line.
        assert(not found[group.text], "Long joined text shown")
        assert(found["Any one"], "Any one heading")

        for _, option in ipairs(group.children) do
            local short = "T" .. option.minimum_tier .. "+ " .. (option.style and option.style .. " " or "")
            local hit = false

            for text in pairs(found) do
                hit = hit or text:sub(1, #short) == short
            end

            assert(hit, "Missing option label starting " .. short)
        end

        PluginShutdown()
    end)

    test("recurring methods show per-run profit with their cycle and sort after hourly ones", function()
        client()
        prettyui = pretty()
        gepl = countingLibrary()

        local recurring

        for _, method in ipairs(catalogue.methods) do
            if method.income.period == "run" then
                recurring = method
                break
            end
        end

        assert(recurring, "Expected recurring methods in the catalogue")

        -- Sorting: once a per-run method appears, no hourly method follows it.
        local Browser = require("src/methods/browser")
        local Preferences = require("src/storage/preferences")
        local browser = Browser.new(catalogue.methods, Preferences.new(PersistentDB), function()
            return { status = "available", profit = math.random(1, 1000000), roi = 1 }
        end)
        browser:refreshEstimates()
        local seenRun = false

        for _, method in ipairs(browser:rows()) do
            local isRun = method.income.period == "run"
            assert(not (seenRun and not isRun), "An hourly method came after a recurring one")
            seenRun = seenRun or isRun
        end

        assert(seenRun, "Recurring methods should be listed")

        -- The method page speaks per run, with a yield and the cycle in Notes.
        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1200, height = 900 } })
        prettyui:findButton("Open Profit Path")()
        prettyui.views[#prettyui.views].children[2].fields[1]:SetText(recurring.title, true)

        local rowTexts = {}

        for _, view in ipairs(prettyui.allViews) do
            if not view.destroyed and view.buttons["View method"] then
                for _, label in ipairs(view.texts) do
                    rowTexts[#rowTexts + 1] = tostring(label.content)
                end
            end
        end

        assert(table.concat(rowTexts, " / "):find("every " .. recurring.income.recurrence.every, 1, true),
            "Browse row shows the cycle")

        -- Recurring methods are their own activity, with a sidebar button after
        -- Production that shows only them.
        equal(recurring.category, "recurring")
        prettyui.views[#prettyui.views].children[2].fields[1]:SetText("", true)
        prettyui:findButton("Recurring")()
        local shown = 0

        for _, view in ipairs(prettyui.allViews) do
            if not view.destroyed and view.buttons["View method"] then
                shown = shown + 1
            end
        end

        assert(shown > 0, "The Recurring section lists methods")

        for _, method in ipairs(catalogue.methods) do
            equal(method.category == "recurring", method.income.period == "run")
        end

        -- Search for it again so its row is on the first page.
        prettyui.views[#prettyui.views].children[2].fields[1]:SetText(recurring.title, true)
        prettyui:findMethod(recurring.title)()
        local income = prettyui.views[#prettyui.views].tabs[1].pages[1]
        local texts = {}

        for _, label in ipairs(income:allTexts()) do
            texts[#texts + 1] = tostring(label.content)
        end

        local all = table.concat(texts, " / ")
        assert(all:find("Profit per run (after tax)", 1, true), "Per-run headline")
        assert(all:find("Yield (% of guide)", 1, true), "Yield label")
        assert(all:find("Per run", 1, true), "Per-run column")
        assert(all:find("Can be done every", 1, true), "Cycle note")

        PluginShutdown()
    end)

    test("every capability icon a method uses resolves to a sprite name", function()
        local icons = require("data/icons")
        local missing = {}

        local function walk(node)
            if node.display_icon and not icons[node.display_icon] and not catalogue.icons[node.display_icon] then
                missing[#missing + 1] = node.display_icon
            end

            for _, child in ipairs(node.children or {}) do
                walk(child)
            end
        end

        for _, method in ipairs(catalogue.methods) do
            walk(method.requirements.access)
            walk(method.requirements.recommended)
        end

        equal(#missing, 0)
    end)
end
