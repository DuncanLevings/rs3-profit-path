-- Draws the four method tabs and owns their labels/panels through the parent
-- view. Calculations and saves stay in main.lua; refreshing only updates labels,
-- so typing a rate never rebuilds the input or loses keyboard focus.
local Style = require("src/ui/view_style")
local ItemIcon = require("src/ui/item_icon")
local MethodView = {}

local HEADER_HEIGHT = 48
local itemDefinitions = require("data/methods").items
local categories = { skill = "Skills", item = "Items", gear = "Items", quest = "Quests", capability = "Other" }

-- Keep an alternative group together. Splitting an ANY across categories would
-- make it look like the player needs every alternative rather than just one.
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

-- Group source requirements like the Wiki. Text carries the requirement status;
-- item borders describe presence and tooltips contain only the item name.
local function mountRequirements(parent, method, calculator)
    local groups = { Skills = {}, ["Required items"] = {}, ["Recommended items"] = {}, Quests = {}, Other = {} }

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
                recommended = entry.recommended, index = index,
            }
        end
    end

    local updates = {}
    local borders = {}
    local wanted = {}

    -- Only item sections share a row. Empty halves are omitted, so the other
    -- half fills the width; matching heights keep following sections below both.
    local sections = {}
    local bothItems = #groups["Required items"] > 0 and #groups["Recommended items"] > 0
    local itemHeight = 0

    for _, category in ipairs({ "Skills", "Required items", "Recommended items", "Quests", "Other" }) do
        local entries = groups[category]
        local isItems = category == "Required items" or category == "Recommended items"
        local height = 38

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
        local category, entries = definition.category, definition.entries
        local options = { height = definition.height, scrollable = false, marginBottom = 6 }

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
            section:AddText({ text = method.requirements.coverage == "complete" and "None listed" or "Not listed in this sample", x = 12, y = 32, height = 24, colour = Style.muted })
        end

        local y = 34

        for _, entry in ipairs(entries) do
            local definition = entry.definition
            local icons = definition.display_items

            -- Each item tooltip is just its name. Border state is separate from
            -- this requirement's gear/use checks, which remain unverified.
            if icons then
                for index, itemId in ipairs(icons) do
                    local x = 12 + ((index - 1) % 5) * 44
                    local iconY = y + math.floor((index - 1) / 5) * 44
                    local _, _, verified = ItemIcon.add(section, itemId, { x = x, y = iconY })
                    local border = Style.rectangle(section, { x = x, y = iconY, width = 40, height = 40, fill = false, colour = Style.muted })
                    local aliases = itemDefinitions[tostring(itemId)].ownership_ids or { itemId }

                    for _, alias in ipairs(aliases) do
                        wanted[alias] = true
                    end

                    borders[#borders + 1] = { border = border, aliases = aliases, verified = verified }
                end

            else
                -- An alternative skill group still needs each skill's icon, but
                -- keep its original combined wording so OR doesn't become AND.
                local icons, seen = {}, {}

                local function collectIcons(requirement)
                    local icon = requirement.display_icon

                    if requirement.kind == "skill" then
                        icon = "skill_" .. requirement.skill:lower()
                    end

                    if icon and not seen[icon] then
                        icons[#icons + 1] = icon
                        seen[icon] = true
                    end

                    for _, child in ipairs(requirement.children or {}) do
                        collectIcons(child)
                    end
                end

                collectIcons(definition)

                for index, icon in ipairs(icons) do
                    Style.icon(section, icon, { x = 12 + (index - 1) * 26, y = y + 4, size = 22 })
                end

                local x = 12 + #icons * 26
                local label = section:AddText({ text = definition.text, x = x, y = y, width = -x - 16, widthAnchor = 1, height = 42, colour = Style.text })
                updates[#updates + 1] = { label = label, index = entry.index, recommended = entry.recommended }
            end

            y = y + entry.height
        end
    end

    if next(wanted) then
        parent:AddText({ text = "Borders check backpack, worn gear and bank; other storage is not checked. Grey means data is unavailable.", colour = Style.muted })
    end

    -- Read evidence again, but never rebuild the controls on a skill update.
    return function()
        local required, suggested = calculator:requirements()

        for _, update in ipairs(updates) do
            local checked = (update.recommended and suggested or required).children[update.index]
            update.label.rgba = Style.statusColour(checked.status)
        end
    end, function()
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
end

-- The Wiki presents inputs and outputs beside each other. Use three compact
-- columns: the native item icon, hourly quantity and total value. No empty name
-- column or per-item frames; the icon tooltip supplies only the item name.
local function itemTable(panel, definitions)
    Style.rectangle(panel, { x = 12, y = 34, width = -32, widthAnchor = 1, height = 28, colour = 0x39372EFF })
    panel:AddText({ text = "Item", x = 12, y = 36, width = 50, colour = Style.muted })
    panel:AddText({ text = "Per hour", x = 66, y = 36, width = 90, colour = Style.muted })
    panel:AddText({ text = "Value", x = -162, xAnchor = 1, y = 36, width = 130, colour = Style.muted, alignHorizontal = ui.AlignMode.BOTTOMRIGHT })
    local rows = {}

    for index, definition in ipairs(definitions) do
        local y = 64 + (index - 1) * 46
        local background = index % 2 == 0 and 0x292A25FF or 0x24251FFF
        Style.rectangle(panel, { x = 12, y = y, width = -32, widthAnchor = 1, height = 44, colour = background })
        ItemIcon.add(panel, definition.display_item_id or definition.item_id, { x = 12, y = y + 2 })
        local quantity = panel:AddText({ text = "", x = 66, y = y + 10, width = 90, height = 24 })
        Style.icon(panel, "coins", { x = -186, xAnchor = 1, y = y + 12, size = 18 })
        local total = panel:AddText({ text = "", x = -162, xAnchor = 1, y = y + 10, width = 130, height = 24, alignHorizontal = ui.AlignMode.BOTTOMRIGHT })
        rows[#rows + 1] = { quantity = quantity, total = total }
    end

    -- The title and hourly subtotal share one row, ahead of every item.
    Style.icon(panel, "coins", { x = -186, xAnchor = 1, y = 9, size = 20 })
    local subtotal = panel:AddText({ text = "", x = -162, xAnchor = 1, y = 6, width = 130, height = 26, colour = Style.gold, alignHorizontal = ui.AlignMode.BOTTOMRIGHT })

    return function(values, total)
        for index, row in ipairs(rows) do
            row.quantity.content = Style.quantity(values[index].quantity)
            row.total.content = Style.number(values[index].value)
        end

        subtotal.content = total and Style.number(total) .. "/h" or "Unavailable"
    end
end

-- Mount once, then return a refresh for skill events and header actions. Native
-- controls belong to the supplied view and disappear with it on navigation.
function MethodView.mount(view, method, calculator, guarded)
    view:AddTitle({ text = method.title .. (method.variant and " - " .. method.variant or ""), absolute = true, x = 44, y = 10, width = -88, widthAnchor = 1, height = 28, alignHorizontal = ui.AlignMode.CENTRE })

    local tabs = view:AddTabs({
        { text = "Income" }, { text = "Requirements" },
        { text = "How to do it" }, { text = "Getting there" },
    }, {
        activeIndex = 1, absolute = true, y = HEADER_HEIGHT,
        width = 0, height = -HEADER_HEIGHT, widthAnchor = 1, heightAnchor = 1,
    })

    local income = tabs:GetPage(1)
    local summary = income:AddPanel({ height = 72, scrollable = false, marginTop = 4, marginBottom = 6 })
    summary:AddText({ text = "Profit per hour (after tax)", x = 12, y = 4, width = -204, widthAnchor = 1, colour = Style.muted })
    Style.icon(summary, "coins", { x = 12, y = 34, size = 20 })
    local profit = summary:AddTitle({ text = "", x = 38, y = 30, width = -230, widthAnchor = 1, height = 30 })
    local roi = summary:AddText({ text = "", x = -184, xAnchor = 1, y = 30, width = 174, height = 30, colour = Style.gold })
    local render
    local ready = false

    local rowCount = math.max(#method.income.inputs, #method.income.outputs, 1)
    local tableHeight = 74 + rowCount * 46
    local inputs = income:AddPanel({ height = tableHeight, width = -12, widthAnchor = 0.5, scrollable = false, marginTop = 0 })
    local outputs = income:AddPanel({ height = tableHeight, width = -12, widthAnchor = 0.5, x = 4, xAnchor = 0.5, inline = true, scrollable = false })
    inputs:AddText({ text = "Inputs", x = 12, y = 6, width = 88, colour = Style.gold, height = 26, tooltip = "Supply costs use instant-buy prices. Actual purchase prices may differ." })
    outputs:AddText({ text = "Outputs", x = 12, y = 6, width = 88, colour = Style.gold, height = 26, tooltip = "Outputs use instant-sell prices after tax. Your pace and actual sale prices affect profit." })
    local updateInputs = itemTable(inputs, method.income.inputs)
    local updateOutputs = itemTable(outputs, method.income.outputs)

    if method.income.loot then
        outputs:AddText({ text = "Drop income is not available yet.", x = 12, y = 64, height = 48, colour = Style.muted })
    end

    income:AddText({ text = "Rate per hour", width = 106, height = 28, colour = Style.muted, tooltip = method.income.rate.unit })

    -- Callbacks can fire during construction, before all the labels below exist.
    local rate = income:AddTextField({
        text = tostring(calculator.rate), maxLength = 24, width = 104, inline = true,
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

    Style.saveButton(income, guarded(function()
        calculator:save(rate:GetText())
        render()
    end))

    income:AddSpriteButton("UNDO", guarded(function()
        if calculator:reset() then
            rate:SetText(tostring(calculator.rate), false)
        end

        render()
    end), { inline = true, size = 24, tooltip = "Reset to source rate" })

    -- Keep errors and unsaved changes visible, without an extra default-rate label.
    local state = income:AddText({ text = "", inline = true, width = -370, widthAnchor = 1, height = 42, colour = Style.muted })

    income:AddTitle("Notes")

    for _, assumption in ipairs(method.income.assumptions) do
        income:AddText({ text = assumption, colour = Style.muted })
    end

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

    -- Only label content/colour changes here. Saved, preview and error states stay
    -- next to the headline, so a storage failure can't disappear below the fold.
    render = function()
        local result = calculator.result
        local label = ""

        if calculator.dirty then
            label = "Preview - not saved"
        elseif calculator.saved then
            label = "Saved personal rate"
        end

        local messages = {}

        if label ~= "" then
            messages[#messages + 1] = label
        end

        if calculator.message then
            messages[#messages + 1] = calculator.message
        elseif result.status ~= "available" then
            messages[#messages + 1] = "Income estimate unavailable: some prices or costs are missing."
        end

        state.content = table.concat(messages, " / ")
        state.rgba = calculator.message and Style.bad or Style.muted
        profit.content = result.profit and Style.number(result.profit) .. "/hour" or "Not estimated"
        profit.rgba = result.profit and result.profit < 0 and Style.bad or Style.gold
        roi.content = result.roi and Style.number(result.roi, 1) .. "% ROI" or ""
        roi.rgba = Style.gold

        if updateOutputs then
            updateOutputs(result.outputs or {}, result.revenue)
        end

        updateInputs(result.inputs or {}, result.cost)
    end

    ready = true
    render()
    refreshRequirements()
    refreshOwnership()

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
