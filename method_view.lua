-- Draws one method's screen: the title plus four tabs (Income, Requirements, How
-- to do it, Getting there).
--
-- This file only draws. The maths, the requirement checks and saving rates all
-- happen in the `calculator` passed in from main.lua; we call it and show what it
-- returns.
--
-- One design choice worth knowing: when a number changes we update label text in
-- place and never rebuild the screen. Rebuilding would recreate the rate input box
-- and kick the player's cursor out of it mid-typing.
local MethodView = {}

-- Pixel height of the Back button and title above the tabs.
local HEADER_HEIGHT = 110

-- Two decimal places, or "Unavailable" when we don't have the number.
local function formatNumber(value)
    if value == nil then
        return "Unavailable"
    end

    return string.format("%.2f", value)
end

-- Turns a requirement result tree (from requirements.lua) into indented lines like:
--   Access: met
--     Smithing 30: met
--       Base level meets the requirement.
--       Observed SMITHING: 96
local function requirementText(checked, depth)
    depth = depth or 0

    -- An empty group means the source lists nothing; say so rather than show "met".
    if checked.children and #checked.children == 0 then
        return (checked.text or "Requirements") .. ": None listed."
    end

    local lines = { string.rep("  ", depth) .. (checked.text or "Alternative") .. ": " .. checked.status }

    -- Single checks (no children) also show why, plus the level we actually saw.
    if not checked.children then
        lines[#lines + 1] = string.rep("  ", depth + 1) .. checked.reason

        for _, evidence in ipairs(checked.evidence) do
            if evidence.skill then
                lines[#lines + 1] = string.rep("  ", depth + 1) .. "Observed " .. evidence.skill .. ": " .. evidence.level
            end
        end
    end

    for _, child in ipairs(checked.children or {}) do
        lines[#lines + 1] = requirementText(child, depth + 1)
    end

    return table.concat(lines, "\n")
end

-- One line per item row: quantity, unit price, hourly value, tax and the price's
-- trade timestamp. The timestamp is there so the player can spot old prices.
local function lineText(rows)
    local lines = {}

    for _, row in ipairs(rows) do
        local line = row.name .. " | " .. formatNumber(row.quantity) .. "/hour | "
            .. formatNumber(row.unitPrice) .. " GP each | " .. formatNumber(row.value) .. " GP/hour"

        if row.tax and row.tax > 0 then
            line = line .. " after " .. formatNumber(row.tax) .. " GP tax"
        end

        if row.timestamp then
            line = line .. " | trade timestamp " .. tostring(row.timestamp)
        end

        if row.message then
            line = line .. " | " .. row.message
        end

        lines[#lines + 1] = line
    end

    return #lines > 0 and table.concat(lines, "\n") or "No direct item rows in this model."
end

-- Builds the whole method screen inside `view`. `guarded` comes from ui.lua: wrap
-- every callback with it so stale clicks are ignored. Returns a function that
-- re-checks requirements, which ui.lua calls when the player's skills change.
function MethodView.mount(view, method, calculator, guarded)
    view:AddTitle(method.title .. (method.variant and " - " .. method.variant or ""))

    -- The tabs sit at a fixed spot below the header and stretch to fill the rest of
    -- the window. They're absolutely positioned on purpose: in normal flow layout,
    -- the tabs' height and the view's height kept resizing each other.
    local tabs = view:AddTabs({
        { text = "Income" }, { text = "Requirements" },
        { text = "How to do it" }, { text = "Getting there" },
    }, {
        activeIndex = 1, absolute = true, y = HEADER_HEIGHT,
        width = 0, height = -HEADER_HEIGHT, widthAnchor = 1, heightAnchor = 1,
    })

    -- PrettyUI text labels keep the height they're created with and don't grow.
    -- So labels we update later get a fixed height big enough for their longest
    -- expected text. That's what all the height = ... numbers below are.

    -- Income tab.
    local income = tabs:GetPage(1)
    income:AddText("Inputs: instant-buy prices. Outputs: instant-sell prices, less the modelled per-item GE tax. Prices differ from Wiki guide prices.")

    local summary = income:AddText({ text = "", height = 220 })
    local state = income:AddText({ text = "", height = 75 })

    income:AddText("Manual profile: choose a name for the current character. Profiles are local to this device; they are not detected automatically.")
    local profile = income:AddTextField({ text = calculator.profile, maxLength = 40 })

    -- These are filled in further down, but the button callbacks need to see them.
    local render
    local rate

    -- The rate box may report changes while it's still being built, before render
    -- exists. Ignore those until we're ready.
    local ready = false

    -- SetText(..., false) below means "change the box without firing onChange",
    -- so putting the saved rate back in doesn't count as the player typing.
    income:AddSimpleButton("Use profile", guarded(function()
        if calculator:useProfile(profile:GetText()) then
            rate:SetText(tostring(calculator.rate), false)
        end

        render()
    end))

    income:AddText(method.income.rate.unit .. " (source default: " .. method.income.rate.default .. ")")

    -- Typing previews the new numbers straight away; Enter (onSubmit) saves.
    rate = income:AddTextField({
        text = tostring(calculator.rate), maxLength = 24,

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

    income:AddSimpleButton("Save rate", guarded(function()
        calculator:save(rate:GetText())
        render()
    end))

    income:AddSimpleButton("Reset to source rate", guarded(function()
        if calculator:reset() then
            rate:SetText(tostring(calculator.rate), false)
        end

        render()
    end))

    income:AddSimpleButton("Refresh prices", guarded(function()
        calculator:refreshPrices()
        render()
    end))

    -- Item breakdowns: roughly 90px of label per item row.
    income:AddTitle("Revenue")
    local outputs = income:AddText({ text = "", height = math.max(90, #method.income.outputs * 90) })

    income:AddTitle("Supplies and operating costs")
    local inputs = income:AddText({ text = "", height = math.max(90, #method.income.inputs * 90) })

    -- The source's own caveats, shown as-is so nothing is hidden from the player.
    income:AddText("Last recorded trades may be old or illiquid. Refresh reads GEPL's cache; the library owns network refreshes.")

    for _, assumption in ipairs(method.income.assumptions) do
        income:AddText(assumption)
    end

    for _, problem in ipairs(method.income.unresolved) do
        income:AddText("Unresolved: " .. problem)
    end

    -- Requirements tab. Label heights scale with how many checks each group has.
    local requirements = tabs:GetPage(2)
    local access = requirements:AddText({ text = "", height = 100 + #method.requirements.access.children * 65 })
    local recommended = requirements:AddText({ text = "", height = 70 + #method.requirements.recommended.children * 110 })

    requirements:AddText("These checks do not yet verify membership/world restrictions or owned gear. Recommendations are not implemented.")

    for _, problem in ipairs(method.requirements.unresolved or {}) do
        requirements:AddText("Unresolved: " .. problem)
    end

    local function refreshRequirements()
        local accessResult, recommendedResult = calculator:requirements()

        access.content = requirementText(accessResult)
        recommended.content = requirementText(recommendedResult)
    end

    requirements:AddSimpleButton("Refresh requirements", guarded(refreshRequirements))

    -- How to do it tab: numbered steps straight from the method data.
    local instructions = tabs:GetPage(3)

    for index, step in ipairs(method.instructions) do
        instructions:AddText(index .. ". " .. step)
    end

    -- Getting there tab.
    local travel = tabs:GetPage(4)
    travel:AddText(method.location.text)

    if method.location.coverage ~= "complete" then
        travel:AddText("Travel details are still being prepared for this method.")
    end

    -- Copies the calculator's latest numbers into the Income tab labels. Called after
    -- every action above; it only sets label text, so it's cheap and keeps focus.
    render = function()
        local result = calculator.result

        -- Tell the player which rate the numbers are using.
        local label

        if calculator.dirty then
            label = "Preview - not saved"
        elseif calculator.saved then
            label = "Saved personal rate"
        else
            label = "Source default"
        end

        local stateLines = { "Profile: " .. calculator.profile .. " | " .. label }

        if calculator.message then
            stateLines[#stateLines + 1] = calculator.message
        end

        state.content = table.concat(stateLines, "\n")

        local roiText = "Not applicable / unavailable"

        if result.roi then
            roiText = formatNumber(result.roi) .. "%"
        end

        local summaryLines = {
            "Net profit: " .. formatNumber(result.profit) .. " GP/hour",
            "ROI: " .. roiText,
            "Gross revenue: " .. formatNumber(result.gross) .. " GP/hour",
            "GE tax: " .. formatNumber(result.tax) .. " GP/hour",
            "Revenue after tax: " .. formatNumber(result.revenue) .. " GP/hour",
            "Supply costs: " .. formatNumber(result.cost) .. " GP/hour",
        }

        if result.message then
            summaryLines[#summaryLines + 1] = result.message
        end

        summary.content = table.concat(summaryLines, "\n")

        -- PvM loot isn't valued yet (see income.lua), so say that plainly instead of
        -- showing an empty revenue list.
        if method.income.loot then
            outputs.content = "Selected " .. method.income.loot.monster
                .. " drop rows are bundled; their income model is still being reconciled."
        else
            outputs.content = lineText(result.outputs or {})
        end

        inputs.content = lineText(result.inputs or {})
    end

    -- Everything exists now: switch input handling on and fill in the first numbers.
    ready = true

    render()
    refreshRequirements()

    return refreshRequirements
end

return MethodView
