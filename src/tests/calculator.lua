-- Calculator, saved-rate and whole-plugin tests. src/tests/run.lua loads this file and
-- passes in its helpers: test, equal, the fake client() and the fake pretty() UI.
--
-- Prices here are fixed made-up numbers (see quotes() below), so every expected
-- result can be worked out by hand. The steel-bar maths is written out in the
-- first calculator test.
return function(test, equal, client, pretty)
    local Income = require("src/methods/income")
    local Preferences = require("src/storage/preferences")

    -- methods[1] is the steel-bar method in the generated catalogue.
    local steel = require("data/methods").methods[1]

    -- Read evidence across nested visual panels without depending on their order.
    local function textContent(surface)
        local lines = {}

        for _, label in ipairs(surface:allTexts()) do
            lines[#lines + 1] = label.content
        end

        return table.concat(lines, "\n")
    end

    -- Fake GEPL quotes for the three steel-bar items. A fresh copy each call, so a
    -- test can change one without affecting the next.
    --   440 iron ore:  buy 10   |  453 coal:  buy 20   |  2353 steel bar:  sell 50
    -- The "other" side of each is deliberately silly (1 or 999), so using the wrong
    -- side would show up straight away.
    local function quotes()
        return {
            [440] = { status = "available", high = 10, highTime = 100, low = 1, lowTime = 90 },
            [453] = { status = "available", high = 20, highTime = 100, low = 1, lowTime = 90 },
            [2353] = { status = "available", low = 50, lowTime = 80, high = 999, highTime = 100 },
        }
    end

    -- Calculator maths (income.lua) -----------------------------------------------

    test("method skill evidence reads only mapped skills while logged in", function()
        local state = client()
        local account = require("src/game/account").new(function() end)

        -- Unknown skill names are skipped instead of erroring.
        local skills = account:readSkills({ SMITHING = true, UNMAPPED = true })

        equal(skills.SMITHING.level, 96)
        equal(skills.UNMAPPED, nil)

        -- Logged out: nothing at all, so requirement checks show "unknown".
        state.available = false
        equal(next(account:readSkills({ SMITHING = true })), nil)

        account:destroy()
    end)

    -- Worked by hand at 2,000 smelts/hour:
    --   revenue: 2,000 bars x 50 = 100,000 gross; tax floor(50/50) = 1 per bar = 2,000
    --            so 98,000 after tax
    --   supplies: 2,000 x (10 ore + 20 coal) = 60,000
    --   profit: 98,000 - 60,000 = 38,000;  ROI: 38,000 / 60,000 = 63.33%
    test("source steel recipe uses buy inputs, sell outputs, tax and cost-based ROI", function()
        local result = Income.calculate(steel.income, 2000, quotes())

        equal(result.status, "available")
        equal(result.gross, 100000)
        equal(result.tax, 2000)
        equal(result.revenue, 98000)
        equal(result.cost, 60000)
        equal(result.profit, 38000)
        assert(math.abs(result.roi - 63.3333333333333) < 0.000001)

        -- Each row keeps the timestamp of the side it used (buy for inputs, sell for outputs).
        equal(result.inputs[1].timestamp, 100)
        equal(result.outputs[1].timestamp, 80)
    end)

    test("rate scaling and zero throughput preserve hourly costs", function()
        -- Half the rate, half the profit.
        local half = Income.calculate(steel.income, 1000, quotes())
        equal(half.profit, 19000)

        -- A fixed "per hour" cost (5 x 10 = 50) is paid even at rate 0, and doesn't
        -- grow when the rate goes up.
        local model = {
            coverage = "complete",
            inputs = { { name = "Hourly cost", item_id = 440, quantity = 5, basis = "hour" } },
            outputs = steel.income.outputs,
        }

        local stopped = Income.calculate(model, 0, quotes())

        equal(stopped.cost, 50)
        equal(stopped.revenue, 0)
        equal(stopped.profit, -50)
        equal(stopped.roi, -100)

        equal(Income.calculate(model, 1000, quotes()).cost, 50)

        -- Rate 0 with no prices at all: zero of everything is known to cost nothing,
        -- so profit is a real 0. ROI has no spend to divide by, so it's left empty.
        local zero = Income.calculate(steel.income, 0, {})

        equal(zero.status, "available")
        equal(zero.profit, 0)
        equal(zero.roi, nil)
    end)

    -- Tax per bar is floor(price / 50): 49 -> 0, 99 -> 1, 100 -> 2. Times 3 bars.
    test("tax rounds down per item before multiplying quantity", function()
        local prices = quotes()

        prices[2353].low = 49
        equal(Income.calculate(steel.income, 3, prices).tax, 0)

        prices[2353].low = 99
        equal(Income.calculate(steel.income, 3, prices).tax, 3)

        prices[2353].low = 100
        equal(Income.calculate(steel.income, 3, prices).tax, 6)
    end)

    -- Break the iron ore price four different ways. Each time, revenue still shows
    -- (the bar price is fine), but there's no cost total and no profit.
    test("missing, stale or malformed price sides never produce complete profit", function()
        for _, value in ipairs({ "missing", "stale", "timestamp", "nan" }) do
            local prices = quotes()

            if value == "missing" then
                prices[440] = nil
            end

            if value == "stale" then
                prices[440].status = "stale"
            end

            if value == "timestamp" then
                prices[440].highTime = nil
            end

            if value == "nan" then
                prices[440].high = 0 / 0
            end

            local result = Income.calculate(steel.income, 2000, prices)

            equal(result.status, "partial")
            equal(result.profit, nil)
            equal(result.cost, nil)
            equal(result.revenue, 98000)
        end

        -- A GEPL error message should reach the row so the player can see why.
        local prices = quotes()
        prices[440] = { status = "error", message = "Dependency error fixture" }

        equal(Income.calculate(steel.income, 2000, prices).inputs[1].message, "Dependency error fixture")
    end)

    -- methods[2] is elder logs (potion cost still unknown); methods[3] is abyssal
    -- demons (loot not valued yet). Neither may show a total profit.
    test("incomplete source recipes and unprocessed loot do not imply zero costs or revenue", function()
        -- 320 logs x 1,000 = 320,000 minus tax 320 x 20 = 313,600.
        local result = Income.calculate(require("data/methods").methods[2].income, 320, {
            [29556] = { status = "available", low = 1000, lowTime = 50 },
        })

        equal(result.status, "partial")
        equal(result.revenue, 313600)
        equal(result.cost, nil)
        equal(result.profit, nil)

        local pvm = Income.calculate(require("data/methods").methods[3].income, 900, {})

        equal(pvm.status, "partial")
        equal(pvm.revenue, nil)
        equal(pvm.profit, nil)
    end)

    test("rate parser rejects empty negative nonfinite input and arithmetic overflow", function()
        -- "1e999" parses to infinity in Lua, so it must be rejected too.
        for _, text in ipairs({ "", "abc", "-1", "1e999" }) do
            equal(Income.parseRate(text), nil)
        end

        equal(Income.parseRate("0"), 0)
        equal(Income.parseRate("123.5"), 123.5)

        -- A huge but finite rate overflows the multiplication; it must say so.
        equal(Income.calculate(steel.income, math.huge, {}).status, "invalid")
        equal(Income.calculate(steel.income, 1e308, quotes()).status, "invalid")
    end)

    -- The same item three times (twice as input, once as output) means one GEPL call.
    test("quote capture deduplicates items and copies dependency values", function()
        local calls = 0
        local source = quotes()

        local library = {
            isReady = function()
                return true
            end,

            getLatest = function(id)
                calls = calls + 1
                return source[id]
            end,
        }

        local captured = Income.captureQuotes(library, {
            inputs = { { item_id = 440 }, { item_id = 440 } }, outputs = { { item_id = 440 } },
        })

        equal(calls, 1)

        source[440].high = 999
        equal(captured[440].high, 10)
    end)

    -- Saved rates (preferences.lua) -------------------------------------------------

    -- Each `Preferences.new(PersistentDB)` below is like a plugin reload: a fresh
    -- object reading the same storage.
    test("rate overrides survive reload, isolate manual profiles and reset only one rate", function()
        local state = client()
        local preferences = Preferences.new(PersistentDB)

        equal(preferences:loadRate(steel), 2000)

        assert(preferences:saveRate(steel, 1234.5))
        equal(Preferences.new(PersistentDB):loadRate(steel), 1234.5)

        -- A second profile starts from the default and keeps its own value (0 is valid).
        assert(preferences:selectProfile("Other character"))
        equal(preferences:loadRate(steel), 2000)

        assert(preferences:saveRate(steel, 0))

        -- The selected profile itself is remembered across a reload.
        local reloaded = Preferences.new(PersistentDB)

        equal(reloaded.profile, "Other character")
        equal(reloaded:loadRate(steel), 0)

        -- Resetting Default's rate must not touch unrelated keys or the other profile.
        assert(reloaded:selectProfile("Default"))
        state.db["unrelated-setting"] = "preserve"

        assert(reloaded:resetRate(steel))
        equal(reloaded:loadRate(steel), 2000)
        equal(state.db["unrelated-setting"], "preserve")

        assert(reloaded:selectProfile("Other character"))
        equal(reloaded:loadRate(steel), 0)
    end)

    test("corrupt or changed-unit settings stay visible and do not overwrite unrelated data", function()
        local state = client()
        local preferences = Preferences.new(PersistentDB)

        assert(preferences:saveRate(steel, 1000))

        -- Pretend the method's unit changed since the rate was saved.
        for _, record in pairs(state.db) do
            if type(record) == "table" then
                record.unit = "runs/hour"
            end
        end

        local rate, saved, warning = preferences:loadRate(steel)

        equal(rate, 2000)
        equal(saved, false)
        assert(warning:find("units changed", 1, true))

        -- Now pretend the record is outright garbage.
        for key, record in pairs(state.db) do
            if type(record) == "table" then
                state.db[key] = "malformed"
            end
        end

        rate, saved, warning = preferences:loadRate(steel)

        equal(rate, 2000)
        assert(warning)
    end)

    test("storage failures and invalid profile names are reported without changing selection", function()
        local state = client()
        local preferences = Preferences.new(PersistentDB)

        equal(preferences:selectProfile(""), false)
        equal(preferences:selectProfile("bad/name"), false)

        -- A failed write leaves us on the old profile and reports failure.
        state.failWrite = true

        equal(preferences:selectProfile("New"), false)
        equal(preferences.profile, "Default")
        equal(preferences:saveRate(steel, 1000), false)

        state.failWrite = false
        assert(preferences:saveRate(steel, 1000))

        -- A failed delete keeps the saved rate.
        state.failDelete = true

        equal(preferences:resetRate(steel), false)
        equal(preferences:loadRate(steel), 1000)

        -- A failed read falls back to the default, with the real error in the warning.
        state.failRead = true
        local rate, _, warning = preferences:loadRate(steel)

        equal(rate, 2000)
        assert(warning:find("Storage read failed", 1, true))
    end)

    -- Whole plugin through main.lua ------------------------------------------------
    -- These load main.lua for real and drive it by "clicking" the fake buttons.
    -- prettyui.views is every view in creation order: [1] is usually the launcher,
    -- [2] Browse and [3] the method screen.

    -- The main happy path: open steel bars, type rates, save, reset, go back, shut down.
    test("browse detail preview save reset and teardown work through the actual entry point", function()
        local state = client()
        prettyui = pretty()

        local source = quotes()
        local calls = 0

        gepl = {
            isReady = function()
                return true
            end,

            getLatest = function(id)
                calls = calls + 1
                return source[id]
            end,
        }

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 900, height = 700 } })
        prettyui.views[1].buttons["Open Profit Path"]()
        prettyui:findMethod("Smelting steel bars")()

        -- Income opens first and the tabs are in the agreed order.
        local detail = prettyui.views[3]
        local tabs = detail.tabs[1]

        equal(tabs.activeIndex, 1)
        equal(tabs.entries[1].text, "Income")
        equal(tabs.entries[2].text, "Requirements")

        -- fields[1] is the rate box; profile controls come after the breakdown.
        local income = tabs.pages[1]
        local rate = income.fields[1]

        -- Opening fetched 3 prices (one per item). Typing a rate must not fetch more.
        equal(calls, 6)

        rate:SetText("1000", true)
        equal(calls, 6)

        -- Save 1000, then type away and back. Being back on the saved value should
        -- show "Saved personal rate" again, not "not saved".
        rate:Submit()
        rate:SetText("2000", true)
        rate:SetText("1000", true)

        local savedLabelFound = false

        for _, label in ipairs(income:allTexts()) do
            if label.content:find("Saved personal rate", 1, true) then
                savedLabelFound = true
            end
        end

        assert(savedLabelFound, "Returning to the committed rate must clear the dirty label")

        local saved

        for key, value in pairs(state.db) do
            if key:find("profit-path.rate.v1/", 1, true) == 1 then
                saved = value.value
            end
        end

        equal(saved, 1000)

        -- Junk input can't be saved, and the last good estimate stays on screen.
        rate:SetText("invalid", true)
        income.buttons["Save rate"]()

        for key, value in pairs(state.db) do
            if key:find("profit-path.rate.v1/", 1, true) == 1 then
                equal(value.value, 1000)
            end
        end

        local combined = {}

        for _, label in ipairs(income:allTexts()) do
            combined[#combined + 1] = label.content
        end

        assert(table.concat(combined):find("19,000/hour", 1, true))

        -- Reset puts 2000 back in the box and deletes the saved record.
        income.buttons["Reset to source rate"]()
        equal(rate:GetText(), "2000")

        for key, value in pairs(state.db) do
            assert(key:find("profit-path.rate.v1/", 1, true) ~= 1)
        end

        -- After Back, the old screen is destroyed and its controls must do nothing.
        detail.buttons["Back to methods"]()
        assert(detail.destroyed and income.destroyed)

        rate:SetText("5", true)
        income.buttons["Save rate"]()
        equal(calls, 6)

        for key, value in pairs(state.db) do
            assert(key:find("profit-path.rate.v1/", 1, true) ~= 1)
        end

        PluginShutdown()

        for _, sourceEvent in pairs(Event) do
            equal(sourceEvent.count(), 0)
        end
    end)

    test("launcher remount and close-reopen retain one independent window and its draft", function()
        local state = client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        -- The launcher alone must not open the window.
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        local firstLauncher = prettyui.views[1]

        equal(#prettyui.windows, 0)

        firstLauncher.buttons["Open Profit Path"]()
        local window = prettyui.windows[1]

        equal(window.options.resizable, true)
        equal(window.options.scrollable, false)

        prettyui:findMethod("Smelting steel bars")()

        local detail = prettyui.views[3]
        local income = detail.tabs[1].pages[1]
        local rate = income.fields[1]

        -- Type a draft, then close (hide) the window. Buttons on a hidden window
        -- must do nothing, so this Save doesn't write.
        rate:SetText("1234.5", true)
        window:Close()

        income.buttons["Save rate"]()
        assert(state.db["profit-path.characters.v1"])

        -- The client remounts the launcher. The old launcher goes; the window stays.
        Event.ContentLayerReady.emit({ component = { width = 700, height = 450 } })
        local latestLauncher = prettyui.views[4]

        assert(firstLauncher.destroyed)
        assert(not detail.destroyed)

        -- The dead launcher's button does nothing; the new one reopens the same window.
        firstLauncher.buttons["Open Profit Path"]()
        equal(window.hidden, true)

        latestLauncher.buttons["Open Profit Path"]()

        equal(#prettyui.windows, 1)
        equal(window.hidden, false)
        equal(rate:GetText(), "1234.5")

        -- Reopened, so the draft can be saved now.
        rate:Submit()

        local found = false

        for _, record in pairs(state.db) do
            if type(record) == "table" and record.value == 1234.5 then
                found = true
            end
        end

        assert(found)

        -- Navigating swaps the content but keeps the same window.
        detail.buttons["Back to methods"]()

        equal(#prettyui.windows, 1)
        assert(not window.destroyed)
        assert(detail.destroyed)

        PluginShutdown()
        assert(window.destroyed and latestLauncher.destroyed)
    end)

    test("skill updates refresh visible base evidence and stop after shutdown", function()
        client()
        prettyui = pretty()
        gepl = nil

        -- Every skill reads as `level`, which we can change mid-test.
        local level = 10
        Player.GetLevelUncapped = function()
            return level
        end

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui.views[1].buttons["Open Profit Path"]()
        prettyui:findMethod("Smelting steel bars")()

        local requirements = prettyui.views[3].tabs[1].pages[2]
        local skillLabel = requirements.children[1].texts[2]
        equal(skillLabel.content, "20 Smithing")
        equal(skillLabel.rgba, require("src/ui/view_style").bad)

        level = 40
        Event.SkillTransmit.emit({ skill = SkillType.SMITHING })
        equal(skillLabel.content, "20 Smithing")
        equal(skillLabel.rgba, require("src/ui/view_style").good)
        assert(not textContent(requirements):find("Your level:", 1, true))

        -- After shutdown the listener is gone, and firing the event is harmless.
        PluginShutdown()
        equal(Event.SkillTransmit.count(), 0)

        Event.SkillTransmit.emit({ skill = SkillType.SMITHING })
    end)

    -- Inventory events can fire on every action while skilling. They can't change
    -- skill requirements, so they shouldn't trigger skill reads.
    test("inventory updates do not repeat method skill reads", function()
        client()
        prettyui = pretty()
        gepl = nil

        local reads = 0
        Player.GetLevelUncapped = function()
            reads = reads + 1
            return 30
        end

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui.views[1].buttons["Open Profit Path"]()
        prettyui:findMethod("Smelting steel bars")()

        local afterOpen = reads

        Event.InventoryUpdated.emit({ inv = config.Inv.INV })
        equal(reads, afterOpen)

        Event.SkillTransmit.emit({ skill = SkillType.SMITHING })
        assert(reads > afterOpen, "Skill updates should still refresh method evidence")

        PluginShutdown()
    end)

    -- A typo'd screen name must error loudly and clean up, not quietly fall back
    -- to some other screen.
    test("unknown navigation fails visibly and cleans up instead of opening diagnostics", function()
        client()

        local account = require("src/game/account").new(function() end)
        local library = pretty()
        local screen = require("src/ui/workbench").new(library, account)

        screen.screen = "misspelled-screen"

        local ok, problem = pcall(function()
            screen:mount({ width = 600, height = 400 })
        end)

        equal(ok, false)
        assert(tostring(problem):find("Unknown Profit Path screen", 1, true))
        assert(library.views[1].destroyed)

        screen:destroy()
        account:destroy()

        equal(account:readPlayer().status, "stopped")
    end)

    test("game-state transitions discard the native window without reopening it", function()
        local state = client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })

        local launcher = prettyui.views[1]
        launcher.buttons["Open Profit Path"]()
        local first = prettyui.windows[1]

        -- Simulate a logout: the game area disappears and the game state changes.
        state.gameArea = nil
        Event.GameStateChanged.emit({})

        assert(first.destroyed)
        assert(prettyui.views[2].destroyed)
        equal(#prettyui.windows, 1)

        -- With no game area, Open fails politely and says why on the launcher.
        launcher.buttons["Open Profit Path"]()
        equal(#prettyui.windows, 1)

        local message = table.concat({ launcher.texts[1].content, launcher.texts[2].content, launcher.texts[3].content })
        assert(message:find("game area is unavailable", 1, true))

        -- Back in game: Open builds a brand-new window.
        state.gameArea = { width = 1280, height = 900, interfaceID = 2 }
        launcher.buttons["Open Profit Path"]()
        equal(#prettyui.windows, 2)

        PluginShutdown()
        assert(prettyui.windows[2].destroyed)

        for _, sourceEvent in pairs(Event) do
            equal(sourceEvent.count(), 0)
        end
    end)

    test("a failed window body is cleaned up and the launcher can retry", function()
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")

        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        local open = prettyui.views[1].buttons["Open Profit Path"]

        -- First attempt: building the Browse screen throws, so the window and its
        -- half-built view are both destroyed.
        prettyui.failTitle = true
        open()

        assert(prettyui.windows[1].destroyed)
        assert(prettyui.views[2].destroyed)

        -- Second attempt works and makes a new window.
        prettyui.failTitle = false
        open()

        equal(#prettyui.windows, 2)

        -- Closing the dead first window must not stop the new one working.
        local current = prettyui.views[3]
        prettyui.windows[1]:Close()

        prettyui:findMethod("Smelting steel bars")()
        equal(#prettyui.views, 4)

        PluginShutdown()
        assert(prettyui.windows[2].destroyed)
    end)
end
