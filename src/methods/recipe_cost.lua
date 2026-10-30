-- Prices untradeable supplies by what they cost to MAKE.
--
-- Some supplies (Perfect plus potion, Overload, Dungeoneering pouches) can't be
-- traded, so the GE has no price for them. Instead we add up their ingredients:
--
--   ge      an ingredient with a GE price: we use its instant-buy price ("high"),
--           same as any other supply you'd buy
--   recipe  an ingredient that's untradeable too: we price ITS recipe, and so on
--           down the chain (Perfect plus -> Overload -> extreme potions)
--   free    an ingredient with no price at all (e.g. Crystal tree blossom, which
--           you gather yourself): counted as 0 GP, and freeNames() lists these so
--           the screen can say so
--
-- Doses: recipes say how many doses they make and use. A Perfect plus recipe uses an
-- Overload (4), but the Overload recipe makes Overload (3), so one 4-dose overload
-- costs 4/3 of an overload recipe.
--
-- The data comes from data/recipes.lua, generated and checked (no loops, every GE
-- ingredient has an item ID) by src/tools/catalogue.py.
local recipes = require("data/recipes")

local RecipeCost = {}

-- True for real numbers from 0 upwards (same check as income.lua).
local function nonNegativeFinite(value)
    return type(value) == "number" and value >= 0 and value < math.huge
end

-- Is there a recipe we can price this item by?
function RecipeCost.has(page)
    return recipes[page] ~= nil
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

-- Names of every "free" ingredient anywhere in the tree, sorted and without
-- repeats, e.g. { "Crystal tree blossom" }. Doesn't need prices, so the screen can
-- show it straight away.
function RecipeCost.freeNames(page)
    local seen, names = {}, {}

    local function walk(current)
        for _, material in ipairs(recipes[current].materials) do
            if material.pricing == "free" and not seen[material.name] then
                seen[material.name] = true
                names[#names + 1] = material.name
            elseif material.pricing == "recipe" then
                walk(material.page)
            end
        end
    end

    walk(page)
    table.sort(names)

    return names
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
            -- Free: no price exists, so it adds nothing. freeNames() reports it.
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
