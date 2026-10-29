-- Draws an item's icon using the client's own item config (Obj), for the income
-- tables and the Requirements tab. This is display only: showing an icon never
-- means the player owns the item or can use it.
local definitions = require("data/methods").items
local ItemIcon = {}

-- Adds the icon for `itemId` to `parent` and returns three things:
--   control  - the item slot (or an info icon if we couldn't verify the item)
--   name     - the item's name from our catalogue, also used as the tooltip
--   verified - true only if the client's item has the name we expected
--
-- The name check matters: if the ID in our data were wrong, the client would
-- happily draw some unrelated item. Showing an info icon instead keeps the
-- mistake visible. The parent owns the control and its tooltip, as usual.
function ItemIcon.add(parent, itemId, options)
    local definition = definitions[tostring(itemId)]

    -- Native config lookups can throw for unknown IDs, so protect this one.
    local ok, object = pcall(function()
        return config.Obj.FromID(itemId)
    end)

    local expected = definition and definition.name or "Unknown item"
    options.tooltip = expected

    if not ok or not object or not definition or object.name:lower() ~= expected:lower() then
        return parent:AddSpriteButton("INFO", function() end, options), expected, false
    end

    -- Item slots ignore the mouse by default; we need hovers for the tooltip.
    options.clickthrough = false

    return parent:AddItemSlot(object, options), expected, true
end

return ItemIcon
