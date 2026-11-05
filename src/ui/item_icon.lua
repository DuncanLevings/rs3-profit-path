-- Draws an item's icon using the client's own item config (Obj), for the income
-- tables and the Requirements tab. This is display only: showing an icon never
-- means the player owns the item or can use it.
local definitions = require("src/data/method_data").items
local ItemNames = require("src/data/item_names")
local ItemIcon = {}

-- Check the native item's name before showing it. A bad ID must never display
-- some unrelated picture. Keep native property access inside the protected read.
function ItemIcon.resolve(itemId)
    -- The bundled catalogue's name first; custom activities can use any GE item,
    -- so fall back to the GE item list's name.
    local definition = definitions[tostring(itemId)]
    local expected = definition and definition.name or (itemId and ItemNames.label(itemId)) or "Unknown item"
    local known = definition ~= nil or expected ~= "Unknown item"
    local ok, object = pcall(function()
        local native = config.Obj.FromID(itemId)
        local name = native and native.name

        if known and type(name) == "string" and name:lower() == expected:lower() then
            return native
        end
    end)

    return ok and object or nil, expected
end

-- Fixed source icons and the changing owned-match slot share the same native
-- identity check, so a stale/bad ID never displays another item's picture.
-- `name` is optional: what to call a row that has no item at all (the Wiki's
-- "Rare drop table", say), instead of "Unknown item".
--
-- Pass options.tooltip = false for no tooltip, where the item is already named
-- beside its picture (each tooltip costs native IDs; see README).
function ItemIcon.add(parent, itemId, options, name)
    local object, expected = ItemIcon.resolve(itemId)
    local named = options.tooltip == false

    if named then
        options.tooltip = nil
    else
        options.tooltip = itemId == nil and name or expected
    end

    -- No picture we can trust. The info icon is only there to hover for the
    -- name, so when the name is already shown, draw nothing.
    if not object then
        if named then
            return nil, expected, false
        end

        return parent:AddSpriteButton("INFO", function() end, options), expected, false
    end

    options.clickthrough = false

    return parent:AddItemSlot(object, options), expected, true
end

return ItemIcon
