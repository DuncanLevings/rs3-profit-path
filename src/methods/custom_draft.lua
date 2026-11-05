-- The custom activity editor's working copy, with no UI (Phase 9, slice 4).
--
-- The editor screen (src/ui/method_editor.lua) only draws and forwards clicks.
-- Everything it decides lives here, where tests can reach it:
--   * starting a draft: blank, from a monster, or from a thieving target;
--   * which state each loaded drop comes in (counted, off, or needs a number);
--   * which source drops don't fit under the output limit ("left out");
--   * what the preview strip says, and whether Save is allowed.
--
-- A draft is just a custom record without an ID (see custom_methods.lua), so
-- saving it is CustomMethods.store(db):create(draft) and nothing else.
local CustomMethods = require("src/methods/custom_methods")
local Income = require("src/methods/income")
local Loot = require("src/methods/loot")

local Draft = {}

-- Where loaded drops come from. Both readers share one format.
local SOURCES = {
    monster = require("src/data/monster_data"),
    thieving = require("src/data/thieving_data"),
}

-- The coins item. Coins are worth exactly 1 GP each, so they're a fixed amount
-- (no GE price, no GE tax) rather than a GE item.
local COINS = 995

-- ---- Which state a loaded drop comes in ------------------------------------------
--
-- Drop notes are free text from the Wiki. A note that RESTRICTS when the drop
-- happens (a Slayer task, an event month, "only if not already owned", a quest
-- stage) means the drop shouldn't count by default. A note that only adds
-- information (a better rate with luck, "this rate is approximate", a citation)
-- doesn't. Anything we don't recognise is treated as a restriction: guessing
-- "counted" could only make an activity look better than it is.
--
-- A note counts as information only if EVERY sentence in it matches one of these.
-- They're matched against lower-case text, as plain substrings.
local INFORMATIONAL = {
    -- Luck changes the rate; the base rate (what we use) still holds.
    "with tier", "tier 1 luck", "tier 2 luck", "tier 3 luck", "tier 4 luck", "luck or higher",
    "luck is active", "lucky charm", "luck decreases", "luck increases",
    -- Our own importer's notes.
    "the wiki marks this rate as approximate", "the wiki also lists a rate of",
    -- Citations the Wiki attaches to a rate.
    "jagex.", "twitter", "archived from", "youtube", "modcast", "q&a",
    -- Order or roll mechanics that don't change the per-kill rate.
    "dropped in order", "rolls separately",
}

-- Words that always mean a restriction, even next to luck text ("only dropped if
-- tier 4 luck is not active").
local RESTRICTING = { "only", "unless", "until", "not active", "requires", "during", "before", "after" }

local function sentences(note)
    local list = {}

    -- Sentences end with ". ", or a line break (citations come on new lines).
    for piece in (note .. "\n"):gsub("%.%s+", ".\n"):gmatch("([^\n]*)\n") do
        local trimmed = piece:match("^%s*(.-)%s*$")

        if trimmed ~= "" then
            list[#list + 1] = trimmed
        end
    end

    return list
end

local function containsAny(text, words)
    for _, word in ipairs(words) do
        if text:find(word, 1, true) then
            return true
        end
    end

    return false
end

-- True if a source note restricts when the drop happens (so the row starts off).
-- No note, or only informational sentences, is false.
function Draft.isConditional(note)
    if type(note) ~= "string" or not note:find("%S") then
        return false
    end

    for _, sentence in ipairs(sentences(note)) do
        local lower = sentence:lower()

        -- A bare number or fraction left over from a rate ("1/496.") is information.
        local bare = lower:gsub("[%d%s%p]", "") == ""

        if not bare and (containsAny(lower, RESTRICTING) or not containsAny(lower, INFORMATIONAL)) then
            return true
        end
    end

    return false
end

-- A source note made safe for a row: one line, at most the row-note limit.
local function rowNote(note)
    if type(note) ~= "string" then
        return nil
    end

    local flat = note:gsub("%c", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    local limit = CustomMethods.LIMITS.requirementNote

    if flat == "" then
        return nil
    end

    if #flat > limit then
        flat = flat:sub(1, limit - 3):gsub("%s+%S*$", "") .. "..."
    end

    return flat
end

local function shorten(text, limit)
    return #text > limit and text:sub(1, limit) or text
end

-- ---- Starting a draft ---------------------------------------------------------

-- An empty record the editor fills in, of `category` (PvM if not given). It
-- doesn't pass validation yet (no name).
function Draft.blank(category)
    local draft = {
        schema = 1,
        title = "",
        category = "pvm",
        rate = { unit = "kills/hour", default = 0 },
        outputs = {},
        supplies = {},
        requirements = { required = {}, recommended = {} },
    }

    Draft.setCategory(draft, category or "pvm")
    return draft
end

-- Changes a draft's category and keeps the rest consistent with it:
--   * daily/weekly counts runs (default 1), every row per run, and has a how-often;
--   * the others count kills (PvM) or actions per hour;
--   * "No requirements needed" only exists for production and daily/weekly.
function Draft.setCategory(draft, category)
    local was = draft.category
    draft.category = category

    if category == "recurring" then
        if was ~= "recurring" or draft.rate.unit ~= "runs" then
            draft.rate = { unit = "runs", default = 1 }
        end

        draft.recurrence = draft.recurrence or { every = "day" }
        draft.actions_per_trip = nil

        for _, side in ipairs({ "outputs", "supplies" }) do
            for _, row in ipairs(draft[side]) do
                row.basis = "action"
            end
        end
    else
        draft.recurrence = nil

        if draft.rate.unit == "runs" then
            draft.rate = { unit = "actions/hour", default = 0 }
        end

        -- A new draft follows its category; a player's own choice is kept.
        if was == nil or draft.rate.default == 0 and #draft.outputs == 0 then
            draft.rate.unit = category == "pvm" and "kills/hour" or "actions/hour"
        end

        -- A thieving target is never killed: always actions per hour.
        if draft.source and draft.source.kind == "thieving" then
            draft.rate.unit = "actions/hour"
        end
    end

    if category ~= "production" and category ~= "recurring" then
        draft.no_requirements = nil
    end
end

-- Source titles matching `query`, for the picker. kind is "monster" or "thieving".
function Draft.searchSources(kind, query, limit)
    return SOURCES[kind].search(query, limit)
end

-- The last source decoded. The editor asks for the same source's rows on every
-- preview update, and a big monster has hundreds of drops, so keep one.
local lastKey, lastRows, lastRecord

-- Every drop of a source as an output row, in the Wiki's order, each with the
-- state it starts in. Returns nil for an unknown source. The rows are always
-- fresh copies: the editor adds them to drafts and then edits them.
function Draft.sourceRows(kind, title)
    local key = tostring(kind) .. "|" .. tostring(title)

    if key ~= lastKey then
        lastRows, lastRecord = Draft.decodeSource(kind, title)
        lastKey = key
    end

    if not lastRows then
        return nil
    end

    return Draft.copy(lastRows), lastRecord
end

function Draft.decodeSource(kind, title)
    local record = SOURCES[kind] and SOURCES[kind].find(title)

    if not record then
        return nil
    end

    local rows = {}

    for sectionIndex, section in ipairs(record.sections) do
        for dropIndex, drop in ipairs(section.drops) do
            local expected = Loot.expected(drop)
            local row = {
                label = shorten(drop.name, CustomMethods.LIMITS.label),
                quantity = expected,
                basis = "action",
                source_key = sectionIndex .. ":" .. dropIndex,
                note = rowNote(drop.notes),
            }

            -- How the row is valued: coins at 1 GP, a GE item at its price, and
            -- anything else (untradeable) waits for the player's own GP value.
            local sellable = drop.item_id and not drop.untradeable

            -- Every row keeps its item ID when it has one: GE rows are priced by
            -- it, and coins and untradeables (charms) use it for their picture.
            row.item_id = drop.item_id

            if drop.item_id == COINS then
                row.pricing, row.unit_value = "fixed", 1
            elseif sellable then
                row.pricing = "ge"
            else
                row.pricing = "fixed"
            end

            -- The three states (see the editor plan): restricted or unvalued drops
            -- start off; unreadable rates wait for a number; the rest count.
            if Draft.isConditional(drop.notes) then
                row.state = "off"
            elseif row.pricing == "fixed" and row.unit_value == nil then
                row.state = "off"
                row.note = "Can't be sold on the GE. Set your own GP value to count it."
            elseif expected == nil then
                row.state = "needs"
            else
                row.state = "included"
            end

            rows[#rows + 1] = row
        end
    end

    return rows, record
end

-- What one output row is worth per kill/action at these quotes, for ranking.
-- Unknown values count as 0, so they're the first to be left out.
function Draft.valuePerAction(row, quotes)
    if row.quantity == nil or row.basis ~= "action" then
        return 0
    end

    local price = row.unit_value

    if row.pricing == "ge" then
        local quote = quotes and quotes[row.item_id]
        price = row.price or (quote and (quote.low or quote.high))
    end

    if type(price) ~= "number" or price ~= price or price == math.huge then
        return 0
    end

    return row.quantity * price
end

-- Picks which rows fit under the output limit: the most valuable per kill at
-- these quotes, kept in source order. Returns kept, leftOut. Leaving drops out
-- can only make the profit look lower, never higher.
local function fit(rows, quotes)
    local limit = CustomMethods.LIMITS.outputs

    if #rows <= limit then
        return rows, {}
    end

    local ranked = {}

    for index, row in ipairs(rows) do
        ranked[index] = { row = row, index = index, value = Draft.valuePerAction(row, quotes) }
    end

    -- Most valuable first; ties keep the source order so results are stable.
    table.sort(ranked, function(left, right)
        if left.value ~= right.value then
            return left.value > right.value
        end

        return left.index < right.index
    end)

    local keep = {}

    for position = 1, limit do
        keep[ranked[position].index] = true
    end

    local kept, leftOut = {}, {}

    for index, row in ipairs(rows) do
        if keep[index] then
            kept[#kept + 1] = row
        else
            leftOut[#leftOut + 1] = row
        end
    end

    return kept, leftOut
end

-- A draft seeded from a monster or thieving target: all its drops (up to the
-- limit), a suggested name, the category and throughput unit, and for thieving
-- the Thieving level as a Required check. `quotes` (optional) ranks drops when
-- there are too many. Returns the draft, or nil plus a message.
function Draft.fromSource(kind, title, quotes)
    local rows, source = Draft.sourceRows(kind, title)

    if not rows then
        return nil, "That source isn't in the bundled data."
    end

    local draft = Draft.blank()
    draft.source = { kind = kind, title = shorten(source.title, CustomMethods.LIMITS.requirementNote) }
    draft.outputs = fit(rows, quotes)

    if kind == "thieving" then
        draft.title = shorten("Thieving: " .. source.title, CustomMethods.LIMITS.title)
        draft.category = "skilling"
        draft.rate.unit = "actions/hour"

        if source.level then
            draft.requirements.required[1] = { kind = "skill", skill = "THIEVING", level = source.level }
        end
    else
        draft.title = shorten("Killing " .. source.title, CustomMethods.LIMITS.title)
    end

    return draft
end

-- A bundled requirement tree flattened into custom checks. Levels, combat level and
-- quests stay checks; anything else (items, gear, unlocks, "any of" choices)
-- becomes a note with the source's own wording, for the player to check.
-- An item node as a custom item check, or nil if it isn't a plain item.
local function itemCheck(node)
    if node.kind == "item" and math.type(node.itemId) == "integer" and type(node.text) == "string" then
        local quantity = math.type(node.quantity) == "integer" and node.quantity >= 1 and node.quantity or 1
        return { item_id = node.itemId, name = shorten(node.text, CustomMethods.LIMITS.label), quantity = quantity }
    end
end

local function flattenRequirements(node, into, skipped, depth)
    if type(node) ~= "table" then
        return
    end

    depth = depth or 0

    local limit = CustomMethods.LIMITS.requirements
    local function add(check)
        if #into < limit then
            into[#into + 1] = check
        else
            skipped.requirements = skipped.requirements + 1
        end
    end

    -- A nested "any"/"all" made only of items (two pickaxes, an outfit) stays
    -- one check: the game can still see whether you own them.
    local children = node.children or {}

    if depth > 0 and (node.kind == "any" or node.kind == "all") and #children >= 2
        and #children <= CustomMethods.LIMITS.groupItems and type(node.text) == "string" then
        local items = {}

        for _, child in ipairs(children) do
            items[#items + 1] = itemCheck(child) or false
        end

        local allItems = true

        for _, item in ipairs(items) do
            allItems = allItems and item ~= false
        end

        if allItems then
            add({ kind = "items", mode = node.kind, name = shorten(node.text, CustomMethods.LIMITS.requirementNote), items = items })
            return
        end
    end

    if node.kind == "all" then
        for _, child in ipairs(children) do
            flattenRequirements(child, into, skipped, depth + 1)
        end
    elseif itemCheck(node) then
        local check = itemCheck(node)
        check.kind = "item"
        add(check)
    elseif node.kind == "skill" and type(node.skill) == "string" and type(node.level) == "number" then
        add({ kind = "skill", skill = node.skill, level = node.level })
    elseif node.kind == "combat_level" and type(node.level) == "number" then
        add({ kind = "combat_level", level = node.level })
    elseif node.kind == "quest" and type(node.quest) == "string" and type(node.text) == "string" then
        add({ kind = "quest", quest = node.quest, name = shorten(node.text, CustomMethods.LIMITS.requirementNote) })
    elseif type(node.text) == "string" and node.text:find("%S") then
        add({ kind = "note", text = rowNote(node.text) })
    end
end

-- A draft copied from a bundled activity ("Duplicate as custom"). Its outputs,
-- supplies, rate and requirements come across as far as custom records can hold
-- them. Returns the draft plus what didn't fit:
--   { outputs = n, supplies = n, requirements = n, recipes = { labels } }
-- Recurring activities can't be custom (no per-run model), so they return nil.
function Draft.fromMethod(method, quotes)
    -- Bundled daily/weekly guides count a percentage of the guide's yield, which
    -- doesn't map onto custom runs one for one, so those aren't copied (yet).
    if method.category ~= "pvm" and method.category ~= "skilling" and method.category ~= "production" then
        return nil, "Daily and weekly activities can't be copied as custom activities."
    end

    local skipped = { outputs = 0, supplies = 0, requirements = 0, recipes = {} }
    local draft = Draft.blank()
    local income = method.income

    draft.title = shorten(method.title .. (method.variant and (" - " .. method.variant) or ""), CustomMethods.LIMITS.title)
    draft.category = method.category
    draft.rate = {
        unit = method.category == "pvm" and "kills/hour" or "actions/hour",
        default = income.rate.default,
    }

    -- One income line as a custom row. Recipe-priced supplies (untradeable things
    -- you make yourself) have no custom equivalent yet, so they're reported.
    local function row(line)
        if line.pricing == "recipe" then
            skipped.recipes[#skipped.recipes + 1] = line.name
            return nil
        end

        local copy = {
            label = shorten(line.name, CustomMethods.LIMITS.label),
            quantity = line.quantity,
            basis = line.basis or "hour",
        }

        if line.pricing == "fixed" then
            copy.pricing, copy.unit_value = "fixed", line.unit_value
            copy.item_id = line.display_item_id or line.item_id
        elseif line.item_id == COINS then
            copy.pricing, copy.unit_value, copy.item_id = "fixed", 1, COINS
        else
            copy.pricing, copy.item_id = "ge", line.item_id
        end

        return copy
    end

    local outputs = {}

    for _, line in ipairs(Loot.outputs(income)) do
        local copy = row(line)

        if copy then
            copy.state = "included"
            outputs[#outputs + 1] = copy
        end
    end

    local kept, leftOut = fit(outputs, quotes)
    draft.outputs = kept
    skipped.outputs = #leftOut

    for _, line in ipairs(income.inputs) do
        local copy = row(line)

        if copy and #draft.supplies < CustomMethods.LIMITS.supplies then
            draft.supplies[#draft.supplies + 1] = copy
        elseif copy then
            skipped.supplies = skipped.supplies + 1
        end
    end

    if Income.usesTrips(income) then
        draft.actions_per_trip = income.actions_per_trip
    end

    -- The bundled activity's steps become the copy's notes, so nothing the player
    -- could read before is lost. One line each, within the note limits.
    local steps = {}

    for _, step in ipairs(method.instructions or {}) do
        local flat = type(step) == "string" and step:gsub("%c", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""

        if flat ~= "" and #steps < CustomMethods.LIMITS.steps then
            if #flat > CustomMethods.LIMITS.notes then
                flat = flat:sub(1, CustomMethods.LIMITS.notes - 3):gsub("%s+%S*$", "") .. "..."
            end

            steps[#steps + 1] = flat
        end
    end

    draft.notes = #steps > 0 and steps or nil

    flattenRequirements(method.requirements.access, draft.requirements.required, skipped)

    -- Recommended shares the one requirement limit with Required.
    local recommended = {}
    flattenRequirements(method.requirements.recommended, recommended, skipped)

    for _, check in ipairs(recommended) do
        if #draft.requirements.required + #draft.requirements.recommended < CustomMethods.LIMITS.requirements then
            draft.requirements.recommended[#draft.requirements.recommended + 1] = check
        else
            skipped.requirements = skipped.requirements + 1
        end
    end

    return draft, skipped
end

-- The source drops not in the draft right now (left out at the limit, or removed
-- by the player), in source order, so they can be added back.
function Draft.missingSourceRows(draft)
    if not draft.source then
        return {}
    end

    local rows = Draft.sourceRows(draft.source.kind, draft.source.title) or {}
    local present, missing = {}, {}

    for _, row in ipairs(draft.outputs) do
        if row.source_key then
            present[row.source_key] = true
        end
    end

    for _, row in ipairs(rows) do
        if not present[row.source_key] then
            missing[#missing + 1] = row
        end
    end

    return missing
end

-- ---- What the preview strip says -------------------------------------------------

-- Everything the strip shows, from the draft as it stands:
--   result      Income.calculate's result (nil if the draft can't be priced yet)
--   problems    validation problems; Save stays off while there are any
--   counts      { outputs, supplies, requirements } against the limits
--   leftOut     { count, value } for source drops not in the draft
function Draft.preview(draft, quotes)
    local ok, problems = CustomMethods.validate(Draft.withPlaceholderId(draft))
    local preview = { problems = ok and {} or problems }

    local requirements = #draft.requirements.required + #draft.requirements.recommended

    preview.counts = {
        outputs = #draft.outputs, supplies = #draft.supplies, requirements = requirements,
    }

    -- Price only a valid draft: an invalid one has nothing trustworthy to add up.
    if ok then
        local method = CustomMethods.toMethod(Draft.withPlaceholderId(draft))
        preview.result = Income.calculate(method.income, draft.rate.default, quotes or {})
        preview.coverage = method.income.coverage
    end

    local missing = Draft.missingSourceRows(draft)
    local value = 0

    for _, row in ipairs(missing) do
        if row.state == "included" then
            value = value + Draft.valuePerAction(row, quotes)
        end
    end

    preview.leftOut = { count = #missing, value = value }

    return preview
end

-- Validation wants an ID; a new draft gets one only when it's saved.
function Draft.withPlaceholderId(draft)
    if draft.id then
        return draft
    end

    local copy = {}

    for key, value in pairs(draft) do
        copy[key] = value
    end

    copy.id = "custom.0"
    return copy
end

-- A deep copy, so editing never touches a saved record until Save works.
function Draft.copy(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}

    for key, item in pairs(value) do
        copy[key] = Draft.copy(item)
    end

    return copy
end

return Draft
