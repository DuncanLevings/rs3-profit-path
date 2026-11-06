-- Reads packed monster or thieving drop tables. The snapshot shares strings, drop
-- rows and sections by numeric reference. Each lookup returns fresh tables so
-- callers can safely edit the result.
-- Only the fields the plugin uses are packed (see catalogue.py's PACKED_*_FIELDS,
-- whose order the positions below must match). catalogue verify round-trips every
-- record to catch mismatches.

-- Builds a reader for one packed data module. Each reader keeps its own data.
local function open(moduleName)
    local reader = {}

    -- Loaded on first use (the monster file is over 1 MB, so don't load it unless
    -- someone needs it).
    local packed
    local byTitle

    local function load()
        if packed then
            return
        end

        local data = require(moduleName)
        assert(data.schema == 2, "Unsupported Profit Path drop data schema: " .. moduleName)

        -- Build a title -> row index lookup once, so find() doesn't scan every record.
        local titles = {}

        for index, row in ipairs(data.monsters) do
            titles[data.strings[row[1]]] = index
        end

        packed = data
        byTitle = titles
    end

    -- Turns a string number back into its text. nil stays nil (the field wasn't set),
    -- but a number that points nowhere means the data file is broken, so we error.
    local function text(index)
        return index and assert(packed.strings[index], "Missing drop data string") or nil
    end

    local function drop(row)
        return {
            name = text(row[1]), quantity = text(row[2]), rate = text(row[3]),
            notes = text(row[4]), item_id = row[5], rolls = row[6],
            quantity_low = row[7], quantity_high = row[8], untradeable = row[9],
        }
    end

    -- A section is one drop table on the Wiki page, like "Herbs" or "Tertiary".
    local function section(row)
        local drops = {}

        for _, index in ipairs(row[2]) do
            drops[#drops + 1] = drop(assert(packed.drops[index], "Missing drop row"))
        end

        return { title = text(row[1]), drops = drops }
    end

    -- Titles containing `query` (ignoring case, plain text), best matches first,
    -- at most `limit` of them, plus the total number of matches. For the custom
    -- activity editor's source picker. A blank query matches nothing.
    function reader.search(query, limit)
        load()

        -- Best matches first, like the item search (see item_names.lua's rank),
        -- with doubled spaces read as one.
        local ItemNames = require("src/data/item_names")
        local needle = ItemNames.needle(query)
        local matches = {}

        if needle == "" then
            return matches, 0
        end

        local ranks = {}

        for title in pairs(byTitle) do
            local rank = ItemNames.rank(title:lower(), needle)

            if rank then
                matches[#matches + 1] = title
                ranks[title] = rank
            end
        end

        -- pairs() has no order, so sort before cutting the list short.
        table.sort(matches, function(left, right)
            if ranks[left] ~= ranks[right] then
                return ranks[left] < ranks[right]
            end

            return left:lower() < right:lower()
        end)

        local total = #matches

        for index = total, limit + 1, -1 do
            matches[index] = nil
        end

        return matches, total
    end

    -- Summary of the bundle: schema version, build date and record count.
    function reader.info()
        load()

        return { schema = packed.schema, built = packed.built, monsters = #packed.monsters }
    end

    -- Find an exact title so encounter variants stay separate. Returns nil,
    -- "unknown" for an absent title. Thieving results also include the required
    -- level.
    function reader.find(title)
        load()

        local index = byTitle[title]

        if not index then
            return nil, "unknown"
        end

        local row = packed.monsters[index]
        local sections = {}

        for _, sectionId in ipairs(row[2]) do
            sections[#sections + 1] = section(assert(packed.sections[sectionId], "Missing drop section"))
        end

        return {
            title = text(row[1]), sections = sections,
            no_drops = text(row[3]), level = row[4],
        }
    end

    return reader
end

local MonsterData = open("data/monsters")

-- So thieving_data.lua (and the tests) can open another file in the same format.
MonsterData.open = open

return MonsterData
