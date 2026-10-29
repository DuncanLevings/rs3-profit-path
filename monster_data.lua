-- Reads monster drop tables from our bundled snapshot (data/monsters.lua).
--
-- How the data is packed: lots of monsters share the same text ("Coins", "1/128")
-- and even whole drop rows, so the generator stores each string, drop row and
-- section once and refers to them by number. A monster row is just a list of those
-- numbers. This reader turns one monster back into normal named fields when asked.
--
-- Important: the field positions (row[1], row[2]...) must match the *_FIELDS lists
-- in tools/catalogue.py. Change one and you must change the other; the catalogue
-- `verify` command round-trips every monster to catch any mismatch.
--
-- Every call returns brand-new tables, so one caller editing a result can't
-- accidentally change what another caller sees.
local MonsterData = {}

-- Loaded on first use (it's over 1 MB, so don't load it unless someone needs it).
local packed
local byTitle

local function load()
    if packed then
        return
    end

    local data = require("data/monsters")
    assert(data.schema == 1, "Unsupported Profit Path monster data schema")

    -- Build a title -> row index lookup once, so find() doesn't scan every monster.
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
    return index and assert(packed.strings[index], "Missing monster string") or nil
end

local function drop(row)
    return {
        name = text(row[1]), quantity = text(row[2]), rate = text(row[3]),
        notes = text(row[4]), note_marker = text(row[5]), item_id = row[6],
        chance = text(row[7]), rolls = row[8], quantity_low = row[9],
        quantity_high = row[10], untradeable = row[11],
    }
end

-- A section is one drop table on the Wiki page, like "Herbs" or "Tertiary".
local function section(row)
    local drops, notes, noteIds = {}, {}, {}

    for _, index in ipairs(row[4]) do
        drops[#drops + 1] = drop(assert(packed.drops[index], "Missing monster drop"))
    end

    for _, index in ipairs(row[5]) do
        notes[#notes + 1] = text(index)
    end

    for _, pair in ipairs(row[6]) do
        noteIds[text(pair[1])] = pair[2]
    end

    return {
        title = text(row[1]), description = text(row[2]), afterword = text(row[3]),
        drops = drops, notes = notes, note_ids = noteIds,
        drop_mode = text(row[7]), drop_switch = row[8], drop_threshold = row[9],
    }
end

-- Summary of the bundle: schema version, build date and monster count.
function MonsterData.info()
    load()

    return { schema = packed.schema, built = packed.built, monsters = #packed.monsters }
end

-- Looks a monster up by its exact Wiki page title. Exact matching matters: some
-- monsters have several pages for different encounters, and we mustn't mix them.
-- An unknown title returns nil, "unknown". We never go online to look it up.
function MonsterData.find(title)
    load()

    local index = byTitle[title]

    if not index then
        return nil, "unknown"
    end

    local row = packed.monsters[index]
    local sections, npcIds = {}, {}

    for _, sectionId in ipairs(row[3]) do
        sections[#sections + 1] = section(assert(packed.sections[sectionId], "Missing monster section"))
    end

    for _, id in ipairs(row[2]) do
        npcIds[#npcIds + 1] = id
    end

    return { title = text(row[1]), npc_ids = npcIds, sections = sections, no_drops = text(row[4]) }
end

return MonsterData
