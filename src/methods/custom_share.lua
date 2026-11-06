-- Encodes custom recipes as one copyable line and validates pasted lines before
-- import. The parser builds only known fields; it never executes text. Parsed
-- records also pass CustomMethods.validate.
-- Format: PP1:{...}*<8 hex FNV-1a checksum>. The checksum detects changed or
-- truncated text; unknown versions are refused.
-- The client text box truncates at 9,999 characters and at line breaks. Keep
-- codes to 9,998 printable ASCII characters on one line.
-- Share only the recipe, requirements and drop source. Exclude profiles, account
-- evidence, favourites, personal rates, GE price overrides and profit figures.
local CustomShare = {}

local CustomMethods = require("src/methods/custom_methods")
local ItemNames = require("src/data/item_names")
local UnlockData = require("src/data/unlock_data")

local PREFIX = "PP1:"

-- The text box holds 9,999 characters. A line that long might have been cut off at
-- the box's limit, so the longest we write (and accept) is one less.
CustomShare.MAX_LENGTH = 9998

-- The editor starts showing the share code's size from here (85% of the most),
-- so a player hears it's getting big before Export would refuse it.
CustomShare.WARN_LENGTH = 8500

-- ---- The fields -------------------------------------------------------------------
-- Every field a shared activity can have: its name in the record, its short name in
-- the line (to keep the line short), and its shape:
--   "value"  a string, a number or true
--   "map"    a table of named fields, like rate = { unit, default }
--   "list"   a list of maps (rows, requirements)
--   "lines"  a list of strings (notes, steps)
-- Anything not listed here is left out when writing and refused when reading.
local FIELDS = {
    -- The activity.
    { "title", "t", "value" },
    { "category", "c", "value" },
    { "notes", "n", "lines" },
    { "income_notes", "in", "lines" },
    { "getting_there", "gt", "lines" },
    { "rate", "r", "map" },
    { "recurrence", "rc", "map" },
    { "outputs", "o", "list" },
    { "supplies", "s", "list" },
    { "actions_per_trip", "ap", "value" },
    { "requirements", "rq", "map" },
    { "no_requirements", "nr", "value" },
    { "source", "so", "map" },
    { "difficulty_level", "dl", "value" },

    -- Inside rate, recurrence, requirements and source.
    { "unit", "u", "value" },
    { "default", "d", "value" },
    { "every", "ev", "value" },
    { "minutes", "mn", "value" },
    { "required", "rr", "list" },
    { "recommended", "rm", "list" },
    { "kind", "k", "value" },

    -- Inside an output or supply row. (Not `price`: that's the player's own GE
    -- price, which stays on their computer. The importer gets live GE prices.)
    { "label", "l", "value" },
    { "basis", "b", "value" },
    { "state", "st", "value" },
    { "quantity", "q", "value" },
    { "source_key", "sk", "value" },
    { "custom", "cu", "value" },
    { "note", "nt", "value" },
    { "pricing", "p", "value" },
    { "item_id", "id", "value" },
    { "unit_value", "uv", "value" },

    -- Inside a requirement (and an item group's items).
    { "skill", "sl", "value" },
    { "level", "lv", "value" },
    { "quest", "qu", "value" },
    { "name", "nm", "value" },
    { "unlock", "ul", "value" },
    { "mode", "md", "value" },
    { "items", "it", "list" },
    { "text", "tx", "value" },
}

-- Lookups both ways, made once.
local SHORT, LONG, SHAPE = {}, {}, {}

for _, field in ipairs(FIELDS) do
    SHORT[field[1]] = field[2]
    LONG[field[2]] = field[1]
    SHAPE[field[1]] = field[3]
end

-- Share a legacy string note as one step so older saved activities still
-- export.

-- ---- Checksum --------------------------------------------------------------------

-- FNV-1a, 32 bits, as 8 hex digits. It isn't security (anyone can make a valid
-- one); it only catches a line that was cut off or mangled on the way.
local function checksum(text)
    local hash = 2166136261

    for index = 1, #text do
        hash = ((hash ~ text:byte(index)) * 16777619) & 0xffffffff
    end

    return string.format("%08x", hash)
end

-- ---- Writing ---------------------------------------------------------------------
-- The body:
--   {k...,k...}  a map: each field's short name, straight followed by its value
--   [v,v]        a list
--   'text'       a string. ', ~ and any byte outside plain printable ASCII are
--                written as ~ and two hex digits (~27 for '), so names with
--                accents survive too
--   12 / 0.5     a number
--   T            true
-- Short names are lower-case letters only, and values start with ', {, [, T
-- (upper case), - or a digit, so nothing needs a separator between a name and
-- its value.

local function writeString(text)
    return "'" .. text:gsub("[^ -&(-}]", function(char)
        return string.format("~%02x", char:byte())
    end) .. "'"
end

local function writeNumber(number)
    if math.type(number) == "integer" or number == math.floor(number) and math.abs(number) < 2 ^ 53 then
        return string.format("%d", number)
    end

    -- 17 significant digits always reads back as exactly the same number.
    return string.format("%.17g", number)
end

local writeValue

-- A map of known fields, in a fixed order (FIELDS'), so the same activity always
-- gives the same line.
local function writeMap(map)
    local parts = {}

    for _, field in ipairs(FIELDS) do
        local value = map[field[1]]

        if value ~= nil then
            parts[#parts + 1] = field[2] .. writeValue(value, field[3])
        end
    end

    return "{" .. table.concat(parts, ",") .. "}"
end

writeValue = function(value, shape)
    if type(value) == "table" then
        if shape == "map" then
            return writeMap(value)
        end

        local parts = {}

        for index, item in ipairs(value) do
            parts[index] = shape == "list" and writeMap(item) or writeValue(item, "value")
        end

        return "[" .. table.concat(parts, ",") .. "]"
    end

    if type(value) == "string" then
        return writeString(value)
    end

    if type(value) == "number" then
        return writeNumber(value)
    end

    -- Saved records only ever hold true (a field is left out when it's off).
    return "T"
end

-- Omit GE names that exactly match the bundled list and restore them on import.
-- Keep custom names and fixed-GP row labels in the share code.

-- Calls fn(entry, field) for every row and requirement item whose name could be
-- the list's: GE rows (field "label"), item checks and the items in a group
-- (field "name"). Anything not shaped right is skipped; validate reports it.
local function eachItemName(record, fn)
    for _, side in ipairs({ "outputs", "supplies" }) do
        for _, row in ipairs(type(record[side]) == "table" and record[side] or {}) do
            if type(row) == "table" and row.pricing == "ge" then
                fn(row, "label")
            end
        end
    end

    local requirements = type(record.requirements) == "table" and record.requirements or {}

    for _, group in ipairs({ "required", "recommended" }) do
        for _, check in ipairs(type(requirements[group]) == "table" and requirements[group] or {}) do
            if type(check) == "table" and check.kind == "item" then
                fn(check, "name")
            elseif type(check) == "table" and check.kind == "items" and type(check.items) == "table" then
                for _, item in ipairs(check.items) do
                    if type(item) == "table" then
                        fn(item, "name")
                    end
                end
            end
        end
    end
end

-- A deep copy of plain tables, so leaving names out never touches the saved record.
local function copy(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}

    for key, item in pairs(value) do
        result[key] = copy(item)
    end

    return result
end

-- The record as it goes into the line: names that match the GE list left out.
local function withoutListedNames(record)
    local compact = copy(record)

    eachItemName(compact, function(entry, field)
        if type(entry.item_id) == "number" and entry[field] ~= nil and entry[field] == ItemNames.label(entry.item_id) then
            entry[field] = nil
        end
    end)

    return compact
end

-- Puts left-out names back from the GE list. An item the list doesn't have (a
-- line from a newer Profit Path, say) is named "Item <id>" so it still imports,
-- and the review says so. Returns the messages for requirement items.
local function restoreNames(record)
    local unnamed = {}

    eachItemName(record, function(entry, field)
        -- Only a whole-number ID can be looked up (or written with %d); anything
        -- else is left for validate to refuse.
        local id = entry.item_id

        if entry[field] ~= nil or type(id) ~= "number" or id ~= math.floor(id) or math.abs(id) >= 2 ^ 53 then
            return
        end

        local label = ItemNames.label(entry.item_id)

        if label then
            entry[field] = label
            return
        end

        entry[field] = "Item " .. string.format("%d", entry.item_id)

        -- A row already gets a warning from CustomShare.warnings (its price may
        -- not load either), so only requirement items need one here.
        if field == "name" then
            unnamed[#unnamed + 1] = "Item " .. string.format("%d", entry.item_id)
                .. " isn't in Profit Path's GE list, so it came without a name. It's called \""
                .. entry[field] .. "\" for now."
        end
    end)

    return unnamed
end

-- The share line for a saved record. Returns the line, or nil plus a message when
-- the activity is too big for the text box (very long notes on every row, say).
-- The third result is the line's length either way.
function CustomShare.encode(record)
    local line = PREFIX .. writeMap(withoutListedNames(record))
    line = line .. "*" .. checksum(line)

    if #line > CustomShare.MAX_LENGTH then
        return nil, "This activity is too big to share: it comes to " .. #line
            .. " characters and the text box holds " .. CustomShare.MAX_LENGTH
            .. ". Shorten its notes, or remove some rows or requirements.", #line
    end

    return line, nil, #line
end

-- Just the share line's length, for the editor's size note. Works on an unsaved
-- draft too (it doesn't need to be valid).
function CustomShare.length(record)
    local _, _, length = CustomShare.encode(record)
    return length
end

-- ---- Reading ---------------------------------------------------------------------
-- A small hand-written reader for the body above. It walks the text once, left to
-- right. Any surprise stops it with a message (error() inside, caught by decode).

-- Deep enough for the deepest real field (requirements > required > a group >
-- items > an item); anything deeper isn't one of ours.
local MAX_DEPTH = 6

local function reader(text)
    local position = 1

    local function fail(message)
        error({ message = message }, 0)
    end

    local function peek()
        return text:sub(position, position)
    end

    local function expect(char)
        if peek() ~= char then
            fail("The shared text is damaged (expected " .. char .. " at character " .. position .. ").")
        end

        position = position + 1
    end

    local readValue

    local function readString()
        expect("'")

        local finish = text:find("'", position, true)

        if not finish then
            fail("The shared text is damaged (a name never ends).")
        end

        local raw = text:sub(position, finish - 1)
        position = finish + 1

        -- Only the characters writeString leaves as they are, plus ~ escapes.
        if raw:find("[^ -&(-}~]") then
            fail("The shared text is damaged (an unexpected character).")
        end

        -- Every ~ must start a two-digit escape.
        if raw:gsub("~%x%x", ""):find("~", 1, true) then
            fail("The shared text is damaged (a bad escape).")
        end

        return (raw:gsub("~(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end))
    end

    local function readNumber()
        local digits = text:match("^%-?%d+%.?%d*[eE]?[%-+]?%d*", position)

        if not digits then
            fail("The shared text is damaged (expected a number at character " .. position .. ").")
        end

        local number = tonumber(digits)

        -- tonumber gives inf for 1e999, which no field can use.
        if not number or number ~= number or math.abs(number) == math.huge then
            fail("The shared text has a number Profit Path can't use.")
        end

        position = position + #digits
        return number
    end

    local function readMap(depth)
        expect("{")

        local map = {}

        if peek() == "}" then
            position = position + 1
            return map
        end

        while true do
            local short = text:match("^%l+", position)
            local name = short and LONG[short]

            if not name then
                fail("The shared text has a field Profit Path doesn't know. "
                    .. "It may come from a newer version of Profit Path.")
            end

            if map[name] ~= nil then
                fail("The shared text has the same field twice.")
            end

            position = position + #short
            map[name] = readValue(SHAPE[name], depth + 1)

            if peek() == "}" then
                position = position + 1
                return map
            end

            expect(",")
        end
    end

    local function readList(itemShape, depth)
        expect("[")

        local list = {}

        if peek() == "]" then
            position = position + 1
            return list
        end

        while true do
            list[#list + 1] = itemShape == "map" and readMap(depth + 1) or readValue("value", depth + 1)

            if peek() == "]" then
                position = position + 1
                return list
            end

            expect(",")
        end
    end

    -- One value of the shape its field expects; anything else is refused, so a
    -- list can never turn up where a name should be.
    readValue = function(shape, depth)
        if depth > MAX_DEPTH then
            fail("The shared text is nested too deeply.")
        end

        local char = peek()

        if shape == "map" then
            return readMap(depth)
        end

        if shape == "list" then
            return readList("map", depth)
        end

        -- Notes: a list of strings, or the old single string.
        if shape == "lines" then
            if char == "[" then
                return readList("value", depth)
            end

            if char ~= "'" then
                fail("The shared text is damaged (expected notes at character " .. position .. ").")
            end

            return (readString())
        end

        if char == "'" then
            return (readString())
        end

        if char == "T" then
            position = position + 1
            return true
        end

        if char == "-" or char:match("%d") then
            return readNumber()
        end

        fail("The shared text is damaged (unexpected " .. (char == "" and "end" or char)
            .. " at character " .. position .. ").")
    end

    return {
        map = function()
            local map = readMap(0)

            if position <= #text then
                fail("The shared text is damaged (something extra after the end).")
            end

            return map
        end,
    }
end

-- Reads a pasted line. Returns the record (ready for CustomMethods' store to
-- create, without an ID), or nil plus a message saying why it was refused.
-- Spaces and line breaks around the line are ignored (chat apps add them).
function CustomShare.decode(pasted)
    if type(pasted) ~= "string" then
        return nil, "Paste a shared activity first."
    end

    local line = pasted:match("^%s*(.-)%s*$")

    if line == "" then
        return nil, "Paste a shared activity first."
    end

    if #line > CustomShare.MAX_LENGTH then
        return nil, "That's too long to be a shared activity. It may have been cut off by the text box."
    end

    if line:sub(1, #PREFIX) ~= PREFIX then
        if line:match("^PP%d+:") then
            return nil, "That activity was shared from a newer version of Profit Path. Update Profit Path, then try again."
        end

        return nil, "That isn't a shared Profit Path activity (it should start with " .. PREFIX .. ")."
    end

    -- The checksum covers everything before the last *.
    local body, sum = line:match("^(.*)%*(%x%x%x%x%x%x%x%x)$")

    if not body then
        return nil, "The shared text is incomplete: its end is missing. Copy all of it, then paste again."
    end

    if checksum(body) ~= sum:lower() then
        return nil, "The shared text was changed or cut off on the way. Copy all of it again, then paste again."
    end

    local ok, result = pcall(function()
        return reader(body:sub(#PREFIX + 1)).map()
    end)

    if not ok then
        return nil, type(result) == "table" and result.message or "The shared text couldn't be read."
    end

    result.schema = 1

    -- The third result: items that came without a name the GE list could fill.
    return result, nil, restoreNames(result)
end

-- ---- The import review -----------------------------------------------------------

-- Things worth knowing about a record that still imports fine: items the bundled
-- list doesn't know (their GE price may not load) and quests the list doesn't know
-- (the game may not be able to check them). Returns a list of messages.
function CustomShare.warnings(record)
    local warnings = {}

    for _, side in ipairs({ "outputs", "supplies" }) do
        for index, row in ipairs(record[side] or {}) do
            if type(row) == "table" and row.pricing == "ge" and type(row.item_id) == "number"
                and not ItemNames.label(row.item_id) then
                warnings[#warnings + 1] = (side == "outputs" and "Output " or "Supply ") .. index .. " ("
                    .. tostring(row.label) .. ") is item " .. row.item_id
                    .. ", which isn't in Profit Path's GE list, so its price may not load."
            end
        end
    end

    local requirements = type(record.requirements) == "table" and record.requirements or {}

    for _, group in ipairs({ "required", "recommended" }) do
        for _, check in ipairs(requirements[group] or {}) do
            if type(check) == "table" and check.kind == "quest" and type(check.quest) == "string"
                and not UnlockData.questName(check.quest) then
                warnings[#warnings + 1] = "The quest " .. tostring(check.name)
                    .. " isn't in Profit Path's quest list, so it may show as \"Check this yourself\"."
            end
        end
    end

    return warnings
end

-- Everything the import screen shows about a pasted line: the record, the
-- problems that stop it being added (empty when it can be), and warnings.
function CustomShare.review(pasted)
    local record, problem, unnamed = CustomShare.decode(pasted)

    if not record then
        return { problems = { problem }, warnings = {} }
    end

    -- The same checks a save makes, with a stand-in ID (the real one is given
    -- when it's added).
    local candidate = {}

    for key, value in pairs(record) do
        candidate[key] = value
    end

    candidate.id = "custom.0"

    local valid, problems = CustomMethods.validate(candidate, { saving = true })
    local warnings = CustomShare.warnings(record)

    for _, message in ipairs(unnamed) do
        warnings[#warnings + 1] = message
    end

    return {
        record = record,
        problems = valid and {} or problems,
        warnings = warnings,
    }
end

return CustomShare
