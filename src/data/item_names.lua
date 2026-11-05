-- Names of every Grand Exchange item, for the custom activity editor's item search.
--
-- The list (data/ge_items.lua) is built by src/tools/catalogue.py from
-- catalogue-source/ge-items.json, which src/tools/wiki_drop_sources.py imports from
-- the RuneScape Wiki. It holds only items with a GE page, because those are the ones
-- GE Prices Library can price. Labels are unique: when two items share a name, the
-- label is the Wiki page name instead, e.g. "Monk's robe (top)".
--
-- It's two parallel lists, ids[i] and labels[i], sorted by label. That's the
-- smallest plain format for ~7,500 entries, and needs no unpacking step.
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

-- Items whose label contains `query` (ignoring case), best matches first (see
-- rank), then in label order, at most `limit` of them. Returns a list of
-- { id, label } plus the total number of matches, so the editor can say
-- "showing 5 of 143". A blank query matches nothing: listing all 7,500 items
-- at once would be no help to anyone.
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
