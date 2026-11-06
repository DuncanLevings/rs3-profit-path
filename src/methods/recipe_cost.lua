-- Prices untradeable supplies from their ingredients, using the validated
-- data/recipes.lua bundle. GE ingredients use instant-buy prices; nested recipes
-- are priced recursively. Free ingredients count as 0.
-- Convert doses explicitly: an Overload (4) uses 4/3 of a recipe that produces
-- Overload (3).
local recipes = require("data/recipes")

local RecipeCost = {}

-- True for real numbers from 0 upwards (same check as income.lua).
local function nonNegativeFinite(value)
    return type(value) == "number" and value >= 0 and value < math.huge
end

-- Collects every GE item ID anywhere in this recipe's ingredient tree into `ids`
-- (a set), so captureQuotes can fetch them all up front in one go.
function RecipeCost.itemIds(page, ids)
    ids = ids or {}

    for _, material in ipairs(recipes[page].materials) do
        if material.pricing == "ge" then
            ids[material.item_id] = true
        elseif material.pricing == "recipe" then
            RecipeCost.itemIds(material.page, ids)
        end
    end

    return ids
end

-- The cost of one item made by `page`'s recipe, counted in `portion` doses (nil
-- means "as the recipe makes it"). Returns:
--   price, timestamp   timestamp is the OLDEST GE price used, so the screen can
--                      never make the result look fresher than its stalest input
--   nil, message       if any GE ingredient has no usable buy price
function RecipeCost.price(page, portion, quotes)
    local recipe = recipes[page]
    local total = 0
    local oldest

    for _, material in ipairs(recipe.materials) do
        local unitPrice, timestamp

        if material.pricing == "ge" then
            local quote = quotes[material.item_id]
            local usable = quote and (quote.status == "available" or quote.status == "partial")

            -- An hourly average counts without a timestamp (see Income.inspectQuote).
            local current = usable and (quote.highSource == "hour" or nonNegativeFinite(quote.highTime))

            if not (current and nonNegativeFinite(quote.high)) then
                local why = quote and (quote.highMessage or quote.message)

                return nil, "No GE price for " .. material.name .. ", an ingredient" .. (why and (": " .. why) or ".")
            end

            unitPrice, timestamp = quote.high, quote.highTime
        elseif material.pricing == "recipe" then
            -- Same function one level down. Its second value is a timestamp when it
            -- worked, or the reason when it didn't.
            local subPrice, subInfo = RecipeCost.price(material.page, material.portion, quotes)

            if not subPrice then
                return nil, subInfo
            end

            unitPrice, timestamp = subPrice, subInfo
        else
            -- Free (no GE price exists, e.g. Crystal tree blossom): it adds nothing.
            unitPrice = 0
        end

        total = total + material.quantity * unitPrice

        if timestamp and (not oldest or timestamp < oldest) then
            oldest = timestamp
        end
    end

    -- Per item made, then rescaled to the doses asked for.
    local each = total / recipe.quantity

    if portion and recipe.portion then
        each = each * portion / recipe.portion
    end

    return each, oldest
end

return RecipeCost
