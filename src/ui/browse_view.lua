-- Draws the workbench's sidebar, filters and method list. This file owns three
-- child views; its cleanup runs before ui.lua destroys the parent screen.
-- Browser state and money calculations live elsewhere, so repainting is cheap.
local Browser = require("src/methods/browser")
local Dropdown = require("src/ui/dropdown")
local Style = require("src/ui/view_style")
local BrowseView = {}

local categories = {
    { id = "all", label = "All activities" },
    { id = "pvm", label = "PvM" },
    { id = "skilling", label = "Skilling" },
    { id = "production", label = "Production" },
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
-- estimate, and unknown checks are a distinct filter rather than a failed check.
local readinessEntries = {
    { id = 0, label = "All" }, { id = 1, label = "Met" },
    { id = 2, label = "Missing" }, { id = 3, label = "Needs checking" },
}
local readinessValues = { [0] = "any", [1] = "met", [2] = "unmet", [3] = "unknown" }

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
local ROW_INSET = 16

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
    -- the estimate assumes, e.g. "580 logs/hour" or "2,000 smelts/hour".
    return Style.number(estimate.rate) .. " " .. method.income.rate.unit
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
    local renderResults
    -- release() functions for the dropdowns' pending change callbacks.
    local dropdownReleases = {}

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

    -- These are interface units, not physical pixels. The right column stretches
    -- with the window; the narrow sidebar and header stay separate from list scroll.
    local function drawResults()
        local generation = rowGeneration
        results = library.SimpleView.new(view.content, {
            x = 190, y = resultsY, width = -190, height = -resultsY,
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

        -- Rows are sized to the list's final width once they're all added (see
        -- Style.panelFitter: a scrollbar may appear partway through). The list's
        -- side padding is 10.
        local fitter = Style.panelFitter(results, 10)

        heading.content = browser.section == "favourites" and "Favourites" or "Browse methods"

        -- Only the active entry gets the gold native toggle treatment. Keep the
        -- section and category groups independent: both are filters at once.
        for section, button in pairs(sectionButtons) do
            button:SetActive(browser.section == section)
        end

        for category, button in pairs(categoryButtons) do
            button:SetActive(browser.category == category)
        end

        results:AddText({
            text = #rows .. " matching methods",
            colour = Style.muted, height = 26,
        })

        if browser.message then
            results:AddText({ text = browser.message, colour = Style.bad })
        end

        if #rows == 0 then
            results:AddTitle("No matching methods")
            results:AddText("Try another activity or search. Add favourites from Browse to keep them here.")
        end

        for _, method in ipairs(rows) do
            local estimate = browser.estimates[method.id]
            local available = estimate and estimate.status == "available"
            local name = method.title .. (method.variant and " - " .. method.variant or "")
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
            -- shrink with the window without running underneath the figure.
            row:AddTitle({ text = name, x = ROW_INSET + 32, y = 6, width = -238, widthAnchor = 1, height = 28, colour = titleColour })

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
                text = Style.compact(available and estimate.profit or nil),
                x = profitX, xAnchor = 1, y = 6, width = -10 - profitX, height = 28,
                colour = profitColour,
                tooltip = estimateText(method, estimate),
            })

            row:AddText({
                text = method.source_category,
                x = ROW_INSET, y = 36, width = -242, widthAnchor = 1, height = 24, colour = Style.muted,
            })

            if available and estimate.roi then
                row:AddText({
                    text = Style.number(estimate.roi, 1) .. "% ROI",
                    x = -184, xAnchor = 1, y = 36, width = 174, height = 24, colour = Style.muted,
                })
            end

            -- Difficulty is only shown when the source rates it; we never guess one.
            local activity = "Intensity: " .. method.intensity

            if method.difficulty then
                activity = activity .. "  /  Difficulty: " .. method.difficulty
            end

            row:AddText({
                text = activity,
                x = ROW_INSET, y = 62, width = -108, widthAnchor = 1, height = 24, colour = Style.muted,
            })

            row:AddSpriteButton("ARROW_RIGHT", rowAction(function()
                browser.scroll = results.scrollY
                openMethod(method)
            end), { x = -38, xAnchor = 1, y = 62, size = 24, tooltip = "View method" })

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

        results:AddText({ text = "RuneScape Wiki contributors / CC BY-NC-SA 3.0. GEPL trade estimates may use old trades.", colour = Style.muted })
        fitter:fit()
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
        renderResults()
    end

    local ok, failure = pcall(function()
        -- A continuous backdrop and divider tie navigation to the window edge.
        Style.rectangle(view, { x = 0, y = 0, width = 174, height = 0, heightAnchor = 1, colour = 0x24231FFF })
        Style.rectangle(view, { x = 172, y = 0, width = 2, height = 0, heightAnchor = 1, colour = 0x655638FF })

        sidebar = library.SimpleView.new(view.content, {
            x = 0, y = 0, width = 174, height = 0, heightAnchor = 1,
            layout = { startY = 10, padding = 8, rowGap = 8 },
        })

        sidebar:AddText({ text = "FIND A METHOD", colour = Style.muted, height = 26 })
        sectionButtons.browse = sidebar:AddSimpleButton("Browse", guarded(function()
            browser.section = "browse"
            filterChanged()
        end), { width = 158, height = 32 })

        sectionButtons.favourites = sidebar:AddSimpleButton("Favourites", guarded(function()
            browser.section = "favourites"
            filterChanged()
        end), { width = 158, height = 32 })

        sidebar:AddText({ text = "ACTIVITIES", colour = Style.muted, marginTop = 18, height = 26 })

        for _, category in ipairs(categories) do
            categoryButtons[category.id] = sidebar:AddSimpleButton(category.label, guarded(function()
                browser.category = category.id
                filterChanged()
            end), { width = 158, height = 32, colour = Style.categories[category.id] or Style.text })
        end

        header = library.SimpleView.new(view.content, {
            x = 190, y = 0, width = -190, height = headerHeight, widthAnchor = 1, scrollable = false,
        })

        heading = header:AddTitle({ text = "Browse methods", x = 10, y = 4, height = 32, colour = Style.gold })
        header:AddTextField({
            text = browser.search, placeholder = "Search methods", maxLength = 100,
            x = 10, y = 44, width = -20, widthAnchor = 1, height = 30,
            onChange = guarded(function(_, _, text)
                browser.search = text
                filterChanged()
            end),
        })

        -- Small captions over the dropdowns, in the same muted capitals as the
        -- sidebar headings: one "Sort by" over the sort pair, one per filter.
        header:AddText({ text = "SORT BY", x = slotX(0), y = captionY(0), width = DROPDOWN_STEP * 2, height = 22, colour = Style.muted })
        header:AddText({ text = "DIFFICULTY", x = slotX(2), y = captionY(2), width = DROPDOWN_WIDTH, height = 22, colour = Style.muted })
        header:AddText({ text = "INTENSITY", x = slotX(3), y = captionY(3), width = DROPDOWN_WIDTH, height = 22, colour = Style.muted })

        header:AddText({ text = "REQUIREMENTS", x = slotX(4), y = captionY(4), width = DROPDOWN_WIDTH, height = 22, colour = Style.muted })

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

            dropdownReleases[#dropdownReleases + 1] = release

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
        dropdown(difficultyEntries, entryFor(difficultyValues, browser.difficulty), 2, function(selectedID)
            local value = difficultyValues[selectedID]

            if value and value ~= browser.difficulty then
                browser.difficulty = value
                filterChanged()
            end
        end)

        dropdown(intensityEntries, entryFor(intensityValues, browser.intensity), 3, function(selectedID)
            local value = intensityValues[selectedID]

            if value and value ~= browser.intensity then
                browser.intensity = value
                filterChanged()
            end
        end)

        dropdown(readinessEntries, entryFor(readinessValues, browser.availability), 4, function(selectedID)
            local value = readinessValues[selectedID]

            if value and value ~= browser.availability then
                browser.availability = value
                filterChanged()
            end
        end)

        renderResults()
    end)

    if not ok then
        destroy()
        error(failure, 0)
    end

    return destroy, renderResults
end

return BrowseView
