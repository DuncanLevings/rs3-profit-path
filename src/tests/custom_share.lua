-- Sharing custom activities: the share line's writer and
-- reader, what's left out, every way a paste gets refused, and the Export and
-- Import screens end to end.
return function(test, equal, client, pretty)
    local CustomMethods = require("src/methods/custom_methods")
    local CustomShare = require("src/methods/custom_share")

    local INDEX = "profit-path.custom.v1/index"

    -- A record using every kind of field and requirement, with awkward text: an
    -- apostrophe, a tilde, an accent, symbols and a rate written as a fraction.
    local function full()
        return {
            schema = 1,
            id = "custom.7",
            title = "Caf\195\169 run: Bob's ~best~ \"route\" {50%}",
            category = "pvm",
            difficulty_level = 6,
            notes = { "Step one, bank at the chest.", "Step two: kill; loot; repeat." },
            income_notes = { "Rates from 2 hours of kills." },
            getting_there = { "Teleport to the lodestone." },
            rate = { unit = "kills/hour", default = 42.5 },
            actions_per_trip = 25,
            source = { kind = "monster", title = "Abyssal demon" },
            outputs = {
                { label = "Abyssal whip", item_id = 4151, pricing = "ge", quantity = 1 / 512, basis = "action",
                    state = "included", source_key = "2:14", note = "Rolled on the main table." },
                { label = "My clue guess", pricing = "fixed", unit_value = 150000, quantity = 1, basis = "hour",
                    custom = true },
                { label = "Charm", pricing = "fixed", item_id = 12158, basis = "action", state = "needs" },
                { label = "Steel bar", item_id = 2353, pricing = "ge", quantity = 3, basis = "trip", state = "off",
                    price = 999 },
            },
            supplies = {
                { label = "Shark", item_id = 385, pricing = "ge", quantity = 8, basis = "trip", price = 1234 },
            },
            requirements = {
                required = {
                    { kind = "skill", skill = "SLAYER", level = 85 },
                    { kind = "combat_level", level = 100 },
                    { kind = "unlock", unlock = "soul-split", name = "Soul Split" },
                    { kind = "item", item_id = 4151, name = "Abyssal whip", quantity = 1 },
                },
                recommended = {
                    { kind = "quest", quest = "COOKS_ASSISTANT", name = "Cook's Assistant" },
                    { kind = "items", mode = "any", name = "Food", items = {
                        { item_id = 385, name = "Shark", quantity = 10 },
                        { item_id = 7946, name = "Monkfish", quantity = 10 },
                    } },
                    { kind = "note", text = "Bring a ring of wealth ~ if you have one." },
                },
            },
        }
    end

    -- Deep comparison of plain tables.
    local function same(a, b, where)
        where = where or "record"

        if type(a) ~= "table" or type(b) ~= "table" then
            assert(a == b, where .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
            return
        end

        for key, value in pairs(b) do
            same(a[key], value, where .. "." .. tostring(key))
        end

        for key in pairs(a) do
            assert(b[key] ~= nil, where .. "." .. tostring(key) .. " should not be there")
        end
    end

    -- The same FNV-1a checksum the writer uses, so tests can make lines that
    -- pass the checksum but are wrong in other ways.
    local function signed(body)
        local hash = 2166136261
        local line = "PP1:" .. body

        for index = 1, #line do
            hash = ((hash ~ line:byte(index)) * 16777619) & 0xffffffff
        end

        return line .. "*" .. string.format("%08x", hash)
    end

    local function refused(line, text)
        local record, problem = CustomShare.decode(line)
        equal(record, nil)
        assert(tostring(problem):find(text, 1, true), "expected '" .. text .. "', got: " .. tostring(problem))
    end

    -- The line itself -------------------------------------------------------------

    test("share: an activity survives the trip, minus the private parts", function()
        local record = full()
        local line, problem, length = CustomShare.encode(record)
        assert(line, problem)
        equal(length, #line)

        -- One line of printable ASCII, so it survives the text box (a line
        -- break cuts the text there).
        assert(not line:find("[^ -~]"), "only printable ASCII")
        assert(line:sub(1, 4) == "PP1:", line)

        -- Read back, it's the same activity, except: no ID (it gets a new one
        -- when it's added) and no player's own GE prices.
        local back = assert(CustomShare.decode(line))
        local expected = full()
        expected.id = nil
        expected.outputs[4].price = nil
        expected.supplies[1].price = nil
        same(back, expected)

        -- The fraction is the exact same number, not a rounded one.
        equal(back.outputs[1].quantity, 1 / 512)
        equal(back.rate.default, 42.5)

        -- And it passes the same checks a save does.
        local review = CustomShare.review(line)
        equal(#review.problems, 0)
        equal(#review.warnings, 0)
    end)

    test("share: GE item names are left out of the line and put back from the list", function()
        local ItemNames = require("src/data/item_names")
        local record = full()

        -- The fixture's names are the GE list's own, except one renamed row.
        equal(ItemNames.label(4151), "Abyssal whip")
        equal(ItemNames.label(385), "Shark")
        record.supplies[1].label = "Sharks for the trip"

        local line = assert(CustomShare.encode(record))

        -- Listed names aren't in the line; the renamed row and the fixed-value
        -- rows (the player's own names) are.
        assert(not line:find("Abyssal whip", 1, true), "row and requirement names come from the list")
        assert(not line:find("'Monkfish'", 1, true), "group item names too")
        assert(line:find("Sharks for the trip", 1, true), "a renamed GE row keeps its name")
        assert(line:find("My clue guess", 1, true), "a fixed-value row keeps its name")

        -- Read back, every name is there again.
        local back = assert(CustomShare.decode(line))
        equal(back.outputs[1].label, "Abyssal whip")
        equal(back.requirements.required[4].name, "Abyssal whip")
        equal(back.requirements.recommended[2].items[2].name, "Monkfish")
        equal(back.supplies[1].label, "Sharks for the trip")

        -- Leaving them out never touches the saved record itself.
        equal(record.outputs[1].label, "Abyssal whip")
    end)

    test("share: an item the reader's GE list lacks still imports, named by its ID", function()
        local ItemNames = require("src/data/item_names")
        local record = full()
        record.requirements.required[4] = { kind = "item", item_id = 999999999, name = "Future item", quantity = 1 }
        record.outputs[1].item_id, record.outputs[1].label = 999999998, "Future drop"

        -- Written by a Profit Path whose list has them (so their names are left
        -- out), read by one whose list doesn't.
        local label = ItemNames.label
        ItemNames.label = function(id)
            return ({ [999999999] = "Future item", [999999998] = "Future drop" })[id] or label(id)
        end

        local line = assert(CustomShare.encode(record))
        ItemNames.label = label
        assert(not line:find("Future", 1, true), line)

        local review = CustomShare.review(line)
        equal(#review.problems, 0)
        equal(review.record.requirements.required[4].name, "Item 999999999")
        equal(review.record.outputs[1].label, "Item 999999998")

        -- One warning for the row (its price may not load), one for the requirement.
        equal(#review.warnings, 2)
        assert(review.warnings[1]:find("Item 999999998", 1, true), review.warnings[1])
        assert(review.warnings[2]:find("came without a name", 1, true), review.warnings[2])
    end)

    test("share: the same activity always gives the same line", function()
        equal(CustomShare.encode(full()), CustomShare.encode(full()))
    end)

    test("share: a custom activity at the size limits fits the text box", function()
        local record = full()
        local limits = CustomMethods.LIMITS

        -- Every row and requirement used, with ordinary-length names.
        for index = #record.outputs + 1, limits.outputs do
            record.outputs[index] = { label = "Uncut gem number " .. index, item_id = 1623, pricing = "ge",
                quantity = 0.25, basis = "action", state = "included", source_key = "1:" .. index }
        end

        for index = #record.supplies + 1, limits.supplies do
            record.supplies[index] = { label = "Prayer potion (4)", item_id = 2434, pricing = "ge", quantity = 2, basis = "trip" }
        end

        local line, problem = CustomShare.encode(record)
        assert(line, problem)
        print("[share] a 40-output, 15-supply activity is " .. #line .. " characters")
        equal(#CustomShare.review(line).problems, 0)
    end)

    test("share: an activity too big for the text box says so instead", function()
        local record = full()

        -- Every text at its longest is more than the box holds.
        for index = 1, CustomMethods.LIMITS.outputs do
            record.outputs[index] = { label = string.rep("x", CustomMethods.LIMITS.label), item_id = 1623,
                pricing = "ge", quantity = 1, basis = "action", note = string.rep("n", CustomMethods.LIMITS.requirementNote) }
        end

        local line, problem, length = CustomShare.encode(record)
        equal(line, nil)
        assert(length > CustomShare.MAX_LENGTH)
        assert(problem:find("too big to share", 1, true), problem)
    end)

    -- Refusals --------------------------------------------------------------------

    test("share: a damaged, cut-off or foreign line is refused", function()
        local line = assert(CustomShare.encode(full()))

        refused("", "Paste a shared activity first")
        refused("hello there", "isn't a shared Profit Path activity")
        refused("PP2:{t'x'}*00000000", "newer version of Profit Path")

        -- Cut off (the end with the checksum is gone).
        refused(line:sub(1, 200), "incomplete")

        -- One character changed in the middle.
        local changed = line:sub(1, 30) .. (line:sub(31, 31) == "a" and "b" or "a") .. line:sub(32)
        refused(changed, "changed or cut off")

        -- Longer than the text box can hold: it may have been cut at the limit.
        refused("PP1:" .. string.rep("x", CustomShare.MAX_LENGTH), "too long")

        -- Spaces and line breaks around it (from a chat app) are fine.
        assert(CustomShare.decode("  \n" .. line .. " \r\n"))
    end)

    test("share: a line with the right checksum but the wrong shape is refused", function()
        -- A field nobody knows (or from a newer version).
        refused(signed("{t'x',zz1}"), "doesn't know")

        -- The same field twice.
        refused(signed("{t'x',t'y'}"), "same field twice")

        -- A list where a map belongs, and a map where a list belongs.
        refused(signed("{r['a']}"), "damaged")
        refused(signed("{o{l'x'}}"), "damaged")

        -- Numbers the game can't use, and bad text escapes.
        refused(signed("{ap1e999}"), "number")
        refused(signed("{t'a~zz'}"), "bad escape")
        refused(signed("{t'a\tb'}"), "unexpected character")

        -- Something left over after the end.
        refused(signed("{t'x'}{t'y'}"), "extra after the end")

        -- Nested deeper than any real field.
        refused(signed("{rq{rr[{it[{it[{it[{}]}]}]}]}}"), "nested too deeply")
    end)

    test("share: a well-formed line that breaks the activity rules is refused with reasons", function()
        local record = full()
        record.title = ""
        record.requirements.required = {}

        -- The writer doesn't judge (it only writes saved records), so build it.
        local line = assert(CustomShare.encode(record))
        local review = CustomShare.review(line)

        equal(review.record ~= nil, true)
        assert(#review.problems >= 2, "every problem is listed")
        assert(review.problems[1]:find("name", 1, true), review.problems[1])
    end)

    test("share: unknown GE items and quests import, with a warning", function()
        local record = full()
        record.outputs[1].item_id = 999999999
        record.requirements.recommended[1].quest = "NOT_A_QUEST"

        local review = CustomShare.review((CustomShare.encode(record)))
        equal(#review.problems, 0)
        equal(#review.warnings, 2)
        assert(review.warnings[1]:find("isn't in Profit Path's GE list", 1, true), review.warnings[1])
        assert(review.warnings[2]:find("Cook's Assistant", 1, true), review.warnings[2])
    end)

    -- The screens -----------------------------------------------------------------

    local function live()
        local views = {}

        for _, view in ipairs(prettyui.allViews) do
            if not view.destroyed then
                views[#views + 1] = view
            end
        end

        return views
    end

    local function button(label)
        for _, view in ipairs(live()) do
            if view.buttons[label] then
                return view.buttons[label]
            end
        end

        error("No button: " .. label)
    end

    local function texts()
        local all = {}

        for _, view in ipairs(live()) do
            for _, label in ipairs(view:allTexts()) do
                all[#all + 1] = tostring(label.content)
            end
        end

        return table.concat(all, " | ")
    end

    local function shows(text)
        return texts():find(text, 1, true) ~= nil
    end

    local function fields()
        local all = {}

        for _, view in ipairs(live()) do
            for _, field in ipairs(view:allFields()) do
                all[#all + 1] = field
            end
        end

        return all
    end

    local function open(database)
        local state = client(database)
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 600, height = 400 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:chooseEntry("Custom only")

        return state
    end

    test("share screens: export one activity, then import it as a new one", function()
        local saved = full()
        saved.id = "custom.1"
        local state = open({ [INDEX] = { schema = 1, next = 2, ids = { "custom.1" } }, ["profit-path.custom.v1/custom.1"] = saved })

        prettyui:findMethod(saved.title)()
        button("Export to share with others")()

        -- The box holds the line, and says how long it is.
        local line = assert(CustomShare.encode(saved))
        local box = fields()[#fields()]
        equal(box.text, line)
        assert(shows(#line .. " characters."), texts())
        assert(shows("Your own GE prices"), texts())

        -- Typing in it puts the line straight back.
        box:SetText("oops", true)
        equal(box.text, line)

        -- Back goes to the activity, not the list.
        button("Back to the activity")()
        assert(shows(saved.title), texts())
        assert(not shows("characters."), texts())

        -- To the list, then Import activity.
        button("Back to activities")()
        button("Import activity")()

        local paste = fields()[#fields()]
        equal(paste.placeholder, "Paste the shared text here")

        -- Nothing is checked until the paste settles.
        paste:SetText(line, true)
        assert(not shows("Add as new"), texts())
        settleSearch()

        -- The review: what it is, and what's in it.
        assert(shows("PvM, 42.5 kills/hour."), texts())
        assert(shows("4 outputs, 1 supply. 4 required checks, 3 recommended checks."), texts())
        assert(shows("Drops loaded from Abyssal demon."), texts())

        button("Add as new activity")()

        -- Saved under a new ID; the original is untouched; its page is open.
        local added = state.db["profit-path.custom.v1/custom.2"]
        equal(added.title, saved.title)
        equal(added.outputs[4].price, nil)
        equal(#state.db[INDEX].ids, 2)
        equal(state.db["profit-path.custom.v1/custom.1"].supplies[1].price, 1234)
        assert(shows("Rate per hour"), texts())
        assert(not shows("Add as new"), texts())

        PluginShutdown()
    end)

    test("share screens: a bad paste says why and adds nothing", function()
        local state = open()

        -- The empty list offers Import too.
        assert(shows("Or import one someone shared."), texts())
        button("Import activity")()

        local paste = fields()[#fields()]
        paste:SetText("PP1:{t'nope'}*00000000", true)
        settleSearch()

        assert(shows("This can't be imported:"), texts())
        assert(shows("changed or cut off"), texts())
        assert(not pcall(button, "Add as new activity"), "nothing to add")
        equal(state.db[INDEX], nil)

        -- Enter checks straight away, without waiting. (The review redrew the
        -- screen, so it's a new box, holding what was pasted.)
        paste = fields()[#fields()]
        equal(paste.text, "PP1:{t'nope'}*00000000")
        paste:SetText("", false)
        paste:Submit()
        assert(not shows("This can't be imported:"), texts())

        PluginShutdown()
    end)

    test("share screens: the editor shows the share size only when it's close to the limit", function()
        local limits = CustomMethods.LIMITS

        local function editing(record)
            record.id = "custom.1"
            open({ [INDEX] = { schema = 1, next = 2, ids = { "custom.1" } }, ["profit-path.custom.v1/custom.1"] = record })
            prettyui:findMethod(record.title)()
            button("Edit this custom activity")()
        end

        -- An ordinary activity: nothing about sharing at all.
        editing(full())
        assert(not shows("Share code"), texts())
        assert(not shows("Too big to share"), texts())
        PluginShutdown()

        -- Long steps, income notes and directions: close, so it says how close.
        local near = full()
        near.notes, near.income_notes, near.getting_there = {}, {}, {}

        for index = 1, limits.steps do
            near.notes[index] = string.rep("s", limits.notes)
            near.getting_there[index] = string.rep("g", limits.notes)
        end

        for index = 1, limits.incomeNotes do
            near.income_notes[index] = string.rep("i", limits.notes)
        end

        local length = CustomShare.length(near)
        assert(length >= CustomShare.WARN_LENGTH and length <= CustomShare.MAX_LENGTH, "fixture is near: " .. length)

        editing(near)
        assert(shows("Share code: "), texts())
        assert(shows(" of 9,998 characters"), texts())
        PluginShutdown()

        -- Over: a row note on every row as well. It still saves; it says so.
        for _, row in ipairs(near.outputs) do
            row.note = string.rep("n", limits.requirementNote)
        end

        for index = #near.outputs + 1, limits.outputs do
            near.outputs[index] = { label = "Row " .. index, pricing = "fixed", unit_value = 1, quantity = 1,
                basis = "action", note = string.rep("n", limits.requirementNote) }
        end

        editing(near)
        assert(shows("Too big to share: "), texts())
        assert(shows("Ready to save."), texts())
        PluginShutdown()
    end)

    test("share screens: Export is on custom pages only, within the tooltip budget", function()
        local saved = full()
        saved.id = "custom.1"
        open({ [INDEX] = { schema = 1, next = 2, ids = { "custom.1" } }, ["profit-path.custom.v1/custom.1"] = saved })

        prettyui:findMethod(saved.title)()

        -- Left of Delete, clear of it.
        local view = prettyui.views[#prettyui.views]
        local export = view.buttonControls["Export to share with others"].options
        local delete = view.buttonControls["Delete this custom activity"].options
        assert(export.x < delete.x, "Export is left of Delete")
        assert(delete.x - export.x >= 28 + 32, "with the usual gap")

        PluginShutdown()
    end)
end
