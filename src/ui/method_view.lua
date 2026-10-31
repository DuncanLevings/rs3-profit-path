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
local Loot = require("src/methods/loot")
local Dropdown = require("src/ui/dropdown")

local MethodView = {}

-- Height of the header row (Back, title, favourite) above the tabs.
local HEADER_HEIGHT = 48

-- PrettyUI's default side padding inside a tab page, and the space we leave
-- between the Inputs and Outputs tables.
local PAGE_PADDING = 14
local TABLE_GAP = 8

-- The Income tab's top row: the rate panel's fixed width, and the height it
-- shares with the profit panel beside it.
local RATE_WIDTH = 220
local TOP_ROW_HEIGHT = 84

-- Inside the top row: space from the panel edges, and the y of its two lines.
local TOP_INSET = 16
local FIRST_LINE_Y = 10
local SECOND_LINE_Y = 46

local itemDefinitions = require("src/data/method_data").items

-- The client stops any single callback that runs past one second, and native
-- components are slow to make (PrettyUI builds every tooltip up front, about a
-- dozen parts each). A boss with 60 drops plus a long requirements list is too
-- much for one click. So opening a method draws only what's on screen, then
-- the rest a piece per game tick (50 a second): Income rows a batch at a time,
-- then each other tab. Clicking a tab that isn't drawn yet draws it straight away.
local ROWS_PER_STEP = 6
local BUILD_EVENT = "profit-path-method-build"

-- Which Requirements section each kind of check goes in.
local categories = {
    skill = "Skills", combat_level = "Skills", item = "Items", gear = "Items", quest = "Quests", capability = "Other",
}

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

    -- A quest we can't check yet (not mapped to its game config) still belongs
    -- with the quests.
    if definition.kind == "capability" and definition.capability_kind == "quest" then
        return "Quests"
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

        -- Combat level has no icon: the Skills tab's badge isn't a sprite the
        -- plugin can find, and a stand-in looked wrong.
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

-- A group of tiered gear checks, drawn as one slot per piece instead of one long
-- line of link text: "any one" of several styles (magic, melee, ranged or
-- necromancy armour), or "all" the pieces of one line ("Tier 90+ magic weapon and
-- armour" needs both the weapon and the armour).
local function gearOptions(definition)
    if definition.kind ~= "any" and definition.kind ~= "all" then
        return false
    end

    for _, child in ipairs(definition.children) do
        if child.kind ~= "gear" then
            return false
        end
    end

    return true
end

-- A short name for one tiered gear option: "T61+ magic armour".
local GEAR_PIECES = { weapon = "weapon", body = "armour", shield = "shield" }

local function gearLabel(requirement)
    local words = { "T" .. requirement.minimum_tier .. "+" }

    if requirement.style then
        words[#words + 1] = requirement.style
    end

    if requirement.armour_type then
        words[#words + 1] = requirement.armour_type:match("^(%a+)"):lower()
    end

    words[#words + 1] = GEAR_PIECES[requirement.slot] or requirement.slot

    return table.concat(words, " ")
end

-- Panel headings already say whether something is required or recommended.
-- Only remove standalone labels, keeping useful qualifiers such as "recommended
-- for faster kills" and the rest of the source wording.
local function requirementText(text)
    local cleaned = text:gsub("%s*%([Rr]ecommended%)", ""):gsub("%s*%([Rr]equired%)", "")
    cleaned = cleaned:gsub("%s+[Rr]ecommended%s*$", ""):gsub("%s+[Rr]equired%s*$", "")

    return cleaned
end

-- The hover for an "any"/"all" line that isn't met: what each part reads as,
-- e.g. "Either one will do. Mobile: can't be checked in game. Shadow's Grace:
-- not unlocked yet." Without it, a neutral line doesn't say why it's neutral.
-- A met line needs no explaining, so it gets nil.
local function partsTooltip(checked)
    if checked.status == "met" or not checked.children then
        return nil
    end

    local parts = {}
    local plain = { met = "met", unmet = "not met", unknown = "needs checking" }

    for _, child in ipairs(checked.children) do
        local reads

        if child.children then
            -- A nested group: just its verdict, or the hover gets very long.
            reads = plain[child.status]
        elseif child.kind == "capability" then
            reads = "can't be checked in game"
        else
            -- The check's own reason, as part of a sentence ("not unlocked yet").
            reads = child.reason:gsub("^%u", string.lower):gsub("%.$", "")
        end

        parts[#parts + 1] = requirementText(child.text or "") .. ": " .. reads
    end

    local heading = checked.kind == "any" and "Either one will do. " or "All of these are needed. "

    return heading .. table.concat(parts, ". ") .. "."
end

-- Builds matching Required/Recommended pairs for skills, items, quests and other
-- checks. Each pair owns its controls; refreshing changes only their verdicts.
local function mountRequirements(parent, method, calculator, fitter)
    local groups = {}

    for _, category in ipairs({ "Skills", "Items", "Quests", "Other" }) do
        groups[category] = { {}, {} }
    end

    -- Keep each check's original index: the calculator still evaluates the source
    -- groups in order, even though we arrange their display into separate panels.
    for side, definition in ipairs({ method.requirements.access, method.requirements.recommended }) do
        for index, child in ipairs(definition.children) do
            local entries = groups[categoryFor(child)][side]
            entries[#entries + 1] = { definition = child, recommended = side == 2, index = index }
        end
    end

    -- Uncheckable advice belongs in the same Required/Recommended layout, but
    -- stays neutral. Moving it into a panel mustn't turn advice into a verdict.
    for _, note in ipairs(method.requirements.notes or {}) do
        local entries = groups.Other[1]
        entries[#entries + 1] = { definition = { text = note }, displayOnly = true }
    end

    for _, tip in ipairs(method.requirements.tips or {}) do
        local entries = groups.Other[2]
        entries[#entries + 1] = { definition = { text = tip.text }, icons = tip.icons, displayOnly = true }
    end

    local updates = {}
    local borders = {}

    -- Plan each panel before drawing it. Consecutive item requirements share
    -- an icon grid instead of wasting a whole line on each separate item. An
    -- "Any one" group keeps its own grid so alternatives never look mandatory.
    local sections = {}

    for _, category in ipairs({ "Skills", "Items", "Quests", "Other" }) do
        local pair = groups[category]
        local both = #pair[1] > 0 and #pair[2] > 0
        local pairHeight = 0
        local planned = {}

        for side, entries in ipairs(pair) do
            if #entries > 0 then
                local y, usedSlots = 34, 0
                local panelWidth = parent.content.width - PAGE_PADDING * 2

                if both then
                    panelWidth = (panelWidth - TABLE_GAP) / 2
                end

                for _, entry in ipairs(entries) do
                    local requirement = entry.definition
                    local icons = requirement.display_items

                    if icons and requirement.kind ~= "any" then
                        entry.y, entry.startSlot = y, usedSlots
                        usedSlots = usedSlots + #icons
                    else
                        y = y + math.ceil(usedSlots / 5) * 44
                        usedSlots = 0
                        entry.y = y
                        -- A single text line needs 26 units, not the old 42.
                        -- Keep the existing two-line allowance for longer wording
                        -- so compact rows don't squeeze wrapped text out of view.
                        local iconNames = entry.icons or requirementIcons(requirement)
                        local textInset = requirement.equipment_group and 62 or (12 + #iconNames * 26)
                        local textWidth = math.max(1, panelWidth - textInset - 16)
                        entry.textHeight = Style.textWidth(requirementText(requirement.text)) <= textWidth and 26 or 42
                        local height = entry.textHeight + 4

                        if requirement.equipment_group then
                            -- The box and its wording share one row. Leave room for
                            -- a short ownership hint below the wording when present.
                            entry.matchHeight = math.max(40, entry.textHeight + 20)
                            height = entry.matchHeight + 4
                        end

                        if icons then
                            height = 24 + math.ceil(#icons / 5) * 44 + 8
                        elseif gearOptions(requirement) then
                            -- Only "any one" has a heading; "all" is just its slots.
                            local heading = requirement.kind == "any" and 24 or 0
                            height = heading + #requirement.children * 44 + 8
                        end

                        y = y + height
                    end
                end

                local height = y + math.ceil(usedSlots / 5) * 44 + 8
                pairHeight = math.max(pairHeight, height)
                planned[#planned + 1] = { category = category, entries = entries,
                    height = height, recommended = side == 2, half = both }
            end
        end

        for _, section in ipairs(planned) do
            if both then
                section.height = pairHeight
            end

            sections[#sections + 1] = section
        end
    end

    for _, definition in ipairs(sections) do
        local entries = definition.entries
        local half = definition.half
        local options = { height = definition.height, scrollable = false, marginBottom = 6 }

        -- Like Inputs/Outputs: matching heights and padding, with the right panel
        -- inline. With just one side present the remaining panel fills the row.
        if half then
            options.width = -(PAGE_PADDING + TABLE_GAP / 2)
            options.widthAnchor = 0.5

            if definition.recommended then
                options.inline = true
                options.x = TABLE_GAP / 2
                options.xAnchor = 0.5
            end
        end

        local section = fitter:add(parent:AddPanel(options), options.height, half)
        section:AddText({ text = (definition.recommended and "Recommended " or "Required ") .. definition.category:lower(), x = 12, y = 4, height = 26, colour = Style.gold })

        for _, entry in ipairs(entries) do
            local requirement = entry.definition
            local icons = requirement.display_items
            local y = entry.y

            if gearOptions(requirement) then
                -- One slot per option: an owned match shows its icon, otherwise
                -- the empty slot's border gives the verdict. The short label sits
                -- beside it, coloured the same way.
                -- "Any one" says the slots are alternatives. Without it ("all"),
                -- every slot is needed, like any other list of items.
                local heading = 0

                if requirement.kind == "any" then
                    section:AddText({ text = "Any one", x = 12, y = y, height = 24, colour = Style.muted })
                    heading = 24
                end

                for childIndex, child in ipairs(requirement.children) do
                    local matchY = y + heading + (childIndex - 1) * 44

                    updates[#updates + 1] = {
                        index = entry.index,
                        recommended = entry.recommended,
                        childIndex = childIndex,
                        matchSection = section,
                        minimumItemId = child.minimum_item_id,
                        matchY = matchY,
                        fixedText = gearLabel(child),
                        matchText = section:AddText({ text = "", x = 62, y = matchY + 6, width = -78, widthAnchor = 1, height = 30, colour = Style.muted }),
                    }
                end
            elseif icons then
                -- Item requirement: a grid of item icons. Each tooltip is just the
                -- item's name, and the border shows presence only. Owning an item
                -- doesn't prove you can use it, so we never claim that.
                local iconStart = y

                if requirement.kind == "any" then
                    section:AddText({ text = "Any one", x = 12, y = y, height = 24, colour = Style.muted })
                    iconStart = y + 24
                end

                for index, itemId in ipairs(icons) do
                    local slot = (entry.startSlot or 0) + index - 1
                    local x = 12 + (slot % 5) * 44
                    local iconY = iconStart + math.floor(slot / 5) * 44

                    local _, _, verified = ItemIcon.add(section, itemId, { x = x, y = iconY })
                    local border = Style.rectangle(section, { x = x, y = iconY, width = 40, height = 40, fill = false, colour = Style.muted })

                    -- Some items count under several IDs (charged or worn variants).
                    local aliases = itemDefinitions[tostring(itemId)].ownership_ids or { itemId }

                    borders[#borders + 1] = { border = border, aliases = aliases, verified = verified }
                end
            else
                -- Text requirement: its icons, then the source wording, coloured later
                -- by the refresh below.
                local iconNames = entry.icons or requirementIcons(requirement)

                -- Centre the icons on the compact text box (or its wrapped version).
                local iconY = Style.middle(y, entry.textHeight, 22)

                for index, icon in ipairs(iconNames) do
                    Style.icon(section, icon, { x = 12 + (index - 1) * 26, y = iconY, size = 22 })
                end

                local x = requirement.equipment_group and 62 or (12 + #iconNames * 26)
                local labelOptions = { text = requirementText(requirement.text), x = x, y = y, width = -x - 16, widthAnchor = 1, height = entry.matchHeight or entry.textHeight, colour = Style.text }
                local label = section:AddText(labelOptions)

                local update = { label = label, index = entry.index, recommended = entry.recommended }

                -- An "any"/"all" line explains its parts when hovered. PrettyUI
                -- sets a tooltip only when a label is made, so the refresh makes
                -- this label again, but only when the hover text changes.
                if requirement.children and not requirement.equipment_group then
                    update.section = section
                    update.labelOptions = labelOptions
                end

                if requirement.equipment_group then
                    -- Show an owned match or an explicitly named minimum. With
                    -- neither, an empty bordered slot shows the verdict (red when
                    -- missing), never a placeholder item.
                    update.matchSection = section
                    update.minimumItemId = requirement.minimum_item_id
                    update.matchY = Style.middle(y, entry.matchHeight, 40)
                    update.matchText = label
                    update.matchTextY = y
                    update.sourceText = requirementText(requirement.text)
                end

                if entry.displayOnly then
                    label.rgba = Style.muted
                else
                    updates[#updates + 1] = update
                end
            end
        end
    end

    local storageStatus = parent:AddText({ text = "", height = 96, colour = Style.muted })

    -- Apply the shared verdict to text and update the owned-equipment match.
    -- Only a changed match creates/removes its small slot; the rate field stays put.
    local function refreshRequirements()
        local required, suggested = calculator:requirements()

        for _, update in ipairs(updates) do
            local results = update.recommended and suggested or required
            local checked = results.children[update.index]

            -- One option of an "any one" gear group has its own result.
            if update.childIndex then
                checked = checked.children[update.childIndex]
            end

            if update.labelOptions then
                local tooltip = partsTooltip(checked)

                if tooltip ~= update.tooltip then
                    local options = {}

                    for key, value in pairs(update.labelOptions) do
                        options[key] = value
                    end

                    options.tooltip = tooltip
                    update.label:Destroy()
                    update.label = update.section:AddText(options)
                    update.tooltip = tooltip
                end
            end

            if update.label then
                update.label.rgba = Style.statusColour(checked.status)
            end

            if update.matchSection then
                local match = checked.evidence[1]
                local object, name

                -- A named minimum is part of the requirement itself, unlike a
                -- top-end example of a flexible tool. Show it when no match exists.
                local displayId = match and match.itemId or update.minimumItemId

                if displayId then
                    object, name = ItemIcon.resolve(displayId)
                end

                -- false (not nil) when there's no item, so the first refresh still
                -- draws the empty slot.
                local itemId = object and displayId or false

                if update.matchId ~= itemId then
                    if update.matchSlot then
                        update.matchSlot:Destroy()
                        update.matchSlot = nil
                    end

                    if update.matchBorder then
                        update.matchBorder:Destroy()
                        update.matchBorder = nil
                    end

                    -- An owned match shows its icon. With no match, the slot stays
                    -- empty and its border shows the verdict, like item icons do.
                    if object then
                        update.matchSlot = update.matchSection:AddItemSlot(object, { x = 12, y = update.matchY, tooltip = name, clickthrough = false })
                    end

                    update.matchBorder = Style.rectangle(update.matchSection, { x = 12, y = update.matchY, width = 40, height = 40, fill = false, colour = Style.muted })
                    update.matchId = itemId
                end

                update.matchText:SetPos(62, update.matchTextY or Style.middle(update.matchY, 40, 30))

                -- An empty slot speaks for itself; the group's coverage note was
                -- just clutter next to it.
                local description = ""

                if object then
                    if not match then
                        description = "Minimum required"
                    elseif match.saved then
                        description = "Saved match - verify in game"
                    elseif match.toolbelt then
                        description = "On your tool belt"
                    else
                        description = "Usable owned match"
                    end
                end

                -- Gear options always show their short name ("T61+ magic armour").
                local text = update.fixedText or description

                if update.sourceText then
                    -- Keep the source requirement visible even with an empty slot.
                    -- This native label renders a newline as a box, so keep the
                    -- ownership hint inline in the centred text beside the item.
                    text = update.sourceText .. (description ~= "" and (" - " .. description) or "")
                end

                update.matchText.content = text
                local colour = match and match.saved and Style.gold or Style.statusColour(checked.status)

                if not match and checked.lastKnownAbsent then
                    colour = Style.bad
                end

                update.matchText.rgba = colour

                if update.matchBorder then
                    update.matchBorder.rgba = colour
                end
            end
        end
    end

    -- Recolour from the same cached evidence as the checks:
    -- Green = live, gold = saved presence, red = absent when last checked in all
    -- three stores, grey = never fully checked. The footer makes saved stores clear;
    -- retained red borders don't turn historical evidence into a live access check.
    -- Unverified icons (name mismatch) always stay grey.
    local function refreshOwnership()
        local ownership = calculator:ownership()
        local sources = ownership.sources or {}
        local labels = { INV = "Backpack", WORN = "Worn", BANK = "Bank" }
        local parts = {}

        for _, container in ipairs({ "INV", "WORN", "BANK" }) do
            parts[#parts + 1] = labels[container] .. ": " .. (sources[container] or "unavailable")
        end

        parts[#parts + 1] = "Tool belt (hatchet/pickaxe/mattock): " .. (sources.TOOLBELT or "unavailable")
        storageStatus.content = table.concat(parts, " / ") .. ". Red: absent when last checked. Gold: saved item. Other tool-belt items and stores are not checked."

        if ownership.message then
            storageStatus.content = storageStatus.content .. " " .. ownership.message
        end

        for _, entry in ipairs(borders) do
            local present = false
            local lastKnownAbsent = true

            for _, itemId in ipairs(entry.aliases) do
                present = present or (ownership.counts[itemId] or 0) > 0
                lastKnownAbsent = lastKnownAbsent and (ownership.lastKnownAbsent or {})[itemId] == true
            end

            local colour = Style.muted

            if entry.verified and present then
                colour = Style.good
            elseif entry.verified and (ownership.complete or lastKnownAbsent) then
                colour = Style.bad
            elseif entry.verified then
                for _, itemId in ipairs(entry.aliases) do
                    if ((ownership.savedCounts or {})[itemId] or 0) > 0 then
                        colour = Style.gold
                    end
                end
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
-- Returns an update function that fills in the numbers, and addRows(limit),
-- which draws up to `limit` more item rows and says how many it drew (0 once
-- they're all there). The panel's height is set for every row up front, so rows
-- drawn later don't move anything else on the page.
--
-- An "Unavailable" value says why when hovered. PrettyUI can't change a label's
-- tooltip after it's made, so the value label is made again when its reason
-- changes. That only happens when prices are fetched again, never while typing.
local function itemTable(panel, definitions, moneyColour, period)
    -- Recurring (daily/weekly) methods count per run instead of per hour.
    local perRun = period == "run"

    -- Right edge of the Value column, from the panel's right side. The shaded
    -- bands sit 12 in from both panel edges, and the values 8 inside the bands.
    local valueRight = -20

    -- Column headings on a shaded band.
    Style.rectangle(panel, { x = 12, y = 34, width = -24, widthAnchor = 1, height = 28, colour = 0x39372EFF })
    panel:AddText({ text = "Item", x = 12, y = 36, width = 50, colour = Style.muted })
    panel:AddText({ text = perRun and "Per run" or "Per hour", x = 66, y = 36, width = 90, colour = Style.muted })
    panel:AddText({ text = "Value", x = valueRight - 130, xAnchor = 1, y = 36, width = 130, colour = Style.muted, alignHorizontal = ui.AlignMode.BOTTOMRIGHT })

    -- Item rows, with alternating background shades.
    local rows = {}

    -- The last numbers we were given, so a row drawn later shows them straight away.
    local latest = {}

    -- The value label, with its tooltip: the reason a value is missing, or else
    -- the row's usual pricing note (if it has one).
    local function addValue(row, tooltip)
        if row.total then
            row.total:Destroy()
        end

        row.total = panel:AddText({
            text = "", x = valueRight - 130, xAnchor = 1, y = row.y + 10, width = 130, height = 24,
            colour = moneyColour, alignHorizontal = ui.AlignMode.BOTTOMRIGHT, tooltip = tooltip,
        })
        row.tooltip = tooltip
    end

    local function fill(index)
        local value = latest[index]
        local row = rows[index]

        if value then
            -- A row in one of a guide's price choices says whether it's used and why.
            local tooltip = value.message or value.choiceNote or row.note

            if not row.total or tooltip ~= row.tooltip then
                addValue(row, tooltip)
            end

            row.quantity.content = Style.quantity(value.quantity)
            row.total.content = Style.number(value.value)
        end
    end

    local function addRow(index, definition)
        local y = 64 + (index - 1) * 46
        local background = index % 2 == 0 and 0x292A25FF or 0x24251FFF

        Style.rectangle(panel, { x = 12, y = y, width = -24, widthAnchor = 1, height = 44, colour = background })
        ItemIcon.add(panel, definition.display_item_id or definition.item_id, { x = 12, y = y + 2 }, definition.name)

        local quantity = panel:AddText({ text = "", x = 66, y = y + 10, width = 90, height = 24 })

        -- Untradeable supplies are priced by what they cost to make; the tooltip
        -- says so when the player hovers over the value.
        local note = definition.pricing == "recipe"
            and "Creation cost: made from its ingredients at GE buy prices." or definition.valuation_note

        local row = { quantity = quantity, y = y, note = note }
        rows[index] = row

        -- With numbers already in, fill() makes the value label with the right
        -- tooltip; without them, make it now with the usual note.
        if latest[index] then
            fill(index)
        else
            addValue(row, note)
        end
    end

    local function addRows(limit)
        local added = 0

        while added < limit and #rows < #definitions do
            local index = #rows + 1
            addRow(index, definitions[index])
            added = added + 1
        end

        return added
    end

    -- The hourly total shares the heading row, with its coin just to the left.
    local coinY = Style.middle(6, 26, 20)
    local coin = Style.coins(panel, { xAnchor = 1, y = coinY, size = 20 })
    local subtotal = panel:AddText({ text = "", x = valueRight - 130, xAnchor = 1, y = 6, width = 130, height = 26, colour = moneyColour, alignHorizontal = ui.AlignMode.BOTTOMRIGHT })

    local function update(values, total)
        latest = values

        for index in ipairs(rows) do
            fill(index)
        end

        subtotal.content = total and Style.number(total) .. (perRun and " / run" or " / h") or "Unavailable"
        Style.placeCoin(coin, subtotal.content, { rightEdge = valueRight, y = coinY, size = 20 })
    end

    return update, addRows
end

-- The header's title, plus a version dropdown when the method has several
-- versions (e.g. elder logs with or without wood spirits). The title and dropdown
-- are centred together as one unit, the dropdown right after the title. Picking
-- another version calls onVersion(method). Returns a release() for the dropdown's
-- pending callback (a no-op when there's no dropdown).
local VERSION_GAP = 10

local function mountTitle(view, method, guarded, versions, onVersion)
    -- One version: the usual centred "Title - Version" text.
    if not versions or #versions < 2 then
        local title = method.title .. (method.variant and " - " .. method.variant or "")

        view:AddTitle({
            text = title, absolute = true, x = 44, y = 10, width = -88, widthAnchor = 1, height = 28,
            alignHorizontal = ui.AlignMode.CENTRE,
        })

        return function() end
    end

    -- Several versions: the title alone, then the dropdown. Work out the pair's
    -- total width so both can be placed either side of the centre line.
    local titleWidth = Style.textWidth(method.title, true)
    local versionWidth = 0

    -- Fit the longest label, leaving room for the small native arrow and insets.
    for _, version in ipairs(versions) do
        versionWidth = math.max(versionWidth, Style.textWidth(version.variant) + 28)
    end

    local left = -math.floor((titleWidth + VERSION_GAP + versionWidth) / 2)

    view:AddTitle({
        text = method.title, absolute = true,
        x = left, xAnchor = 0.5, y = 10, width = titleWidth + 8, height = 28,
    })

    local entries, selected = {}, 0

    for index, version in ipairs(versions) do
        entries[index] = { id = index - 1, label = version.variant }

        if version == method then
            selected = index - 1
        end
    end

    local _, release = Dropdown.new(view.content, {
        x = left + titleWidth + VERSION_GAP, xAnchor = 0.5, y = 12,
        width = versionWidth,
        compact = true,
        entries = entries,
        selected = selected,
        owner = "profit-path-version",
        guarded = guarded,
        onChange = function(id)
            local chosen = versions[id + 1]

            if chosen and chosen ~= method then
                onVersion(chosen)
            end
        end,
    })

    return release
end

-- Builds the whole method screen inside `view`. `guarded` comes from the workbench:
-- wrap every callback with it, so clicks on a screen we've left are ignored.
--
-- options (all optional):
--   activeTab   reopen this tab, e.g. when the screen is rebuilt after a resize
--   versions    every version of this method, in catalogue order
--   onVersion   called with the chosen method when the player picks a version
--
-- Returns three functions: refresh(reason), which the workbench calls when the
-- account changes; activeTab(), which says which tab is open right now; and
-- release(), which stops the staged drawing and the version dropdown's pending
-- callback when the screen goes away.
function MethodView.mount(view, method, calculator, guarded, options)
    options = options or {}

    local activeTab = options.activeTab or 1
    local releaseTitle = mountTitle(view, method, guarded, options.versions, options.onVersion)

    -- buildTab[index] draws that tab's contents; it's set further down and cleared
    -- once the tab is drawn (see ROWS_PER_STEP at the top for why it waits).
    local buildTab = {}

    -- Tabs fill everything under the header, and stretch with the window.
    local tabs = view:AddTabs({
        { text = "Income" }, { text = "Requirements" },
        { text = "How to do it" }, { text = "Getting there" },
    }, {
        activeIndex = activeTab,

        -- Clicking a tab that isn't drawn yet draws it now, rather than showing an
        -- empty page until its turn comes.
        onChange = guarded(function(_, index)
            if buildTab[index] then
                buildTab[index]()
            end
        end),

        -- x = 0 matters: without it PrettyUI starts absolute items at its 14-unit
        -- default padding, which pushed the tabs right while keeping them full
        -- width (an extra gap on the left, and the right edge cut off).
        absolute = true, x = 0, y = HEADER_HEIGHT,
        width = 0, height = -HEADER_HEIGHT, widthAnchor = 1, heightAnchor = 1,
    })

    -- Income tab: the headline profit band first.
    local income = tabs:GetPage(1)
    -- Panels on the Income and Requirements pages get their final width once the
    -- whole screen is built (see Style.panelFitter).
    local incomeFitter = Style.panelFitter(income, PAGE_PADDING, TABLE_GAP)

    -- Filled in further down, but callbacks created before then need to see them.
    local render
    local ready = false

    -- The Wiki's risk warning comes first when the guide has one, in the Wiki's
    -- own words ({{MMGWarning}}), with the editors' reason underneath.
    if method.warning then
        income:AddText({
            text = "Warning from the Wiki: the methods in this guide may involve considerable risks, including "
                .. "(but not limited to) loss of money and goods, price volatility, and low GE sales volume.",
            colour = Style.bad, marginTop = 4,
        })

        income:AddText({ text = "Reason: " .. method.warning, colour = Style.gold, marginBottom = 4 })
    end

    -- Top row: a small rate panel on the left, the profit panel filling the rest.
    -- The rate sits beside the number it changes, so editing it and watching the
    -- profit move happen in one place.
    local ratePanel = incomeFitter:add(income:AddPanel({
        height = TOP_ROW_HEIGHT, width = RATE_WIDTH, scrollable = false, marginTop = 4, marginBottom = 6,
    }), TOP_ROW_HEIGHT, { fixed = RATE_WIDTH })

    -- First line: the label, with Reset at the right end.
    -- Wiki guides given only per hour use a pace instead (100 is the guide's own),
    -- and recurring runs a yield.
    local rateLabels = { ["% of guide pace"] = "Pace (% of guide)", ["% of guide yield"] = "Yield (% of guide)" }
    local rateLabel = rateLabels[method.income.rate.unit] or "Rate per hour"
    ratePanel:AddText({ text = rateLabel, x = TOP_INSET, y = FIRST_LINE_Y, width = 150, height = 28, colour = Style.muted, tooltip = method.income.rate.unit })

    -- SetText(..., false) puts the default back without firing onChange, so the reset
    -- doesn't count as the player typing. `rate` is the box made just below.
    local rate

    Style.iconButton(ratePanel, "reset", "Reset", "Reset to source rate", guarded(function()
        if calculator:reset() then
            rate:SetText(tostring(calculator.rate), false)
        end

        render()
    end), { right = TOP_INSET, y = FIRST_LINE_Y })

    -- Second line: the box, with Save at the right end. The box takes whatever
    -- width Save leaves (Save is wider when it falls back to a text button).
    local saveWidth = Style.iconButtonWidth("save")

    -- Typing previews straight away; Enter saves. The input can report changes while
    -- the screen is still being built, before render exists, so `ready` holds those off.
    rate = ratePanel:AddTextField({
        text = tostring(calculator.rate),
        maxLength = 24,
        x = TOP_INSET, y = SECOND_LINE_Y, height = 28,
        width = -(TOP_INSET + 10 + saveWidth + TOP_INSET), widthAnchor = 1,

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

    Style.iconButton(ratePanel, "save", "Save", "Save rate", guarded(function()
        calculator:save(rate:GetText())
        render()
    end), { right = TOP_INSET, y = SECOND_LINE_Y })

    -- The profit panel starts one TABLE_GAP after the rate panel and runs to the
    -- page's right padding.
    local summaryX = PAGE_PADDING + RATE_WIDTH + TABLE_GAP
    local summary = incomeFitter:add(income:AddPanel({
        height = TOP_ROW_HEIGHT, x = summaryX, width = -(summaryX + PAGE_PADDING), widthAnchor = 1,
        inline = true, scrollable = false,
    }), TOP_ROW_HEIGHT, { rest = RATE_WIDTH })

    local perRun = method.income.period == "run"
    local profitLabel = perRun and "Profit per run (after tax)" or "Profit per hour (after tax)"
    summary:AddText({ text = profitLabel, x = TOP_INSET, y = FIRST_LINE_Y, width = 200, colour = Style.muted })

    -- Unsaved changes and errors show at the top right of the profit panel, right
    -- beside the rate box, so they're hard to miss. They start a clear gap after
    -- the label's measured width, so a long message never runs into it.
    local stateX = TOP_INSET + math.ceil(Style.textWidth(profitLabel)) + 16

    local state = summary:AddText({
        text = "", x = stateX, y = FIRST_LINE_Y, width = -(stateX + TOP_INSET), widthAnchor = 1, height = 24,
        colour = Style.muted, alignHorizontal = ui.AlignMode.BOTTOMRIGHT,
    })

    -- The headline: profit per hour in the biggest bold font, with a matching coin,
    -- and ROI a step smaller. Both sit on the second line, centred together.
    local headlineY = SECOND_LINE_Y - 8
    local headlineHeight = 36

    Style.coins(summary, { x = TOP_INSET, y = Style.middle(headlineY, headlineHeight, 26), size = 26 })

    local profit = Style.setFont(summary:AddText({
        text = "", x = TOP_INSET + 32, y = headlineY, width = -260, widthAnchor = 1, height = headlineHeight,
        colour = Style.gold,
    }), Style.HEADLINE_FONT)

    -- ROI hugs the right edge, TOP_INSET in, matching the left side.
    local roi = Style.setFont(summary:AddText({
        text = "", x = -(200 + TOP_INSET), xAnchor = 1, y = headlineY, width = 200, height = headlineHeight,
        colour = Style.gold, alignHorizontal = ui.AlignMode.BOTTOMRIGHT,
    }), Style.SUBHEADLINE_FONT)

    -- Inputs and Outputs side by side, both sized for the longer of the two lists.
    local outputDefinitions = Loot.outputs(method.income)
    local rowCount = math.max(#method.income.inputs, #outputDefinitions, 1)
    local tableHeight = 74 + rowCount * 46

    -- Each table takes half the page. The page keeps PAGE_PADDING clear on both
    -- outer edges (like the full-width summary above), with TABLE_GAP between the
    -- two tables: Inputs ends TABLE_GAP/2 left of the middle, Outputs starts
    -- TABLE_GAP/2 right of it.
    local halfWidth = -(PAGE_PADDING + TABLE_GAP / 2)

    local inputs = incomeFitter:add(income:AddPanel({
        height = tableHeight, width = halfWidth, widthAnchor = 0.5, scrollable = false, marginTop = 0,
    }), tableHeight, true)

    local outputs = incomeFitter:add(income:AddPanel({
        height = tableHeight,
        x = TABLE_GAP / 2, xAnchor = 0.5,
        width = halfWidth, widthAnchor = 0.5,
        inline = true,
        scrollable = false,
    }), tableHeight, true)

    inputs:AddText({ text = "Inputs", x = 12, y = 6, width = 88, colour = Style.gold, height = 26, tooltip = "Supply costs use the last hour's average instant-buy price (the latest trade if there were none). Actual purchase prices may differ." })
    outputs:AddText({ text = "Outputs", x = 12, y = 6, width = 88, colour = Style.gold, height = 26, tooltip = "GE outputs use the last hour's average instant-sell price (the latest trade if there were none), after tax. Coin drops and alchemy proceeds are untaxed. Your pace and luck affect profit." })

    -- Costs read red and earnings green, so it's obvious at a glance which way
    -- the money goes. The "Inputs"/"Outputs" headings still say it in words.
    -- Each table's update function, plus addRows to draw its item rows later.
    local inputTable, outputTable = {}, {}
    inputTable.update, inputTable.addRows = itemTable(inputs, method.income.inputs, Style.bad, method.income.period)
    outputTable.update, outputTable.addRows = itemTable(outputs, outputDefinitions, Style.good, method.income.period)

    income:AddTitle("Notes")

    for _, assumption in ipairs(method.income.assumptions) do
        income:AddText({ text = assumption, colour = Style.muted })
    end

    -- The other three tabs. Each is drawn once, when its turn comes or when it's
    -- clicked, whichever is first.
    -- These stay nil until the Requirements tab is drawn.
    local refreshRequirements, refreshOwnership

    buildTab[2] = function()
        buildTab[2] = nil

        local requirements = tabs:GetPage(2)
        local requirementsFitter = Style.panelFitter(requirements, PAGE_PADDING, TABLE_GAP)
        refreshRequirements, refreshOwnership = mountRequirements(requirements, method, calculator, requirementsFitter)

        -- Every panel exists now, so size them to the page's final width (see
        -- Style.panelFitter), then colour the checks.
        requirementsFitter:fit()
        refreshRequirements()
        refreshOwnership()
    end

    buildTab[3] = function()
        buildTab[3] = nil

        local instructions = tabs:GetPage(3)
        instructions:AddTitle("Activity steps")

        for index, step in ipairs(method.instructions) do
            instructions:AddText({ text = index .. ". " .. step, marginTop = 10, marginBottom = 12 })
        end

        -- Imported methods don't have our own steps yet; point at the Wiki guide.
        if #method.instructions == 0 then
            instructions:AddText({ text = "Steps haven't been written for this activity yet. The Wiki guide \""
                .. method.source.title .. "\" explains how to do it.", colour = Style.muted })
        end
    end

    buildTab[4] = function()
        buildTab[4] = nil

        local travel = tabs:GetPage(4)
        local sections = method.location.sections or {}

        -- Area headings replace the condensed location line when several places
        -- are offered. Keep standalone/generic locations' normal description.
        if #sections < 2 and (#sections == 0 or sections[1].title ~= method.location.text) then
            travel:AddText(method.location.text)
        end

        -- Shared itineraries remain above the individual locations. These are
        -- reading-only directions, never live navigation or game actions.
        for _, route in ipairs(method.location.routes or {}) do
            travel:AddText({ text = route, colour = Style.muted })
        end

        for _, section in ipairs(sections) do
            travel:AddTitle(section.title)

            for _, route in ipairs(section.routes) do
                travel:AddText({ text = "- " .. route, colour = Style.muted })
            end
        end

        if method.location.coverage ~= "complete" then
            travel:AddText({ text = "Travel details are still being prepared for this activity.", colour = Style.muted })
        end
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
            messages[#messages + 1] = result.message or "Income estimate unavailable: some prices or costs are missing."
        elseif result.note then
            -- An output with no price that was counted as 0 (see Income.calculate).
            messages[#messages + 1] = result.note
        end

        state.content = table.concat(messages, " / ")
        state.rgba = calculator.message and Style.bad or Style.muted

        -- Headline profit and ROI use the same money colours as the Outputs and
        -- Browse figures: green for a profit, red for a loss. "Not estimated" stays
        -- gold. No ROI means no text at all.
        local headlineColour = Style.gold

        if result.profit then
            profit.content = Style.number(result.profit) .. (perRun and " / run" or " / h")
            headlineColour = result.profit < 0 and Style.bad or Style.good
        else
            profit.content = "Not estimated"
        end

        profit.rgba = headlineColour
        roi.content = result.roi and Style.number(result.roi, 1) .. "% ROI" or ""
        roi.rgba = result.roi and (result.roi < 0 and Style.bad or Style.good) or headlineColour

        outputTable.update(result.outputs or {}, result.revenue)
        inputTable.update(result.inputs or {}, result.cost)
    end

    -- Every Income panel exists now (their heights already allow for every item
    -- row), so we know whether the page grew a scrollbar: size the panels to its
    -- final width, then allow input handling and fill in the first numbers.
    incomeFitter:fit()

    ready = true

    render()

    -- Draws one more piece of the screen. Returns false once it's all drawn.
    local function buildStep()
        if inputTable.addRows(ROWS_PER_STEP) + outputTable.addRows(ROWS_PER_STEP) > 0 then
            return true
        end

        for index = 2, 4 do
            if buildTab[index] then
                buildTab[index]()
                return true
            end
        end

        return false
    end

    -- Whatever's on screen first: the open tab, and the first Income rows.
    if buildTab[activeTab] then
        buildTab[activeTab]()
    end

    local building = buildStep()

    -- Then the rest, a piece per tick.
    local function stopBuilding()
        if building then
            building = false
            Event.Logic.Unsubscribe(BUILD_EVENT)
        end
    end

    if building then
        Event.Logic.Subscribe(BUILD_EVENT, guarded(function()
            -- If a piece fails to draw, stop here and report it once. Carrying on
            -- would retry the same piece every tick, 50 errors a second.
            local ok, more = pcall(buildStep)

            if not ok or not more then
                stopBuilding()
            end

            if not ok then
                error(more, 0)
            end
        end))
    end

    -- Skill changes can't affect item borders, and inventory changes can't affect
    -- skill levels or prices, so each reason only redoes the work it can change.
    local function refresh(reason)
        if reason ~= "inventory" then
            render()
        end

        -- Nothing to recolour until the Requirements tab is drawn.
        if refreshRequirements then
            refreshRequirements()
            refreshOwnership()
        end
    end

    local function currentTab()
        return tabs:GetActiveIndex()
    end

    -- Leaving the screen stops the drawing, as well as the version dropdown.
    local function release()
        stopBuilding()
        releaseTitle()
    end

    return refresh, currentTab, release
end

return MethodView
