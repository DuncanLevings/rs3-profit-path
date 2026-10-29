-- Turns selected shared monster drops into expected outputs per kill. This file
-- owns no native objects or prices. The build uses the same expansion function
-- to reject ambiguous rates/quantities before they can reach the game.
local Loot = {}

-- Static models don't change while enabled. Cache their expanded rows so typing
-- a rate doesn't decode the monster table again; discarded models can be freed.
local expanded = setmetatable({}, { __mode = "k" })

-- Use exact fractions, never the rounded percentage in the monster's "chance".
-- A rate can already include several rolls (2 × 1/128); don't apply rolls twice.
local function probability(text)
    assert(type(text) == "string", "Drop rate must be text")

    if text == "Always" then
        return 1
    end

    local compact = text:gsub(",", ""):gsub("%s", ""):gsub("×", "*")
    local multiplier, numerator, denominator = compact:match("^(%d+%.?%d*)%*(%d+%.?%d*)/(%d+%.?%d*)$")

    if not numerator then
        numerator, denominator = compact:match("^(%d+%.?%d*)/(%d+%.?%d*)$")
        multiplier = 1
    end

    assert(numerator and tonumber(denominator) > 0,
        "Choose one explicit drop rate for ambiguous/unknown rate: " .. text)

    local rolls = tonumber(multiplier)
    local top, bottom = tonumber(numerator), tonumber(denominator)

    assert(rolls < math.huge and top < math.huge and bottom < math.huge,
        "Non-finite drop probability")

    local result = rolls * top / bottom

    assert(result >= 0 and result < math.huge, "Invalid drop probability")

    -- Multi-roll expected occurrences can exceed one; each roll still needs a
    -- probability between zero and one.
    assert(top <= bottom, "Drop probability exceeds one")

    return result
end

-- Ranges use their arithmetic mean. Prefer the structured bounds: some inherited
-- display strings have encoding damage or a '(noted)' suffix.
local function averageQuantity(drop)
    if drop.quantity_low ~= nil then
        local low, high = drop.quantity_low, drop.quantity_high or drop.quantity_low

        assert(type(low) == "number" and type(high) == "number" and low >= 0 and high >= low,
            "Invalid drop quantity range")

        return (low + high) / 2
    end

    local text = drop.quantity:gsub(",", "")

    assert(text:match("^%d+%.?%d*$"), "Unknown drop quantity: " .. drop.quantity)

    return tonumber(text)
end

-- Pure expansion, also called with source JSON data by catalogue validation.
-- Each selector produces one row; repeated coin ranges are combined into it.
function Loot.expand(selection, monster)
    local outputs = {}
    local used = {}

    for _, selected in ipairs(selection) do
        local quantity, count, itemId = 0, 0, nil

        for sectionIndex, section in ipairs(monster.sections) do
            if section.title == selected.section then
                for dropIndex, drop in ipairs(section.drops) do
                    if drop.name == selected.item then
                        local key = sectionIndex .. ":" .. dropIndex

                        assert(not used[key], "Loot row selected twice: " .. drop.name)

                        used[key] = true

                        assert(drop.item_id and not drop.untradeable, "Unpriceable selected drop: " .. drop.name)

                        assert(not itemId or itemId == drop.item_id, "Selected drops have different item IDs")

                        itemId = drop.item_id
                        quantity = quantity + averageQuantity(drop) * probability(selected.rate or drop.rate)
                        count = count + 1
                    end
                end
            end
        end

        assert(count == selected.rows, "Loot selector changed: " .. selected.item)

        assert(quantity >= 0 and quantity < math.huge, "Invalid expected drop quantity")

        assert(selected.pricing == nil or selected.pricing == "fixed", "Unsupported loot valuation")

        local fixed = selected.pricing == "fixed"

        if fixed then
            assert(type(selected.unit_value) == "number" and selected.unit_value >= 0
                and selected.unit_value < math.huge, "Invalid fixed loot value")

            assert(type(selected.valuation_note) == "string" and selected.valuation_note ~= "",
                "Fixed loot needs a valuation explanation")

            assert(selected.tax_denominator == nil, "Fixed coin proceeds cannot have GE sale tax")
        else
            assert(selected.unit_value == nil, "Fixed loot value needs fixed pricing")
        end

        outputs[#outputs + 1] = {
            name = selected.item, item_id = itemId, quantity = quantity, basis = "action",
            pricing = selected.pricing, unit_value = selected.unit_value,
            valuation_note = selected.valuation_note,
            tax_denominator = not fixed and 50 or nil,
        }
    end

    return outputs
end

-- Ordinary production methods keep their existing output rows. Loot methods
-- add their shared-drop selections without copying drop tables into each method.
function Loot.outputs(model)
    if not model.loot then
        return model.outputs
    end

    if expanded[model] then
        return expanded[model]
    end

    local monster = assert(require("src/data/monster_data").find(model.loot.monster), "Missing method monster")
    local rows = {}

    for _, row in ipairs(model.outputs) do
        rows[#rows + 1] = row
    end

    for _, row in ipairs(Loot.expand(model.loot.selection, monster)) do
        rows[#rows + 1] = row
    end

    expanded[model] = rows
    return rows
end

return Loot
