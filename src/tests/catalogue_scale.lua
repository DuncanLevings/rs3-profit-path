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
