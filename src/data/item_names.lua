-- Searches bundled GE item names for the editor. catalogue.py builds
-- data/ge_items.lua from wiki_drop_sources.py's ge-items.json snapshot.
-- Only items with GE pages are included. Unique labels use the Wiki page name
-- when display names clash. Parallel ids/labels lists are sorted by label.
local ItemNames = {}

-- Loaded on first use, like the other data readers.
local data
local labelById

-- Lower-case copies of the labels, made once, so searching doesn't lower-case
-- 7,500 strings on every keystroke.
local lowered

local function load()
    if data then
        return
    end

    local packed = require("data/ge_items")
    assert(packed.schema == 1 and #packed.ids == #packed.labels, "Unsupported Profit Path GE item data")

    labelById, lowered = {}, {}

    for index, id in ipairs(packed.ids) do
        labelById[id] = packed.labels[index]
        lowered[index] = packed.labels[index]:lower()
    end

    data = packed
end

-- The label for one item ID, or nil if it isn't a GE item we know.
function ItemNames.label(id)
    load()

    return labelById[id]
end

-- What a search looks for: lower case, trimmed, and any run of spaces counted
-- as one ("prayer  potion" finds Prayer potion).
function ItemNames.needle(query)
    if type(query) ~= "string" then
        return ""
    end

    return (query:gsub("%s+", " "):match("^ ?(.-) ?$"):lower())
end

-- How well `label` (lower case) matches `needle`: 1 if the label starts with it,
-- 2 if a word in it does, 3 if it's anywhere else, nil if not at all. So
-- "prayer potion" lists Prayer potion before Perfect juju prayer potion.
function ItemNames.rank(label, needle)
    -- `true` = plain find: a "(" or "-" in the query is just a character.
    local at = label:find(needle, 1, true)

    if not at then
        return nil
    end

    if at == 1 then
        return 1
    end

    -- Any later match that starts a word (after a space, bracket or dash).
    while at do
        if label:sub(at - 1, at - 1):find("[%s%(%-/]") then
            return 2
        end

        at = label:find(needle, at + 1, true)
    end

    return 3
end

-- Return up to limit matching { id, label } entries, best matches first, plus the
-- total match count. Matching ignores case; a blank query returns nothing.
function ItemNames.search(query, limit)
    load()

    local needle = ItemNames.needle(query)

    if needle == "" then
        return {}, 0
    end

    -- The first `limit` matches of each rank, in label order (the list is
    -- already sorted by label), plus how many there are in all.
    local best, total = { {}, {}, {} }, 0

    for index, label in ipairs(lowered) do
        local rank = ItemNames.rank(label, needle)

        if rank then
            total = total + 1

            if #best[rank] < limit then
                table.insert(best[rank], index)
            end
        end
    end

    local results = {}

    for _, indexes in ipairs(best) do
        for _, index in ipairs(indexes) do
            if #results < limit then
                results[#results + 1] = { id = data.ids[index], label = data.labels[index] }
            end
        end
    end

    return results, total
end

return ItemNames
