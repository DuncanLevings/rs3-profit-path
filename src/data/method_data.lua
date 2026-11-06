-- Unpacks data/methods.lua into items, methods, equipment, toolbelt and icons,
-- with find(id) for activity lookup.
-- The packer shares strings and key sets (shapes). Records store a shape number
-- followed by values in key order; a $ key marks a string reference. Lists start
-- with 0, or -1 for string references.
-- Keep this format in sync with catalogue.py: catalogue verify round-trips every
-- activity against its source.
local data = require("data/methods")
assert(data.schema == 1 and data.packing == 1, "Unsupported Profit Path method data")

local strings = data.strings

-- Turn each shape's key list into {name, isText} pairs once, up front, so decoding
-- a record doesn't have to look at "$" prefixes every time.
local shapes = {}

for index, keys in ipairs(data.shapes) do
    local fields = {}

    for position, key in ipairs(keys) do
        if key:sub(1, 1) == "$" then
            fields[position] = { name = key:sub(2), text = true }
        else
            fields[position] = { name = key, text = false }
        end
    end

    shapes[index] = fields
end

-- A number that points at no string means the data file is broken. Fail loudly
-- rather than quietly showing a blank.
local function text(index)
    return assert(strings[index], "Broken text reference in method data")
end

local function decode(value)
    -- Plain numbers and booleans are stored as themselves.
    if type(value) ~= "table" then
        return value
    end

    local shape = value[1]
    local result = {}

    -- Lists: 0 holds numbers/records, -1 holds text.
    if shape == 0 or shape == -1 then
        for index = 2, #value do
            if shape == -1 then
                result[index - 1] = text(value[index])
            else
                result[index - 1] = decode(value[index])
            end
        end

        return result
    end

    -- Records: values follow in the same order as the shape's keys.
    local fields = assert(shapes[shape], "Broken shape reference in method data")

    for position, field in ipairs(fields) do
        local item = value[position + 1]

        if field.text then
            result[field.name] = text(item)
        else
            result[field.name] = decode(item)
        end
    end

    return result
end

local catalogue = {
    schema = data.schema,
    items = decode(data.items),
    equipment = decode(data.equipment),
    toolbelt = decode(data.toolbelt),

    -- Sprite names for capability icons (relics, abilities...), keyed by the alias
    -- a requirement's display_icon uses. Style.icon looks here after data/icons.lua.
    icons = decode(data.icons or { 0 }),
    methods = {},
}

-- Look methods up by ID as well as by position. With hundreds of methods, "the
-- third one" means nothing; an ID is stable.
local byId = {}

for index, packed in ipairs(data.methods) do
    local method = decode(packed)
    catalogue.methods[index] = method
    byId[method.id] = method
end

function catalogue.find(id)
    return byId[id]
end

return catalogue
