-- Draws one method's screen: a header row plus four tabs (Income, Requirements,
-- How to do it, Getting there).
--
-- This file only draws. The maths, requirement checks and saving all happen in
-- the `calculator` from src/main.lua; we call it and show what it returns. Every
-- control is a child of the `view` passed in, so it all goes away on navigation.
--
-- One rule worth knowing: a refresh only changes label text and colours. It never
-- rebuilds controls, because rebuilding the rate box would kick the player's
-- cursor out of it mid-typing.
local Style = require("src/ui/view_style")
local ItemIcon = require("src/ui/item_icon")

local MethodView = {}

-- Height of the header row (Back, title, favourite) above the tabs.
local HEADER_HEIGHT = 48

-- PrettyUI's default side padding inside a tab page, and the space we leave
-- between the Inputs and Outputs tables.
local PAGE_PADDING = 14
local TABLE_GAP = 8

local itemDefinitions = require("data/methods").items

-- Which Requirements section each kind of check goes in.
local categories = { skill = "Skills", item = "Items", gear = "Items", quest = "Quests", capability = "Other" }

-- Picks the section for one requirement. An "any of these" group stays in one
-- piece: splitting it across sections would make it look like every alternative is
-- needed, not just one. A group that mixes kinds goes to Other.
local function categoryFor(definition)
    if definition.children then
        local category

        for _, child in ipairs(definition.children) do
            local childCategory = categoryFor(child)

            if category and category ~= childCategory then
                return "Other"
            end

            category = childCategory
        end

        return category or "Other"
    end

    return categories[definition.kind] or "Other"
end

-- Every skill (and perk) icon a requirement needs, in order, without repeats. For an
-- "any of these" skill group we show every option's icon, but keep the source's
-- original combined wording next to them, so "this OR that" never reads as "both".
local function requirementIcons(definition)
    local icons = {}
    local seen = {}

    local function collect(requirement)
        local icon = requirement.display_icon

        if requirement.kind == "skill" then
            icon = "skill_" .. requirement.skill:lower()
        end

        if icon and not seen[icon] then
            icons[#icons + 1] = icon
            seen[icon] = true
        end

        for _, child in ipairs(requirement.children or {}) do
            collect(child)
        end
    end

    collect(definition)

    return icons
end

-- Builds the Requirements tab, grouped like the Wiki. Two kinds of live feedback:
--   * text colour on each requirement: met / unmet / unknown (from skill levels)
--   * a border on each item icon: found in backpack, worn or bank / not found / can't tell
-- Returns two refresh functions: one for requirement text, one for item borders.
local function mountRequirements(parent, method, calculator)
    local groups = { Skills = {}, ["Required items"] = {}, ["Recommended items"] = {}, Quests = {}, Other = {} }

    -- Sort each top-level requirement into its section. Items split further into
    -- required (access) and recommended, because that difference matters most.
    for _, entry in ipairs({
        { definition = method.requirements.access, recommended = false },
        { definition = method.requirements.recommended, recommended = true },
    }) do
        for index, child in ipairs(entry.definition.children) do
            local category = categoryFor(child)

            if category == "Items" then
                category = entry.recommended and "Recommended items" or "Required items"
            end

            groups[category][#groups[category] + 1] = {
                definition = child,
                recommended = entry.recommended,
                index = index,
            }
        end
    end

    local updates = {}
    local borders = {}
    local wanted = {}

    -- Work out each section's height up front, since panels have fixed heights.
    -- Required and recommended items sit side by side when both exist, so they share
    -- the taller height. An empty item section is left out entirely and the other
    -- one takes the full width.
    local sections = {}
    local bothItems = #groups["Required items"] > 0 and #groups["Recommended items"] > 0
    local itemHeight = 0

    for _, category in ipairs({ "Skills", "Required items", "Recommended items", "Quests", "Other" }) do
        local entries = groups[category]
        local isItems = category == "Required items" or category == "Recommended items"
        local height = 38

        -- Item rows hold up to five 44px icons per line; text rows are 48px tall.
        for _, entry in ipairs(entries) do
            local icons = entry.definition.display_items
            entry.height = icons and (math.ceil(#icons / 5) * 44 + 8) or 48
            height = height + entry.height
        end

        if #entries == 0 then
            height = height + 28
        end

        if not isItems or #entries > 0 then
            sections[#sections + 1] = { category = category, entries = entries, height = height, isItems = isItems }
        end

        if isItems then
            itemHeight = math.max(itemHeight, height)
        end
    end

    for _, definition in ipairs(sections) do
        local category = definition.category
        local entries = definition.entries
        local options = { height = definition.height, scrollable = false, marginBottom = 6 }

        -- Side-by-side item sections: each takes half the width, minus a small gutter.
        if definition.isItems and bothItems then
            options.height = itemHeight
            options.width = -12
            options.widthAnchor = 0.5

            if category == "Recommended items" then
                options.inline = true
                options.x = 4
                options.xAnchor = 0.5
            end
        end

        local section = parent:AddPanel(options)
        section:AddText({ text = category, x = 12, y = 4, height = 26, colour = Style.gold })

        if #entries == 0 then
            local emptyText = method.requirements.coverage == "complete" and "None listed" or "Not listed in this sample"
            section:AddText({ text = emptyText, x = 12, y = 32, height = 24, colour = Style.muted })
        end

        local y = 34

        for _, entry in ipairs(entries) do
            local requirement = entry.definition
            local icons = requirement.display_items

            if icons then
                -- Item requirement: a grid of item icons. Each tooltip is just the
                -- item's name, and the border shows presence only. Owning an item
                -- doesn't prove you can use it, so we never claim that.
                for index, itemId in ipairs(icons) do
                    local x = 12 + ((index - 1) % 5) * 44
                    local iconY = y + math.floor((index - 1) / 5) * 44

                    local _, _, verified = ItemIcon.add(section, itemId, { x = x, y = iconY })
                    local border = Style.rectangle(section, { x = x, y = iconY, width = 40, height = 40, fill = false, colour = Style.muted })

                    -- Some items count under several IDs (charged or worn variants).
                    local aliases = itemDefinitions[tostring(itemId)].ownership_ids or { itemId }

                    for _, alias in ipairs(aliases) do
                        wanted[alias] = true
                    end

                    borders[#borders + 1] = { border = border, aliases = aliases, verified = verified }
                end
            else
                -- Text requirement: its icons, then the source wording, coloured later
                -- by the refresh below.
                local iconNames = requirementIcons(requirement)

                -- The text is centred in its 42-tall box, so centre the icons on
                -- that box too; otherwise they sit a few units above the words.
                local iconY = Style.middle(y, 42, 22)

                for index, icon in ipairs(iconNames) do
                    Style.icon(section, icon, { x = 12 + (index - 1) * 26, y = iconY, size = 22 })
                end

                local x = 12 + #iconNames * 26
                local label = section:AddText({ text = requirement.text, x = x, y = y, width = -x - 16, widthAnchor = 1, height = 42, colour = Style.text })

                updates[#updates + 1] = { label = label, index = entry.index, recommended = entry.recommended }
            end

            y = y + entry.height
        end
    end

    if next(wanted) then
        parent:AddText({ text = "Borders check backpack, worn gear and bank; other storage is not checked. Grey means data is unavailable.", colour = Style.muted })
    end

    -- Re-checks skills and recolours the requirement text. Cheap: no new controls.
    local function refreshRequirements()
        local required, suggested = calculator:requirements()

        for _, update in ipairs(updates) do
            local results = update.recommended and suggested or required
            local checked = results.children[update.index]

            update.label.rgba = Style.statusColour(checked.status)
        end
    end

    -- Re-reads the containers and recolours item borders:
    --   green = found, red = definitely not in backpack, worn or bank, grey = can't tell.
    -- Red needs complete evidence. If a container couldn't be read, absence proves
    -- nothing. Unverified icons (name mismatch) always stay grey.
    local function refreshOwnership()
        local ownership = calculator:ownership(wanted)

        for _, entry in ipairs(borders) do
            local present = false

            for _, itemId in ipairs(entry.aliases) do
                present = present or (ownership.counts[itemId] or 0) > 0
            end

            local colour = Style.muted

            if entry.verified and present then
                colour = Style.good
            elseif entry.verified and ownership.complete then
                colour = Style.bad
            end

            entry.border.rgba = colour
        end
    end

    return refreshRequirements, refreshOwnership
end

-- One Inputs or Outputs table: a heading row with the hourly total, then a row per
-- item with its icon, hourly quantity and hourly value. Columns are laid out with
-- right-anchored offsets so values line up as the window is resized.
--
-- Only the heading total gets a coin. A coin on every row was noisy, and the coin
-- is moved next to the total's number each time it changes (see Style.placeCoin).
-- `moneyColour` tints the GP values (rows and total): subtle red for money going
-- out (Inputs), subtle green for money coming in (Outputs).
--
-- Returns an update function that fills in the numbers.
local function itemTable(panel, definitions, moneyColour)
    -- Right edge of the Value column, from the panel's right side. The shaded
    -- bands sit 12 in from both panel edges, and the values 8 inside the bands.
    local valueRight = -20

    -- Column headings on a shaded band.
    Style.rectangle(panel, { x = 12, y = 34, width = -24, widthAnchor = 1, height = 28, colour = 0x39372EFF })
    panel:AddText({ text = "Item", x = 12, y = 36, width = 50, colour = Style.muted })
    panel:AddText({ text = "Per hour", x = 66, y = 36, width = 90, colour = Style.muted })
    panel:AddText({ text = "Value", x = valueRight - 130, xAnchor = 1, y = 36, width = 130, colour = Style.muted, alignHorizontal = ui.AlignMode.BOTTOMRIGHT })

    -- Item rows, with alternating background shades.
    local rows = {}

    for index, definition in ipairs(definitions) do
        local y = 64 + (index - 1) * 46
        local background = index % 2 == 0 and 0x292A25FF or 0x24251FFF

        Style.rectangle(panel, { x = 12, y = y, width = -24, widthAnchor = 1, height = 44, colour = background })
        ItemIcon.add(panel, definition.display_item_id or definition.item_id, { x = 12, y = y + 2 })

        local quantity = panel:AddText({ text = "", x = 66, y = y + 10, width = 90, height = 24 })
        local total = panel:AddText({ text = "", x = valueRight - 130, xAnchor = 1, y = y + 10, width = 130, height = 24, colour = moneyColour, alignHorizontal = ui.AlignMode.BOTTOMRIGHT })

        rows[#rows + 1] = { quantity = quantity, total = total }
    end

    -- The hourly total shares the heading row, with its coin just to the left.
    local coinY = Style.middle(6, 26, 20)
    local coin = Style.coins(panel, { xAnchor = 1, y = coinY, size = 20 })
    local subtotal = panel:AddText({ text = "", x = valueRight - 130, xAnchor = 1, y = 6, width = 130, height = 26, colour = moneyColour, alignHorizontal = ui.AlignMode.BOTTOMRIGHT })

    return function(values, total)
        for index, row in ipairs(rows) do
            row.quantity.content = Style.quantity(values[index].quantity)
            row.total.content = Style.number(values[index].value)
        end

        subtotal.content = total and Style.number(total) .. " / h" or "Unavailable"
        Style.placeCoin(coin, subtotal.content, { rightEdge = valueRight, y = coinY, size = 20 })
    end
end

-- Builds the whole method screen inside `view`. `guarded` comes from the workbench:
-- wrap every callback with it, so clicks on a screen we've left are ignored.
-- Returns a refresh(reason) function the workbench calls when the account changes.
function MethodView.mount(view, method, calculator, guarded)
    local title = method.title .. (method.variant and " - " .. method.variant or "")
    view:AddTitle({ text = title, absolute = true, x = 44, y = 10, width = -88, widthAnchor = 1, height = 28, alignHorizontal = ui.AlignMode.CENTRE })

    -- Tabs fill everything under the header, and stretch with the window.
    local tabs = view:AddTabs({
        { text = "Income" }, { text = "Requirements" },
        { text = "How to do it" }, { text = "Getting there" },
    }, {
        activeIndex = 1, absolute = true, y = HEADER_HEIGHT,
        width = 0, height = -HEADER_HEIGHT, widthAnchor = 1, heightAnchor = 1,
    })

    -- Income tab: the headline profit band first.
    local income = tabs:GetPage(1)
    local summary = income:AddPanel({ height = 72, scrollable = false, marginTop = 4, marginBottom = 6 })

    summary:AddText({ text = "Profit per hour (after tax)", x = 12, y = 4, width = -204, widthAnchor = 1, colour = Style.muted })

    -- Coin first, then the profit figure right after it, both centred on one line.
    Style.coins(summary, { x = 12, y = Style.middle(30, 30, 20), size = 20 })

    local profit = summary:AddTitle({ text = "", x = 36, y = 30, width = -230, widthAnchor = 1, height = 30 })
    -- ROI hugs the right edge, 12 in, matching the 12 on the left.
    local roi = summary:AddText({ text = "", x = -186, xAnchor = 1, y = 30, width = 174, height = 30, colour = Style.gold, alignHorizontal = ui.AlignMode.BOTTOMRIGHT })

    -- Filled in further down, but callbacks created before then need to see them.
    local render
    local ready = false

    -- Inputs and Outputs side by side, both sized for the longer of the two lists.
    local rowCount = math.max(#method.income.inputs, #method.income.outputs, 1)
    local tableHeight = 74 + rowCount * 46

    -- Each table takes half the page. The page keeps PAGE_PADDING clear on both
    -- outer edges (like the full-width summary above), with TABLE_GAP between the
    -- two tables: Inputs ends TABLE_GAP/2 left of the middle, Outputs starts
    -- TABLE_GAP/2 right of it.
    local halfWidth = -(PAGE_PADDING + TABLE_GAP / 2)

    local inputs = income:AddPanel({ height = tableHeight, width = halfWidth, widthAnchor = 0.5, scrollable = false, marginTop = 0 })

    local outputs = income:AddPanel({
        height = tableHeight,
        x = TABLE_GAP / 2, xAnchor = 0.5,
        width = halfWidth, widthAnchor = 0.5,
        inline = true,
        scrollable = false,
    })

    inputs:AddText({ text = "Inputs", x = 12, y = 6, width = 88, colour = Style.gold, height = 26, tooltip = "Supply costs use instant-buy prices. Actual purchase prices may differ." })
    outputs:AddText({ text = "Outputs", x = 12, y = 6, width = 88, colour = Style.gold, height = 26, tooltip = "Outputs use instant-sell prices after tax. Your pace and actual sale prices affect profit." })

    -- Costs read red and earnings green, so it's obvious at a glance which way
    -- the money goes. The "Inputs"/"Outputs" headings still say it in words.
    local updateInputs = itemTable(inputs, method.income.inputs, Style.bad)
    local updateOutputs = itemTable(outputs, method.income.outputs, Style.good)

    -- PvM loot isn't valued yet; say so rather than show an empty table.
    if method.income.loot then
        outputs:AddText({ text = "Drop income is not available yet.", x = 12, y = 64, height = 48, colour = Style.muted })
    end

    -- The rate row: label, input box, Save and Reset buttons, then a status line.
    income:AddText({ text = "Rate per hour", width = 106, height = 28, colour = Style.muted, tooltip = method.income.rate.unit })

    -- Typing previews straight away; Enter saves. The input can report changes while
    -- the screen is still being built, before render exists, so `ready` holds those off.
    local rate = income:AddTextField({
        text = tostring(calculator.rate),
        maxLength = 24,
        width = 104,
        inline = true,

        onChange = guarded(function(_, _, text)
            if ready then
                calculator:preview(text)
                render()
            end
        end),

        onSubmit = guarded(function(_, text)
            calculator:save(text)
            render()
        end),
    })

    Style.iconButton(income, "save", "Save", "Save rate", guarded(function()
        calculator:save(rate:GetText())
        render()
    end))

    -- SetText(..., false) puts the default back without firing onChange, so the reset
    -- doesn't count as the player typing.
    Style.iconButton(income, "reset", "Reset", "Reset to source rate", guarded(function()
        if calculator:reset() then
            rate:SetText(tostring(calculator.rate), false)
        end

        render()
    end))

    -- Unsaved changes and errors show right by the rate, so they're hard to miss.
    local state = income:AddText({ text = "", inline = true, width = -370, widthAnchor = 1, height = 42, colour = Style.muted })

    income:AddTitle("Notes")

    for _, assumption in ipairs(method.income.assumptions) do
        income:AddText({ text = assumption, colour = Style.muted })
    end

    -- The other three tabs.
    local requirements = tabs:GetPage(2)
    local refreshRequirements, refreshOwnership = mountRequirements(requirements, method, calculator)

    local instructions = tabs:GetPage(3)
    instructions:AddTitle("Method steps")

    for index, step in ipairs(method.instructions) do
        instructions:AddText({ text = index .. ". " .. step, marginTop = 10, marginBottom = 12 })
    end

    local travel = tabs:GetPage(4)
    travel:AddTitle("Getting there")
    travel:AddText(method.location.text)

    if method.location.coverage ~= "complete" then
        travel:AddText({ text = "Travel details are still being prepared for this method.", colour = Style.muted })
    end

    -- Copies the calculator's latest numbers into the Income tab. Only text and
    -- colours change here, so it's cheap enough to run on every keystroke.
    render = function()
        local result = calculator.result

        -- Status line: unsaved/saved first, then any error or missing-price note.
        local messages = {}

        if calculator.dirty then
            messages[#messages + 1] = "Preview - not saved"
        elseif calculator.saved then
            messages[#messages + 1] = "Saved personal rate"
        end

        if calculator.message then
            messages[#messages + 1] = calculator.message
        elseif result.status ~= "available" then
            messages[#messages + 1] = "Income estimate unavailable: some prices or costs are missing."
        end

        state.content = table.concat(messages, " / ")
        state.rgba = calculator.message and Style.bad or Style.muted

        -- Headline profit (red when it's a loss) and ROI. No ROI means no text at all.
        if result.profit then
            profit.content = Style.number(result.profit) .. " / h"
        else
            profit.content = "Not estimated"
        end

        profit.rgba = result.profit and result.profit < 0 and Style.bad or Style.gold
        roi.content = result.roi and Style.number(result.roi, 1) .. "% ROI" or ""
        roi.rgba = Style.gold

        updateOutputs(result.outputs or {}, result.revenue)
        updateInputs(result.inputs or {}, result.cost)
    end

    -- Everything exists now: allow input handling and fill in the first numbers.
    ready = true

    render()
    refreshRequirements()
    refreshOwnership()

    -- Skill changes can't affect item borders, and inventory changes can't affect
    -- skill levels or prices, so each reason only redoes the work it can change.
    return function(reason)
        if reason ~= "inventory" then
            render()
            refreshRequirements()
        end

        if reason ~= "skills" then
            refreshOwnership()
        end
    end
end

return MethodView
