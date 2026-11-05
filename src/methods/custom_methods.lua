-- Custom activities: the player's own money-making recipes (Phase 9).
--
-- This file owns three things, and no UI:
--   1. the saved record format, and checking a record before we trust it
--      (records come from storage, and later from pasted imports, so they're
--      untrusted: anything could be in them);
--   2. turning a valid record into the same method shape the bundled catalogue
--      uses, so the shared calculator, Browse and favourites need no special cases;
--   3. saving, loading and deleting records in PersistentDB.
--
-- On screen these are "Custom activities". In code they're methods, like the
-- bundled ones, with `origin = "custom"`.
--
-- Storage contract (shared by every profile on this computer; favourites, rates and
-- hiding stay per profile as before):
--   profit-path.custom.v1/index        { schema = 1, next = n, ids = { "custom.1", ... } }
--   profit-path.custom.v1/custom.<n>   one record per activity
-- One key per activity means a failed or oversized write can only affect that one
-- activity. IDs are never reused, so a leftover favourite, rate or history entry for
-- a deleted activity can never point at a different one later.
local CustomMethods = {}

local INDEX_KEY = "profit-path.custom.v1/index"
local RECORD_PREFIX = "profit-path.custom.v1/"

-- Size limits. They exist so nobody can build an activity big enough to run the
-- client out of native UI IDs (Mega Shop Run's page did, at ~112 tooltips). They're
-- provisional until the editor's pages are measured (Phase 9 plan, slice 4).
CustomMethods.LIMITS = {
    outputs = 40,
    supplies = 15,
    requirements = 25,
    groupItems = 10,
    activities = 100,
    title = 60,
    notes = 300,
    steps = 10,
    incomeNotes = 6,
    label = 80,
    requirementNote = 120,
}

-- Categories a custom activity can use. Recurring (daily/weekly/monthly) ones
-- count per run instead of per hour: every row is per run, and the rate is how
-- many runs to count (usually 1).
local CATEGORIES = { pvm = true, skilling = true, production = true, recurring = true }

local RECURRENCES = { day = true, week = true, month = true }

-- What lists call each category (Browse's second line for a custom activity).
local CATEGORY_LABELS = { pvm = "PvM", skilling = "Skilling", production = "Production", recurring = "Daily / weekly" }

-- Which categories must have at least one requirement the game can check. A PvM
-- or skilling activity always needs *something* (a level, at least). Production
-- ranges from smithing to buying and decanting, so it may say "none needed".
local NEEDS_TRACKED_CHECK = { pvm = true, skilling = true }

-- The throughput units a custom activity can use, and their saved-rate keys.
local RATE_KEYS = { ["kills/hour"] = "kills_per_hour", ["actions/hour"] = "actions_per_hour", runs = "runs" }

local BASES = { action = true, trip = true, hour = true }

-- Output rows can be switched off (a conditional drop) or waiting for a number
-- (an unreadable Wiki rate). Supply rows are always counted.
local OUTPUT_STATES = { included = true, off = true, needs = true }

-- The client's SkillType names (developer.runescape.com/rs/game/player.html,
-- checked 4 Nov 2026). Constitution is HITPOINTS there.
local SKILLS = {}

-- The same names as a list, in the client's order (the editor's skill search).
CustomMethods.SKILLS = {}

for _, name in ipairs({
    "ATTACK", "DEFENCE", "STRENGTH", "HITPOINTS", "RANGED", "PRAYER", "MAGIC", "COOKING",
    "WOODCUTTING", "FLETCHING", "FISHING", "FIREMAKING", "CRAFTING", "SMITHING", "MINING",
    "HERBLORE", "AGILITY", "THIEVING", "SLAYER", "FARMING", "RUNECRAFTING", "HUNTER",
    "CONSTRUCTION", "SUMMONING", "DUNGEONEERING", "DIVINATION", "INVENTION", "ARCHAEOLOGY",
    "NECROMANCY",
}) do
    SKILLS[name] = true
    CustomMethods.SKILLS[#CustomMethods.SKILLS + 1] = name
end

-- Readable skill names for the screen. The client's names are upper case, and it
-- calls Constitution HITPOINTS.
function CustomMethods.skillName(skill)
    if skill == "HITPOINTS" then
        return "Constitution"
    end

    return skill:sub(1, 1) .. skill:sub(2):lower()
end

-- The client's skill name for what a player typed ("slayer", "Constitution",
-- "hitpoints"), or nil if it isn't a skill.
function CustomMethods.skillFromName(typed)
    local name = type(typed) == "string" and typed:match("^%s*(.-)%s*$"):upper() or ""

    if name == "CONSTITUTION" then
        name = "HITPOINTS"
    end

    return SKILLS[name] and name or nil
end

-- The non-blank lines of a list (or of one string, as a list of one).
function CustomMethods.lines(list)
    local lines = {}

    if type(list) == "string" then
        list = { list }
    end

    for _, line in ipairs(type(list) == "table" and list or {}) do
        if type(line) == "string" and line:find("%S") then
            lines[#lines + 1] = line
        end
    end

    return lines
end

-- A record's notes as a list of non-blank steps (an old single note is one step).
function CustomMethods.steps(record)
    return CustomMethods.lines(record.notes)
end

-- GE sale tax: 2%, rounded down per item, the same as bundled outputs.
local GE_TAX_DENOMINATOR = 50

-- ---- Small checks ---------------------------------------------------------------

-- A real number from 0 upwards. Rejects NaN (fails >=), infinity and non-numbers.
local function nonNegativeFinite(value)
    return type(value) == "number" and value >= 0 and value < math.huge
end

-- Stored numbers can come back as floats (4.0), so check the value, not the type.
local function wholeNumber(value, low, high)
    return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
end

-- Non-blank text within a length limit, with no control characters (they'd
-- break labels and have no business in a name).
local function text(value, limit)
    return type(value) == "string" and value:find("%S") ~= nil and #value <= limit and not value:find("%c")
end

-- ---- Checking a record ----------------------------------------------------------

-- Checks one income row. `side` is "outputs" or "supplies". Adds a message to
-- `problems` for anything wrong and returns nothing.
local function checkRow(row, side, index, problems)
    local where = side .. " row " .. index

    if type(row) ~= "table" then
        problems[#problems + 1] = where .. " is not a record."
        return
    end

    if not text(row.label, CustomMethods.LIMITS.label) then
        problems[#problems + 1] = where .. " needs a name of at most " .. CustomMethods.LIMITS.label .. " characters."
    end

    if not BASES[row.basis] then
        problems[#problems + 1] = where .. " must be per kill/action, per trip or per hour."
    end

    -- Only a counted row must be complete. An output waiting for a number may lack
    -- its quantity, and one that's switched off may lack its quantity or GP value
    -- (an untradeable drop, say): neither is counted until the player fills it in.
    local state = row.state or "included"

    if side == "outputs" then
        if not OUTPUT_STATES[state] then
            problems[#problems + 1] = where .. " has an unknown state."
        end
    elseif row.state ~= nil then
        problems[#problems + 1] = where .. ": supplies are always counted."
    end

    if state == "included" and not nonNegativeFinite(row.quantity) then
        problems[#problems + 1] = where .. " needs a quantity of 0 or more."
    end

    if state ~= "included" and row.quantity ~= nil and not nonNegativeFinite(row.quantity) then
        problems[#problems + 1] = where .. " needs a quantity of 0 or more."
    end

    -- Where a seeded row came from in its source's drop table ("section:drop"),
    -- so the editor can tell which source drops were left out or removed.
    if row.source_key ~= nil and not (type(row.source_key) == "string" and row.source_key:match("^%d+:%d+$")) then
        problems[#problems + 1] = where .. " has an invalid source reference."
    end

    -- true on a row made with the editor's "Custom item" button (its name and
    -- GP value can be edited; copied and loaded rows keep theirs).
    if row.custom ~= nil and row.custom ~= true then
        problems[#problems + 1] = where .. " has an invalid custom flag."
    end

    -- The source's own note (a condition or a luck rate), shown on the row.
    if row.note ~= nil and not text(row.note, CustomMethods.LIMITS.requirementNote) then
        problems[#problems + 1] = where .. " has a note over " .. CustomMethods.LIMITS.requirementNote .. " characters."
    end

    -- Priced from the GE (needs an item ID) or a fixed GP amount the player sets.
    if row.pricing == "ge" then
        if not wholeNumber(row.item_id, 1, 2 ^ 31) then
            problems[#problems + 1] = where .. " needs an item."
        end

        if row.unit_value ~= nil then
            problems[#problems + 1] = where .. ": a GE item can't also have a fixed value."
        end

        -- The player's own price for it, instead of the live GE price.
        if row.price ~= nil and not nonNegativeFinite(row.price) then
            problems[#problems + 1] = where .. " needs a price of 0 or more."
        end
    elseif row.pricing == "fixed" then
        if (state == "included" or row.unit_value ~= nil) and not nonNegativeFinite(row.unit_value) then
            problems[#problems + 1] = where .. " needs a GP value of 0 or more."
        end

        -- An item ID here is only for its picture (coins, a charm).
        if row.item_id ~= nil and not wholeNumber(row.item_id, 1, 2 ^ 31) then
            problems[#problems + 1] = where .. " has an invalid item."
        end

        if row.price ~= nil then
            problems[#problems + 1] = where .. ": only GE items take a price of your own."
        end
    else
        problems[#problems + 1] = where .. " must be a GE item or a fixed GP amount."
    end
end

-- Checks one requirement. Returns true if it's one the game can check (a level
-- or a quest), false for a note the player has to check themselves.
local function checkRequirement(check, where, problems)
    if type(check) ~= "table" then
        problems[#problems + 1] = where .. " is not a record."
        return false
    end

    if check.kind == "skill" then
        if not SKILLS[check.skill] then
            problems[#problems + 1] = where .. " names an unknown skill."
        end

        if not wholeNumber(check.level, 1, 120) then
            problems[#problems + 1] = where .. " needs a level from 1 to 120."
        end

        return true
    end

    if check.kind == "combat_level" then
        if not wholeNumber(check.level, 3, 152) then
            problems[#problems + 1] = where .. " needs a combat level from 3 to 152."
        end

        return true
    end

    -- Quests are stored by their client config name (e.g. COOKS_ASSISTANT), plus
    -- the readable name to show.
    if check.kind == "quest" then
        if type(check.quest) ~= "string" or not check.quest:match("^[A-Z][A-Z0-9_]*$") then
            problems[#problems + 1] = where .. " has an invalid quest."
        end

        if not text(check.name, CustomMethods.LIMITS.requirementNote) then
            problems[#problems + 1] = where .. " needs the quest's name."
        end

        return true
    end

    -- An item to have (in the bank or inventory), by GE item ID, with its name to
    -- show and how many.
    if check.kind == "item" then
        if not wholeNumber(check.item_id, 1, 2 ^ 31) then
            problems[#problems + 1] = where .. " needs an item."
        end

        if not text(check.name, CustomMethods.LIMITS.label) then
            problems[#problems + 1] = where .. " needs the item's name."
        end

        if not wholeNumber(check.quantity, 1, 2 ^ 31) then
            problems[#problems + 1] = where .. " needs a quantity of at least 1."
        end

        return true
    end

    -- A group of items: any one of them (e.g. either of two pickaxes) or all of
    -- them (an outfit), under one name. Each item is checked like the above.
    if check.kind == "items" then
        if check.mode ~= "any" and check.mode ~= "all" then
            problems[#problems + 1] = where .. " must need any one or all of its items."
        end

        if not text(check.name, CustomMethods.LIMITS.requirementNote) then
            problems[#problems + 1] = where .. " needs a name."
        end

        local items = check.items

        if type(items) ~= "table" or #items < 2 or #items > CustomMethods.LIMITS.groupItems then
            problems[#problems + 1] = where .. " needs 2 to " .. CustomMethods.LIMITS.groupItems .. " items."
            return true
        end

        for index, item in ipairs(items) do
            local itemWhere = where .. " item " .. index

            if type(item) ~= "table" or not wholeNumber(item.item_id, 1, 2 ^ 31)
                or not text(item.name, CustomMethods.LIMITS.label) or not wholeNumber(item.quantity, 1, 2 ^ 31) then
                problems[#problems + 1] = itemWhere .. " needs an item, its name and a quantity of at least 1."
            end
        end

        return true
    end

    if check.kind == "note" then
        if not text(check.text, CustomMethods.LIMITS.requirementNote) then
            problems[#problems + 1] = where .. " needs text of at most "
                .. CustomMethods.LIMITS.requirementNote .. " characters."
        end

        return false
    end

    problems[#problems + 1] = where .. " is an unsupported kind of requirement."
    return false
end

-- Checks a whole record. Returns true, or false plus a list of every problem
-- found (not just the first), so the editor and import review can show them all.
function CustomMethods.validate(record)
    local problems = {}

    if type(record) ~= "table" or record.schema ~= 1 then
        return false, { "Unsupported custom activity format." }
    end

    if type(record.id) ~= "string" or not record.id:match("^custom%.%d+$") then
        problems[#problems + 1] = "Invalid custom activity ID."
    end

    if not text(record.title, CustomMethods.LIMITS.title) then
        problems[#problems + 1] = "The name must be 1 to " .. CustomMethods.LIMITS.title .. " characters."
    end

    if not CATEGORIES[record.category] then
        problems[#problems + 1] = "The category must be PvM, Skilling, Production or Daily/weekly."
    end

    -- A list of one-line texts (optional): at most `most` of them, each at most
    -- LIMITS.notes characters. `what` names one ("Step", "Income note").
    local function checkLines(lines, most, what)
        if lines == nil then
            return
        end

        if type(lines) ~= "table" or #lines > most then
            problems[#problems + 1] = "At most " .. most .. " " .. what:lower() .. "s."
            return
        end

        for index, line in ipairs(lines) do
            if type(line) ~= "string" or #line > CustomMethods.LIMITS.notes or line:find("%c") then
                problems[#problems + 1] = what .. " " .. index .. " can be at most "
                    .. CustomMethods.LIMITS.notes .. " characters, on one line."
            end
        end
    end

    -- Notes are numbered steps (shown on How to do it). Builds before 0.8.36
    -- saved one plain note; that still loads, as a single step.
    if type(record.notes) == "string" then
        if #record.notes > CustomMethods.LIMITS.notes then
            problems[#problems + 1] = "Notes can be at most " .. CustomMethods.LIMITS.notes .. " characters."
        end
    else
        checkLines(record.notes, CustomMethods.LIMITS.steps, "Step")
    end

    -- The Income tab's notes, and the Getting there tab's directions.
    checkLines(record.income_notes, CustomMethods.LIMITS.incomeNotes, "Income note")
    checkLines(record.getting_there, CustomMethods.LIMITS.steps, "Getting there line")

    -- Throughput: one unit and a default rate.
    local rate = record.rate

    if type(rate) ~= "table" or not RATE_KEYS[rate.unit] or not nonNegativeFinite(rate.default) then
        problems[#problems + 1] = "Throughput needs a unit and a rate of 0 or more."
    elseif (rate.unit == "runs") ~= (record.category == "recurring") then
        problems[#problems + 1] = "Daily/weekly activities count runs; other activities count kills or actions per hour."
    end

    -- Daily/weekly: how often, and optionally how long a run takes.
    local recurrence = record.recurrence

    if record.category == "recurring" then
        if type(recurrence) ~= "table" or not RECURRENCES[recurrence.every]
            or (recurrence.minutes ~= nil and not (nonNegativeFinite(recurrence.minutes)
                and recurrence.minutes > 0 and recurrence.minutes <= 1440)) then
            problems[#problems + 1] = "Daily/weekly activities need how often they're done (and minutes from 1 to 1,440, if set)."
        end
    elseif recurrence ~= nil then
        problems[#problems + 1] = "Only daily/weekly activities have a how-often."
    end

    -- Rows, with their size limits.
    local usesTrips = false

    for _, side in ipairs({ "outputs", "supplies" }) do
        local rows = record[side]

        if type(rows) ~= "table" then
            problems[#problems + 1] = "Missing " .. side .. " list."
        elseif #rows > CustomMethods.LIMITS[side] then
            problems[#problems + 1] = "At most " .. CustomMethods.LIMITS[side] .. " " .. side .. " rows."
        else
            for index, row in ipairs(rows) do
                checkRow(row, side, index, problems)

                -- A run is one run: per trip or per hour make no sense there.
                if record.category == "recurring" and type(row) == "table" and row.basis ~= "action" then
                    problems[#problems + 1] = side .. " row " .. index .. ": daily/weekly rows are per run."
                end
                usesTrips = usesTrips or (type(row) == "table" and row.basis == "trip")
            end
        end
    end

    -- Kills/actions per trip: needed exactly when a row is per trip.
    if usesTrips then
        if not (nonNegativeFinite(record.actions_per_trip) and record.actions_per_trip > 0) then
            problems[#problems + 1] = "Per-trip rows need a number of kills/actions per trip greater than 0."
        end
    elseif record.actions_per_trip ~= nil then
        problems[#problems + 1] = "Kills/actions per trip is only used with per-trip rows."
    end

    -- Requirements: Required and Recommended lists, with one shared limit.
    local requirements = record.requirements
    local tracked, count = 0, 0

    if type(requirements) ~= "table" or type(requirements.required) ~= "table"
        or type(requirements.recommended) ~= "table" then
        problems[#problems + 1] = "Missing requirements lists."
    else
        for _, group in ipairs({ "required", "recommended" }) do
            for index, check in ipairs(requirements[group]) do
                count = count + 1

                -- Only Required checks count towards the minimum: a recommended
                -- level doesn't stop anyone doing the activity.
                if checkRequirement(check, group .. " requirement " .. index, problems) and group == "required" then
                    tracked = tracked + 1
                end
            end
        end
    end

    if count > CustomMethods.LIMITS.requirements then
        problems[#problems + 1] = "At most " .. CustomMethods.LIMITS.requirements .. " requirements."
    end

    -- The minimum-requirement rule (agreed 4 Nov). A note can't count: the game
    -- can't check it, so it would let anything through.
    if record.no_requirements ~= nil and record.no_requirements ~= true then
        problems[#problems + 1] = "Invalid 'no requirements needed' choice."
    end

    if NEEDS_TRACKED_CHECK[record.category] then
        if tracked == 0 then
            problems[#problems + 1] = "PvM and Skilling activities need at least one Required level or quest."
        end

        if record.no_requirements then
            problems[#problems + 1] = "PvM and Skilling activities can't be marked 'no requirements needed'."
        end
    elseif tracked == 0 and not record.no_requirements then
        problems[#problems + 1] = "Add a Required level or quest, or tick 'no requirements needed'."
    elseif tracked > 0 and record.no_requirements then
        problems[#problems + 1] = "'No requirements needed' can't be ticked alongside Required checks."
    end

    -- Where the drops came from, so removed ones can be added back later.
    local source = record.source

    if source ~= nil and not (type(source) == "table" and (source.kind == "monster" or source.kind == "thieving")
        and text(source.title, CustomMethods.LIMITS.requirementNote)) then
        problems[#problems + 1] = "Invalid drop source."
    end

    if #problems > 0 then
        return false, problems
    end

    return true
end

-- ---- Turning a record into a method ---------------------------------------------

-- One income row in the calculator's shape. GE outputs pay the GE tax; fixed GP
-- amounts don't (nothing is sold).
local function incomeRow(row, isOutput)
    local line = { name = row.label, quantity = row.quantity, basis = row.basis }

    if row.pricing == "fixed" then
        line.pricing = "fixed"
        line.unit_value = row.unit_value
        line.display_item_id = row.item_id
    elseif row.price then
        -- A GE item at the player's own price: a fixed value with the item's
        -- picture, still taxed when sold.
        line.pricing = "fixed"
        line.unit_value = row.price
        line.display_item_id = row.item_id
        line.tax_denominator = isOutput and GE_TAX_DENOMINATOR or nil
    else
        line.item_id = row.item_id
        line.tax_denominator = isOutput and GE_TAX_DENOMINATOR or nil
    end

    return line
end

-- A requirement in requirements.lua's shape. A note becomes an `ignored` check:
-- listed for the player, left out of Met/Missing (the game can't answer it).
local function requirementNode(check)
    if check.kind == "skill" then
        return { kind = "skill", skill = check.skill, level = check.level, text = check.level .. " " .. CustomMethods.skillName(check.skill) }
    end

    if check.kind == "combat_level" then
        return { kind = "combat_level", level = check.level, text = "Combat level " .. check.level }
    end

    if check.kind == "quest" then
        return { kind = "quest", quest = check.quest, text = check.name }
    end

    if check.kind == "item" then
        local text = (check.quantity > 1 and (check.quantity .. " x ") or "") .. check.name
        -- display_items is what makes the activity page draw the item's picture
        -- (with a border showing whether you have it) instead of a text line.
        return { kind = "item", itemId = check.item_id, quantity = check.quantity, text = text, display_items = { check.item_id } }
    end

    -- A group becomes the same "any"/"all" node bundled activities use.
    if check.kind == "items" then
        local children, pictures = {}, {}

        for index, item in ipairs(check.items) do
            children[index] = requirementNode({ kind = "item", item_id = item.item_id, name = item.name, quantity = item.quantity })
            pictures[index] = item.item_id
        end

        return { kind = check.mode, text = check.name, children = children, display_items = pictures }
    end

    return { kind = "text", text = check.text, ignored = true }
end

local function requirementGroup(checks, label)
    local children = {}

    for index, check in ipairs(checks) do
        children[index] = requirementNode(check)
    end

    return { kind = "all", text = label, children = children }
end

-- Builds the method the rest of the plugin understands from a VALID record (call
-- validate first). Only counted rows go into the income model: rows switched off
-- are left out, and any row still waiting for a number makes the model incomplete,
-- so there's no total profit until the player fills it in or removes it.
function CustomMethods.toMethod(record)
    local outputs, inputs = {}, {}
    local coverage = "complete"

    for _, row in ipairs(record.outputs) do
        local state = row.state or "included"

        if state == "included" then
            outputs[#outputs + 1] = incomeRow(row, true)
        elseif state == "needs" then
            coverage = "partial"
        end
    end

    -- The Income tab's notes are the player's own.
    local assumptions = CustomMethods.lines(record.income_notes)

    for _, row in ipairs(record.supplies) do
        inputs[#inputs + 1] = incomeRow(row, false)
    end

    return {
        schema = 1,
        id = record.id,
        origin = "custom",
        title = record.title,
        category = record.category,
        source_category = CATEGORY_LABELS[record.category],

        -- Lists show this for an activity nobody has rated.
        intensity = "Unclassified",

        income = {
            coverage = coverage,
            period = record.category == "recurring" and "run" or "hour",
            recurrence = record.recurrence and { every = record.recurrence.every, minutes = record.recurrence.minutes },
            rate = { key = RATE_KEYS[record.rate.unit], unit = record.rate.unit, default = record.rate.default },
            actions_per_trip = record.actions_per_trip,
            inputs = inputs,
            outputs = outputs,
            assumptions = assumptions,
            unresolved = {},
        },

        requirements = {
            access = requirementGroup(record.requirements.required, "Required"),
            recommended = requirementGroup(record.requirements.recommended, "Recommended"),
            coverage = "complete",
            unresolved = {},
            notes = {},
        },

        -- The saved record itself, for the editor's Edit button.
        record = record,

        -- The player's own steps and directions (How to do it, Getting there).
        instructions = CustomMethods.steps(record),
        location = { coverage = "complete", text = "", routes = CustomMethods.lines(record.getting_there) },
        source = { title = "Your custom activity" },
    }
end

-- ---- Storage --------------------------------------------------------------------

-- `db` is the client's PersistentDB (a fake one in tests).
function CustomMethods.store(db)
    local self = {}

    -- Reads the index. Returns index, warning, writable. Like preferences.lua,
    -- an index we can't read or understand is never written over: that could
    -- lose every custom activity at once.
    local function loadIndex()
        local ok, stored, exists = pcall(function()
            return db:GetStructuredData(INDEX_KEY), db:CheckExists(INDEX_KEY)
        end)

        if not ok then
            return nil, "Custom activities could not be loaded: " .. tostring(stored), false
        end

        if stored == nil and not exists then
            return { next = 1, ids = {} }, nil, true
        end

        if type(stored) ~= "table" or stored.schema ~= 1 or not wholeNumber(stored.next, 1, 2 ^ 31)
            or type(stored.ids) ~= "table" then
            return nil, "Saved custom activities have an unsupported format; no changes were made.", false
        end

        local ids, seen = {}, {}

        for _, id in ipairs(stored.ids) do
            -- An ID at or past `next` would be reused later, so it's damaged too.
            local number = type(id) == "string" and tonumber(id:match("^custom%.(%d+)$"))

            if not number or number >= stored.next or seen[id] then
                return nil, "Saved custom activities are damaged; no changes were made.", false
            end

            seen[id] = true
            ids[#ids + 1] = id
        end

        return { next = math.floor(stored.next), ids = ids }, nil, true
    end

    local function writeIndex(index)
        local ok, written = pcall(function()
            return db:SetStructuredData(INDEX_KEY, { schema = 1, next = index.next, ids = index.ids })
        end)

        return ok and written == true, written
    end

    -- Every valid custom activity, in the order they were made, plus a warning if
    -- any couldn't be read. A bad record is skipped but stays saved (and stays in
    -- the index), so a glitch or a newer format never deletes anyone's work.
    function self:load()
        local index, warning = loadIndex()

        if not index then
            return {}, warning
        end

        local records, skipped = {}, 0

        for _, id in ipairs(index.ids) do
            local ok, stored = pcall(function()
                return db:GetStructuredData(RECORD_PREFIX .. id)
            end)

            if ok and type(stored) == "table" and stored.id == id and CustomMethods.validate(stored) then
                records[#records + 1] = stored
            else
                skipped = skipped + 1
            end
        end

        if skipped > 0 then
            warning = skipped .. " saved custom " .. (skipped == 1 and "activity" or "activities")
                .. " couldn't be read and " .. (skipped == 1 and "was" or "were") .. " left out. "
                .. "They're still saved."
        end

        return records, warning
    end

    -- Saves a new activity. `record` is everything but the ID; we give it the next
    -- unused one. Returns the saved record, or nil plus a message (or the list of
    -- validation problems).
    --
    -- Order matters: the record is written first, then the index. If the index
    -- write fails, the record is just an unlisted leftover under an ID the index
    -- hasn't handed out yet, so the next save simply writes over it.
    function self:create(record)
        local index, warning, writable = loadIndex()

        if not writable then
            return nil, warning
        end

        if #index.ids >= CustomMethods.LIMITS.activities then
            return nil, "You can have at most " .. CustomMethods.LIMITS.activities .. " custom activities."
        end

        local saved = {}

        for key, value in pairs(record) do
            saved[key] = value
        end

        saved.id = "custom." .. index.next

        local valid, problems = CustomMethods.validate(saved)

        if not valid then
            return nil, problems
        end

        local ok, written = pcall(function()
            return db:SetStructuredData(RECORD_PREFIX .. saved.id, saved)
        end)

        if not ok or written ~= true then
            return nil, "The custom activity could not be saved: " .. tostring(written)
        end

        local ids = {}

        for position, id in ipairs(index.ids) do
            ids[position] = id
        end

        ids[#ids + 1] = saved.id

        local listed, problem = writeIndex({ next = index.next + 1, ids = ids })

        if not listed then
            return nil, "The custom activity could not be saved: " .. tostring(problem)
        end

        return saved
    end

    -- Saves changes to an existing activity, under its own key only.
    function self:update(record)
        local index, warning, writable = loadIndex()

        if not writable then
            return nil, warning
        end

        local valid, problems = CustomMethods.validate(record)

        if not valid then
            return nil, problems
        end

        local listed = false

        for _, id in ipairs(index.ids) do
            listed = listed or id == record.id
        end

        if not listed then
            return nil, "That custom activity no longer exists."
        end

        local ok, written = pcall(function()
            return db:SetStructuredData(RECORD_PREFIX .. record.id, record)
        end)

        if not ok or written ~= true then
            return nil, "The changes could not be saved: " .. tostring(written)
        end

        return record
    end

    -- Deletes one activity. It leaves the index first (so it's gone even if the
    -- record delete then fails), then its record. Its ID is never handed out again.
    -- Favourites, rates and history that mention it are left alone: they belong to
    -- each profile, and a deleted ID matches nothing.
    function self:delete(id)
        local index, warning, writable = loadIndex()

        if not writable then
            return false, warning
        end

        local ids, found = {}, false

        for _, existing in ipairs(index.ids) do
            if existing == id then
                found = true
            else
                ids[#ids + 1] = existing
            end
        end

        if not found then
            return true
        end

        local listed, problem = writeIndex({ next = index.next, ids = ids })

        if not listed then
            return false, "The custom activity could not be deleted: " .. tostring(problem)
        end

        -- Best effort: if this fails the record is an unlisted leftover that
        -- nothing reads, so the delete has still happened from the player's view.
        pcall(function()
            db:Delete(RECORD_PREFIX .. id)
        end)

        return true
    end

    return self
end

return CustomMethods
