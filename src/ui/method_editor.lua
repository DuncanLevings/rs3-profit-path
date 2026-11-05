-- The custom activity editor screen (Phase 9).
--
-- This file only draws and forwards clicks. The decisions (how drops are loaded,
-- which are left out, what the preview says, whether Save is allowed) live in
-- src/methods/custom_draft.lua, and saving lives in main.lua.
--
-- How it redraws: anything that changes the layout (adding a row, switching a
-- tab, changing a row's basis) changes `state` and then calls actions.rebuild(),
-- which mounts the whole screen again from `state`. Typing in a box only updates
-- the draft and the profit band's text, so the box keeps its focus.
--
-- Searches (items, monsters, thieving targets) wait for a short pause in typing,
-- then redraw only their own list of matches, again so the search box keeps
-- its focus.
--
-- Native parts: the client shares 4,096 between every plugin, so this screen
-- draws only the open tab and at most ROWS_PER_PAGE rows of it. Tooltips cost
-- the most: Outputs/Supplies have one per row's item icon, remove button and
-- (drops with a note) On/Off button; Requirements has one per skill icon and
-- per remove button. Tests measure both (see README "Native dynamic IDs").
local CustomMethods = require("src/methods/custom_methods")
local Draft = require("src/methods/custom_draft")
local Income = require("src/methods/income")
local ItemIcon = require("src/ui/item_icon")
local ItemNames = require("src/data/item_names")
local Style = require("src/ui/view_style")

local MethodEditor = {}

-- Defined further down, next to the tabs that use them; mount() needs them too.
local resultsBox, itemSearch

local ROWS_PER_PAGE = 8
local SEARCH_RESULTS = 6
local SEARCH_SHOWN = 5
local MISSING_SHOWN = 8
local HEADER_HEIGHT = 44
local BAND_HEIGHT = 104
local RESULT_HEIGHT = 30

-- The item table, drawn like the activity page's: a shaded heading band, then
-- rows of alternating shades, ROW_GAP apart.
-- Rows are tall enough for a grey "About 2.4 an hour" line under the item's
-- name. Daily/weekly rows have no such line, so they keep the shorter height.
-- Every box and button is centred in its row either way, so they line up.
local TABLE_TOP = 36
local ROW_HEIGHT = 58
local SHORT_ROW_HEIGHT = 44
local ROW_GAP = 2

-- The hourly line's smaller font (the one Browse uses for an activity's
-- version), and the height of its one line.
local HOURLY_FONT = "MUSEO_SANS_11PT_REGULAR"
local HOURLY_HEIGHT = 16

-- How many Logic ticks of no typing before a search runs (same as Browse).
local SEARCH_SETTLE_TICKS = 12

-- The "Can't save yet" flash: blinks for FLASH_TICKS ticks, switching colour
-- every FLASH_STEP ticks, then stays red.
local FLASH_TICKS = 24
local FLASH_STEP = 4
local FLASH_RED = 0xFF6655FF

-- Logic event names. The client allows one handler per name, and unmount()
-- unsubscribes whichever are still running.
local EVENTS = {
    flash = "profit-path.editor.flash",
    items = "profit-path.editor.items",
}

-- What each kind of number box lets you type (anything else is removed).
local ALLOWED = {
    whole = "[^%d]",
    decimal = "[^%d%.,]",
    -- Quantities can also be a Wiki-style rate: "1/50" is one in fifty.
    rate = "[^%d%.,/]",
}

-- The same tabs as the activity page, with Income's two tables split out.
local TABS = { "Income", "Outputs", "Supplies", "Requirements", "How to do it", "Getting there" }

local CATEGORIES = {
    { id = "pvm", label = "PvM" },
    { id = "skilling", label = "Skilling" },
    { id = "production", label = "Production" },
    { id = "recurring", label = "Daily / weekly" },
}

local RECURRENCES = {
    { id = "day", label = "Every day" },
    { id = "week", label = "Every week" },
    { id = "month", label = "Every month" },
}

-- A row's Counted button cycles through these ("Each trip" only while the
-- player banks between trips).
local BASES = { "action", "trip", "hour" }

-- The draft's lists of lines (steps, income notes, getting there) as lists.
-- Older saves had one plain note; a blank draft has none of them. Either way
-- the editor works on lists.
local LINE_LISTS = { "notes", "income_notes", "getting_there" }

local function normaliseNotes(draft)
    for _, key in ipairs(LINE_LISTS) do
        if type(draft[key]) == "string" then
            draft[key] = { draft[key] }
        elseif type(draft[key]) ~= "table" then
            draft[key] = {}
        end
    end
end

-- A fresh editor state. `options`:
--   draft   a record to edit (a copy is made); omit to start a new one
--   skipped what Duplicate as custom couldn't bring across (custom_draft.fromMethod)
function MethodEditor.state(options)
    options = options or {}

    local state = {
        tab = 1,
        pages = { outputs = 1, supplies = 1 },

        -- Each tab's scroll position, so a redraw keeps your place.
        scroll = {},
        search = { outputs = "", supplies = "", requirement = "" },
        target = "required",
        quotes = {},
        message = nil,
    }

    if options.draft then
        state.draft = Draft.copy(options.draft)
        state.step = "edit"
        state.editing = options.draft.id ~= nil
        normaliseNotes(state.draft)
    else
        state.step = "start"
    end

    if options.skipped then
        local notes = {}
        local skipped = options.skipped

        if skipped.outputs > 0 then
            notes[#notes + 1] = skipped.outputs .. " outputs over the limit were left out"
        end

        if skipped.supplies > 0 then
            notes[#notes + 1] = skipped.supplies .. " supplies over the limit were left out"
        end

        if skipped.requirements > 0 then
            notes[#notes + 1] = skipped.requirements .. " requirements over the limit were left out"
        end

        if #skipped.recipes > 0 then
            notes[#notes + 1] = "made-by-you supplies can't be copied yet (" .. table.concat(skipped.recipes, ", ") .. ")"
        end

        if #notes > 0 then
            state.message = "Copied. " .. table.concat(notes, "; ") .. "."
        end
    end

    return state
end

-- ---- Small helpers ------------------------------------------------------------

-- Numbers in boxes, never in "1e+06" form. A small chance that is exactly one
-- in a whole number reads "1/50", the way the Wiki writes drop rates.
local function numberText(value)
    if value == nil then
        return ""
    end

    if value > 0 and value < 1 then
        local oneIn = 1 / value
        local whole = math.floor(oneIn + 0.5)

        if whole >= 2 and math.abs(oneIn - whole) <= whole * 1e-6 then
            return "1/" .. whole
        end
    end

    -- Up to 6 significant digits, unless that needs an exponent.
    local text = string.format("%.6g", value)

    if text:find("e") then
        text = string.format(value >= 1 and "%.0f" or "%.10f", value)
        text = text:find("%.") and text:gsub("0+$", ""):gsub("%.$", "") or text
    end

    return text
end

-- A typed number, or nil if it isn't a finite number of 0 or more. With
-- `fraction`, "a/b" is accepted too (1/50 = 0.02).
local function parseNumber(text, fraction)
    text = tostring(text or ""):gsub(",", ""):match("^%s*(.-)%s*$")

    if fraction then
        local top, bottom = text:match("^([%d%.]+)%s*/%s*([%d%.]+)$")

        if top then
            top, bottom = tonumber(top), tonumber(bottom)

            if top and bottom and bottom > 0 then
                return top / bottom
            end

            return nil
        end
    end

    local value = tonumber(text)

    if value and value >= 0 and value < math.huge then
        return value
    end
end

-- "kill", "action" or "run": what one of this activity's counts is. The rate's
-- unit decides (not the category), so an older Skilling activity that was saved
-- counting kills still says "kill".
local function actionWord(draft)
    if draft.category == "recurring" then
        return "run"
    end

    return draft.rate.unit == "kills/hour" and "kill" or "action"
end

-- The plural, for "About how many kills an hour?".
local function actionsWord(draft)
    return actionWord(draft) .. "s"
end

-- What a row's Counted button says: "Each kill", "Each trip", "Each hour"...
local function basisLabel(basis, draft)
    if draft.category == "recurring" then
        return "Each run"
    end

    if basis == "trip" then
        return "Each trip"
    elseif basis == "hour" then
        return "Each hour"
    end

    return "Each " .. actionWord(draft)
end

-- "per kill", "per run" or "per action", for sentences.
local function perWhat(draft)
    return "per " .. actionWord(draft)
end

-- Whether the player banks between trips ("Do you bank between trips?"). It
-- lives on the editor state, not the draft, because it's only a question: the
-- saved activity just has (or hasn't) a kills per trip number and per-trip
-- rows. Worked out from those the first time it's asked.
local function tripsOn(state)
    if state.trips == nil then
        state.trips = Draft.usesTrips(state.draft)
    end

    return state.trips
end

-- A short, readable amount for the hourly line: whole numbers once they're
-- big, a couple of decimals for small ones (0.25 food a kill).
local function roughNumber(value)
    if value >= 100 then
        return Style.number(value, 0)
    end

    if value >= 1 then
        -- One decimal, but "12" rather than "12.0".
        return (Style.number(value, 1):gsub("%.0$", ""))
    end

    -- Two significant figures for small amounts, so 1/5000 doesn't read as 0.
    local text = string.format("%.2g", value)

    -- %g switches to "1e-05" for really tiny ones; write those out in full.
    if text:find("e") then
        text = string.format("%.8f", value):gsub("0+$", ""):gsub("%.$", "")
    end

    return text
end

-- The grey line under a row's boxes: what the row comes to over an hour (or,
-- for an hourly row, per kill/action), so the player can see straight away
-- whether they picked the right "Each ...". Blank when it can't be worked out
-- yet (no quantity, no kills an hour, no kills per trip) or the row isn't counted.
local function hourlyText(row, draft)
    local rate = draft.rate.default

    if draft.category == "recurring" or row.quantity == nil or row.state == "off" or row.state == "needs" then
        return ""
    end

    if type(rate) ~= "number" or rate <= 0 then
        return ""
    end

    -- An hourly row: show it per kill/action instead (an hour is already shown).
    if row.basis == "hour" then
        return "About " .. roughNumber(row.quantity / rate) .. " a " .. actionWord(draft)
    end

    local times = Income.timesPerHour(row.basis, rate, draft.actions_per_trip)

    if times == nil then
        return ""
    end

    return "About " .. roughNumber(row.quantity * times) .. " an hour"
end

-- How tall a text box must be for `text` to wrap inside `width`.
local function wrappedHeight(text, width)
    local lines = math.max(1, math.ceil(Style.textWidth(text) / math.max(1, width)))
    return math.max(28, lines * 20 + 8)
end

-- Fetches prices for any GE item in the draft we haven't asked about yet. Only
-- called when rows change, never while typing.
local function priceRows(state, quote)
    for _, side in ipairs({ "outputs", "supplies" }) do
        for _, row in ipairs(state.draft[side]) do
            if row.pricing == "ge" and row.item_id and not state.quotes[row.item_id] then
                state.quotes[row.item_id] = quote(row.item_id)
            end
        end
    end
end

-- The GE price one of a row's items is counted at, from the GE Price Library:
-- outputs sell (instant-sell price), supplies buy (instant-buy price). The same
-- prices the activity page uses. nil if there's no price.
local function gePrice(quote, side)
    if type(quote) ~= "table" then
        return nil
    end

    local price

    if side == "outputs" then
        price = quote.low or quote.high
    else
        price = quote.high or quote.low
    end

    if type(price) == "number" and price == price and price < math.huge then
        return price
    end
end

-- Whether a row came from the monster/thieving source (and so can be switched
-- off, like a drop you only get on task). Rows the player added always count.
local function fromSource(row)
    return row.source_key ~= nil
end

-- The skill grid: one icon button per skill, SKILL_COLUMNS to a line.
local SKILL_COLUMNS = 10
local SKILL_BUTTON = 40

-- ---- The screen -----------------------------------------------------------------

-- Returns an unmount() that destroys the screen's nested views and stops its
-- Logic tickers. Call it before destroying `view`: PrettyUI keeps a nested view's
-- scrollbar overlay registered with the window until that view itself is
-- destroyed, and a leftover overlay crashed the next rebuild in game (4 Nov,
-- "attempt to index a nil value (local 'target')"). browse_view.lua destroys its
-- nested views the same way.
--
-- `library` is PrettyUI. `actions`:
--   rebuild()            mount the screen again from `state`
--   quote(itemId)        one GE quote (Income.inspectQuote's shape)
--   save(draft)          returns the saved record, or nil plus a message/problems
--   delete(id)           returns true, or false plus a message
--   done(saved)          leave the editor (saved is the record, or nil)
function MethodEditor.mount(library, view, state, guarded, actions)
    -- Every nested view made below, so unmount() can destroy them.
    local nested = {}

    -- Logic handlers still subscribed, by event name.
    local tickers = {}

    local function stopTicker(name)
        if tickers[name] then
            tickers[name] = nil
            Event.Logic.Unsubscribe(name)
        end
    end

    -- Calls onTick every game tick until stopTicker(name).
    local function startTicker(name, onTick)
        stopTicker(name)
        tickers[name] = true
        Event.Logic.Subscribe(name, guarded(onTick))
    end

    local function unmount()
        for name in pairs(tickers) do
            stopTicker(name)
        end

        for index = #nested, 1, -1 do
            nested[index]:Destroy()
            nested[index] = nil
        end
    end

    -- A nested view on `parent` (the screen itself unless given).
    local function nestedView(options, parent)
        local child = library.SimpleView.new((parent or view).content, options)
        nested[#nested + 1] = child
        return child
    end

    local function rebuild()
        actions.rebuild()
    end

    -- The open tab's scrolling area (set further down), so a redraw can put the
    -- player back where they were instead of at the top.
    local body

    -- A click that changes the layout: apply it, then redraw.
    local function change(callback)
        return guarded(function(...)
            if body then
                state.scroll[state.tab] = body.scrollY
            end

            state.message = nil
            callback(...)
            rebuild()
        end)
    end

    -- Waits for a pause in typing, then calls settle(). Returns typed() for the
    -- box's onChange, and now() to skip the wait (Enter).
    local function debounced(name, settle)
        local quiet

        local function now()
            quiet = nil
            stopTicker(name)
            settle()
        end

        local function typed()
            -- Each keystroke restarts the countdown.
            local waiting = quiet ~= nil
            quiet = 0

            if waiting then
                return
            end

            startTicker(name, function()
                quiet = quiet + 1

                if quiet >= SEARCH_SETTLE_TICKS then
                    now()
                end
            end)
        end

        return typed, now
    end

    -- A text box that only takes numbers. `kind` is "whole", "decimal" or
    -- "rate" (see ALLOWED); anything else typed is taken straight back out.
    -- options.most caps it (typing 150 in a level box shows 120). onText(text)
    -- gets the cleaned text.
    local function numberField(parent, options, kind, onText)
        local field
        local most = options.most
        options.most = nil

        options.onChange = guarded(function(_, _, text)
            text = text or ""
            local clean = text:gsub(ALLOWED[kind], "")

            if most and (tonumber((clean:gsub(",", ""))) or 0) > most then
                clean = tostring(most)
            end

            if clean ~= text then
                field:SetText(clean, false)
            end

            if onText then
                onText(clean)
            end
        end)

        field = parent:AddTextField(options)
        return field
    end

    -- Tools the tab builders below share.
    local tools = {
        library = library,
        guarded = guarded,
        change = change,
        debounced = debounced,
        numberField = numberField,
        quote = actions.quote,
    }

    -- The title sits on the left, clear of the Save and Delete buttons.
    view:AddTitle({
        text = state.editing and "Edit custom activity" or "New custom activity", absolute = true,
        x = 44, y = 10, width = -(44 + 300), widthAnchor = 1, height = 28,
    })

    -- ---- Step 1: what kind of activity ----------------------------------------------
    -- Any activity can be custom, so the kind comes first and starts an empty one.
    -- Loading a monster's drops or a thieving target's loot is an optional shortcut.
    if state.step == "start" or state.step == "pick" then
        local start = nestedView({
            x = 0, y = HEADER_HEIGHT, width = 0, height = -HEADER_HEIGHT, widthAnchor = 1, heightAnchor = 1,
            scrollable = true, layout = { startY = 8, padding = 20, rowGap = 10 },
        })

        start:AddTitle("What kind of activity?")
        start:AddText({ text = "Pick one to start with an empty activity. You can change it later on the Income tab.",
            colour = Style.muted })

        for index, category in ipairs(CATEGORIES) do
            start:AddSimpleButton(category.label, change(function()
                state.draft = Draft.blank(category.id)
                normaliseNotes(state.draft)
                state.step = "edit"
                state.tab = 1
            end), { width = 150, height = 32, inline = index > 1 })
        end

        start:AddTitle({ text = "Or start from drops", marginTop = 12 })
        start:AddText({ text = "Loads every drop of a monster, or the loot of a pickpocket target or stall, "
            .. "as outputs you can then edit.", colour = Style.muted })

        start:AddSimpleButton("A monster's drops", change(function()
            state.step, state.pickKind, state.pickQuery = "pick", "monster", ""
        end), { width = 200, height = 32, active = state.pickKind == "monster" })

        start:AddSimpleButton("A thieving target's loot", change(function()
            state.step, state.pickKind, state.pickQuery = "pick", "thieving", ""
        end), { width = 220, height = 32, inline = true, active = state.pickKind == "thieving" })

        if state.step == "pick" then
            local kind = state.pickKind
            local fitter = Style.panelFitter(start, 20)
            local field, box

            -- Picking a match loads its drops and opens the editor.
            local function pick(title)
                return change(function()
                    -- Rank drops by value when there are more than fit, so price
                    -- the source's GE items first.
                    local rows = Draft.sourceRows(kind, title) or {}
                    local quotes = {}

                    if #rows > CustomMethods.LIMITS.outputs then
                        for _, row in ipairs(rows) do
                            if row.pricing == "ge" and not quotes[row.item_id] then
                                quotes[row.item_id] = actions.quote(row.item_id)
                            end
                        end
                    end

                    state.quotes = quotes
                    state.draft = Draft.fromSource(kind, title, quotes)
                    normaliseNotes(state.draft)
                    state.step = "edit"
                    state.tab = 2
                end)
            end

            -- The matches for what's typed, drawn in place (like the item search),
            -- once typing pauses.
            local function settle()
                local query = state.pickQuery
                local matches, total = Draft.searchSources(kind, query, SEARCH_RESULTS)
                local entries = {}

                for index, title in ipairs(matches) do
                    entries[index] = { label = title, pick = pick(title) }
                end

                if not query:find("%S") then
                    box:show(entries, "Type part of the name.")
                elseif total == 0 then
                    box:show(entries, "Nothing matches \"" .. query .. "\".")
                elseif total > #entries then
                    box:show(entries, #entries .. " of " .. total .. " matches. Type more to narrow it down.")
                else
                    box:show(entries)
                end
            end

            local typed, now = debounced(EVENTS.items, settle)

            start:AddTitle({ text = kind == "monster" and "Find a monster" or "Find a thieving target", marginTop = 12 })

            field = start:AddTextField({
                text = state.pickQuery, placeholder = "Type part of the name", maxLength = 60,
                width = 360, height = 30,
                onChange = guarded(function(_, _, text)
                    state.pickQuery = text or ""
                    typed()
                end),
                onSubmit = guarded(function()
                    state.pickQuery = field:GetText() or ""
                    now()
                end),
            })

            box = resultsBox(start, fitter, { rows = SEARCH_RESULTS })
            settle()
            fitter:fit()
        end

        return unmount
    end

    -- ---- Step 2: the editor itself ------------------------------------------------
    local draft = state.draft
    normaliseNotes(draft)
    priceRows(state, actions.quote)

    -- ---- The profit band (laid out like the activity page's) -----------------------
    local band = view:AddPanel({
        x = 10, y = HEADER_HEIGHT, width = -20, widthAnchor = 1, height = BAND_HEIGHT, scrollable = false,
    })

    local recurring = draft.category == "recurring"
    local profitLabel = recurring and "Profit per run (after tax)" or "Profit per hour (after tax)"
    band:AddText({ text = profitLabel, x = 14, y = 8, width = 220, height = 24, colour = Style.muted })

    -- Save status at the top right, a clear gap after the label (like the
    -- activity page's unsaved-changes message).
    local statusX = 14 + math.ceil(Style.textWidth(profitLabel)) + 16

    local status = band:AddText({
        text = "", x = statusX, y = 8, width = -(statusX + 14), widthAnchor = 1, height = 24,
        colour = Style.muted, alignHorizontal = ui.AlignMode.BOTTOMRIGHT,
    })

    -- The headline: profit in the big bold font with a coin, ROI a step smaller
    -- on the right. Both sit on the second line.
    local headlineY, headlineHeight = 32, 36

    Style.coins(band, { x = 14, y = Style.middle(headlineY, headlineHeight, 26), size = 26 })

    local headline = Style.setFont(band:AddText({
        text = "", x = 46, y = headlineY, width = -260, widthAnchor = 1, height = headlineHeight, colour = Style.gold,
    }), Style.HEADLINE_FONT)

    local roi = Style.setFont(band:AddText({
        text = "", x = -(200 + 14), xAnchor = 1, y = headlineY, width = 200, height = headlineHeight,
        colour = Style.gold, alignHorizontal = ui.AlignMode.BOTTOMRIGHT,
    }), Style.SUBHEADLINE_FONT)

    -- Revenue (green) and cost (red), each with a coin, on the third line.
    local moneyY = 72

    band:AddText({ text = "Revenue", x = 14, y = moneyY, width = 70, height = 24, colour = Style.muted })
    Style.coins(band, { x = 86, y = Style.middle(moneyY, 24, 18), size = 18 })
    local revenue = band:AddText({ text = "", x = 108, y = moneyY, width = 150, height = 24, colour = Style.good })

    band:AddText({ text = "Cost", x = 270, y = moneyY, width = 44, height = 24, colour = Style.muted })
    Style.coins(band, { x = 316, y = Style.middle(moneyY, 24, 18), size = 18 })
    local cost = band:AddText({ text = "", x = 338, y = moneyY, width = 150, height = 24, colour = Style.bad })

    -- Rewrites the band from the draft. Cheap: text only.
    local function updatePreview()
        local preview = Draft.preview(draft, state.quotes)
        local result = preview.result

        if result and preview.coverage == "complete" and result.status == "available" then
            headline.content = Style.number(result.profit)
            headline.rgba = result.profit < 0 and Style.bad or Style.gold
            roi.content = result.roi and (Style.number(result.roi, 1) .. "% ROI") or ""
            revenue.content, revenue.rgba = Style.number(result.revenue), Style.good
            cost.content, cost.rgba = Style.number(result.cost), Style.bad
        else
            -- Why there's no number yet, in the headline's place.
            if not result then
                headline.content = "No estimate yet"
            elseif preview.coverage ~= "complete" then
                headline.content = "Some drops need a quantity"
            else
                headline.content = result.message or "Prices aren't available yet"
            end

            headline.rgba = Style.muted
            roi.content = ""
            revenue.content, revenue.rgba = "Unavailable", Style.muted
            cost.content, cost.rgba = "Unavailable", Style.muted
        end

        -- The status: a message, why it can't save (only once Save was pressed),
        -- or ready.
        if state.message then
            status.content = state.message
            status.rgba = Style.gold
        elseif #preview.problems > 0 then
            if state.saveTried then
                status.content = "Can't save yet: " .. preview.problems[1]
                    .. (#preview.problems > 1 and ("  (+" .. (#preview.problems - 1) .. " more)") or "")

                if not tickers[EVENTS.flash] then
                    status.rgba = Style.bad
                end
            else
                status.content = ""
            end
        else
            status.content = "Ready to save."
            status.rgba = Style.good
        end
    end

    -- Blinks the status red, so a Save that didn't happen is hard to miss.
    local function flashStatus()
        local ticks = 0
        status.rgba = FLASH_RED

        startTicker(EVENTS.flash, function()
            ticks = ticks + 1

            if ticks >= FLASH_TICKS then
                stopTicker(EVENTS.flash)
                status.rgba = Style.bad
                return
            end

            status.rgba = math.floor(ticks / FLASH_STEP) % 2 == 0 and FLASH_RED or Style.text
        end)
    end

    -- Save, top right. It always responds: if the draft isn't valid yet, the
    -- status says why and flashes.
    view:AddSimpleButton("Save", guarded(function()
        -- Blank lines are just empty boxes; don't save them.
        for _, key in ipairs(LINE_LISTS) do
            draft[key] = CustomMethods.lines(draft[key])
        end

        local saved, problem = actions.save(draft)

        if saved then
            actions.done(saved)
            return
        end

        state.saveTried = true

        if type(problem) ~= "table" then
            state.message = tostring(problem)
        end

        updatePreview()
        flashStatus()
    end), { absolute = true, x = -110, xAnchor = 1, y = 8, width = 100, height = 30 })

    -- Delete needs a second click, since it can't be undone.
    if state.editing then
        view:AddSimpleButton(state.confirmDelete and "Click again to delete" or "Delete", guarded(function()
            if not state.confirmDelete then
                state.confirmDelete = true
                rebuild()
                return
            end

            local deleted, problem = actions.delete(draft.id)

            if deleted then
                actions.done(nil)
            else
                state.confirmDelete = false
                state.message = problem
                rebuild()
            end
        end), { absolute = true, x = -270, xAnchor = 1, y = 8, width = 150, height = 30 })
    end

    -- ---- Tabs (only the open one is drawn) ----------------------------------------
    local top = HEADER_HEIGHT + BAND_HEIGHT + 6
    local entries = {}

    for index, label in ipairs(TABS) do
        entries[index] = { text = label }
    end

    local tabs = view:AddTabs(entries, {
        activeIndex = state.tab,
        onChange = change(function(_, index)
            state.tab = index
        end),
        absolute = true, x = 0, y = top, width = 0, height = -top, widthAnchor = 1, heightAnchor = 1,
    })

    -- The open tab's contents go in their own scrolling area, so a redraw can
    -- scroll back to where the player was (a tab page can't be told to).
    body = nestedView({
        x = 0, y = 0, width = 0, height = 0, widthAnchor = 1, heightAnchor = 1,
        scrollable = true, layout = { startY = 8, padding = 10, rowGap = 8 },
    }, tabs:GetPage(state.tab))

    local fitter = Style.panelFitter(body, 10)

    tools.updatePreview = updatePreview
    tools.fitter = fitter

    if state.tab == 1 then
        MethodEditor.income(body, state, tools)
    elseif state.tab == 2 or state.tab == 3 then
        MethodEditor.rows(body, state, state.tab == 2 and "outputs" or "supplies", tools)
    elseif state.tab == 4 then
        MethodEditor.requirements(body, state, tools)
    elseif state.tab == 5 then
        body:AddText({ text = "Steps for doing the activity, shown on its How to do it tab.", colour = Style.muted })
        MethodEditor.lines(body, draft.notes, tools, {
            what = "step", most = CustomMethods.LIMITS.steps,
            placeholder = "e.g. Bank at the Wars Retreat, then teleport to the boss",
        })
    else
        body:AddText({ text = "How to get there, shown on the activity's Getting there tab.", colour = Style.muted })
        MethodEditor.lines(body, draft.getting_there, tools, {
            what = "direction", most = CustomMethods.LIMITS.steps,
            placeholder = "e.g. Fairy ring code CKS, then run north-east",
        })
    end

    fitter:fit()
    body:SetScrollPosition(state.scroll[state.tab] or 0)
    updatePreview()

    return unmount
end

-- A box of result buttons under a search field, `rows` lines of `columns`
-- buttons each `width` wide. show() swaps its contents in place, so the search
-- field above keeps its focus. box:show(entries, note) takes { label, pick,
-- active } entries and an optional muted note (e.g. "5 of 143 matches").
resultsBox = function(page, fitter, layout)
    layout = layout or {}

    local rows = layout.rows or SEARCH_SHOWN
    local columns = layout.columns or 1
    local width = layout.width or 360
    local height = rows * RESULT_HEIGHT + 8
    local panel = fitter:add(page:AddPanel({ height = height, scrollable = false }), height)
    local drawn = {}
    local box = {}

    function box:show(entries, note)
        -- Out with the old matches...
        for index = #drawn, 1, -1 do
            drawn[index]:Destroy()
            drawn[index] = nil
        end

        -- ...and in with the new, left to right, then down.
        for index, entry in ipairs(entries) do
            local column = (index - 1) % columns
            local line = (index - 1) // columns

            if line < rows then
                drawn[#drawn + 1] = panel:AddSimpleButton(entry.label, entry.pick, {
                    x = 6 + column * (width + 8), y = 4 + line * RESULT_HEIGHT, width = width,
                    height = RESULT_HEIGHT - 2, active = entry.active == true,
                })
            end
        end

        if note then
            local x = #entries > 0 and (columns * (width + 8) + 12) or 8

            drawn[#drawn + 1] = panel:AddText({
                text = note, x = x, y = 6, width = -(x + 8), widthAnchor = 1, height = 24, colour = Style.muted,
            })
        end
    end

    return box
end

-- A Grand Exchange item search: a field, its results box, and `pick(item)` for
-- a clicked match. `key` is where state.search keeps the typed text across
-- redraws. Returns the field.
itemSearch = function(page, state, tools, key, options)
    local box
    local field

    -- Draws the matches for whatever's typed now.
    local function settle()
        local query = state.search[key]
        local results, total = ItemNames.search(query, SEARCH_SHOWN)
        local entries = {}

        for _, item in ipairs(results) do
            entries[#entries + 1] = {
                label = item.label,
                pick = tools.change(function()
                    state.search[key] = ""
                    options.pick(item)
                end),
            }
        end

        if not query:find("%S") then
            box:show(entries, options.hint)
        elseif total == 0 then
            box:show(entries, "No Grand Exchange item matches \"" .. query .. "\".")
        elseif total > #entries then
            box:show(entries, #entries .. " of " .. total .. " matches. Type more to narrow it down.")
        else
            box:show(entries)
        end
    end

    local typed, now = tools.debounced(EVENTS.items, settle)

    field = page:AddTextField({
        text = state.search[key], placeholder = options.placeholder, maxLength = 60,
        width = options.width or 300, height = 30, inline = options.inline,
        onChange = tools.guarded(function(_, _, text)
            state.search[key] = text or ""
            typed()
        end),
        onSubmit = tools.guarded(function()
            state.search[key] = field:GetText() or ""
            now()
        end),
    })

    if options.after then
        options.after()
    end

    box = resultsBox(page, tools.fitter)
    settle()

    return field
end

-- ---- Income tab ------------------------------------------------------------------

function MethodEditor.income(page, state, tools)
    local draft = state.draft
    local guarded, change, updatePreview = tools.guarded, tools.change, tools.updatePreview

    page:AddText({ text = "Name", colour = Style.gold })
    page:AddTextField({
        text = draft.title, placeholder = "e.g. Killing ghouls with a cannon",
        maxLength = CustomMethods.LIMITS.title, width = 420, height = 30,
        onChange = guarded(function(_, _, text)
            draft.title = text
            updatePreview()
        end),
    })

    -- Category. Switching between PvM, Skilling and Production only changes
    -- which buttons are lit and a few words (kills or actions), so it happens
    -- in place (no redraw, no flicker). Daily/weekly has different boxes below,
    -- so going to or from it redraws.
    page:AddText({ text = "Category", colour = Style.gold, marginTop = 6 })

    local categoryButtons = {}
    local questionLabel, tripLabel

    -- "About how many kills an hour?" and "Kills per trip", for the category now.
    local function questionText()
        return "About how many " .. actionsWord(draft) .. " an hour?"
    end

    local function tripText()
        local word = actionsWord(draft)
        return word:sub(1, 1):upper() .. word:sub(2) .. " per trip"
    end

    local function light()
        for id, button in pairs(categoryButtons) do
            button:SetActive(id == draft.category)
        end

        if questionLabel then
            questionLabel.content = questionText()
        end

        if tripLabel then
            tripLabel.content = tripText()
        end
    end

    for index, category in ipairs(CATEGORIES) do
        local redraw = change(function()
            Draft.setCategory(draft, category.id)

            -- Daily/weekly has no trips (setCategory clears them), so ask
            -- again from what the draft now has.
            state.trips = nil
        end)

        categoryButtons[category.id] = page:AddSimpleButton(category.label, guarded(function(...)
            if draft.category == category.id then
                return
            end

            if draft.category == "recurring" or category.id == "recurring" then
                redraw(...)
                return
            end

            Draft.setCategory(draft, category.id)
            light()
            updatePreview()
        end), { width = 130, height = 30, inline = index > 1, active = draft.category == category.id })
    end

    -- A daily or weekly activity counts per run, so it has a how-often instead
    -- of a throughput.
    if draft.category == "recurring" then
        page:AddText({ text = "How often", colour = Style.gold, marginTop = 6 })

        for index, every in ipairs(RECURRENCES) do
            page:AddSimpleButton(every.label, change(function()
                draft.recurrence.every = every.id
            end), { width = 130, height = 30, inline = index > 1, active = draft.recurrence.every == every.id })
        end

        page:AddText({ text = "Minutes one run takes (optional)", colour = Style.muted })
        tools.numberField(page, { text = numberText(draft.recurrence.minutes), maxLength = 6, width = 160, height = 30 },
            "decimal", function(text)
                local value = parseNumber(text)
                draft.recurrence.minutes = value and value > 0 and value or nil
                updatePreview()
            end)

        page:AddText({ text = "Default runs to count (usually 1)", colour = Style.muted })
    else
        -- One plain question. Whether it's kills or actions follows the
        -- category (a thieving target always counts actions: you pickpocket it).
        questionLabel = page:AddText({ text = questionText(), colour = Style.gold, marginTop = 6 })
        page:AddText({ text = "Players can change this to their own speed on the activity page.", colour = Style.muted })
    end

    tools.numberField(page, { text = numberText(draft.rate.default), placeholder = "e.g. 300", maxLength = 12, width = 160, height = 30 },
        "decimal", function(text)
            local value = parseNumber(text)

            if value then
                draft.rate.default = value
            end

            updatePreview()
        end)

    -- Trips. Asked up front, so the kills per trip box is right here instead of
    -- only turning up after a row on another tab was set to "Each trip".
    -- Daily/weekly counts runs, so it has no trips.
    if draft.category ~= "recurring" then
        local trips = tripsOn(state)

        page:AddText({ text = "Do you bank between trips?", colour = Style.gold, marginTop = 6 })

        page:AddSimpleButton("No", change(function()
            -- Per-trip rows become per kill/action with the same hourly amount.
            Draft.stopTrips(draft)
            state.trips = false
        end), { width = 100, height = 30, active = not trips })

        page:AddSimpleButton("Yes", change(function()
            state.trips = true
        end), { width = 100, height = 30, inline = true, active = trips })

        if trips then
            tripLabel = page:AddText({ text = tripText(), colour = Style.gold, marginTop = 6 })
            page:AddText({ text = "Rows counted \"Each trip\" use this to work out trips an hour.", colour = Style.muted })

            tools.numberField(page, { text = numberText(draft.actions_per_trip), placeholder = "e.g. 25",
                maxLength = 12, width = 160, height = 30 }, "decimal", function(text)
                    local value = parseNumber(text)
                    draft.actions_per_trip = value and value > 0 and value or nil
                    updatePreview()
                end)
        end
    end

    -- The Income tab's Notes, under the tables on the activity page.
    page:AddTitle({ text = "Notes", marginTop = 10 })
    page:AddText({ text = "Shown under the Income tab's tables, e.g. what the rate assumes.", colour = Style.muted })
    MethodEditor.lines(page, draft.income_notes, tools, {
        what = "note", most = CustomMethods.LIMITS.incomeNotes,
        placeholder = "e.g. Assumes a full inventory of food each trip",
    })

    if draft.source then
        page:AddText({
            text = "Drops loaded from: " .. draft.source.title .. " (RuneScape Wiki)", colour = Style.muted, marginTop = 6,
        })
    end
end

-- A numbered list of one-line texts (steps, notes, directions): a box and a
-- remove button per line, and an Add button below while there's room.
-- options: what ("step"), most (the limit), placeholder.
function MethodEditor.lines(page, list, tools, options)
    local guarded, change, updatePreview = tools.guarded, tools.change, tools.updatePreview
    local what = options.what

    if #list == 0 then
        page:AddText({ text = "No " .. what .. "s yet.", colour = Style.muted })
    end

    for index, line in ipairs(list) do
        page:AddText({ text = index .. ".", width = 26, height = 30 })

        page:AddTextField({
            text = line, placeholder = options.placeholder,
            maxLength = CustomMethods.LIMITS.notes, width = 480, height = 30, inline = true,
            onChange = guarded(function(_, _, text)
                list[index] = text or ""
                updatePreview()
            end),
        })

        Style.iconButton(page, "trash", "Remove", "Remove " .. what .. " " .. index, change(function()
            table.remove(list, index)
        end))
    end

    if #list < options.most then
        page:AddSimpleButton("Add " .. what, change(function()
            list[#list + 1] = ""
        end), { width = 130, height = 28 })
    end
end

-- ---- Outputs and Supplies tabs ----------------------------------------------------

-- The table's columns, right to left, with a clear gap between each. x is from
-- the panel's right edge. Supplies have no Include column, so theirs shift right.
local COLUMN_GAP = 14

local function tableColumns(side)
    local columns = {}
    local right = 20

    local function column(name, width)
        columns[name] = { x = -(right + width), width = width }
        right = right + width + COLUMN_GAP
    end

    column("remove", 28)

    -- Include (outputs only): a drop's On/Off switch.
    if side == "outputs" then
        column("include", 58)
    end

    -- Wide enough for a price like 12,345,678, "Each action" and a 1/12,000 drop.
    -- "per" is the Counted column (each kill, each trip or each hour).
    column("price", 130)
    column("per", 110)
    column("quantity", 100)

    -- The item's name runs from beside its icon up to the quantity column.
    columns.name = { x = 62, width = -(62 + right) }

    return columns
end

function MethodEditor.rows(page, state, side, tools)
    local draft = state.draft
    local guarded, change, updatePreview, fitter = tools.guarded, tools.change, tools.updatePreview, tools.fitter
    local rows = draft[side]
    local limit = CustomMethods.LIMITS[side]
    local pages = math.max(1, math.ceil(#rows / ROWS_PER_PAGE))

    state.pages[side] = math.min(math.max(state.pages[side] or 1, 1), pages)

    local first = (state.pages[side] - 1) * ROWS_PER_PAGE + 1
    local last = math.min(#rows, first + ROWS_PER_PAGE - 1)

    -- What the table means, in the activity's own words ("each kill", "each
    -- trip" only when they bank). Daily/weekly rows are all for one run.
    local recurring = draft.category == "recurring"
    local trips = not recurring and tripsOn(state)
    local word = actionWord(draft)
    local choices = trips and ("each " .. word .. ", each trip or each hour") or ("each " .. word .. " or each hour")
    local intro

    if recurring then
        intro = side == "outputs" and "What you get from one run. Type 1/50 for a 1 in 50 chance."
            or "What you use up on one run."
    else
        intro = (side == "outputs" and "What you get." or "What you use up.")
            .. " Type how many, then pick whether that's " .. choices .. "."
            .. (side == "outputs" and " Type 1/50 for a 1 in 50 drop." or "")
    end

    page:AddText({ text = intro, colour = Style.muted })

    -- The grey "About ... an hour" lines need a speed (and, for trips, kills
    -- per trip). Say once what's missing here rather than on every row.
    if not recurring then
        local rate = draft.rate.default

        if type(rate) ~= "number" or rate <= 0 then
            page:AddText({ text = "Fill in how many " .. actionsWord(draft)
                .. " you do an hour on the Income tab to see what each row comes to.", colour = Style.muted })
        elseif trips and draft.actions_per_trip == nil then
            page:AddText({ text = "Fill in " .. actionsWord(draft)
                .. " per trip on the Income tab to see what \"Each trip\" rows come to.", colour = Style.muted })
        end
    end

    -- ---- Add a row (above the table) ----
    if #rows >= limit then
        page:AddText({ text = "This list is full (" .. limit .. " rows). Remove one to add another.", colour = Style.bad })
    else
        itemSearch(page, state, tools, side, {
            placeholder = "Search the Grand Exchange",
            hint = "Type an item's name, then pick it here. For anything not on the GE, use Custom item.",

            -- The Custom item button sits beside the search box.
            after = function()
                page:AddSimpleButton("Custom item", change(function()
                    rows[#rows + 1] = {
                        label = side == "outputs" and "Other loot" or "Other cost", pricing = "fixed", unit_value = 0,
                        quantity = 1, basis = Draft.newRowBasis(draft, side, trips),
                        state = side == "outputs" and "included" or nil, custom = true,
                    }
                    state.pages[side] = math.ceil(#rows / ROWS_PER_PAGE)
                end), { width = 130, height = 30, inline = true })
            end,

            pick = function(item)
                rows[#rows + 1] = {
                    label = item.label, item_id = item.id, pricing = "ge", quantity = 1,
                    basis = Draft.newRowBasis(draft, side, trips),
                    state = side == "outputs" and "included" or nil,
                }
                state.pages[side] = math.ceil(#rows / ROWS_PER_PAGE)
            end,
        })
    end

    -- ---- The table ----
    if #rows == 0 then
        page:AddText({ text = side == "outputs" and "No outputs yet." or "No supplies yet.", colour = Style.muted, marginTop = 6 })
    else
        MethodEditor.table(page, state, side, tools, first, last)
    end

    -- Page controls.
    if pages > 1 then
        local function turn(step)
            return change(function()
                state.pages[side] = state.pages[side] + step
            end)
        end

        if state.pages[side] > 1 then
            page:AddSimpleButton("Previous", turn(-1), { width = 100, height = 28 })
        end

        page:AddText({ text = "Page " .. state.pages[side] .. " of " .. pages, inline = state.pages[side] > 1,
            width = 110, height = 28, colour = Style.muted, alignHorizontal = ui.AlignMode.CENTRE })

        if state.pages[side] < pages then
            page:AddSimpleButton("Next", turn(1), { width = 100, height = 28, inline = true })
        end
    end

    -- Source drops that aren't in the activity (left out at the limit, or removed),
    -- most valuable first, so the player can bring them back.
    if side == "outputs" and draft.source then
        local missing = Draft.missingSourceRows(draft)

        if #missing > 0 then
            table.sort(missing, function(left, right)
                return Draft.valuePerAction(left, state.quotes) > Draft.valuePerAction(right, state.quotes)
            end)

            page:AddTitle({ text = "Not included from " .. draft.source.title .. " (" .. #missing .. ")", marginTop = 10 })

            for position = 1, math.min(#missing, MISSING_SHOWN) do
                local row = missing[position]
                local worth = Draft.valuePerAction(row, state.quotes)

                page:AddSimpleButton("Add back", change(function()
                    if #rows >= limit then
                        state.message = "Outputs are full. Remove one first."
                        return
                    end

                    rows[#rows + 1] = row
                    state.pages.outputs = math.ceil(#rows / ROWS_PER_PAGE)
                end), { width = 90, height = 28 })

                page:AddText({
                    text = row.label .. (worth > 0 and ("  (about " .. Style.number(worth, worth < 10 and 1 or 0)
                        .. " GP " .. perWhat(draft) .. ")") or ""),
                    inline = true, width = 420, height = 28, colour = Style.muted,
                })
            end

            if #missing > MISSING_SHOWN then
                page:AddText({ text = "...and " .. (#missing - MISSING_SHOWN) .. " more, worth less.", colour = Style.muted })
            end
        end
    end
end

-- Rows first..last of a side as one table, drawn like the activity page's item
-- tables: a shaded heading band, then alternately shaded rows with item icons.
function MethodEditor.table(page, state, side, tools, first, last)
    local draft = state.draft
    local guarded, change, updatePreview = tools.guarded, tools.change, tools.updatePreview
    local rows = draft[side]
    local columns = tableColumns(side)
    -- Rows with an hourly line are taller (see ROW_HEIGHT).
    local hasHourly = draft.category ~= "recurring"
    local rowHeight = hasHourly and ROW_HEIGHT or SHORT_ROW_HEIGHT
    local rowStep = rowHeight + ROW_GAP
    local height = TABLE_TOP + (last - first + 1) * rowStep + 6
    local panel = tools.fitter:add(page:AddPanel({ height = height, scrollable = false, marginTop = 6 }), height)

    -- Column headings on a shaded band, like the activity page.
    Style.rectangle(panel, { x = 12, y = 4, width = -24, widthAnchor = 1, height = 28, colour = 0x39372EFF })

    local function heading(text, column, tooltip)
        panel:AddText({
            text = text, x = column.x, xAnchor = column.x < 0 and 1 or 0, y = 6,
            width = column.width > 0 and column.width or 200, height = 24, colour = Style.muted, tooltip = tooltip,
        })
    end

    heading("Item", { x = 20, width = 200 })
    heading("Qty", columns.quantity)
    heading("Counted", columns.per)
    heading("Price each", columns.price, side == "outputs"
        and "Starts at the GE Price Library's instant-sell price (before tax). Type your own to use it instead; clear the box to go back to the live price."
        or "Starts at the GE Price Library's instant-buy price. Type your own to use it instead; clear the box to go back to the live price.")

    if columns.include then
        heading("Include", columns.include)
    end

    -- "Each trip" is only offered while the player banks between trips.
    local trips = draft.category ~= "recurring" and tripsOn(state)

    for index = first, last do
        local row = rows[index]
        local y = TABLE_TOP + (index - first) * rowStep

        -- Everything on the right is centred on the row's middle: 28-tall boxes
        -- and buttons at `control`, 24-tall labels at `middle`.
        local centre = y + math.floor(rowHeight / 2)
        local control = centre - 14
        local middle = centre - 12

        Style.rectangle(panel, {
            x = 12, y = y, width = -24, widthAnchor = 1, height = rowHeight,
            colour = (index - first) % 2 == 1 and 0x292A25FF or 0x24251FFF,
        })

        -- The item's icon (a coin for a custom item, which is just GP), centred too.
        if row.item_id then
            ItemIcon.add(panel, row.item_id, { x = 14, y = centre - 20 }, row.label)
        else
            Style.coins(panel, { x = 22, y = centre - 12, size = 24 })
        end

        -- Name: only a custom item's can be changed; items and drops keep theirs.
        -- The name is centred on the icon, like everything else in the row; the
        -- small hourly line hangs just below it (see further down).
        local nameBottom

        if row.custom then
            panel:AddTextField({
                text = row.label, maxLength = CustomMethods.LIMITS.label, x = columns.name.x, y = control,
                width = columns.name.width, widthAnchor = 1, height = 28,
                onChange = guarded(function(_, _, text)
                    row.label = text
                    updatePreview()
                end),
            })

            -- Tucked just under the box, so the line still fits in the row.
            nameBottom = control + 26
        elseif hasHourly then
            -- One line, centred on the icon, so the hourly line fits underneath.
            panel:AddText({ text = row.label, x = columns.name.x, y = middle, width = columns.name.width, widthAnchor = 1,
                height = 24 })

            nameBottom = middle + 22
        else
            -- No hourly line: two lines' room, so a long name wraps instead of running on.
            panel:AddText({ text = row.label, x = columns.name.x, y = y + 2, width = columns.name.width, widthAnchor = 1,
                height = rowHeight - 4 })
        end

        -- Include (outputs only): drops can be switched on and off, with the
        -- drop's note (e.g. "Only on a Slayer task") on hover; a drop the Wiki
        -- gave no number for waits for one. Rows you added always count.
        local countedLabel

        if columns.include then
            local column = columns.include

            if row.state == "needs" then
                countedLabel = panel:AddText({ text = "Needs qty", x = column.x, xAnchor = 1, y = middle,
                    width = column.width, height = 24, colour = Style.bad })
            elseif fromSource(row) then
                panel:AddSimpleButton(row.state == "off" and "Off" or "On", change(function()
                    row.state = row.state == "off" and "included" or "off"
                end), { x = column.x, xAnchor = 1, y = control, width = column.width, height = 28,
                    active = row.state ~= "off", tooltip = row.note })
            else
                countedLabel = panel:AddText({ text = "Yes", x = column.x, xAnchor = 1, y = middle,
                    width = column.width, height = 24, colour = Style.muted })
            end
        end

        -- The small grey line under the item's name: what this row comes to an
        -- hour (see hourlyText). It's in the smaller font so it reads as a note,
        -- not a second name. Typing a quantity updates it in place. Daily/weekly
        -- rows are just "each run", so they don't get one.
        local hourly

        if hasHourly then
            hourly = Style.setFont(panel:AddText({
                text = hourlyText(row, draft), x = columns.name.x, y = nameBottom,
                width = columns.name.width, widthAnchor = 1, height = HOURLY_HEIGHT, colour = Style.muted,
            }), HOURLY_FONT)
        end

        -- Quantity: a number, or a drop chance like 1/50. Typing one into a row
        -- that needs it starts counting it.
        tools.numberField(panel, {
            text = numberText(row.quantity), placeholder = "Qty", maxLength = 16,
            x = columns.quantity.x, xAnchor = 1, y = control, width = columns.quantity.width, height = 28,
        }, "rate", function(text)
            local value = parseNumber(text, true)
            row.quantity = value

            if value and row.state == "needs" then
                row.state = "included"
            elseif not value and row.state == "included" and side == "outputs" then
                row.state = "needs"
            end

            if countedLabel then
                countedLabel.content = row.state == "needs" and "Needs qty" or (fromSource(row) and "On" or "Yes")
                countedLabel.rgba = row.state == "needs" and Style.bad or Style.muted
            end

            if hourly then
                hourly.content = hourlyText(row, draft)
            end

            updatePreview()
        end)

        -- Price each, always editable. A GE item's box starts at the live GE
        -- price; typing another price uses yours instead, and clearing the box
        -- (or typing the live price) goes back to the live one. Anything else
        -- (coins, a charm, a custom item) is its own GP value.
        if row.pricing == "ge" then
            local live = gePrice(state.quotes[row.item_id], side)

            tools.numberField(panel, {
                text = numberText(row.price or live), placeholder = live and numberText(live) or "No price",
                maxLength = 14, x = columns.price.x, xAnchor = 1, y = control, width = columns.price.width, height = 28,
            }, "decimal", function(text)
                local value = parseNumber(text)

                if text == "" or value == nil or value == live then
                    row.price = nil
                else
                    row.price = value
                end

                updatePreview()
            end)
        else
            tools.numberField(panel, {
                text = numberText(row.unit_value), placeholder = "GP each", maxLength = 14,
                x = columns.price.x, xAnchor = 1, y = control, width = columns.price.width, height = 28,
            }, "decimal", function(text)
                row.unit_value = parseNumber(text)
                updatePreview()
            end)
        end

        if draft.category == "recurring" then
            panel:AddText({ text = basisLabel(row.basis, draft), x = columns.per.x, xAnchor = 1, y = middle,
                width = columns.per.width, height = 24, colour = Style.muted })
        else
            -- Cycles each kill/action -> each trip -> each hour, skipping
            -- "Each trip" when the player doesn't bank between trips.
            panel:AddSimpleButton(basisLabel(row.basis, draft), change(function()
                local position = 1

                for candidate, basis in ipairs(BASES) do
                    if basis == row.basis then
                        position = candidate
                    end
                end

                repeat
                    position = position % #BASES + 1
                until trips or BASES[position] ~= "trip"

                row.basis = BASES[position]
            end), { x = columns.per.x, xAnchor = 1, y = control, width = columns.per.width, height = 28 })
        end

        Style.iconButton(panel, "trash", "Remove", "Remove " .. row.label, change(function()
            table.remove(rows, index)
        end), { right = -columns.remove.x - columns.remove.width, y = control })
    end
end

-- ---- Requirements tab -------------------------------------------------------------

local function checkText(check)
    if check.kind == "skill" then
        return check.level .. " " .. CustomMethods.skillName(check.skill)
    elseif check.kind == "combat_level" then
        return "Combat level " .. check.level
    elseif check.kind == "quest" then
        return "Quest: " .. check.name
    elseif check.kind == "item" then
        return (check.quantity > 1 and (Style.number(check.quantity) .. " x ") or "") .. check.name
    elseif check.kind == "items" then
        local names = {}

        for index, item in ipairs(check.items) do
            names[index] = item.name
        end

        return check.name .. (check.mode == "any" and " (any one of: " or " (all of: ") .. table.concat(names, ", ") .. ")"
    end

    return "Note: " .. check.text .. " (you check this yourself)"
end

function MethodEditor.requirements(page, state, tools)
    local draft = state.draft
    local guarded, change = tools.guarded, tools.change
    local requirements = draft.requirements
    local total = #requirements.required + #requirements.recommended
    local optional = draft.category == "production" or draft.category == "recurring"

    page:AddText({
        text = optional
            and "Production and daily/weekly activities need a Required level, quest or item, or \"No requirements needed\"."
            or "PvM and Skilling activities need at least one Required level, quest or item. Notes don't count: the game can't check them.",
        colour = Style.muted,
    })

    if optional then
        page:AddSimpleButton("No requirements needed", change(function()
            draft.no_requirements = not draft.no_requirements or nil
        end), { width = 220, height = 30, active = draft.no_requirements == true })
    end

    -- ---- The add form (above the lists) ----
    if total >= CustomMethods.LIMITS.requirements then
        page:AddText({ text = "The list is full (" .. CustomMethods.LIMITS.requirements .. "). Remove one to add another.",
            colour = Style.bad })
    else
        page:AddText({ text = "Add to", colour = Style.gold, width = 60, height = 28, marginTop = 6 })

        page:AddSimpleButton("Required", change(function()
            state.target = "required"
        end), { width = 120, height = 28, inline = true, active = state.target == "required" })

        page:AddSimpleButton("Recommended", change(function()
            state.target = "recommended"
        end), { width = 140, height = 28, inline = true, active = state.target == "recommended" })

        local function add(check)
            local list = requirements[state.target]
            list[#list + 1] = check
        end

        -- A skill level: click a skill's icon (its name shows on hover and
        -- beside the level box), then type the level.
        page:AddText({ text = "Skill level (pick a skill, then type the level)", colour = Style.gold, marginTop = 6 })

        local skills = CustomMethods.SKILLS
        local lines = math.ceil(#skills / SKILL_COLUMNS)
        local gridHeight = lines * (SKILL_BUTTON + 4) + 8
        local grid = tools.fitter:add(page:AddPanel({ height = gridHeight, scrollable = false }), gridHeight)
        local skillButtons = {}
        local chosenLabel

        -- Picking only changes which icon is lit and the name shown, in place.
        local function choose(skill)
            state.skill = skill

            for id, skillButton in pairs(skillButtons) do
                skillButton:SetActive(id == skill)
            end

            chosenLabel.content = skill and CustomMethods.skillName(skill) or "No skill picked yet"
            chosenLabel.rgba = skill and Style.text or Style.muted
        end

        for index, skill in ipairs(skills) do
            local name = CustomMethods.skillName(skill)
            local sprite = Style.spriteId("skill_" .. skill:lower())
            local column = (index - 1) % SKILL_COLUMNS
            local line = (index - 1) // SKILL_COLUMNS

            -- The icon, or the skill's name if this client has no icon for it.
            skillButtons[skill] = grid:AddSimpleButton(sprite or name, guarded(function()
                choose(skill)
            end), {
                x = 8 + column * (SKILL_BUTTON + 4), y = 4 + line * (SKILL_BUTTON + 4),
                width = SKILL_BUTTON, height = SKILL_BUTTON, iconSize = 28, tooltip = name,
                active = state.skill == skill,
            })
        end

        chosenLabel = page:AddText({ text = "", width = 170, height = 28 })

        local levelField = tools.numberField(page, {
            text = "", placeholder = "Level", maxLength = 3, width = 80, height = 28, inline = true, most = 120,
        }, "whole")

        page:AddSimpleButton("Add level", change(function()
            local level = tonumber(levelField:GetText())

            if not state.skill then
                state.message = "Pick a skill's icon first."
            elseif not (level and level == math.floor(level) and level >= 1 and level <= 120) then
                state.message = "Enter a level from 1 to 120."
            else
                add({ kind = "skill", skill = state.skill, level = level })
                state.skill = nil
            end
        end), { width = 110, height = 28, inline = true })

        choose(state.skill)

        -- Combat level.
        page:AddText({ text = "Combat level", colour = Style.gold, marginTop = 6 })
        local combatField = tools.numberField(page, {
            text = "", placeholder = "Combat level", maxLength = 3, width = 200, height = 28, most = 152,
        }, "whole")

        page:AddSimpleButton("Add combat level", change(function()
            local level = tonumber(combatField:GetText())

            if level and level == math.floor(level) and level >= 3 and level <= 152 then
                add({ kind = "combat_level", level = level })
            else
                state.message = "Enter a combat level from 3 to 152."
            end
        end), { width = 160, height = 28, inline = true })

        -- An item to have: set how many, then pick the item from the search.
        page:AddText({ text = "Item (set how many, then pick the item)", colour = Style.gold, marginTop = 6 })

        local quantityField = tools.numberField(page, { text = "1", placeholder = "How many", maxLength = 9, width = 90, height = 30 },
            "whole")

        itemSearch(page, state, tools, "requirement", {
            placeholder = "Search for an item", width = 300, inline = true,
            hint = "Type an item's name, then pick it here to add it.",
            pick = function(item)
                local quantity = tonumber(quantityField:GetText())

                if not (quantity and quantity == math.floor(quantity) and quantity >= 1) then
                    quantity = 1
                end

                add({ kind = "item", item_id = item.id, name = item.label, quantity = quantity })
            end,
        })

        -- A note the player checks themselves.
        page:AddText({ text = "Anything else (a note you check yourself)", colour = Style.gold, marginTop = 6 })

        local noteField = page:AddTextField({
            text = "", placeholder = "e.g. Ring of wealth equipped", maxLength = CustomMethods.LIMITS.requirementNote,
            width = 360, height = 28,
        })

        page:AddSimpleButton("Add note", change(function()
            local text = (noteField:GetText() or ""):match("^%s*(.-)%s*$")

            if text ~= "" then
                add({ kind = "note", text = text })
            end
        end), { width = 100, height = 28, inline = true })
    end

    -- ---- What's been added: remove button on the left, wording wrapping to
    -- the right of it ----
    for _, group in ipairs({ { id = "required", label = "Required" }, { id = "recommended", label = "Recommended" } }) do
        page:AddTitle({ text = group.label, marginTop = 10 })

        if #requirements[group.id] == 0 then
            page:AddText({ text = "None.", colour = Style.muted })
        end

        for index, check in ipairs(requirements[group.id]) do
            local text = checkText(check)

            Style.iconButton(page, "trash", "Remove", "Remove " .. text, change(function()
                table.remove(requirements[group.id], index)
            end), "line")

            page:AddText({ text = text, inline = true, width = 520, height = wrappedHeight(text, 520),
                colour = check.kind == "note" and Style.muted or Style.text })
        end
    end
end

return MethodEditor
