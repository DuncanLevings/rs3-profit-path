-- Custom activities (Phase 9, slice 2): checking saved records, turning them into
-- methods the calculator understands, and storing them. There's no UI yet. The
-- records here are made-up fixtures, not real activities.
return function(test, equal, client, pretty)
    local CustomMethods = require("src/methods/custom_methods")
    local Income = require("src/methods/income")
    local Browser = require("src/methods/browser")
    local Preferences = require("src/storage/preferences")
    local Recommendations = require("src/methods/recommendations")

    local INDEX = "profit-path.custom.v1/index"

    -- A valid PvM record: 30 kills an hour, 10 kills a trip. A fresh copy each
    -- call so a test can break one field without touching the next test.
    local function record(fields)
        local base = {
            schema = 1,
            id = "custom.1",
            title = "Fixture monster",
            category = "pvm",
            rate = { unit = "kills/hour", default = 30 },
            actions_per_trip = 10,
            outputs = {
                { label = "Steel bar", item_id = 2353, pricing = "ge", quantity = 1, basis = "action" },
                { label = "Clue value", pricing = "fixed", unit_value = 1000, quantity = 1, basis = "hour" },
                { label = "Rare drop", item_id = 2353, pricing = "ge", quantity = 5, basis = "action", state = "off" },
            },
            supplies = {
                { label = "Food", item_id = 440, pricing = "ge", quantity = 8, basis = "trip" },
            },
            requirements = {
                required = { { kind = "skill", skill = "HITPOINTS", level = 70 } },
                recommended = { { kind = "note", text = "Bring a ring of wealth." } },
            },
        }

        for key, value in pairs(fields or {}) do
            base[key] = value
        end

        return base
    end

    -- Does any problem message contain `text`?
    local function mentions(problems, text)
        for _, problem in ipairs(problems or {}) do
            if problem:find(text, 1, true) then
                return true
            end
        end

        return false
    end

    local function rejected(fields, text)
        local ok, problems = CustomMethods.validate(record(fields))

        assert(not ok, "expected the record to be rejected")
        assert(mentions(problems, text), "expected a problem about '" .. text .. "', got: "
            .. table.concat(problems, " | "))
    end

    -- Checking records -------------------------------------------------------------

    test("custom records: a complete PvM record is accepted", function()
        equal(CustomMethods.validate(record()), true)
    end)

    test("custom records: anything malformed is rejected with a reason", function()
        equal(CustomMethods.validate(nil), false)
        equal(CustomMethods.validate(record({ schema = 2 })), false)

        rejected({ id = "abyssal-demons" }, "ID")
        rejected({ title = "   " }, "name")
        rejected({ title = string.rep("x", 61) }, "name")
        rejected({ title = "Tab\there" }, "name")
        rejected({ category = "minigame" }, "category")
        rejected({ rate = { unit = "laps/hour", default = 30 } }, "Throughput")
        rejected({ rate = { unit = "kills/hour", default = 0 / 0 } }, "Throughput")
        rejected({ notes = string.rep("x", 301) }, "Notes")

        -- Rows: pricing, item, value, quantity, basis and state.
        rejected({ supplies = { { label = "Food", pricing = "ge", quantity = 1, basis = "action" } } }, "needs an item")
        rejected({ supplies = { { label = "Fee", pricing = "fixed", quantity = 1, basis = "action" } } }, "GP value")
        rejected({ supplies = { { label = "Food", item_id = 440, pricing = "ge", quantity = -1, basis = "action" } } }, "quantity")
        rejected({ supplies = { { label = "Food", item_id = 440, pricing = "ge", quantity = 1, basis = "day" } } }, "per hour")
        rejected({ supplies = { { label = "Food", item_id = 440, pricing = "ge", quantity = 1, basis = "action", state = "off" } } },
            "always counted")
        rejected({ outputs = { { label = "Bar", item_id = 2353, pricing = "ge", quantity = 1, basis = "action", state = "maybe" } } },
            "unknown state")
    end)

    -- Daily/weekly custom activities count per run: runs as the rate, every row
    -- per run, and how often they're done.
    test("custom records: daily/weekly activities count per run", function()
        local function recurring(fields)
            local base = {
                category = "recurring", rate = { unit = "runs", default = 1 }, actions_per_trip = false,
                recurrence = { every = "week", minutes = 15 }, no_requirements = true,
                outputs = { { label = "Reward", pricing = "fixed", unit_value = 50000, quantity = 1, basis = "action" } },
                supplies = {},
                requirements = { required = {}, recommended = {} },
            }

            for key, value in pairs(fields or {}) do
                base[key] = value
            end

            -- actions_per_trip = false above is a marker for "leave it out".
            local built = record(base)
            built.actions_per_trip = nil
            return built
        end

        equal(CustomMethods.validate(recurring()), true)

        local method = CustomMethods.toMethod(recurring())
        equal(method.income.period, "run")
        equal(method.income.recurrence.every, "week")
        equal(Income.calculate(method.income, 1, {}).profit, 50000)

        local ok, problems = CustomMethods.validate(recurring({ rate = { unit = "actions/hour", default = 1 } }))
        equal(ok, false)
        assert(mentions(problems, "count runs"))

        ok, problems = CustomMethods.validate(recurring({ recurrence = { every = "fortnight" } }))
        equal(ok, false)
        assert(mentions(problems, "how often"))

        ok, problems = CustomMethods.validate(recurring({ outputs = {
            { label = "Reward", pricing = "fixed", unit_value = 1, quantity = 1, basis = "hour" },
        } }))
        equal(ok, false)
        assert(mentions(problems, "per run"))

        -- Like production: a Required check or "No requirements needed".
        ok, problems = CustomMethods.validate(recurring({ no_requirements = false }))
        equal(ok, false)

        -- An hourly activity has no how-often.
        rejected({ recurrence = { every = "day" } }, "Only daily/weekly")
    end)

    test("custom records: an output waiting for a number needs no quantity yet", function()
        local waiting = record({ outputs = {
            { label = "Unclear drop", item_id = 2353, pricing = "ge", basis = "action", state = "needs" },
        } })

        equal(CustomMethods.validate(waiting), true)
    end)

    -- The client calls Constitution HITPOINTS, and only its names are accepted.
    test("custom records: skills use the client's names", function()
        rejected({ requirements = { required = { { kind = "skill", skill = "CONSTITUTION", level = 70 } }, recommended = {} } },
            "unknown skill")
        rejected({ requirements = { required = { { kind = "skill", skill = "SLAYER", level = 121 } }, recommended = {} } },
            "level from 1 to 120")

        equal(CustomMethods.validate(record({ requirements = {
            required = { { kind = "skill", skill = "NECROMANCY", level = 120 } }, recommended = {},
        } })), true)
    end)

    test("custom records: per-trip rows need kills per trip; the number may be saved on its own", function()
        rejected({ actions_per_trip = 0 }, "per trip")
        rejected({ actions_per_trip = math.huge }, "per trip")
        rejected({ actions_per_trip = false }, "per trip")

        -- (Passing nil in `fields` wouldn't clear it, so clear it here.)
        local missing = record()
        missing.actions_per_trip = nil
        equal(CustomMethods.validate(missing), false)

        -- No trip rows yet: the editor's "bank between trips: Yes" keeps the
        -- number, so it's accepted, but it still has to be a real number.
        equal(CustomMethods.validate(record({ supplies = {} })), true)
        rejected({ supplies = {}, actions_per_trip = -1 }, "greater than 0")
        rejected({ supplies = {}, actions_per_trip = 0 / 0 }, "greater than 0")

        -- ...and it doesn't change the profit: nothing is counted per trip.
        local withNumber = CustomMethods.toMethod(record({ supplies = {} }))
        local without = record({ supplies = {} })
        without.actions_per_trip = nil

        local quotes = { [2353] = { status = "available", low = 500, lowTime = 1, high = 500, highTime = 1 } }
        local profit = Income.calculate(withNumber.income, 30, quotes).profit

        assert(type(profit) == "number", "the fixture prices to a real profit")
        equal(profit, Income.calculate(CustomMethods.toMethod(without).income, 30, quotes).profit)
    end)

    test("custom records: size limits stop huge activities", function()
        local outputs, requirements = {}, {}

        for index = 1, CustomMethods.LIMITS.outputs + 1 do
            outputs[index] = { label = "Drop " .. index, item_id = 2353, pricing = "ge", quantity = 1, basis = "action" }
        end

        rejected({ outputs = outputs }, "At most 40 outputs")

        -- Exactly at the limit is fine.
        outputs[#outputs] = nil
        equal(CustomMethods.validate(record({ outputs = outputs })), true)

        for index = 1, CustomMethods.LIMITS.requirements + 1 do
            requirements[index] = { kind = "skill", skill = "ATTACK", level = index }
        end

        rejected({ requirements = { required = requirements, recommended = {} } }, "At most 25 requirements")
    end)

    -- Agreed 4 Nov: PvM and skilling need a Required check the game can answer;
    -- production needs one or an explicit "none needed".
    test("custom records: the minimum requirement rule", function()
        local onlyNote = { required = { { kind = "note", text = "Combat gear" } }, recommended = {} }
        local onlyRecommended = { required = {}, recommended = { { kind = "skill", skill = "ATTACK", level = 60 } } }

        rejected({ requirements = onlyNote }, "at least one Required")
        rejected({ requirements = onlyRecommended }, "at least one Required")
        rejected({ no_requirements = true }, "can't be marked")
        rejected({ category = "skilling", requirements = onlyNote }, "at least one Required")

        -- Production: a level, or the explicit tick, but not neither or both.
        rejected({ category = "production", requirements = onlyNote }, "tick 'no requirements needed'")
        equal(CustomMethods.validate(record({ category = "production", requirements = onlyNote, no_requirements = true })), true)
        equal(CustomMethods.validate(record({ category = "production" })), true)
        rejected({ category = "production", no_requirements = true }, "alongside Required")

        -- Combat level and quests count as checks too.
        equal(CustomMethods.validate(record({ requirements = {
            required = { { kind = "combat_level", level = 100 } }, recommended = {},
        } })), true)
        equal(CustomMethods.validate(record({ requirements = {
            required = { { kind = "quest", quest = "FIXTURE_QUEST", name = "Fixture quest" } }, recommended = {},
        } })), true)
        rejected({ requirements = { required = { { kind = "quest", quest = "fixture quest", name = "Fixture quest" } },
            recommended = {} } }, "invalid quest")
    end)

    -- Turning records into methods ----------------------------------------------

    test("custom records price through the shared calculator", function()
        local method = CustomMethods.toMethod(record())
        local quotes = {
            [440] = { status = "available", high = 10, highTime = 100, low = 1, lowTime = 90 },
            [2353] = { status = "available", low = 50, lowTime = 80, high = 999, highTime = 100 },
        }

        equal(method.origin, "custom")
        equal(method.income.coverage, "complete")
        equal(method.income.rate.key, "kills_per_hour")

        -- The switched-off rare drop isn't counted at all.
        equal(#method.income.outputs, 2)

        -- 30 kills, 3 trips. Food 3 x 8 x 10 = 240. Bars 30 x (50 - 1 tax) = 1,470,
        -- plus the fixed 1,000/hour (no tax: nothing is sold) = 2,470.
        local result = Income.calculate(method.income, 30, quotes)

        equal(result.status, "available")
        equal(result.tripsPerHour, 3)
        equal(result.cost, 240)
        equal(result.revenue, 2470)
        equal(result.profit, 2230)
    end)

    test("custom records: a drop waiting for a number keeps the activity unpriced", function()
        local method = CustomMethods.toMethod(record({ outputs = {
            { label = "Bar", item_id = 2353, pricing = "ge", quantity = 1, basis = "action" },
            { label = "Unclear drop", item_id = 2353, pricing = "ge", basis = "action", state = "needs" },
        } }))

        equal(method.income.coverage, "partial")
        equal(#method.income.outputs, 1)
    end)

    test("custom records: notes are listed but never decide Met or Missing", function()
        local Requirements = require("src/game/requirements")
        local method = CustomMethods.toMethod(record({ requirements = {
            required = { { kind = "skill", skill = "HITPOINTS", level = 70 }, { kind = "note", text = "Combat gear" } },
            recommended = {},
        } }))

        local met = Requirements.evaluateAccess(method.requirements, {
            skills = { HITPOINTS = { status = "available", level = 99 } },
        })

        equal(met.status, "met")

        -- And with no level evidence it's unknown, not a false green.
        equal(Requirements.evaluateAccess(method.requirements, { skills = {} }).status, "unknown")
    end)

    -- Storage --------------------------------------------------------------------

    test("custom storage: save, reload, update and delete", function()
        local state = client()
        local store = CustomMethods.store(PersistentDB)

        local first = store:create(record({ id = nil }))
        local second = store:create(record({ id = "ignored", title = "Second" }))

        equal(first.id, "custom.1")
        equal(second.id, "custom.2")
        equal(state.db[INDEX].next, 3)

        -- A fresh store (a reload) reads both back, in the order they were made.
        local loaded, warning = CustomMethods.store(PersistentDB):load()

        equal(warning, nil)
        equal(#loaded, 2)
        equal(loaded[2].title, "Second")

        second.title = "Renamed"
        equal(store:update(second).title, "Renamed")
        equal(state.db["profit-path.custom.v1/custom.2"].title, "Renamed")

        -- Delete, then make another: the deleted ID is never handed out again,
        -- so old favourites or rates for custom.2 can't attach to the new one.
        equal(store:delete("custom.2"), true)
        equal(state.db["profit-path.custom.v1/custom.2"], nil)

        local third = store:create(record({ id = nil, title = "Third" }))

        equal(third.id, "custom.3")
        equal(#store:load(), 2)

        -- Updating a deleted activity doesn't bring it back.
        local _, problem = store:update(second)
        assert(problem:find("no longer exists", 1, true), problem)
    end)

    test("custom storage: invalid records are never saved", function()
        local state = client()
        local saved, problems = CustomMethods.store(PersistentDB):create(record({ id = nil, title = "" }))

        equal(saved, nil)
        assert(mentions(problems, "name"))
        equal(next(state.db), nil)
    end)

    test("custom storage: a failed index write leaves nothing half-saved", function()
        local state = client()
        local store = CustomMethods.store(PersistentDB)
        local realSet = PersistentDB.SetStructuredData

        -- Let the record write through, then fail the index write.
        PersistentDB.SetStructuredData = function(db, key, value)
            if key == INDEX then
                return false
            end

            return realSet(db, key, value)
        end

        local saved, problem = store:create(record({ id = nil }))

        equal(saved, nil)
        assert(problem:find("could not be saved", 1, true), problem)
        equal(#store:load(), 0)

        -- The leftover record sits under the ID the index never handed out, so
        -- the next save simply takes that slot over.
        PersistentDB.SetStructuredData = realSet

        local retried = store:create(record({ id = nil, title = "Retried" }))

        equal(retried.id, "custom.1")
        equal(state.db["profit-path.custom.v1/custom.1"].title, "Retried")
    end)

    test("custom storage: an unreadable or damaged index is never written over", function()
        local state = client({ [INDEX] = { schema = 9, next = 1, ids = {} } })
        local store = CustomMethods.store(PersistentDB)

        local loaded, warning = store:load()

        equal(#loaded, 0)
        assert(warning:find("unsupported format", 1, true), warning)

        local saved = store:create(record({ id = nil }))

        equal(saved, nil)
        equal(state.db[INDEX].schema, 9)

        -- An ID the index says it hasn't handed out yet is damage, too.
        state.db[INDEX] = { schema = 1, next = 2, ids = { "custom.5" } }
        equal(store:create(record({ id = nil })), nil)
        equal(store:delete("custom.5"), false)

        -- Storage that throws on read: nothing is loaded or written.
        state.db[INDEX] = { schema = 1, next = 1, ids = {} }
        state.failRead = true

        loaded, warning = store:load()

        equal(#loaded, 0)
        assert(warning:find("could not be loaded", 1, true), warning)
        equal(store:create(record({ id = nil })), nil)
    end)

    test("custom storage: a damaged record is skipped but kept", function()
        local state = client({
            [INDEX] = { schema = 1, next = 3, ids = { "custom.1", "custom.2" } },
            ["profit-path.custom.v1/custom.1"] = record(),
            ["profit-path.custom.v1/custom.2"] = { schema = 1, id = "custom.2", title = 42 },
        })

        local loaded, warning = CustomMethods.store(PersistentDB):load()

        equal(#loaded, 1)
        assert(warning:find("1 saved custom activity", 1, true), warning)
        equal(state.db["profit-path.custom.v1/custom.2"].title, 42)
        equal(#state.db[INDEX].ids, 2)
    end)

    test("custom storage: at most 100 activities", function()
        local ids = {}

        for index = 1, CustomMethods.LIMITS.activities do
            ids[index] = "custom." .. index
        end

        client({ [INDEX] = { schema = 1, next = #ids + 1, ids = ids } })

        local saved, problem = CustomMethods.store(PersistentDB):create(record({ id = nil }))

        equal(saved, nil)
        assert(problem:find("at most 100", 1, true), problem)
    end)

    -- Where custom activities show ------------------------------------------------

    test("custom activities stay out of Browse and recommendations, but not Favourites", function()
        client()

        local custom = CustomMethods.toMethod(record())
        local bundled = { id = "bundled", title = "Bundled", category = "pvm", source_category = "Combat",
            difficulty = "Easy", difficulty_level = 2, intensity = "Low", income = { period = "hour" } }
        local browser = Browser.new({ bundled, custom }, Preferences.new(PersistentDB), function() end)

        local function shown()
            local values = {}

            for _, row in ipairs(browser:rows()) do
                values[#values + 1] = row.id
            end

            return table.concat(values, ",")
        end

        -- Browse shows both; Show: Custom only narrows to the player's own.
        equal(shown(), "bundled,custom.1")

        browser.origin = "custom"
        equal(shown(), "custom.1")

        -- Favourites take the Show filter too.
        browser.origin = "all"
        browser.section = "favourites"
        browser.favourites = { ["custom.1"] = true, bundled = true }
        equal(shown(), "bundled,custom.1")

        browser.origin = "custom"
        equal(shown(), "custom.1")

        local pool = Recommendations.pool({ bundled, custom }, "pvm", { comfort = 10, learning = false, group = "either" }, {
            readiness = { bundled = { status = "met" }, ["custom.1"] = { status = "met" } },
            estimates = {
                bundled = { status = "available", profit = 1 },
                ["custom.1"] = { status = "available", profit = 999 },
            },
            hidden = {},
        })

        equal(#pool, 1)
        equal(pool[1].method.id, "bundled")
    end)

    -- The sidebar section (slice 3) -------------------------------------------------

    -- Every text currently drawn in a fake view, as one string to search.
    local function screenText(view)
        local texts = {}

        for _, label in ipairs(view:allTexts()) do
            texts[#texts + 1] = tostring(label.content)
        end

        return table.concat(texts, " | ")
    end

    local function has(view, text)
        return screenText(view):find(text, 1, true) ~= nil
    end

    test("Browse: Show Custom only has an empty state, then lists saved activities", function()
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()

        -- No Custom activities section any more: Create activity instead.
        assert(not pcall(prettyui.findButton, prettyui, "Custom activities"), "no separate section")
        assert(prettyui:findButton("Create activity"))

        prettyui:chooseEntry("Custom only")
        local view = prettyui.views[#prettyui.views]

        assert(has(view, "No custom activities yet"), screenText(view))
        assert(not prettyui:findMethod("Smelting steel bars"), "Custom only hides bundled activities")

        -- The empty state offers the same Create activity.
        local createButtons = 0

        for _, candidate in ipairs(prettyui.allViews) do
            if not candidate.destroyed and candidate.buttons["Create activity"] then
                createButtons = createButtons + 1
            end
        end

        equal(createButtons, 2)
        PluginShutdown()

        -- A saved activity, read back at start-up like after a reload.
        client({
            [INDEX] = { schema = 1, next = 2, ids = { "custom.1" } },
            ["profit-path.custom.v1/custom.1"] = record({ notes = "Bank at the chest." }),
        })
        prettyui = pretty()

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()

        -- In Browse with everything else (searching finds it among 674)...
        local search

        for _, candidate in ipairs(prettyui.allViews) do
            for _, box in ipairs(not candidate.destroyed and candidate.fields or {}) do
                if box.placeholder == "Search activities" then
                    search = box
                end
            end
        end

        search:SetText("Fixture", true)
        search:Submit()
        assert(prettyui:findMethod("Fixture monster"), "custom activities show in Browse")

        -- ...and on its own with Show: Custom only, labelled as custom.
        search:SetText("", true)
        search:Submit()
        prettyui:chooseEntry("Custom only")
        view = prettyui.views[#prettyui.views]

        assert(prettyui:findMethod("Fixture monster"), screenText(view))
        assert(not prettyui:findMethod("Smelting steel bars"))
        assert(has(view, "Custom activity"))
        assert(not has(view, "No custom activities yet"))

        -- Show offers just All and Custom only.
        local offered = false

        for _, candidate in ipairs(prettyui.allViews) do
            for _, list in ipairs(not candidate.destroyed and candidate.nativeLists or {}) do
                if list.entries["Custom only"] then
                    offered = true
                    equal(list.entries.All, 0)
                    equal(list.entries["Custom only"], 1)
                    equal(list.entries["Bundled only"], nil)
                end
            end
        end

        assert(offered, "the Show dropdown is there")

        -- Its page says it's a custom activity (just that, no longer blurb).
        prettyui:findMethod("Fixture monster")()
        local page = prettyui.views[#prettyui.views].tabs[1].pages[1]
        assert(has(page, "Custom activity"), screenText(page))
        assert(not has(page, "come from you"), screenText(page))

        PluginShutdown()
    end)

    test("Browse shows a custom activity load warning but still opens", function()
        client({
            [INDEX] = { schema = 1, next = 3, ids = { "custom.1", "custom.2" } },
            ["profit-path.custom.v1/custom.1"] = record(),
            ["profit-path.custom.v1/custom.2"] = { schema = 1, id = "custom.2" },
        })
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:chooseEntry("Custom only")

        local view = prettyui.views[#prettyui.views]

        assert(has(view, "couldn't be read"), screenText(view))
        assert(prettyui:findMethod("Fixture monster"))

        PluginShutdown()
    end)
end
