-- Searches quests/unlocks for the editor and resolves saved choices into
-- requirement checks.
-- catalogue.py builds data/unlocks.lua from quest-list.json (client quest names)
-- and custom-unlocks.json (reviewed prayers, abilities, relics and other
-- unlocks). Unlocks reuse the bundled activity checks.
local ItemNames = require("src/data/item_names")

local UnlockData = {}

-- Loaded on first use, like the other data readers.
local data
local questByConfig
local unlockByKey

-- Everything the search looks through, in name order: { kind, name, lowered, ... }.
local searchable

local function load()
    if data then
        return
    end

    local packed = require("data/unlocks")
    assert(packed.schema == 1 and #packed.quest_configs == #packed.quest_names, "Unsupported Profit Path unlock data")

    questByConfig, unlockByKey, searchable = {}, {}, {}

    for index, config in ipairs(packed.quest_configs) do
        local name = packed.quest_names[index]
        questByConfig[config] = name
        searchable[#searchable + 1] = { kind = "quest", quest = config, name = name, label = "Quest: " .. name }
    end

    for _, unlock in ipairs(packed.unlocks) do
        unlockByKey[unlock.key] = unlock
        searchable[#searchable + 1] = {
            kind = "unlock", key = unlock.key, name = unlock.name,
            label = unlock.name .. " (" .. unlock.kind .. ")",
        }
    end

    -- One list in name order, so quests and unlocks mix in the results.
    table.sort(searchable, function(a, b)
        return a.name:lower() < b.name:lower()
    end)

    for _, entry in ipairs(searchable) do
        entry.lowered = entry.name:lower()
    end

    data = packed
end

-- A quest's display name from its client config name, or nil if it isn't one we list.
function UnlockData.questName(config)
    load()

    return questByConfig[config]
end

-- One unlock's entry ({ key, name, kind, check }), or nil.
function UnlockData.unlock(key)
    load()

    return unlockByKey[key]
end

-- The unlock whose check is this bundled flag or achievement check (same game
-- variable, or the same achievement IDs), or nil. Duplicate as custom uses it so
-- a copied relic or diary stays a real check instead of becoming a note.
local function sameIds(a, b)
    if #a ~= #b then
        return false
    end

    for index, id in ipairs(a) do
        if b[index] ~= id then
            return false
        end
    end

    return true
end

function UnlockData.matching(node)
    load()

    for _, unlock in ipairs(data.unlocks) do
        local check = unlock.check

        if node.kind == "flag" and check.kind == "flag" and check.var == node.var then
            return unlock
        end

        if node.kind == "achievement" and check.kind == "achievement" and type(node.ids) == "table"
            and sameIds(check.ids, node.ids) then
            return unlock
        end
    end

    return nil
end

-- A fresh copy of an unlock's check (the activity page keeps results on the
-- nodes it's given, so two activities must never share one), or nil.
local function copy(node)
    local result = {}

    for field, value in pairs(node) do
        if field == "children" or field == "ids" then
            local list = {}

            for index, child in ipairs(value) do
                list[index] = type(child) == "table" and copy(child) or child
            end

            result[field] = list
        else
            result[field] = value
        end
    end

    return result
end

function UnlockData.check(key)
    local unlock = UnlockData.unlock(key)

    return unlock and copy(unlock.check) or nil
end

-- Return up to limit matching quest/unlock entries plus the total count. Use the
-- item search ranking; a blank query returns nothing.
function UnlockData.search(query, limit)
    load()

    local needle = ItemNames.needle(query)

    if needle == "" then
        return {}, 0
    end

    local best, total = { {}, {}, {} }, 0

    for _, entry in ipairs(searchable) do
        local rank = ItemNames.rank(entry.lowered, needle)

        if rank then
            total = total + 1

            if #best[rank] < limit then
                table.insert(best[rank], entry)
            end
        end
    end

    local results = {}

    for _, entries in ipairs(best) do
        for _, entry in ipairs(entries) do
            if #results < limit then
                results[#results + 1] = { kind = entry.kind, quest = entry.quest, key = entry.key, name = entry.name, label = entry.label }
            end
        end
    end

    return results, total
end

return UnlockData
