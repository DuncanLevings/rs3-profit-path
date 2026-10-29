-- Draws the workbench's sidebar, filters and method list. This file owns three
-- child views; its cleanup runs before ui.lua destroys the parent screen.
-- Browser state and money calculations live elsewhere, so repainting is cheap.
local Style = require("src/ui/view_style")
local BrowseView = {}

local categories = {
    { id = "all", label = "All activities" },
    { id = "pvm", label = "PvM" },
    { id = "skilling", label = "Skilling" },
    { id = "production", label = "Production" },
}

local sortEntries = {
    { id = 1, label = "Profit" }, { id = 2, label = "ROI" },
    { id = 3, label = "Difficulty" }, { id = 4, label = "Intensity" },
}

-- Native combo entries need integer IDs. Keep those UI-only numbers separate
-- from the readable strings used in saved settings and browser logic.
local sortNames = { "profit", "roi", "difficulty", "intensity" }
local sortIDs = { profit = 1, roi = 2, difficulty = 3, intensity = 4 }

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

    local roi = estimate.roi and string.format(" | %.1f%% ROI", estimate.roi) or ""

    return string.format("%.0f GP/hour%s | %.0f %s", estimate.profit, roi, estimate.rate, method.income.rate.unit)
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
    local selectionOwners = {}

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

        for _, owner in ipairs(selectionOwners) do
            Event.Logic.Unsubscribe(owner)
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
            x = 190, y = 150, width = -190, height = -150,
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
            local row = results:AddPanel({ height = 96, scrollable = false, marginBottom = 8 })

            -- Reserve the right column for profit. Anchored offsets let the title
            -- shrink with the window without running underneath the figure.
            row:AddTitle({ text = name, x = 42, y = 6, width = -232, widthAnchor = 1, height = 28, colour = browser.category == "all" and (Style.categories[method.category] or Style.text) or Style.text })
            if available then
                Style.icon(row, "coins", { x = -210, xAnchor = 1, y = 10, size = 20 })
            end

            row:AddTitle({
                text = Style.compact(available and estimate.profit or nil),
                x = -184, xAnchor = 1, y = 6, width = 174, height = 28,
                colour = available and estimate.profit < 0 and Style.bad or Style.gold,
                tooltip = estimateText(method, estimate),
            })

            row:AddText({
                text = method.source_category,
                x = 10, y = 36, width = -236, widthAnchor = 1, height = 24, colour = Style.muted,
            })

            if available and estimate.roi then
                row:AddText({ text = Style.number(estimate.roi, 1) .. "% ROI", x = -184, xAnchor = 1, y = 36, width = 174, height = 24, colour = Style.muted })
            end
            local activity = "Intensity: " .. method.intensity

            if method.difficulty then
                activity = activity .. "  /  Difficulty: " .. method.difficulty
            end

            row:AddText({
                text = activity,
                x = 10, y = 62, width = -102, widthAnchor = 1, height = 24, colour = Style.muted,
            })

            row:AddSpriteButton("ARROW_RIGHT", rowAction(function()
                browser.scroll = results.scrollY
                openMethod(method)
            end), { x = -38, xAnchor = 1, y = 62, size = 24, tooltip = "View method" })

            local favouriteText = browser.favourites[method.id] and "Remove favourite" or "Add favourite"
            row:AddSpriteButton("STAR", rowAction(function()
                browser.scroll = results.scrollY
                browser:toggleFavourite(method)
                renderResults()
            end), { x = 10, y = 8, size = 24, tooltip = favouriteText, toggleable = true, disabled = not browser.favourites[method.id] })

        end

        results:AddText({ text = "RuneScape Wiki contributors / CC BY-NC-SA 3.0. GEPL trade estimates may use old trades.", colour = Style.muted })
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
            x = 190, y = 0, width = -190, height = 144, widthAnchor = 1, scrollable = false,
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

        -- Reconcile the final native selection once after event delivery. Reading
        -- it inside the hook can see the previous selection on this client.
        local function dropdown(entries, selectedID, x, changed)
            local control = ui.List.new(header.content)
            control.stylesheetID = id.StyleSheet.DROPDOWN_DEFAULT
            control:SetPos(x, 90)
            control:SetSize(158, 30)
            control.dropdownMaxVisibleEntries = #entries

            for _, entry in ipairs(entries) do
                assert(control:Add(entry.label, entry.id), "Could not add sort option")
            end

            control:SetEntrySelected(selectedID, true)
            local owner = "profit-path-sort-" .. x
            selectionOwners[#selectionOwners + 1] = owner

            control:Subscribe(ui.Hook.ONSELECTIONCHANGED, guarded(function()
                if closed then
                    return
                end

                -- Repeated clicks replace the same pending callback. This is not
                -- a poller: unsubscribe before reading or rebuilding any controls.
                Event.Logic.Unsubscribe(owner)
                Event.Logic.Subscribe(owner, function()
                    Event.Logic.Unsubscribe(owner)
                    guarded(function()
                        if not closed then
                            for _, entry in pairs(control.selectedEntries) do
                                changed(entry.id)
                                break
                            end
                        end
                    end)()
                end)
            end))

            return control
        end

        -- Restoring a failed save can emit another native event. Compare against
        -- the selected model first so that notification cannot save in a loop.
        sortControl = dropdown(sortEntries, sortIDs[browser.sort], 10, function(selectedID)
            if selectedID == sortIDs[browser.sort] then
                return
            end

            if not browser:setSort(sortNames[selectedID], browser.descending) then
                sortControl:SetEntrySelected(sortIDs[browser.sort], true)
            end
            renderResults()
        end)

        directionControl = dropdown({
            { id = 1, label = "Highest first" }, { id = 2, label = "Lowest first" },
        }, browser.descending and 1 or 2, 180, function(selectedID)
            if selectedID == (browser.descending and 1 or 2) then
                return
            end

            if not browser:setSort(browser.sort, selectedID == 1) then
                directionControl:SetEntrySelected(browser.descending and 1 or 2, true)
            end
            renderResults()
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
