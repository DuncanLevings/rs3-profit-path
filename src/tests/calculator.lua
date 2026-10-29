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

    -- Made-up GE buy prices for every GE ingredient of a Perfect plus potion (6):
    --   Overload (3) = 6 extremes x 10,000 + clean torstol 6,000 = 66,000
    --   Overload (4) = 66,000 x 4/3 doses                         = 88,000
    --   Perfect plus (6) = 88,000 + harmony moss 9,000 + crystal flask 3,000
    --                      + crystal tree blossom (free)          = 100,000
    -- Clean torstol's price is the oldest (time 10), so that's the row's timestamp.
    local function perfectPlusQuotes()
        local quotes = {
            [269] = { status = "available", high = 6000, highTime = 10 },
            [32947] = { status = "available", high = 9000, highTime = 50 },
            [32843] = { status = "available", high = 3000, highTime = 50 },
        }

        for _, extreme in ipairs({ 15309, 15313, 15317, 15321, 15325, 55326 }) do
            quotes[extreme] = { status = "available", high = 10000, highTime = 50 }
        end

        return quotes
    end

    test("untradeable supplies are priced from their recipe chain with doses and free ingredients", function()
        local RecipeCost = require("src/methods/recipe_cost")
        local quotes = perfectPlusQuotes()

        local price, oldest = RecipeCost.price("Perfect plus potion", 6, quotes)
        equal(price, 100000)
        equal(oldest, 10)

        -- Asking for 3 doses of overload is one recipe; 4 doses is 4/3 of one.
        equal(RecipeCost.price("Overload", 3, quotes), 66000)
        equal(RecipeCost.price("Overload", 4, quotes), 88000)

        -- Only the blossom has no price; it's counted as free and named.
        local free = RecipeCost.freeNames("Perfect plus potion")
        equal(#free, 1)
        equal(free[1], "Crystal tree blossom")

        -- All nine GE ingredients (through Overload) are fetched up front.
        local count = 0

        for _ in pairs(RecipeCost.itemIds("Perfect plus potion")) do
            count = count + 1
        end

        equal(count, 9)

        -- One missing ingredient price means no price at all, and says which.
        quotes[269] = nil
        local missing, problem = RecipeCost.price("Perfect plus potion", 6, quotes)
        equal(missing, nil)
        assert(problem:find("Clean torstol", 1, true), problem)
    end)

    -- methods[2] is elder logs: its Perfect plus potion is priced by creation cost,
    -- so with every price it has a full profit. Missing ingredient prices mean no
    -- cost and no profit (never a pretend zero). The same rule applies when
    -- abyssal demon loot prices are missing.
    test("creation-cost supplies give a full profit while missing ingredient or loot prices stay unknown", function()
        local elder = require("data/methods").methods[2].income

        -- 320 logs x 1,000 = 320,000 minus tax 320 x 20 = 313,600. The potion
        -- (100,000 to make) is used at 1/24 of a potion an hour.
        local quotes = perfectPlusQuotes()
        quotes[29556] = { status = "available", low = 1000, lowTime = 50 }

        local result = Income.calculate(elder, 320, quotes)

        equal(result.status, "available")
        equal(result.revenue, 313600)
        assert(math.abs(result.cost - 100000 / 24) < 1e-6, "Potion cost per hour")
        assert(math.abs(result.profit - (313600 - 100000 / 24)) < 1e-6, "Profit per hour")
        equal(result.inputs[1].creationCost, true)
        equal(result.inputs[1].timestamp, 10)

        -- Same again with no ingredient prices: revenue only.
        local noPotion = Income.calculate(elder, 320, {
            [29556] = { status = "available", low = 1000, lowTime = 50 },
        })

        equal(noPotion.status, "partial")
        equal(noPotion.revenue, 313600)
        equal(noPotion.cost, nil)
        equal(noPotion.profit, nil)
        assert(noPotion.inputs[1].message:find("No GE price for", 1, true))

        local pvm = Income.calculate(require("data/methods").methods[3].income, 900, {})

        equal(pvm.status, "partial")
        equal(pvm.revenue, nil)
        equal(pvm.profit, nil)
    end)

    -- Elder logs with wood spirits: each spirit gives one extra log, so at the
    -- source's 580 logs an hour it uses 260 spirits. Spirits scale with the rate.
    test("elder logs with wood spirits uses 260 spirits for 580 logs an hour", function()
        local spirits

        for _, method in ipairs(require("data/methods").methods) do
            if method.id == "cutting-elder-logs.with-spirits" then
                spirits = method
            end
        end

        equal(spirits.title, "Cutting elder logs")
        equal(spirits.income.rate.default, 580)

        local quotes = perfectPlusQuotes()
        quotes[29556] = { status = "available", low = 1000, lowTime = 50 }
        quotes[54924] = { status = "available", high = 400, highTime = 50 }

        local result = Income.calculate(spirits.income, 580, quotes)
        local rows = {}

        for _, row in ipairs(result.inputs) do
            rows[row.name] = row
        end

        -- 580 logs x (1,000 - 20 tax) = 568,400. Spirits 260 x 400 = 104,000, plus
        -- the potion at 100,000 / 24 an hour.
        equal(result.revenue, 568400)
        assert(math.abs(rows["Elder wood spirit"].quantity - 260) < 1e-9)
        assert(math.abs(result.cost - (104000 + 100000 / 24)) < 1e-6)
        equal(result.status, "available")

        -- Half the logs, half the spirits.
        local half = Income.calculate(spirits.income, 290, quotes)
        local halfRows = {}

        for _, row in ipairs(half.inputs) do
            halfRows[row.name] = row
        end

        assert(math.abs(halfRows["Elder wood spirit"].quantity - 130) < 1e-9)
    end)

    -- Abyssal demons: Aggroverload is untradeable (creation cost), Super prayer
    -- renewal is a normal GE item. Every supply gets a value and the supply total
    -- is known, but missing sell quotes still prevent total revenue/profit.
    test("abyssal demon potions are priced while missing loot prices still block profit", function()
        local RecipeCost = require("src/methods/recipe_cost")
        local demons = require("data/methods").methods[3].income

        -- Every price 1,000 GP, for every GE item the supplies need.
        local quotes = {}

        local function price(itemId)
            quotes[itemId] = { status = "available", high = 1000, highTime = 50, low = 1000, lowTime = 50 }
        end

        for itemId in pairs(RecipeCost.itemIds("Aggroverload")) do
            price(itemId)
        end

        for _, itemId in ipairs({ 33186, 31613, 32341 }) do
            price(itemId)
        end

        local result = Income.calculate(demons, 900, quotes)
        local rows = {}

        for _, row in ipairs(result.inputs) do
            rows[row.name] = row
        end

        local aggroverload = rows["Aggroverload (6)"]
        equal(aggroverload.creationCost, true)
        assert(aggroverload.value and aggroverload.value > 0, "Aggroverload should have a creation cost")

        local renewal = rows["Super prayer renewal potion (6)"]
        equal(renewal.creationCost, nil)
        equal(renewal.value, 9 * 1000)

        assert(result.cost, "Every supply is priced, so the supply total is known")
        equal(result.profit, nil)
        equal(result.status, "partial")
    end)

    -- An independent hand calculation for all Wiki-selected drops. GE items use
    -- 1,000 GP each (980 after tax); salvage/coin income never uses a GE quote.
    test("shared PvM loot matches Wiki quantities and alchemy values and scales with kills", function()
        local Loot = require("src/methods/loot")
        local method = require("data/methods").methods[3]
        local outputs = Loot.outputs(method.income)
        equal(#outputs, 16)
        local quotes, fetched = {}, {}
        local library = {
            isReady = function() return true end,
            getLatest = function(itemId)
                assert(itemId ~= 995 and itemId ~= 47240 and itemId ~= 47286 and itemId ~= 47306 and itemId ~= 47312,
                    "Coin and alchemy proceeds must not fetch GE prices")
                assert(not fetched[itemId], "Duplicate quote")
                fetched[itemId] = true
                return { high = 1000, highTime = 50, low = 1000, lowTime = 50 }
            end,
        }
        quotes = Income.captureQuotes(library, method.income)
        local result = Income.calculate(method.income, 900, quotes)
        equal(result.status, "available")
        local rows = {}

        for _, row in ipairs(result.outputs) do
            rows[row.name] = row
        end

        local expectedPerKill = {
            ["Abyssal wand"] = 1/6104, ["Abyssal orb"] = 1/6104, ["Abyssal whip"] = 1/1024,
            ["Uncut ruby"] = 14/128, ["Uncut diamond"] = 6/128, ["Uncut dragonstone"] = 2/128,
            ["Orichalcite stone spirit"] = 4/128, ["Phasmatite stone spirit"] = 4/128,
            ["Medium bladed adamant salvage"] = 12/128, ["Tiny spiky rune salvage"] = 8/128,
            ["Tiny plated rune salvage"] = 4/128, ["Large plated rune salvage"] = 4/128,
            Coins = 2400*18/128 + 3000*14/128,
            ["Pure essence"] = 80*12/128, ["Magic logs"] = 6*6/128, ["Fire orb"] = 2*6/128,
        }

        for name, perKill in pairs(expectedPerKill) do
            assert(math.abs(rows[name].quantity - perKill * 900) < 1e-9, name)
        end

        -- Two coin ranges: average 2,400 at 18/128 and 3,000 at 14/128.
        equal(rows.Coins.quantity, 900 * (2400 * 18 / 128 + 3000 * 14 / 128))
        equal(rows.Coins.value, 599062.5)
        equal(rows.Coins.tax, 0)
        equal(rows["Large plated rune salvage"].value, 900 * 4 / 128 * 32000)
        equal(rows["Medium bladed adamant salvage"].value, 900 * 12 / 128 * 6000)
        equal(rows["Tiny spiky rune salvage"].value, 900 * 8 / 128 * 8000)
        equal(rows["Tiny plated rune salvage"].value, 900 * 4 / 128 * 8000)
        equal(rows["Pure essence"].quantity, 900 * 80 * 12 / 128)
        equal(rows["Magic logs"].quantity, 900 * 6 * 6 / 128)
        equal(rows["Fire orb"].quantity, 900 * 2 * 6 / 128)
        equal(rows["Abyssal wand"].quantity, 900 / 6104)
        equal(rows["Abyssal whip"].quantity, 900 / 1024)

        local gePerKill = 2 / 6104 + 1 / 1024 + 14 / 128 + 6 / 128 + 2 / 128
            + 4 / 128 + 4 / 128 + 80 * 12 / 128 + 6 * 6 / 128 + 2 * 6 / 128
        local expected = 2680312.5 + 900 * gePerKill * 980
        assert(math.abs(result.revenue - expected) < 1e-7)
        assert(math.abs(result.profit - (expected - result.cost)) < 1e-7)
        local half = Income.calculate(method.income, 450, quotes)
        assert(math.abs(half.revenue - result.revenue / 2) < 1e-7)

        -- Missing a single sell price makes total revenue/profit unavailable,
        -- but fixed coin/alchemy rows remain visible and usable.
        quotes[30825] = nil
        local missing = Income.calculate(method.income, 900, quotes)
        equal(missing.revenue, nil)
        equal(missing.profit, nil)
        equal(missing.outputs[13].value, 599062.5)
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
    test("rate overrides survive reload, isolate character profiles and reset only one rate", function()
        local state = client()
        local preferences = Preferences.new(PersistentDB)

        equal(preferences:loadRate(steel), 2000)

        assert(preferences:saveRate(steel, 1234.5))
        equal(Preferences.new(PersistentDB):loadRate(steel), 1234.5)

        -- The first character bound keeps the existing (Default) profile and rate.
        assert(preferences:bindCharacter("First character"))
        equal(preferences:loadRate(steel), 1234.5)

        -- A second character gets its own profile, starting from the source default,
        -- and keeps its own value (0 is valid).
        assert(preferences:bindCharacter("Other character"))
        equal(preferences:loadRate(steel), 2000)

        assert(preferences:saveRate(steel, 0))

        -- The binding itself is remembered across a reload.
        local reloaded = Preferences.new(PersistentDB)
        assert(reloaded:bindCharacter("Other character"))

        equal(reloaded.profile, "Other character")
        equal(reloaded:loadRate(steel), 0)

        -- Resetting the first character's rate must not touch unrelated keys or the
        -- other character's rate.
        assert(reloaded:bindCharacter("First character"))
        state.db["unrelated-setting"] = "preserve"

        assert(reloaded:resetRate(steel))
        equal(reloaded:loadRate(steel), 2000)
        equal(state.db["unrelated-setting"], "preserve")

        assert(reloaded:bindCharacter("Other character"))
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

        -- Blank names and names with control characters are rejected outright.
        equal(preferences:bindCharacter(""), false)
        equal(preferences:bindCharacter("bad\nname"), false)

        -- A failed write leaves us on the old profile and reports failure.
        state.failWrite = true

        equal(preferences:bindCharacter("New"), false)
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

        -- Browse fetched 48 prices across the four methods, including the now-valued
        -- PvM loot and its ingredient tree, then the steel method fetched 3 more. Typing a rate must not fetch more.
        equal(calls, 51)

        rate:SetText("1000", true)
        equal(calls, 51)

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

        assert(table.concat(combined):find("19,000 / h", 1, true))

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
        equal(calls, 51)

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
