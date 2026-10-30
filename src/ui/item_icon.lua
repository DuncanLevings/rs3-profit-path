-- Draws an item's icon using the client's own item config (Obj), for the income
-- tables and the Requirements tab. This is display only: showing an icon never
-- means the player owns the item or can use it.
local definitions = require("src/data/method_data").items
local ItemIcon = {}

-- Check the native item's name before showing it. A bad ID must never display
-- some unrelated picture. Keep native property access inside the protected read.
function ItemIcon.resolve(itemId)
    local definition = definitions[tostring(itemId)]
    local expected = definition and definition.name or "Unknown item"
    local ok, object = pcall(function()
        local native = config.Obj.FromID(itemId)
        local name = native and native.name

        if definition and type(name) == "string" and name:lower() == expected:lower() then
            return native
        end
    end)

    return ok and object or nil, expected
end

-- Fixed source icons and the changing owned-match slot share the same native
-- identity check, so a stale/bad ID never displays another item's picture.
-- `name` is optional: what to call a row that has no item at all (the Wiki's
-- "Rare drop table", say), instead of "Unknown item".
function ItemIcon.add(parent, itemId, options, name)
    local object, expected = ItemIcon.resolve(itemId)
    options.tooltip = itemId == nil and name or expected

    if not object then
        return parent:AddSpriteButton("INFO", function() end, options), expected, false
    end

    options.clickthrough = false

    return parent:AddItemSlot(object, options), expected, true
end

return ItemIcon
