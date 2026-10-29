-- Draws item references using the client's own Obj configs. These are display
-- lookups only: an icon never proves that the player owns or can use the item.
local definitions = require("data/methods").items
local ItemIcon = {}

-- Keep bad/missing references visible without showing an unrelated native item.
-- The parent owns the returned control and its tooltip, including on shutdown.
function ItemIcon.add(parent, itemId, options)
    local definition = definitions[tostring(itemId)]
    local ok, object = pcall(function()
        return config.Obj.FromID(itemId)
    end)

    local expected = definition and definition.name or "Unknown item"
    options.tooltip = expected

    if not ok or not object or not definition or object.name:lower() ~= expected:lower() then
        return parent:AddSpriteButton("INFO", function() end, options), expected, false
    end

    options.clickthrough = false
    options.tooltip = expected

    return parent:AddItemSlot(object, options), expected, true
end

return ItemIcon
