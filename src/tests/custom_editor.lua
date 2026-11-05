-- The custom activity editor (Phase 9, slice 4): loading drops from a source,
-- the three row states, left-out drops, Duplicate as custom, the editor screen,
-- and how many native parts its pages use. Sources are the real bundled data
-- (data/monsters.lua, data/thieving.lua); prices are made-up fixtures.
return function(test, equal, client, pretty)
    local CustomMethods = require("src/methods/custom_methods")
    local Draft = require("src/methods/custom_draft")

    local INDEX = "profit-path.custom.v1/index"

    local function valid(draft)
        return CustomMethods.validate(Draft.withPlaceholderId(draft))
    end

    -- Drop states ------------------------------------------------------------------

    -- Real notes from the bundled data. Information keeps a drop counted;
    -- a restriction, or anything we don't recognise, switches it off.
    test("drop notes: luck and citations count, restrictions and unknowns don't", function()
        equal(Draft.isConditional(nil), false)
        equal(Draft.isConditional("Drop rate improved by 10% with tier 4 luck."), false)
        equal(Draft.isConditional("1/496 with tier 2 luck or higher."), false)
        equal(Draft.isConditional("The Wiki marks this rate as approximate."), false)
        equal(Draft.isConditional("Drop rate improved by 10% with tier 4 luck.\n\nJagex. Mod Sponge's Twitter account. "
            .. "12 Feb 2019 (Archived from the original on 3 April 2019)"), false)

        equal(Draft.isConditional("Only dropped if not already owned."), true)
        equal(Draft.isConditional("During October, the chance is 1/2. Only dropped if not already owned."), true)
        equal(Draft.isConditional("Only dropped if tier 4 luck is not active."), true)
        equal(Draft.isConditional("Requires completion of Azzanadra's Quest."), true)

        -- Not a restriction, but not recognised either: off, never a guess.
        equal(Draft.isConditional("Either obsidian charm or tokkul is dropped."), true)
    end)

    -- Seeding ----------------------------------------------------------------------

    test("a thieving target loads its loot, level and category", function()
        local draft = assert(Draft.fromSource("thieving", "Master Farmer"))

        equal(draft.title, "Thieving: Master Farmer")
        equal(draft.category, "skilling")
        equal(draft.rate.unit, "actions/hour")
        equal(draft.source.kind, "thieving")
        equal(draft.requirements.required[1].skill, "THIEVING")
        equal(draft.requirements.required[1].level, 38)
        equal(#draft.outputs, 29)
        equal(#Draft.missingSourceRows(draft), 0)

        -- Every row starts in one of the three states, and only counted rows
        -- are sure to have a quantity.
        local states = {}

        for _, row in ipairs(draft.outputs) do
            states[row.state] = (states[row.state] or 0) + 1

            if row.state == "included" then
                assert(row.quantity and row.quantity > 0, row.label)
            elseif row.state == "needs" then
                equal(row.quantity, nil)
            end
        end

        assert(states.included and states.included > 0, "some loot counts")

        -- Needs only a rate to price; the Thieving level satisfies the rule.
        equal(valid(draft), true)
    end)

    test("a monster loads its drops, but needs a Required check before saving", function()
        local draft = assert(Draft.fromSource("monster", "Abyssal demon"))

        equal(draft.title, "Killing Abyssal demon")
        equal(draft.category, "pvm")
        equal(draft.rate.unit, "kills/hour")
        equal(#draft.outputs, 36)
        equal(#draft.requirements.required, 0)

        -- Coins are a fixed 1 GP each, untaxed.
        local coins

        for _, row in ipairs(draft.outputs) do
            if row.label == "Coins" then
                coins = row
            end
        end

        assert(coins, "Abyssal demons drop coins")
        equal(coins.pricing, "fixed")
        equal(coins.unit_value, 1)

        local ok, problems = valid(draft)
        equal(ok, false)
        assert(problems[1]:find("at least one Required", 1, true), problems[1])

        draft.requirements.required[1] = { kind = "skill", skill = "SLAYER", level = 85 }
        equal(valid(draft), true)

        equal(Draft.fromSource("monster", "Not a real monster"), nil)
    end)

    test("a big source keeps the 40 most valuable drops and lists the rest", function()
        local all = Draft.sourceRows("monster", "Revenant goblin")
        assert(#all > 40, "fixture needs more than 40 drops")

        -- Make one late GE drop very valuable: it must be kept.
        local late

        for index = #all, 1, -1 do
            if all[index].pricing == "ge" and all[index].state == "included" then
                late = all[index]
                break
            end
        end

        local quotes = { [late.item_id] = { status = "available", low = 1e9, lowTime = 1, high = 1e9, highTime = 1 } }
        local draft = Draft.fromSource("monster", "Revenant goblin", quotes)
        local kept = false

        for _, row in ipairs(draft.outputs) do
            kept = kept or row.source_key == late.source_key
        end

        equal(#draft.outputs, CustomMethods.LIMITS.outputs)
        assert(kept, "the valuable drop is kept")

        local missing = Draft.missingSourceRows(draft)
        equal(#missing, #all - 40)

        local preview = Draft.preview(draft, quotes)
        equal(preview.leftOut.count, #all - 40)
        equal(preview.counts.outputs, 40)

        -- Removing a row puts it back in the missing list.
        table.remove(draft.outputs, 1)
        equal(#Draft.missingSourceRows(draft), #all - 39)
    end)

    test("source rows are fresh copies, so editing a draft never changes the data", function()
        local first = Draft.sourceRows("monster", "Abyssal demon")
        first[1].label = "Changed"

        equal(Draft.sourceRows("monster", "Abyssal demon")[1].label ~= "Changed", true)
    end)

    test("duplicate as custom copies a bundled activity's rows and requirements", function()
        local catalogue = require("src/data/method_data")
        local steel

        for _, method in ipairs(catalogue.methods) do
            if method.title == "Smelting steel bars" then
                steel = method
            end
        end

        local draft, skipped = Draft.fromMethod(steel)

        equal(draft.category, "production")
        equal(draft.rate.unit, "actions/hour")
        equal(draft.rate.default, steel.income.rate.default)
        equal(draft.outputs[1].item_id, 2353)
        equal(draft.outputs[1].state, "included")
        equal(#draft.supplies, #steel.income.inputs)
        equal(skipped.outputs, 0)
        equal(valid(draft), true)

        -- A daily or weekly activity can't be copied.
        equal(Draft.fromMethod({ category = "recurring" }), nil)
    end)

    test("duplicate as custom keeps items, either-or items and outfits as tracked checks", function()
        local item = function(itemId, text)
            return { kind = "item", itemId = itemId, quantity = 1, text = text }
        end

        local method = {
            title = "Croesus-like", category = "skilling",
            income = { rate = { default = 10 }, inputs = {}, outputs = {} },
            requirements = {
                access = { kind = "all", text = "Required", children = {
                    item(36953, "Fishing: Fishing rod-o-matic"),
                    { kind = "any", text = "Hunter: Magic butterfly net or Enhanced yaktwee stick", children = {
                        item(11259, "Magic butterfly net"), item(28084, "Enhanced yaktwee stick"),
                    } },
                    { kind = "capability", text = "Fungus soup" },
                } },
                recommended = { kind = "all", text = "Recommended", children = {
                    { kind = "all", text = "Fury shark outfit", children = {
                        item(34215, "Fury shark head"), item(34216, "Fury shark body"),
                    } },
                } },
            },
        }

        local draft = Draft.fromMethod(method)
        local required = draft.requirements.required

        equal(required[1].kind, "item")
        equal(required[1].item_id, 36953)
        equal(required[2].kind, "items")
        equal(required[2].mode, "any")
        equal(#required[2].items, 2)
        equal(required[3].kind, "note")
        equal(draft.requirements.recommended[1].kind, "items")
        equal(draft.requirements.recommended[1].mode, "all")

        -- Items count as Required checks the game can read, so it's valid as is.
        equal(valid(draft), true)

        -- And they become the same any/all item checks bundled activities use.
        local CustomMethods = require("src/methods/custom_methods")
        local record = Draft.copy(draft)
        record.id = "custom.1"
        local node = CustomMethods.toMethod(record).requirements.access.children[2]
        equal(node.kind, "any")
        equal(node.children[1].kind, "item")
        equal(node.children[2].itemId, 28084)
    end)

    test("the preview prices a valid draft and explains an invalid one", function()
        local draft = Draft.blank()

        local preview = Draft.preview(draft, {})
        equal(preview.result, nil)
        assert(#preview.problems > 0)

        draft.title = "Fixture"
        draft.category = "production"
        draft.no_requirements = true
        draft.rate.default = 10
        draft.outputs[1] = { label = "Bar", item_id = 2353, pricing = "ge", quantity = 1, basis = "action", state = "included" }

        preview = Draft.preview(draft, { [2353] = { status = "available", low = 50, lowTime = 80, high = 999, highTime = 100 } })
        equal(#preview.problems, 0)
        equal(preview.result.revenue, 490)
    end)

    -- The editor screen -------------------------------------------------------------

    -- Every live fake view, newest last.
    local function live()
        local views = {}

        for _, view in ipairs(prettyui.allViews) do
            if not view.destroyed then
                views[#views + 1] = view
            end
        end

        return views
    end

    -- A button anywhere on screen (tab pages included), by its label.
    local function button(label)
        for _, view in ipairs(live()) do
            if view.buttons[label] then
                return view.buttons[label]
            end

            for _, tabs in ipairs(view.tabs) do
                for _, page in ipairs(tabs.pages) do
                    local found = page:button(label)

                    if found then
                        return found
                    end
                end
            end
        end

        error("No button: " .. label)
    end

    -- Every text and every field on screen, tab pages included.
    local function everything()
        local texts, fields, seen = {}, {}, {}

        for _, view in ipairs(live()) do
            local surfaces = { view }

            for _, tabs in ipairs(view.tabs) do
                for _, page in ipairs(tabs.pages) do
                    surfaces[#surfaces + 1] = page
                end
            end

            for _, surface in ipairs(surfaces) do
                for _, label in ipairs(surface:allTexts()) do
                    texts[#texts + 1] = tostring(label.content)
                end

                -- A nested view or panel is also reached through its parent,
                -- so count each box once.
                for _, field in ipairs(surface:allFields()) do
                    if not seen[field] then
                        seen[field] = true
                        fields[#fields + 1] = field
                    end
                end
            end
        end

        return table.concat(texts, " | "), fields
    end

    local function shows(text)
        local texts = everything()
        return texts:find(text, 1, true) ~= nil
    end

    -- The first label on screen whose text contains `text` (to check its colour).
    local function label(text)
        for _, view in ipairs(live()) do
            for _, candidate in ipairs(view:allTexts()) do
                if tostring(candidate.content):find(text, 1, true) then
                    return candidate
                end
            end
        end
    end

    local function field(placeholderOrText)
        local _, fields = everything()

        for index = #fields, 1, -1 do
            if fields[index].placeholder == placeholderOrText or fields[index].text == placeholderOrText then
                return fields[index]
            end
        end
    end

    local function open(database)
        local state = client(database)
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findButton("Custom activities")()

        return state
    end

    test("editor: create from a thieving target, save, edit, then delete", function()
        local state = open()

        button("New activity")()
        button("A thieving target's loot")()

        -- The search waits for typing to stop; Enter skips the wait.
        local search = assert(field("Type part of the name"))
        search:SetText("master farmer")
        search:Submit()

        button("Master Farmer")()

        -- The editor opens on Outputs, with the Thieving level already Required.
        assert(shows("Ready to save."), (everything()))

        -- 29 drops is under the limit of 40, so no "x of y" count.
        assert(not shows("of 40"), (everything()))
        assert(not shows("list is full"), (everything()))

        -- The rows are a table, with headings saying what each column is.
        for _, heading in ipairs({ "Item", "Qty", "Per", "Price each", "Counted" }) do
            assert(shows(heading), heading)
        end

        button("Save")()

        -- Saved, and its page is open.
        local saved = state.db["profit-path.custom.v1/custom.1"]
        equal(saved.title, "Thieving: Master Farmer")
        equal(saved.requirements.required[1].skill, "THIEVING")
        assert(shows("Custom activity"), (everything()))

        -- Edit: rename it on the Details tab, then save.
        button("Edit this custom activity")()

        local editor = prettyui.views[#prettyui.views]
        editor.tabs[1]:SetActive(1)

        local name = assert(field("Thieving: Master Farmer"))
        name:SetText("Master Farmer at Draynor", true)
        button("Save")()

        equal(state.db["profit-path.custom.v1/custom.1"].title, "Master Farmer at Draynor")
        equal(#state.db[INDEX].ids, 1)

        -- Delete takes two clicks.
        button("Edit this custom activity")()
        button("Delete")()
        assert(state.db["profit-path.custom.v1/custom.1"], "one click doesn't delete")

        button("Click again to delete")()
        equal(state.db["profit-path.custom.v1/custom.1"], nil)
        assert(shows("No custom activities yet"))

        PluginShutdown()
    end)

    test("editor: a blank activity says why it can't be saved yet", function()
        local state = open()

        button("New activity")()

        -- The start screen leads with the kind of activity, every kind included.
        for _, kind in ipairs({ "PvM", "Skilling", "Production", "Daily / weekly" }) do
            assert(button(kind), kind)
        end

        button("Production")()

        -- Nothing typed yet, so no complaints until Save is pressed...
        assert(not shows("Can't save yet"), (everything()))
        local Style = require("src/ui/view_style")

        -- ...then it says why, blinks, and ends up red.
        button("Save")()
        equal(state.db[INDEX], nil)
        assert(shows("Can't save yet: The name must be"), (everything()))
        equal(label("Can't save yet").rgba, 0xFF6655FF)

        for _ = 1, 30 do
            Event.Logic.emit({})
        end

        equal(label("Can't save yet").rgba, Style.bad)

        -- Fill it in: a name, production with no requirements, and a fixed output.
        local editor = prettyui.views[#prettyui.views]

        field("e.g. Killing ghouls with a cannon"):SetText("Selling flax", true)

        editor.tabs[1]:SetActive(4)
        button("No requirements needed")()

        editor = prettyui.views[#prettyui.views]
        editor.tabs[1]:SetActive(2)
        button("Custom item")()

        assert(shows("Ready to save."), (everything()))
        button("Save")()

        equal(state.db["profit-path.custom.v1/custom.1"].title, "Selling flax")
        equal(state.db["profit-path.custom.v1/custom.1"].no_requirements, true)

        PluginShutdown()
    end)

    test("editor: a daily/weekly activity counts per run", function()
        local state = open()

        button("New activity")()
        button("Daily / weekly")()

        field("e.g. Killing ghouls with a cannon"):SetText("Weekly herb run", true)
        button("Every week")()

        local editor = prettyui.views[#prettyui.views]
        editor.tabs[1]:SetActive(4)
        button("No requirements needed")()

        editor = prettyui.views[#prettyui.views]
        editor.tabs[1]:SetActive(2)
        button("Custom item")()

        -- Rows have no per kill/trip/hour choice: everything is per run.
        assert(shows("Per run"), (everything()))
        assert(shows("Profit per run (after tax)"), (everything()))

        button("Save")()

        local saved = state.db["profit-path.custom.v1/custom.1"]
        equal(saved.category, "recurring")
        equal(saved.rate.unit, "runs")
        equal(saved.recurrence.every, "week")
        equal(saved.outputs[1].basis, "action")

        PluginShutdown()
    end)

    test("bundled pages offer Duplicate as custom as an icon at the bottom", function()
        open()

        prettyui:findButton("Browse")()
        prettyui:findMethod("Smelting steel bars")()

        -- An icon button, found by its tooltip.
        button("Duplicate as custom for editing")()
        assert(shows("New custom activity"), (everything()))
        assert(shows("Ready to save."), (everything()))

        PluginShutdown()
    end)

    test("editor: rows switch on and off, change basis, and get a number", function()
        local state = open()

        button("New activity")()
        button("A monster's drops")()

        local search = field("Type part of the name")
        search:SetText("Abyssal demon")
        search:Submit()
        button("Abyssal demon")()

        -- PvM needs a Required check first (Save says so).
        assert(not shows("at least one Required"), "quiet until Save is pressed")
        button("Save")()
        assert(shows("at least one Required"), (everything()))

        prettyui.views[#prettyui.views].tabs[1]:SetActive(4)

        -- Every skill is an icon (found here by its tooltip, the skill's name).
        -- Picking one lights it without redrawing the tab.
        assert(button("Agility") and button("Slayer"))
        local before = prettyui.counted.parts
        button("Slayer")()
        equal(prettyui.counted.parts, before, "no redraw")
        assert(shows("Slayer"), (everything()))

        -- The level box stops at 120.
        local level = field("Level")
        level:SetText("150", true)
        equal(level.text, "120")
        level:SetText("85")

        button("Add level")()
        assert(shows("85 Slayer"), (everything()))

        prettyui.views[#prettyui.views].tabs[1]:SetActive(2)

        -- A row's basis cycles kill -> trip -> hour; a trip row needs
        -- kills per trip.
        button("Per kill")()
        assert(shows("need a number of kills/actions per trip"), (everything()))
        button("Per trip")()
        assert(not shows("need a number of kills/actions per trip"))

        button("Save")()

        local saved = state.db["profit-path.custom.v1/custom.1"]
        -- (The rows share one table now; the fake finds the last "Per kill" button, row 8.)
        equal(saved.outputs[8].basis, "hour")
        equal(saved.requirements.required[1].level, 85)

        PluginShutdown()
    end)

    test("editor: item search waits for typing to stop and lists the best match first", function()
        local state = open()

        button("New activity")()
        button("Production")()
        field("e.g. Killing ghouls with a cannon"):SetText("Prayer potions", true)

        local editor = prettyui.views[#prettyui.views]
        editor.tabs[1]:SetActive(4)
        button("No requirements needed")()

        prettyui.views[#prettyui.views].tabs[1]:SetActive(2)

        -- The add form comes first, and nothing is searched mid-word.
        local search = field("Search the Grand Exchange")
        search:SetText("prayer potion", true)
        assert(not pcall(button, "Prayer potion (1)"), "no results while still typing")

        settleSearch()

        -- Names that start with the words come before ones that only contain them.
        button("Prayer potion (1)")()
        assert(not pcall(button, "Perfect juju prayer potion (1)"), "only the top 5 are listed")

        -- Picked: it's a table row now, with its own remove button.
        assert(shows("Prayer potion (1)"), (everything()))
        assert(button("Remove Prayer potion (1)"))

        button("Save")()
        equal(state.db["profit-path.custom.v1/custom.1"].outputs[1].item_id ~= nil, true)

        PluginShutdown()
    end)

    test("editor: steps are a numbered list, and items can be requirements", function()
        local state = open()

        button("New activity")()
        button("Skilling")()
        field("e.g. Killing ghouls with a cannon"):SetText("Cleaning herbs", true)

        -- Steps live on How to do it, like the activity page. Two, then remove the first.
        prettyui.views[#prettyui.views].tabs[1]:SetActive(5)
        button("Add step")()
        button("Add step")()

        local _, fields = everything()
        local steps = {}

        for _, candidate in ipairs(fields) do
            if candidate.placeholder and candidate.placeholder:find("Wars Retreat", 1, true) then
                steps[#steps + 1] = candidate
            end
        end

        equal(#steps, 2)
        steps[1]:SetText("Withdraw grimy herbs", true)
        steps[2]:SetText("Clean them all", true)
        assert(shows("1.") and shows("2."))

        button("Remove step 1")()

        -- An item requirement: how many, then pick the item.
        prettyui.views[#prettyui.views].tabs[1]:SetActive(4)
        field("How many"):SetText("2")
        field("Search for an item"):SetText("prayer potion (4)", true)
        settleSearch()
        button("Prayer potion (4)")()

        assert(shows("2 x Prayer potion (4)"), (everything()))
        assert(shows("Required"))

        button("Save")()

        local saved = state.db["profit-path.custom.v1/custom.1"]
        equal(#saved.notes, 1)
        equal(saved.notes[1], "Clean them all")
        equal(saved.requirements.required[1].kind, "item")
        equal(saved.requirements.required[1].quantity, 2)

        -- The activity's How to do it tab lists the step.
        settleMethod()
        assert(shows("Clean them all"), (everything()))

        PluginShutdown()
    end)

    test("editor: an older save's single note opens as step 1", function()
        local record = {
            schema = 1, id = "custom.1", title = "Old one", category = "production", no_requirements = true,
            rate = { unit = "actions/hour", default = 10 }, notes = "Bank at the chest.",
            outputs = { { label = "Other loot", pricing = "fixed", unit_value = 5, quantity = 1, basis = "action", state = "included" } },
            supplies = {}, requirements = { required = {}, recommended = {} },
        }

        open({ [INDEX] = { schema = 1, next = 2, ids = { "custom.1" } }, ["profit-path.custom.v1/custom.1"] = record })
        prettyui:findMethod("Old one")()
        button("Edit this custom activity")()
        prettyui.views[#prettyui.views].tabs[1]:SetActive(5)

        assert(field("Bank at the chest."), (everything()))
        assert(button("Remove step 1"))

        PluginShutdown()
    end)

    test("Duplicate as custom brings the activity's steps along", function()
        open()

        prettyui:findButton("Browse")()
        prettyui:findMethod("Smelting steel bars")()
        button("Duplicate as custom for editing")()

        prettyui.views[#prettyui.views].tabs[1]:SetActive(5)
        assert(button("Remove step 1"), (everything()))

        PluginShutdown()
    end)

    test("editor: number boxes take numbers only, and a quantity can be a 1/50 rate", function()
        local state = open()

        button("New activity")()
        button("Production")()
        field("e.g. Killing ghouls with a cannon"):SetText("Rates", true)

        -- Letters are taken straight back out of the rate box.
        local rate = field("Rate")
        rate:SetText("12a0", true)
        equal(rate.text, "120")

        prettyui.views[#prettyui.views].tabs[1]:SetActive(4)
        button("No requirements needed")()
        prettyui.views[#prettyui.views].tabs[1]:SetActive(2)
        button("Custom item")()

        -- A custom item's name and GP value can be typed; a big value stays a
        -- plain number (not 1.23457e+06) when the table is drawn again.
        field("Other loot"):SetText("Clue scroll", true)
        field("GP each"):SetText("1234567", true)

        local quantity = field("1")
        quantity:SetText("1/50", true)
        equal(quantity.text, "1/50")

        button("Save")()

        local saved = state.db["profit-path.custom.v1/custom.1"]
        equal(saved.rate.default, 120)
        equal(saved.outputs[1].label, "Clue scroll")
        equal(saved.outputs[1].quantity, 0.02)
        equal(saved.outputs[1].custom, true)

        button("Edit this custom activity")()
        prettyui.views[#prettyui.views].tabs[1]:SetActive(2)
        assert(field("1234567"), (everything()))
        assert(field("1/50"), (everything()))

        PluginShutdown()
    end)

    test("editor: copied rows keep their name, and a GE price can be your own", function()
        local state = open()

        prettyui:findButton("Browse")()
        prettyui:findMethod("Smelting steel bars")()
        button("Duplicate as custom for editing")()
        prettyui.views[#prettyui.views].tabs[1]:SetActive(2)

        -- The steel bar row is a GE item: its name is text, not a box.
        assert(shows("Steel bar"), (everything()))
        assert(not field("Steel bar"), "the name can't be edited")

        -- Its price box starts at the live price (none in tests, so it's empty
        -- and says so). Typing a price uses it instead.
        local price = assert(field("No price"), (everything()))
        price:SetText("500", true)

        button("Save")()

        local saved = state.db["profit-path.custom.v1/custom.1"]
        equal(saved.outputs[1].price, 500)

        -- Clearing it goes back to the live price.
        button("Edit this custom activity")()
        prettyui.views[#prettyui.views].tabs[1]:SetActive(2)
        field("500"):SetText("", true)
        button("Save")()
        equal(state.db["profit-path.custom.v1/custom.1"].outputs[1].price, nil)

        PluginShutdown()
    end)

    test("two custom copies with the same title each open on their own", function()
        local state = open()

        -- Duplicate the same bundled activity twice and save both, unchanged.
        for copy = 1, 2 do
            if copy == 2 then
                button("Back to activities")()
            end

            prettyui:findButton("Browse")()
            prettyui:findMethod("Smelting steel bars")()
            button("Duplicate as custom for editing")()
            button("Save")()
        end

        equal(state.db["profit-path.custom.v1/custom.2"].title, "Smelting steel bars")

        -- The second one's page opened: no version picker mixing the copies
        -- (custom activities have no version label to show).
        assert(button("Edit this custom activity"), (everything()))
        equal(prettyui.views[#prettyui.views].nativeLists, nil)

        PluginShutdown()
    end)

    test("editor: Income notes and Getting there are tabs like the activity page's", function()
        local state = open()

        button("New activity")()
        button("Production")()
        field("e.g. Killing ghouls with a cannon"):SetText("Noted", true)

        -- Same tabs as the activity page, with Outputs and Supplies split out.
        local tabs = prettyui.views[#prettyui.views].tabs[1]
        local names = {}

        for index, entry in ipairs(tabs.entries) do
            names[index] = entry.text
        end

        equal(table.concat(names, ","), "Income,Outputs,Supplies,Requirements,How to do it,Getting there")

        button("Add note")()
        field("e.g. Assumes a full inventory of food each trip"):SetText("Buy flax in bulk", true)

        prettyui.views[#prettyui.views].tabs[1]:SetActive(6)
        button("Add direction")()
        field("e.g. Fairy ring code CKS, then run north-east"):SetText("Teleport to Lumbridge", true)

        prettyui.views[#prettyui.views].tabs[1]:SetActive(4)
        button("No requirements needed")()
        prettyui.views[#prettyui.views].tabs[1]:SetActive(2)
        button("Custom item")()

        button("Save")()

        local saved = state.db["profit-path.custom.v1/custom.1"]
        equal(saved.income_notes[1], "Buy flax in bulk")
        equal(saved.getting_there[1], "Teleport to Lumbridge")
        assert(shows("Buy flax in bulk"), (everything()))

        settleMethod()
        assert(shows("1. Teleport to Lumbridge"), (everything()))

        PluginShutdown()
    end)

    test("editor: a thieving target only counts actions per hour", function()
        open()

        button("New activity")()
        button("A thieving target's loot")()
        local search = assert(field("Type part of the name"))
        search:SetText("master farmer")
        search:Submit()
        button("Master Farmer")()
        prettyui.views[#prettyui.views].tabs[1]:SetActive(1)

        assert(button("Actions per hour"), (everything()))
        assert(not pcall(button, "Kills per hour"), "no kills for thieving")

        -- Even as PvM it stays actions.
        button("PvM")()
        assert(not pcall(button, "Kills per hour"))

        PluginShutdown()
    end)

    test("editor: switching between PvM, Skilling and Production redraws nothing", function()
        open()

        button("New activity")()
        button("PvM")()

        local before = prettyui.counted.parts
        button("Skilling")()
        equal(prettyui.counted.parts, before, "no redraw")

        -- Daily/weekly has different boxes, so that one does redraw.
        button("Daily / weekly")()
        assert(prettyui.counted.parts > before)
        assert(shows("How often"), (everything()))

        PluginShutdown()
    end)

    test("editor: a click keeps the tab scrolled where it was", function()
        open()

        button("New activity")()
        button("Production")()
        prettyui.views[#prettyui.views].tabs[1]:SetActive(4)

        -- Scroll the Requirements tab down, then click something that redraws.
        local function body()
            local page = prettyui.views[#prettyui.views].tabs[1].pages[4]
            return page.children[#page.children]
        end

        body().scrollY = 240
        button("Recommended")()
        equal(body().scrollY, 240)

        PluginShutdown()
    end)

    test("loading a source keeps item pictures for coins and untradeable drops", function()
        local draft = Draft.fromSource("monster", "Abyssal demon", {})
        local coins

        for _, row in ipairs(draft.outputs) do
            if row.label == "Coins" then
                coins = row
            end
        end

        equal(coins.pricing, "fixed")
        equal(coins.item_id, 995)

        -- On the activity page it's a fixed value with the coins picture.
        local CustomMethods = require("src/methods/custom_methods")
        local record = Draft.copy(draft)
        record.id = "custom.1"

        for _, line in ipairs(CustomMethods.toMethod(record).income.outputs) do
            if line.name == "Coins" then
                equal(line.display_item_id, 995)
                equal(line.item_id, nil)
            end
        end
    end)

    test("the activity page deletes a custom activity with two clicks", function()
        local state = open()

        button("New activity")()
        button("Production")()
        field("e.g. Killing ghouls with a cannon"):SetText("Short lived", true)
        prettyui.views[#prettyui.views].tabs[1]:SetActive(4)
        button("No requirements needed")()
        prettyui.views[#prettyui.views].tabs[1]:SetActive(2)
        button("Custom item")()
        button("Save")()
        assert(state.db["profit-path.custom.v1/custom.1"])

        -- One click only asks.
        button("Delete this custom activity")()
        assert(state.db["profit-path.custom.v1/custom.1"], "one click doesn't delete")
        assert(shows("Click the bin again"), (everything()))

        button("Delete this custom activity")()
        equal(state.db["profit-path.custom.v1/custom.1"], nil)
        assert(shows("No custom activities yet"), (everything()))

        PluginShutdown()
    end)

    test("a custom activity's item requirement is read from the game", function()
        local found = require("src/data/item_names").search("prayer potion (4)", 1)[1]
        assert(not require("src/data/method_data").items[tostring(found.id)], "pick an item outside the catalogue")

        local record = {
            schema = 1, id = "custom.1", title = "Needs a potion", category = "production",
            rate = { unit = "actions/hour", default = 10 },
            outputs = { { label = "Other loot", pricing = "fixed", unit_value = 5, quantity = 1, basis = "action", state = "included" } },
            supplies = {},
            requirements = { required = { { kind = "item", item_id = found.id, name = found.label, quantity = 1 } }, recommended = {} },
        }

        -- Like open(), but the game is set up before the plugin starts.
        client({ [INDEX] = { schema = 1, next = 2, ids = { "custom.1" } }, ["profit-path.custom.v1/custom.1"] = record })
        prettyui = pretty()
        gepl = nil

        -- The game knows the item by that name, and there's one in the backpack.
        local lookup = config.Obj.FromID
        config.Obj.FromID = function(itemId)
            return itemId == found.id and { id = itemId, name = found.label } or lookup(itemId)
        end

        Inventory.Find = function(definition)
            return { isValid = true, GetTotal = function(_, itemId)
                return definition.configName == "INV" and itemId == found.id and 1 or 0
            end }
        end

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findButton("Custom activities")()

        prettyui:findMethod("Needs a potion")()
        settleMethod()

        -- It's drawn as the item's picture, like bundled activities' items, and
        -- its border is green because there's one in the backpack.
        local Style = require("src/ui/view_style")
        local slot, border

        for _, view in ipairs(prettyui.allViews) do
            for index, item in ipairs(view.items or {}) do
                if item.object and item.object.id == found.id then
                    slot, border = item, view.rectangles and view.rectangles[index]
                end
            end
        end

        assert(slot, (everything()))
        equal(slot.tooltip, found.label)
        equal(border.rgba, Style.good)

        PluginShutdown()
    end)

    -- Native parts --------------------------------------------------------------------

    -- A custom record with `outputs` outputs and `supplies` supplies, all priced
    -- GE rows, so each one gets the activity page's item icon (and its tooltip).
    local function sized(outputs, supplies)
        local record = {
            schema = 1, id = "custom.1", title = "Sized", category = "production", no_requirements = true,
            rate = { unit = "actions/hour", default = 10 },
            outputs = {}, supplies = {}, requirements = { required = {}, recommended = {} },
        }

        for index = 1, outputs do
            record.outputs[index] = { label = "Out " .. index, item_id = 2353, pricing = "ge", quantity = 1,
                basis = "action", state = "included" }
        end

        for index = 1, supplies do
            record.supplies[index] = { label = "In " .. index, item_id = 440, pricing = "ge", quantity = 1, basis = "action" }
        end

        return record
    end

    -- Opens the record's activity page, lets its staged drawing finish, and
    -- returns how many parts and tooltips the page added.
    local function measurePage(record)
        open({ [INDEX] = { schema = 1, next = 2, ids = { "custom.1" } }, ["profit-path.custom.v1/custom.1"] = record })

        local before = { parts = prettyui.counted.parts, tooltips = prettyui.counted.tooltips }
        prettyui:findMethod("Sized")()

        for _ = 1, 200 do
            Event.Logic.emit({})
        end

        local used = { parts = prettyui.counted.parts - before.parts, tooltips = prettyui.counted.tooltips - before.tooltips }
        PluginShutdown()

        return used
    end

    test("native parts: a custom activity at the limits stays well under Mega Shop Run", function()
        local atLimits = measurePage(sized(CustomMethods.LIMITS.outputs, CustomMethods.LIMITS.supplies))

        -- Mega Shop Run had 51 shop items bought and sold per version. Rebuild a
        -- page that size (it's over our limits, so lift them just for this).
        local saved = { outputs = CustomMethods.LIMITS.outputs, supplies = CustomMethods.LIMITS.supplies }
        CustomMethods.LIMITS.outputs, CustomMethods.LIMITS.supplies = 51, 51

        local ok, mega = pcall(measurePage, sized(51, 51))

        CustomMethods.LIMITS.outputs, CustomMethods.LIMITS.supplies = saved.outputs, saved.supplies
        assert(ok, mega)

        print(string.format("[native parts] custom activity page at the limits: %d parts, %d tooltips; "
            .. "Mega Shop Run-sized page: %d parts, %d tooltips", atLimits.parts, atLimits.tooltips, mega.parts, mega.tooltips))

        -- Mega Shop Run's page ran out of IDs at about 112 tooltips (0.8.x, in
        -- game). A custom page at the limits must stay under 60% of that, even
        -- here, where no prices load and every price is missing.
        -- (The Mega-sized fixture is drawn as a custom page too, so it's lighter
        -- than the real bundled page was; it's here as a second yardstick.)
        assert(atLimits.tooltips <= 67, "custom pages at the limits stay under 60% of Mega Shop Run's tooltips")
        assert(atLimits.tooltips * 100 <= mega.tooltips * 60, "and under 60% of a Mega-sized custom page")
    end)

    test("native parts: the editor's busiest tab draws one page of rows", function()
        local state = open()

        button("New activity")()
        button("A monster's drops")()

        local search = field("Type part of the name")
        search:SetText("Revenant goblin")
        search:Submit()

        local parts, before = prettyui.counted.parts, prettyui.counted.tooltips
        button("Revenant goblin")()

        local used = prettyui.counted.parts - parts
        print(string.format("[native parts] editor Outputs tab with 40 rows (8 drawn): %d parts", used))

        -- Back, the Price each heading, and per drawn row its icon, its remove
        -- button and (drops with a note) its On/Off button.
        assert(prettyui.counted.tooltips - before <= 3 * 8 + 2, "editor tooltips: "
            .. (prettyui.counted.tooltips - before))

        -- 40 drops is the limit, so the add form says the list is full.
        assert(shows("This list is full (40 rows)"), (everything()))
        assert(used < 200, "the editor draws one page of rows, not all 40")
        assert(state)

        PluginShutdown()
    end)
end
