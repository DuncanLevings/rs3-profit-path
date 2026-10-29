-- Shared colours, number formatting and small decorations for both views.
-- Every native control created here belongs to the supplied parent.
local iconNames = require("data/icons")
local Style = {
    text = 0xEEE9DAFF,
    muted = 0xB5B1A2FF,
    gold = 0xE3BF70FF,
    good = 0xB7D8A6FF,
    bad = 0xE4A099FF,
    categories = { pvm = 0xDEA19AFF, skilling = 0xACCEA0FF, production = 0x9EBEDFFF },
}

-- Native rectangles give tables quiet bands and item slots a state border.
-- The parent owns them; clickthrough keeps them out of tooltip/input handling.
function Style.rectangle(parent, options)
    local rectangle = ui.Rectangle.new(parent.content)
    rectangle:SetPos(options.x or 0, options.y or 0, options.xAnchor or 0, 0)
    rectangle:SetSize(options.width, options.height, options.widthAnchor or 0, options.heightAnchor or 0)
    rectangle.rgba = options.colour
    rectangle.fill = options.fill ~= false
    rectangle.clickthrough = true

    return rectangle
end

-- rsprite owns name resolution, caching and unsafe/missing-sprite warnings.
-- PrettyUI owns drawing and cleanup. Missing decorations leave the text usable.
function Style.icon(parent, name, options)
    local sprite = rsprite.Get(iconNames[name])

    if not sprite then
        return nil
    end

    return parent:AddSprite(sprite, options)
end

-- A native save sprite fits PrettyUI's public icon-button API. Keep text Save
-- available if that sprite is absent in a different client build; Enter also saves.
function Style.saveButton(parent, action)
    local sprite = rsprite.Get(iconNames.save)

    return parent:AddSimpleButton(sprite or "Save", action, {
        inline = true, width = sprite and 28 or 64, height = 28,
        iconSize = 20, tooltip = "Save rate",
    })
end

-- Keep full values readable in breakdowns. Group the integer part after rounding
-- so separators don't change the decimal precision or the sign.
function Style.number(value, decimals)
    if value == nil then
        return "Unavailable"
    end

    local text = string.format("%." .. (decimals or 0) .. "f", value)
    local sign, whole, fraction = text:match("^(-?)(%d+)(.*)$")
    local grouped = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")

    return sign .. grouped .. fraction
end

-- The list needs a short comparison value; full numbers remain in Income.
function Style.compact(value)
    if value == nil then
        return "Not estimated"
    end

    local magnitude = math.abs(value)

    if magnitude >= 1000000 then
        return string.format("%.1fm/h", value / 1000000)
    end

    if magnitude >= 1000 then
        return string.format("%.1fk/h", value / 1000)
    end

    return Style.number(value, 0) .. "/h"
end

-- Rates can be fractional (for example, potion doses per hour), unlike GP
-- displays. Keep useful quantity precision without adding .00 to whole amounts.
function Style.quantity(value)
    if value == nil then
        return "Unavailable"
    end

    if value == math.floor(value) then
        return Style.number(value)
    end

    return Style.number(value, 2):gsub("0+$", ""):gsub("%.$", "")
end

-- Text accompanies each colour, so colour isn't the only way to spot a shortfall.
function Style.statusColour(status)
    if status == "met" then
        return Style.good
    end

    if status == "unmet" then
        return Style.bad
    end

    return Style.muted
end

return Style
