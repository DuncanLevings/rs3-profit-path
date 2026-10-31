-- Draws the workbench's sidebar, filters and method list. This file owns three
-- child views; its cleanup runs before workbench.lua destroys the parent screen.
-- Browser state and money calculations live elsewhere, so repainting is cheap.
local Browser = require("src/methods/browser")
local Recommendations = require("src/methods/recommendations")
local Dropdown = require("src/ui/dropdown")
local Style = require("src/ui/view_style")
local BrowseView = {}

local categories = {
    { id = "all", label = "All activities" },
    { id = "pvm", label = "PvM" },
    { id = "skilling", label = "Skilling" },
    { id = "production", label = "Production" },

    -- Daily/weekly methods, counted per run rather than per hour.
    { id = "recurring", label = "Recurring" },
}

-- Native dropdown entries need integer IDs. Keep those UI-only numbers separate
-- from the readable strings used in saved settings and browser logic. IDs count
-- from 0 in list order (see dropdown.lua for why).
local sortEntries = { { id = 0, label = "Profit" }, { id = 1, label = "ROI" } }
local sortNames = { [0] = "profit", [1] = "roi" }
local sortIDs = { profit = 0, roi = 1 }

-- Direction: entry 0 is "Highest first" (descending), entry 1 "Lowest first".
local directionEntries = { { id = 0, label = "Highest first" }, { id = 1, label = "Lowest first" } }

local function directionID(descending)
    return descending and 0 or 1
end

-- Filter dropdowns: entry 0 is "Any", then one entry per level. A caption above
-- each dropdown says which filter it is, so the entries don't need to repeat it.
-- `values[id]` turns the picked ID back into the browser's filter value.
local function filterEntries(levels)
    local entries = { { id = 0, label = "Any" } }
    local values = { [0] = "any" }

    for index, level in ipairs(levels) do
        entries[#entries + 1] = { id = index, label = level }
        values[index] = level
    end

    return entries, values
end

local difficultyEntries, difficultyValues = filterEntries(Browser.difficultyLevels)
local intensityEntries, intensityValues = filterEntries(Browser.intensityLevels)

-- Keep readiness separate from profit: missing requirements do not erase an
-- estimate. Unknown checks stay in All; they are not treated as missing.
local readinessEntries = {
    { id = 0, label = "All" }, { id = 1, label = "Met" },
    { id = 2, label = "Missing" },
}
local readinessValues = { [0] = "any", [1] = "met", [2] = "unmet" }

-- The reverse of `values`: which entry ID shows this filter value ("Any" if
-- somehow it isn't in the list).
local function entryFor(values, value)
    for entryId, candidate in pairs(values) do
        if candidate == value then
            return entryId
        end
    end

    return 0
end

-- Each control is 130 interface units wide. On narrow windows the three filters
-- share a second row, keeping Requirements beside Intensity without clipping.
local DROPDOWN_WIDTH = 130
local DROPDOWN_STEP = 140
local GROUP_GAP = 24

-- Method rows: a fill a little lighter than the page so each row reads as its
-- own card, and the width of the activity-coloured bar on its left edge. Row
-- content starts ROW_INSET in from the left so it clears the bar.
local ROW_FILL = 0x2B2923FF
local ROW_ACCENT_WIDTH = 4

-- Recommend for me's activity strip: where its row of settings "chips" starts,
-- and the chips' size.
local STRIP_TOP = 50
local CHIP_HEIGHT = 24
local CHIP_GAP = 8
local CHIP_FILL = 0x3D3A32FF
local ROW_INSET = 16

-- Browse shows results a page at a time. Each row is a panel with several native
-- parts (and PrettyUI builds every tooltip up front), and the full catalogue has
-- hundreds of methods. 25 rows could take the client past its one-second limit
-- for a single callback; 10 stays well inside it.
local PAGE_SIZE = 10

-- Recommend for me and My account aren't lists of methods: they have no search
-- box, sort or filters, and their page takes the whole column.
local function isList(section)
    return section == "browse" or section == "favourites"
end

-- A button just wide enough for the longest of `labels` (measured in the button
-- font, so the client never clips one), so a set of choices lines up.
local function buttonWidth(labels)
    local widest = 0

    for _, label in ipairs(labels) do
        widest = math.max(widest, Style.textWidth(label))
    end

    return math.ceil(widest) + 40
end

-- Typing in the search box waits for a pause before redrawing the list: one
-- redraw for "steel", not five. Logic ticks come 50 times a second, so 12 ticks
-- is about a quarter of a second. Enter searches straight away.
local SEARCH_SETTLE_TICKS = 12
local SEARCH_EVENT = "profit-path-search"

-- Recommend for me: the activity tiles (two per row), the suggestion card's
-- layout, and Show another's pause (25 logic ticks is half a second).
local TILE_HEIGHT = 110
local TILE_GAP = 12
local CARD_INSET = 20
local CARD_MIN_HEIGHT = 300
local FACT_HEIGHT = 28
local FACT_LABEL_WIDTH = 130
local FIND_EVENT = "profit-path-recommend"
local FIND_TICKS = 25

-- A missing estimate is not zero GP/hour. Keep the reason next to the method so
-- nobody mistakes a partial source model for an unprofitable activity.
local function estimateText(method, estimate)
    if method.income.coverage ~= "complete" then
        return "Income model incomplete"
    end

    if not estimate then
        return "Price unavailable - reopen the window to check again"
    end

    if estimate.status ~= "available" then
        return "Prices or costs unavailable - open Income for details"
    end

    -- The row already shows the profit and ROI, so the tooltip only adds the rate
    -- the estimate assumes, e.g. "580 logs/hour" or "2,000 smelts/hour", and any
    -- output with no price that was counted as 0.
    local text = Style.number(estimate.rate) .. " " .. method.income.rate.unit

    if estimate.note then
        text = text .. ". " .. estimate.note
    end

    return text
end

-- `guarded` checks the screen's lifetime. Row callbacks also check a local
-- generation because searching replaces rows without replacing the whole screen.
function BrowseView.mount(library, view, browser, guarded, openMethod)
    local sidebar, header, results
    local rowGeneration = 0
    local closed = false
    local sortControl, directionControl
    local heading
    local sectionButtons, categoryButtons = {}, {}

    -- The accent bar inside each activity button (see renderResults).
    local categoryBars = {}
    local renderResults, showSection
    local buildHeader, dropHeader

    -- release() functions for pending callbacks (the dropdowns' and the search
    -- box's), so nothing fires after the screen is gone.
    local dropdownReleases = {}

    -- The same for the header's dropdowns alone, so My account can drop the
    -- header without closing the whole screen.
    local headerReleases = {}

    -- Ticks since the last keystroke while a search is waiting; nil when not.
    local searchQuietTicks

    local wrapFilters = view.content.width - 190 < 734
    local headerHeight = wrapFilters and 202 or 144
    local resultsY = headerHeight + 6

    -- Slots 0/1 sort; slots 2/3/4 filter. Only filters wrap on small windows.
    local function slotX(slot)
        if wrapFilters and slot >= 2 then
            return 10 + (slot - 2) * DROPDOWN_STEP
        end

        return 10 + slot * DROPDOWN_STEP + (slot >= 2 and GROUP_GAP or 0)
    end

    local function captionY(slot)
        return wrapFilters and slot >= 2 and 138 or 80
    end

    local function dropdownY(slot)
        return captionY(slot) + 24
    end

    -- Difficulty only rates PvM, so its filter only shows on All activities and
    -- PvM. `headerDifficulty` remembers whether the built header has it.
    local headerDifficulty

    local function showsDifficulty()
        return browser.category == "all" or browser.category == "pvm"
    end

    -- Invalidate row clicks before tearing down their native targets.
    local function clearResults()
        rowGeneration = rowGeneration + 1

        if results then
            results:Destroy()
            results = nil
        end
    end

    -- Called both on normal navigation and if construction fails halfway through.
    local function destroy()
        if closed then
            return
        end

        closed = true

        for _, release in ipairs(dropdownReleases) do
            release()
        end

        for _, release in ipairs(headerReleases) do
            release()
        end

        -- Keep the list's scroll position, so a rebuild (e.g. after the window is
        -- resized) lands where the player was.
        if results then
            browser.scroll = results.scrollY
        end

        clearResults()

        if header then
            header:Destroy()
        end

        if sidebar then
            sidebar:Destroy()
        end
    end

    -- One choice on its own row: a button, and a line saying what it means. The
    -- chosen one (if any) gets the gold "active" look. Rows are sized by `fitter`.
    local function choiceRow(fitter, width, label, about, active, action, colour)
        local row = fitter:add(results:AddPanel({ height = 40, scrollable = false, marginBottom = 4 }), 40)

        row:AddSimpleButton(label, action, {
            x = 0, y = 4, width = width, height = 32, active = active, colour = colour,
        })

        row:AddText({
            text = about, x = width + 12, y = 6, width = -(width + 12), widthAnchor = 1, height = 28,
            maxLines = 1, colour = Style.muted,
        })

        return row
    end

    -- The ten PvM comfort levels, shared by My account and the first PvM
    -- recommendation, each with a few examples. `changed` redraws after a save.
    local function comfortChoices(fitter, rowAction, changed)
        local recommendations = browser.recommendations
        local settings = recommendations:settings()
        local labels = {}

        for index, level in ipairs(Recommendations.comfortLevels) do
            labels[index] = Recommendations.comfortName(level)
        end

        local width = buttonWidth(labels)

        for _, level in ipairs(Recommendations.comfortLevels) do
            choiceRow(fitter, width, Recommendations.comfortName(level), Recommendations.comfortAbout[level],
                settings.comfort == level, rowAction(function()
                    recommendations:setComfort(level)
                    changed()
                end))
        end
    end

    -- Show another's short "finding another" pause: logic ticks left, or nil
    -- when there's no pause running. It's there so a new suggestion feels like
    -- one, rather than the card just blinking.
    local findingTicks

    local function stopFinding()
        if findingTicks then
            findingTicks = nil
            Event.Logic.Unsubscribe(FIND_EVENT)
        end
    end

    dropdownReleases[#dropdownReleases + 1] = stopFinding

    -- Starts the pause; the next suggestion is drawn when it runs out.
    local function startFinding()
        stopFinding()
        findingTicks = FIND_TICKS

        Event.Logic.Subscribe(FIND_EVENT, guarded(function()
            if closed or not findingTicks then
                stopFinding()
                return
            end

            findingTicks = findingTicks - 1

            if findingTicks <= 0 then
                stopFinding()
                renderResults()
            end
        end))
    end

    -- A text label that clicks pass through, so a tile's words don't steal the
    -- click from the tile's button underneath.
    local function overlayText(parent, options)
        local label = parent:AddText(options)
        label.clickthrough = true
        return label
    end

    -- Recommend for me: pick an activity, then one suggestion at a time. The
    -- recommender (src/methods/recommendations.lua) decides what to show; this
    -- only draws it. Back from a method comes straight back to the same card.
    local function drawRecommend(rowAction)
        local recommendations = browser.recommendations
        local fitter = Style.panelFitter(results, 10)

        results:AddTitle({ text = "Recommend for me", colour = Style.gold, height = 32 })

        local function redraw()
            renderResults()
        end

        -- A failed save, say.
        local function showMessage()
            if recommendations.message then
                results:AddText({ text = recommendations.message, colour = Style.bad })
            end
        end

        -- 1. No activity yet: a 2x2 grid of big tiles. Each tile is one button
        -- the size of the tile, with its own label hidden (fully transparent) and
        -- a large title and a description drawn on top.
        if not recommendations.activity then
            results:AddText({ text = "What do you feel like doing?", height = 30 })
            showMessage()

            -- The list has 10 padding on each side; two tiles and a gap fill it.
            local width = math.floor((results.content.width - 20 - TILE_GAP) / 2)

            for first = 1, #Recommendations.activities, 2 do
                local row = fitter:add(results:AddPanel({
                    height = TILE_HEIGHT, scrollable = false, marginBottom = TILE_GAP,
                }), TILE_HEIGHT)

                for offset = 0, 1 do
                    local activity = Recommendations.activities[first + offset]

                    if activity then
                        local x = offset * (width + TILE_GAP)

                        row:AddSimpleButton(activity.label, rowAction(function()
                            recommendations:choose(activity.id)
                            redraw()
                        end), { x = x, y = 0, width = width, height = TILE_HEIGHT, colour = 0x00000000, shadowed = false })

                        Style.setFont(overlayText(row, {
                            text = activity.label, x = x, y = 22, width = width, height = 40,
                            alignHorizontal = ui.AlignMode.CENTRE, colour = Style.categories[activity.id] or Style.text,
                        }), "CINZEL_25PT_BOLD_MULTILINE", "CINZEL_18PT_BOLD")

                        overlayText(row, {
                            text = activity.about, x = x + 12, y = 66, width = width - 24, height = 26,
                            alignHorizontal = ui.AlignMode.CENTRE, maxLines = 1, colour = Style.muted,
                        })
                    end
                end
            end

            fitter:fit()
            return
        end

        local activity = recommendations.activity
        local settings = recommendations:settings()

        local asking = recommendations:needsComfort()

        -- The settings this suggestion follows, shown as chips so it's never a
        -- mystery. None while PvM is still asking for a comfort level.
        local chips = {}

        if not asking then
            if activity == "pvm" then
                chips[#chips + 1] = "Up to " .. Recommendations.comfortName(settings.comfort)

                if settings.learning then
                    chips[#chips + 1] = "Learning opportunities"
                end
            end

            chips[#chips + 1] = Recommendations.groupLabel(settings.group)
        end

        -- Lay the chips out first, left to right, wrapping onto another row when
        -- one won't fit, so the strip can be made at its final height and a
        -- narrow window never loses a chip.
        local chipRoom = results.content.width - 20 - CARD_INSET * 2
        local chipX, chipY = 0, 0
        local placed = {}

        for _, text in ipairs(chips) do
            local width = math.ceil(Style.textWidth(text)) + 20

            if chipX > 0 and chipX + width > chipRoom then
                chipX, chipY = 0, chipY + CHIP_HEIGHT + 6
            end

            placed[#placed + 1] = { text = text, x = chipX, y = chipY, width = width }
            chipX = chipX + width + CHIP_GAP
        end

        local stripHeight = #placed > 0 and (STRIP_TOP + chipY + CHIP_HEIGHT + 12) or 52

        -- The activity strip: one filled bar with the activity's name big on the
        -- left and the two ways out (another activity, or the settings) on the
        -- right, with the chips on their own row underneath.
        local colour = Style.categories[activity] or Style.text
        local strip = fitter:add(results:AddPanel({
            height = stripHeight, scrollable = false, marginBottom = 10,
        }), stripHeight)

        Style.rectangle(strip, {
            x = 0, y = 0, width = 0, height = 0, widthAnchor = 1, heightAnchor = 1, colour = ROW_FILL,
        })

        Style.rectangle(strip, { x = 0, y = 0, width = ROW_ACCENT_WIDTH, height = 0, heightAnchor = 1, colour = colour })

        -- Both buttons the same width, side by side, level with the name.
        local buttonsWidth = buttonWidth({ "Change activity", "Preferences" })

        strip:AddSimpleButton("Change activity", rowAction(function()
            stopFinding()
            recommendations:changeActivity()
            redraw()
        end), { x = -(buttonsWidth * 2 + 22), xAnchor = 1, y = 10, width = buttonsWidth, height = 32 })

        strip:AddSimpleButton("Preferences", rowAction(function()
            showSection("account")
        end), { x = -(buttonsWidth + 14), xAnchor = 1, y = 10, width = buttonsWidth, height = 32 })

        Style.setFont(strip:AddTitle({
            text = Recommendations.activityLabel(activity), x = CARD_INSET, y = 11, widthAnchor = 1,
            width = -(buttonsWidth * 2 + 22 + CARD_INSET + 12), height = 30, maxLines = 1, colour = colour,
        }), "CINZEL_18PT_BOLD")

        for _, chip in ipairs(placed) do
            local x, y = CARD_INSET + chip.x, STRIP_TOP + chip.y

            Style.rectangle(strip, { x = x, y = y, width = chip.width, height = CHIP_HEIGHT, colour = CHIP_FILL })

            strip:AddText({
                text = chip.text, x = x, y = y + 1, width = chip.width, height = CHIP_HEIGHT - 2,
                alignHorizontal = ui.AlignMode.CENTRE, maxLines = 1, colour = Style.text,
            })
        end

        -- 2. The first PvM request asks how much bossing the player has done.
        -- Nothing else asks this; it's saved, and My account can change it.
        if asking then
            results:AddText({ text = "How much bossing have you done? Suggestions go up to this level.", height = 30 })
            showMessage()
            comfortChoices(fitter, rowAction, redraw)
            results:AddText({ text = "You can change this any time in My account.", colour = Style.muted })
            fitter:fit()
            return
        end

        -- Show another's pause: a spinner where the card goes. The next
        -- suggestion is only picked once it ends.
        if findingTicks then
            local waiting = fitter:add(results:AddPanel({ height = CARD_MIN_HEIGHT, scrollable = false, marginBottom = 8 }), CARD_MIN_HEIGHT)

            Style.rectangle(waiting, {
                x = 0, y = 0, width = 0, height = 0, widthAnchor = 1, heightAnchor = 1, colour = ROW_FILL,
            })

            waiting:AddSpinner({ x = -36, xAnchor = 0.5, y = math.floor(CARD_MIN_HEIGHT / 2) - 56, size = 72 })

            waiting:AddText({
                text = "Finding another...", x = 0, y = math.floor(CARD_MIN_HEIGHT / 2) + 24, width = 0, widthAnchor = 1,
                height = 26, alignHorizontal = ui.AlignMode.CENTRE, colour = Style.muted,
            })

            fitter:fit()
            return
        end

        local entry, pool, skipped, replaced = recommendations:suggestion()
        showMessage()

        -- Don't recommend has an immediate Undo; a suggestion that stopped
        -- matching (a requirement read as missing, a setting changed) says so.
        if recommendations.notice then
            local notice = recommendations.notice.method
            local undoWidth = buttonWidth({ "Undo" })
            local row = fitter:add(results:AddPanel({ height = 40, scrollable = false, marginBottom = 4 }), 40)

            row:AddText({
                text = notice.title .. (notice.variant and " - " .. notice.variant or "") .. " won't be recommended.",
                x = 0, y = 6, width = -(undoWidth + 10), widthAnchor = 1, height = 28, maxLines = 1, colour = Style.muted,
            })

            row:AddSimpleButton("Undo", rowAction(function()
                recommendations:undo()
                redraw()
            end), { x = -undoWidth, xAnchor = 1, y = 4, width = undoWidth, height = 32 })
        elseif replaced then
            results:AddText({
                text = replaced.title .. " doesn't match any more, so here's another.", colour = Style.muted,
            })
        end

        -- 3. Nothing matches: say why, in the player's terms.
        if not entry then
            results:AddTitle({ text = "Nothing matches right now", height = 30, marginTop = 8 })

            local reasons = {}

            local function reason(count, text)
                if count > 0 then
                    reasons[#reasons + 1] = count .. " " .. text
                end
            end

            reason(skipped.missing, "need something you don't have yet")
            reason(skipped.comfort, "are harder than your PvM comfort")
            reason(skipped.group, "are group activities (you chose solo only)")
            reason(skipped.unprofitable, "lose money at today's prices")
            reason(skipped.hidden, "you chose not to recommend (My account lists them)")

            results:AddText({
                text = #reasons > 0 and ("Of the " .. Recommendations.activityLabel(activity) .. " activities, "
                    .. table.concat(reasons, "; ") .. ".")
                    or ("There are no " .. Recommendations.activityLabel(activity) .. " activities yet."),
            })

            fitter:fit()
            return
        end

        -- 4. The suggestion card. Profit is the headline; the title is next; the
        -- facts sit underneath as "label  value" rows. Everything is placed from a
        -- running y, worked out first so the card is made at its final height.
        local method = entry.method
        local colour = Style.categories[method.category] or Style.text
        local estimate = entry.estimate

        local facts = {
            { "Requirements", entry.unchecked and "Not checked yet - open your bank once" or "Met",
                entry.unchecked and Style.gold or Style.good },
        }

        -- The ladder level with its name, and how it eases once practised. A
        -- method the ladder doesn't cover yet just shows its band.
        if method.difficulty_level then
            local level = method.difficulty_level
            local text = level .. " of 10: " .. Recommendations.comfortLabels[level]

            if method.farm_level < level then
                text = text .. "  (" .. method.farm_level .. " once practised)"
            end

            facts[#facts + 1] = { "Difficulty", text, Style.text }
        elseif method.difficulty then
            facts[#facts + 1] = { "Difficulty", method.difficulty, Style.text }
        end

        facts[#facts + 1] = { "Group", method.team or "Solo", Style.text }

        -- The Wiki's risk warning is too long for the card; the activity page has
        -- it in full.
        if method.warning then
            facts[#facts + 1] = { "Warning", "The Wiki flags risks: read them on the activity's page", Style.bad }
        end
        facts[#facts + 1] = { "Intensity", method.intensity, Style.text }

        local layout = {}
        local y = 14

        local function place(key, height, gap)
            layout[key] = y
            y = y + height + (gap or 0)
        end

        if entry.learning then
            place("learning", 24, 4)
        end

        place("title", 34, 0)

        if method.variant then
            place("variant", 24, 0)
        end

        place("profit", 54, 0)
        place("unit", 22, 12)
        place("divider", 1, 12)
        place("facts", #facts * FACT_HEIGHT, 16)
        place("buttons", 34, 16)

        local height = math.max(CARD_MIN_HEIGHT, y)
        local card = fitter:add(results:AddPanel({ height = height, scrollable = false, marginBottom = 8 }), height)

        Style.rectangle(card, {
            x = 0, y = 0, width = 0, height = 0, widthAnchor = 1, heightAnchor = 1, colour = ROW_FILL,
        })

        Style.rectangle(card, { x = 0, y = 0, width = ROW_ACCENT_WIDTH, height = 0, heightAnchor = 1, colour = colour })

        -- Only a learning opportunity is labelled; within comfort is the normal case.
        if entry.learning then
            card:AddText({
                text = "Learning opportunity: one step harder than your comfort",
                x = CARD_INSET, y = layout.learning, width = -CARD_INSET, widthAnchor = 1, height = 24, colour = Style.gold,
            })
        end

        Style.setFont(card:AddTitle({
            text = method.title, x = CARD_INSET, y = layout.title, width = -CARD_INSET * 2, widthAnchor = 1,
            height = 34, maxLines = 1, colour = colour,
        }), "CINZEL_18PT_BOLD")

        if method.variant then
            card:AddText({
                text = method.variant, x = CARD_INSET, y = layout.variant, width = -CARD_INSET * 2, widthAnchor = 1,
                height = 24, maxLines = 1, colour = Style.muted,
            })
        end

        -- The headline: a coin and the profit, as big as the client draws text.
        -- Gold "Not estimated" when it can't be priced (green is only for money).
        local profitX = CARD_INSET

        if estimate then
            Style.coins(card, { x = CARD_INSET, y = layout.profit + 8, size = 38 })
            profitX = CARD_INSET + 48
        end

        local profitText = "Not estimated"

        if estimate then
            -- "6.9m": the unit goes on its own line underneath.
            profitText = Style.compact(estimate.profit):gsub(" / .*$", "")
        end

        Style.setFont(card:AddText({
            text = profitText, x = profitX, y = layout.profit, width = -(profitX + CARD_INSET), widthAnchor = 1,
            height = 54, maxLines = 1, colour = estimate and Style.good or Style.gold,
        }), "CINZEL_35PT_BOLD", Style.HEADLINE_FONT)

        card:AddText({
            text = estimate and (method.income.period == "run" and "profit per run" or "profit per hour")
                or "Prices or costs are missing; open the activity for details",
            x = profitX, y = layout.unit, width = -(profitX + CARD_INSET), widthAnchor = 1, height = 22, colour = Style.muted,
        })

        Style.rectangle(card, {
            x = CARD_INSET, y = layout.divider, width = -CARD_INSET * 2, widthAnchor = 1, height = 1, colour = 0x655638FF,
        })

        for index, fact in ipairs(facts) do
            local factY = layout.facts + (index - 1) * FACT_HEIGHT

            card:AddText({ text = fact[1], x = CARD_INSET, y = factY, width = FACT_LABEL_WIDTH, height = FACT_HEIGHT, colour = Style.muted })
            card:AddText({
                text = fact[2], x = CARD_INSET + FACT_LABEL_WIDTH, y = factY, width = -(CARD_INSET * 2 + FACT_LABEL_WIDTH),
                widthAnchor = 1, height = FACT_HEIGHT, maxLines = 1, colour = fact[3],
            })
        end

        -- View method, Show another (only with something else to show) and
        -- Don't recommend. Show another changes no settings.
        local x = CARD_INSET

        local function button(text, action, disabled)
            local width = buttonWidth({ text })
            card:AddSimpleButton(text, rowAction(action), {
                x = x, y = layout.buttons, width = width, height = 34, disabled = disabled,
            })
            x = x + width + 10
        end

        button("View activity", function()
            openMethod(method)
        end)

        button("Show another", function()
            recommendations:showAnother()
            startFinding()
            redraw()
        end, #pool < 2)

        button("Don't recommend", function()
            recommendations:dontRecommend(method)
            redraw()
        end)

        fitter:fit()
    end

    -- My account: who the settings belong to, Recommend for me's settings and
    -- the methods kept out of it, each with Recommend again. `rowAction` guards
    -- the buttons the same way as the method rows. No search or filters here.
    local function drawAccount(rowAction)
        local fitter = Style.panelFitter(results, 10)
        local recommendations = browser.recommendations

        results:AddTitle({ text = "My account", colour = Style.gold, height = 32 })
        results:AddTitle({ text = "Profile", height = 30, marginTop = 8 })

        -- Settings follow the character's name; no tracking ID is read.
        local profile = browser:profileInfo()
        local who = profile.character
            and ("Signed in as " .. profile.character .. ". ")
            or "No character is signed in yet. "

        results:AddText({
            text = who .. "Rates, favourites and hidden activities are saved under the profile \""
                .. (profile.profile or "Default") .. "\".",
            colour = Style.muted,
        })

        if browser.message then
            results:AddText({ text = browser.message, colour = Style.bad })
        end

        -- A change redraws in place, keeping the scroll position.
        local function changed()
            browser.scroll = results.scrollY
            renderResults()
        end

        if recommendations.message then
            results:AddText({ text = recommendations.message, colour = Style.bad })
        end

        local settings = recommendations:settings()

        results:AddTitle({ text = "PvM comfort", height = 30, marginTop = 12 })
        results:AddText({
            text = settings.comfort and "The hardest level, 1 to 10, that Recommend for me suggests."
                or "Not set yet: Recommend for me asks the first time you pick PvM.",
            colour = Style.muted,
        })

        comfortChoices(fitter, rowAction, changed)

        -- Learning opportunities: the level above comfort, labelled as such.
        local learnLabels = { "Show", "Don't show" }
        local learnWidth = buttonWidth(learnLabels)

        results:AddText({ text = "Harder learning opportunities (one step above your comfort)", marginTop = 6 })

        for index, label in ipairs(learnLabels) do
            local learning = index == 1

            choiceRow(fitter, learnWidth, label,
                learning and "Suggested after the bosses within your comfort, and labelled." or "Only bosses within your comfort.",
                settings.learning == learning, rowAction(function()
                    recommendations:setLearning(learning)
                    changed()
                end))
        end

        -- Solo and group, for every activity (Croesus is a group skilling boss).
        results:AddTitle({ text = "Solo and group", height = 30, marginTop = 12 })

        local groupLabels = {}

        for index, choice in ipairs(Recommendations.groupChoices) do
            groupLabels[index] = choice.label
        end

        local groupWidth = buttonWidth(groupLabels)

        for _, choice in ipairs(Recommendations.groupChoices) do
            choiceRow(fitter, groupWidth, choice.label, choice.about, settings.group == choice.id, rowAction(function()
                recommendations:setGroup(choice.id)
                changed()
            end))
        end

        local hidden = browser:hiddenMethods()

        results:AddTitle({ text = "Not recommended", height = 30, marginTop = 12 })
        results:AddText({
            text = #hidden == 0
                and "Nothing here. \"Don't recommend\" on a recommendation keeps that activity out of Recommend for me."
                or "Recommend for me skips these. They still show in Browse and Favourites.",
            colour = Style.muted,
        })

        -- The button fits its measured label, so the client's font never clips it.
        local restoreWidth = math.ceil(Style.textWidth("Recommend again")) + 40

        for _, entry in ipairs(hidden) do
            local method = entry.method
            local row = fitter:add(results:AddPanel({ height = 44, scrollable = false, marginBottom = 4 }), 44)

            Style.rectangle(row, {
                x = 0, y = 0, width = 0, height = 0, widthAnchor = 1, heightAnchor = 1,
                colour = ROW_FILL,
            })

            -- A saved ID this version of the plugin doesn't have still gets a row,
            -- so it can always be restored.
            local text = method
                and (method.title .. (method.variant and " - " .. method.variant or ""))
                or (entry.id .. " (not in this version)")

            row:AddText({
                text = text, x = ROW_INSET, y = 8, width = -(ROW_INSET + restoreWidth + 20), widthAnchor = 1, height = 28,
                maxLines = 1, colour = method and (Style.categories[method.category] or Style.text) or Style.muted,
            })

            row:AddSimpleButton("Recommend again", rowAction(function()
                browser.scroll = results.scrollY
                browser:setHidden(entry.id, false)
                renderResults()
            end), { x = -(restoreWidth + 10), xAnchor = 1, y = 8, width = restoreWidth, height = 28 })
        end

        fitter:fit()
        results:SetScrollPosition(browser.scroll)
    end

    -- These are interface units, not physical pixels. The right column stretches
    -- with the window; the narrow sidebar and header stay separate from list scroll.
    local function drawResults()
        local generation = rowGeneration

        -- Recommend for me and My account have no header, so they take the whole column.
        local top = isList(browser.section) and resultsY or 0

        results = library.SimpleView.new(view.content, {
            x = 190, y = top, width = -190, height = -top,
            widthAnchor = 1, heightAnchor = 1, scrollable = true,
            layout = { startY = 8, padding = 10, rowGap = 8 },
        })

        -- Rebuilt results have their own lifetime even though the header survives.
        local function rowAction(callback)
            return guarded(function(...)
                if not closed and generation == rowGeneration then
                    callback(...)
                end
            end)
        end

        local rows = browser:rows()

        -- Keep the page in range (a search may have shrunk the list), then show
        -- only that page's slice of the sorted results.
        local pages = math.max(1, math.ceil(#rows / PAGE_SIZE))
        browser.page = math.min(math.max(browser.page or 1, 1), pages)
        local first = (browser.page - 1) * PAGE_SIZE + 1
        local last = math.min(#rows, browser.page * PAGE_SIZE)

        -- Rows are sized to the list's final width once they're all added (see
        -- Style.panelFitter: a scrollbar may appear partway through). The list's
        -- side padding is 10.
        local fitter = Style.panelFitter(results, 10)
        local headings = {}

        if heading then
            heading.content = browser.section == "favourites" and "Favourites" or "Browse activities"
        end

        -- Only the page you're on (Browse, Favourites...) gets the gold native
        -- toggle frame. The activity is a filter on that page, so it's marked
        -- differently: the chosen one in its own colour with a matching bar on
        -- its left edge, the rest muted. Two gold frames looked like two pages
        -- open at once.
        for section, button in pairs(sectionButtons) do
            button:SetActive(browser.section == section)
        end

        for category, button in pairs(categoryButtons) do
            local chosen = browser.category == category

            -- PrettyUI reapplies textColour whenever the button's state updates.
            local colour = Style.categories[category] or Style.text
            button.textColour = chosen and colour or Style.muted
            button:SetActive(false)

            -- The bar is always there; it's see-through (alpha 0) when not chosen.
            categoryBars[category].rgba = chosen and colour or (colour & 0xFFFFFF00)
        end

        -- My account and Recommend for me aren't lists, so they draw their own page.
        if browser.section == "account" then
            drawAccount(rowAction)
            return
        end

        if browser.section == "recommend" then
            drawRecommend(rowAction)
            return
        end

        results:AddText({
            text = #rows .. " matching activities" .. (pages > 1 and ("  /  showing " .. first .. "-" .. last) or ""),
            colour = Style.muted, height = 26,
        })

        if browser.message then
            results:AddText({ text = browser.message, colour = Style.bad })
        end

        if #rows == 0 then
            results:AddTitle("No matching activities")
            results:AddText("Try another activity or search. Add favourites from Browse to keep them here.")
        end

        for index = first, last do
            local method = rows[index]
            local estimate = browser.estimates[method.id]
            local available = estimate and estimate.status == "available"
            local row = fitter:add(results:AddPanel({ height = 96, scrollable = false, marginBottom = 8 }), 96)

            -- Titles always take their activity colour (PvM red, skilling green,
            -- production blue), whichever activity filter is selected, so a
            -- method looks the same in every list.
            local titleColour = Style.categories[method.category] or Style.text

            -- Make each row stand out from the page: a slightly lighter fill, plus
            -- a thin bar down the left edge in the activity colour. Drawn first so
            -- they sit behind the text and buttons.
            Style.rectangle(row, {
                x = 0, y = 0, width = 0, height = 0, widthAnchor = 1, heightAnchor = 1,
                colour = ROW_FILL,
            })

            Style.rectangle(row, {
                x = 0, y = 0, width = ROW_ACCENT_WIDTH, height = 0, heightAnchor = 1,
                colour = titleColour,
            })

            -- Reserve the right column for profit. Anchored offsets let the title
            -- shrink with the window without running underneath the figure. Keep
            -- these labels tooltip-free: PrettyUI eagerly builds 11 components
            -- per tooltip, which exhausted the native IDs on a full Browse page.
            local title = row:AddTitle({
                text = method.title, x = ROW_INSET + 32, y = 6,
                width = -238, widthAnchor = 1, height = 28, colour = titleColour,
            })

            if method.variant then
                -- A smaller, neutral suffix keeps the method name easy to scan.
                -- Fit both labels once the card has its final scrollbar-aware width.
                local variantText = " - " .. method.variant
                local variant = row:AddText({
                    text = variantText, x = ROW_INSET + 32, y = 6,
                    width = 0, height = 28, maxLines = 1, colour = Style.muted,
                })
                Style.setFont(variant, "MUSEO_SANS_11PT_REGULAR")
                headings[#headings + 1] = { row = row, title = title, variant = variant,
                    titleText = method.title, variantText = variantText }
            end

            -- Profit reads "[coin] 1.2M / H": coin at the start of the right
            -- column, the figure straight after it, both centred on one line.
            -- No estimate means no coin, so "Not estimated" starts at the edge.
            local profitX = -184

            if available then
                Style.coins(row, { x = profitX, xAnchor = 1, y = Style.middle(6, 28, 20), size = 20 })
                profitX = profitX + 24
            end

            -- Same money colours as the method page: green for a profit, red for
            -- a loss. Gold is only left for "Not estimated", which isn't money.
            local profitColour = Style.gold

            if available then
                profitColour = estimate.profit < 0 and Style.bad or Style.good
            end

            row:AddTitle({
                text = Style.compact(available and estimate.profit or nil, method.income.period == "run" and "run" or "h"),
                x = profitX, xAnchor = 1, y = 6, width = -10 - profitX, height = 28,
                colour = profitColour,
                tooltip = estimateText(method, estimate),
            })

            -- A recurring method says how often it can be done.
            local recurrence = method.income.recurrence

            row:AddText({
                text = method.source_category .. (recurrence and ("  /  every " .. recurrence.every) or ""),
                x = ROW_INSET, y = 36, width = -242, widthAnchor = 1, height = 24, colour = Style.muted,
            })

            -- Keep the sign colour, but let the profit figure take visual priority.
            if available and estimate.roi then
                row:AddText({
                    text = Style.number(estimate.roi, 1) .. "% ROI",
                    x = -184, xAnchor = 1, y = 36, width = 174, height = 24,
                    colour = estimate.roi < 0 and Style.subtleBad or Style.subtleGood,
                })
            end

            -- Difficulty is only shown when the source rates it; we never guess one.
            local activity = "Intensity: " .. method.intensity

            if method.difficulty then
                activity = activity .. "  /  Difficulty: " .. method.difficulty
                    .. (method.difficulty_level and (" " .. method.difficulty_level .. "/10") or "")
            end

            if method.warning then
                activity = activity .. "  /  Wiki warning"
            end

            local isHidden = browser.hidden[method.id] == true

            if isHidden then
                activity = activity .. "  /  Not recommended"
            end

            row:AddText({
                text = activity,
                x = ROW_INSET, y = 62, width = -108, widthAnchor = 1, height = 24, colour = Style.muted,
            })

            row:AddSpriteButton("ARROW_RIGHT", rowAction(function()
                browser.scroll = results.scrollY
                openMethod(method)
            end), { x = -38, xAnchor = 1, y = 62, size = 24, tooltip = "View activity" })

            -- A method kept out of Recommend for me gets a dimmed eye, which puts
            -- it back. Other rows get nothing: an eye on every row would read as
            -- "hide this row", and "Don't recommend" belongs on recommendations.
            if isHidden then
                row:AddSpriteButton("EYE", rowAction(function()
                    browser.scroll = results.scrollY
                    browser:setHidden(method.id, false)
                    renderResults()
                end), {
                    x = -68, xAnchor = 1, y = 62, size = 24, toggleable = true, disabled = true,
                    tooltip = "Not recommended - click to recommend again",
                })
            end

            -- The star toggle: lit when it's a favourite. "disabled" here is
            -- PrettyUI's unlit toggle state; the button can still be clicked.
            local isFavourite = browser.favourites[method.id]
            local favouriteText = isFavourite and "Remove favourite" or "Add favourite"

            row:AddSpriteButton("STAR", rowAction(function()
                browser.scroll = results.scrollY
                browser:toggleFavourite(method)
                renderResults()
            end), { x = ROW_INSET, y = 8, size = 24, tooltip = favouriteText, toggleable = true, disabled = not isFavourite })
        end

        -- Page controls under the list. A new page starts at its top.
        if pages > 1 then
            local function turn(step)
                return rowAction(function()
                    browser.page = browser.page + step
                    browser.scroll = 0
                    renderResults()
                end)
            end

            if browser.page > 1 then
                results:AddSimpleButton("Previous page", turn(-1), { width = 130, height = 30 })
            end

            results:AddText({
                text = "Page " .. browser.page .. " of " .. pages, inline = browser.page > 1,
                width = 120, height = 30, colour = Style.muted, alignHorizontal = ui.AlignMode.CENTRE,
            })

            if browser.page < pages then
                results:AddSimpleButton("Next page", turn(1), { width = 130, height = 30, inline = true })
            end
        end

        results:AddText({ text = "RuneScape Wiki contributors / CC BY-NC-SA 3.0. GEPL trade estimates may use old trades.", colour = Style.muted })
        fitter:fit()

        -- Title and variant share only the space before the profit column. Long
        -- names clip independently; neither overlaps money. The method page has
        -- the full title, so we don't need another tooltip for every list label.
        for _, entry in ipairs(headings) do
            local x, gap = ROW_INSET + 32, 8
            local room = math.max(0, entry.row.content.width - x - 196)
            local variantWidth = math.min(Style.textWidth(entry.variantText) + 4, room * 0.4)
            local titleWidth = math.min(Style.textWidth(entry.titleText, true) + 4,
                math.max(0, room - variantWidth - gap))

            entry.title:SetSize(titleWidth, 28, 0, 0)
            entry.variant:SetPos(x + titleWidth + gap, 6)
            entry.variant:SetSize(math.max(0, room - titleWidth - gap), 28, 0, 0)
        end

        results:SetScrollPosition(browser.scroll)
    end

    -- Search and sort can rebuild after the initial mount has finished. Clean up
    -- a failed rebuild too; don't leave half a list with working stale controls.
    renderResults = function()
        clearResults()

        local ok, failure = pcall(drawResults)

        if not ok then
            clearResults()
            error(failure, 0)
        end
    end

    -- Filter changes start at the top. Opening a method does not reset this state.
    local function filterChanged()
        browser.scroll = 0
        browser.page = 1
        renderResults()
    end

    -- Stops waiting for a pause in typing.
    local function stopSearchWait()
        if searchQuietTicks then
            searchQuietTicks = nil
            Event.Logic.Unsubscribe(SEARCH_EVENT)
        end
    end

    dropdownReleases[#dropdownReleases + 1] = stopSearchWait

    -- Each keystroke restarts the countdown; the list redraws once it runs out.
    local function searchTyped()
        local waiting = searchQuietTicks ~= nil
        searchQuietTicks = 0

        if waiting then
            return
        end

        Event.Logic.Subscribe(SEARCH_EVENT, guarded(function()
            if closed then
                stopSearchWait()
                return
            end

            searchQuietTicks = searchQuietTicks + 1

            if searchQuietTicks >= SEARCH_SETTLE_TICKS then
                stopSearchWait()
                filterChanged()
            end
        end))
    end

    local ok, failure = pcall(function()
        -- A continuous backdrop and divider tie navigation to the window edge.
        Style.rectangle(view, { x = 0, y = 0, width = 174, height = 0, heightAnchor = 1, colour = 0x24231FFF })
        Style.rectangle(view, { x = 172, y = 0, width = 2, height = 0, heightAnchor = 1, colour = 0x655638FF })

        sidebar = library.SimpleView.new(view.content, {
            x = 0, y = 0, width = 174, height = 0, heightAnchor = 1,
            layout = { startY = 10, padding = 8, rowGap = 8 },
        })

        -- Switches the sidebar section. Only a move between a list (Browse,
        -- Favourites) and a page (Recommend for me, My account) touches the
        -- header; Browse <-> Favourites keeps it (and the search text).
        function showSection(section)
            stopFinding()
            local wasList = isList(browser.section)
            browser.section = section

            if wasList and not isList(section) then
                dropHeader()
            elseif isList(section) and not wasList then
                buildHeader()
            end

            filterChanged()
        end

        sidebar:AddText({ text = "FIND AN ACTIVITY", colour = Style.muted, height = 26 })
        sectionButtons.browse = sidebar:AddSimpleButton("Browse", guarded(function()
            showSection("browse")
        end), { width = 158, height = 32 })

        -- Recommend for me always opens on the activity choice. (Back from a
        -- method doesn't come through here, so it keeps its suggestion.)
        sectionButtons.recommend = sidebar:AddSimpleButton("Recommend for me", guarded(function()
            stopFinding()
            browser.recommendations:changeActivity()
            showSection("recommend")
        end), { width = 158, height = 32 })

        sectionButtons.favourites = sidebar:AddSimpleButton("Favourites", guarded(function()
            showSection("favourites")
        end), { width = 158, height = 32 })

        sectionButtons.account = sidebar:AddSimpleButton("My account", guarded(function()
            showSection("account")
        end), { width = 158, height = 32 })

        sidebar:AddText({ text = "ACTIVITIES", colour = Style.muted, marginTop = 18, height = 26 })

        for _, category in ipairs(categories) do
            categoryButtons[category.id] = sidebar:AddSimpleButton(category.label, guarded(function()
                browser.category = category.id

                -- Skilling, Production and Recurring have no Difficulty filter, so
                -- a difficulty picked on PvM mustn't quietly empty them.
                if not showsDifficulty() then
                    browser.difficulty = "any"
                end

                -- An activity is a list filter, so from a page it opens Browse.
                -- On a list, the header is rebuilt when Difficulty comes or goes.
                if not isList(browser.section) then
                    showSection("browse")
                else
                    if header and headerDifficulty ~= showsDifficulty() then
                        dropHeader()
                        buildHeader()
                    end

                    filterChanged()
                end
            end), { width = 158, height = 32, colour = Style.categories[category.id] or Style.text })

            -- A thin bar down the button's left edge, lit for the chosen activity.
            -- It's a plain rectangle, so it costs one native part per button.
            local bar = ui.Rectangle.new(categoryButtons[category.id].root)
            bar:SetPos(5, 6, 0, 0)
            bar:SetSize(4, -12, 0, 1)
            bar.fill = true
            bar.clickthrough = true
            bar.rgba = (Style.categories[category.id] or Style.text) & 0xFFFFFF00
            categoryBars[category.id] = bar
        end

        -- The header: heading, search box, sort and filter dropdowns. My account
        -- has no use for any of it, so it's built only for the method lists, and
        -- dropped (with the dropdowns' pending callbacks) on the way into My account.
        buildHeader = function()
            header = library.SimpleView.new(view.content, {
                x = 190, y = 0, width = -190, height = headerHeight, widthAnchor = 1, scrollable = false,
            })

            heading = header:AddTitle({ text = "Browse activities", x = 10, y = 4, height = 32, colour = Style.gold })
            header:AddTextField({
                text = browser.search, placeholder = "Search activities", maxLength = 100,
                x = 10, y = 44, width = -20, widthAnchor = 1, height = 30,
                onChange = guarded(function(_, _, text)
                    browser.search = text
                    searchTyped()
                end),

                -- Enter doesn't wait for the pause.
                onSubmit = guarded(function(_, text)
                    browser.search = text
                    stopSearchWait()
                    filterChanged()
                end),
            })

            -- Small captions over the dropdowns, in the same muted capitals as the
            -- sidebar headings: one "Sort by" over the sort pair, one per filter.
            header:AddText({ text = "SORT BY", x = slotX(0), y = captionY(0), width = DROPDOWN_STEP * 2, height = 22, colour = Style.muted })
            header:AddText({ text = "INTENSITY", x = slotX(2), y = captionY(2), width = DROPDOWN_WIDTH, height = 22, colour = Style.muted })
            header:AddText({ text = "REQUIREMENTS", x = slotX(3), y = captionY(3), width = DROPDOWN_WIDTH, height = 22, colour = Style.muted })

            headerDifficulty = showsDifficulty()

            if headerDifficulty then
                header:AddText({ text = "DIFFICULTY", x = slotX(4), y = captionY(4), width = DROPDOWN_WIDTH, height = 22, colour = Style.muted })
            end

            -- A divider separates sorting from filtering when they share a row.
            if not wrapFilters then
                local dividerX = slotX(1) + DROPDOWN_WIDTH + math.floor((slotX(2) - slotX(1) - DROPDOWN_WIDTH) / 2) - 1
                Style.rectangle(header, { x = dividerX, y = captionY(0), width = 2, height = 54, colour = 0x655638FF })
            end

            -- One dropdown in the row. `slot` is its place in the row (0 = leftmost);
            -- dropdown.lua handles the client's selection quirks.
            local function dropdown(entries, selectedID, slot, changed)
                local control, release = Dropdown.new(header.content, {
                    x = slotX(slot),
                    y = dropdownY(slot),
                    width = DROPDOWN_WIDTH,
                    entries = entries,
                    selected = selectedID,
                    owner = "profit-path-dropdown-" .. slot,
                    guarded = guarded,
                    onChange = changed,
                    isClosed = function()
                        return closed
                    end,
                })

                headerReleases[#headerReleases + 1] = release

                return control
            end

            -- Restoring a failed save can emit another native event. Compare against
            -- the selected model first so that notification cannot save in a loop.
            sortControl = dropdown(sortEntries, sortIDs[browser.sort], 0, function(selectedID)
                if selectedID == sortIDs[browser.sort] or not sortNames[selectedID] then
                    return
                end

                if not browser:setSort(sortNames[selectedID], browser.descending) then
                    sortControl:SetEntrySelected(sortIDs[browser.sort], true)
                end

                renderResults()
            end)

            directionControl = dropdown(directionEntries, directionID(browser.descending), 1, function(selectedID)
                if selectedID == directionID(browser.descending) then
                    return
                end

                if not browser:setSort(browser.sort, selectedID == directionID(true)) then
                    directionControl:SetEntrySelected(directionID(browser.descending), true)
                end

                renderResults()
            end)

            -- Filters aren't saved, so there's no failed write to undo here: just
            -- remember the choice and redraw from the top.
            dropdown(intensityEntries, entryFor(intensityValues, browser.intensity), 2, function(selectedID)
                local value = intensityValues[selectedID]

                if value and value ~= browser.intensity then
                    browser.intensity = value
                    filterChanged()
                end
            end)

            dropdown(readinessEntries, entryFor(readinessValues, browser.availability), 3, function(selectedID)
                local value = readinessValues[selectedID]

                if value and value ~= browser.availability then
                    browser.availability = value
                    filterChanged()
                end
            end)

            if headerDifficulty then
                dropdown(difficultyEntries, entryFor(difficultyValues, browser.difficulty), 4, function(selectedID)
                    local value = difficultyValues[selectedID]

                    if value and value ~= browser.difficulty then
                        browser.difficulty = value
                        filterChanged()
                    end
                end)
            end
        end

        dropHeader = function()
            for _, release in ipairs(headerReleases) do
                release()
            end

            headerReleases = {}
            stopSearchWait()

            if header then
                header:Destroy()
                header, heading = nil, nil
            end
        end

        if isList(browser.section) then
            buildHeader()
        end

        renderResults()
    end)

    if not ok then
        destroy()
        error(failure, 0)
    end

    -- The workbench's refresh, after account reads: redraw in place, keeping the
    -- player's scroll position (unlike a filter change, which starts at the top).
    local function refresh()
        if results then
            browser.scroll = results.scrollY
        end

        renderResults()
    end

    return destroy, refresh
end

return BrowseView
