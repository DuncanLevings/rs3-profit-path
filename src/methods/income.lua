-- Money maths for a method, plus the one place we talk to GE Prices Library (GEPL).
--
-- Quick primer on GE prices: we use two numbers per item.
--   high = the instant-buy price  -> what you'd pay for supplies
--   low  = the instant-sell price -> what you'd get for your outputs
--
-- Each side is the average over the last hour of trades when there were any.
-- The latest single trade is too easy to throw off: one player dumping steel bars
-- at 15 GP made the "latest sell" 15 while the hour's average was over 1,000.
-- Only a side with no trades in the hour falls back to its latest trade, and even
-- then it's dropped if it's wildly out of line with the other side's average.
-- (Monster Lookup's live drop prices solved the same problem the same way.)
--
-- Opening/reopening reads GEPL's cached getter. That getter owns cache expiry
-- and the in-flight fetch guard; we never force updateDatabase or run HTTP here.
-- Typing a new rate reuses those same prices, so we never hit GEPL per keystroke.
--
-- Untradeable supplies (rows with pricing = "recipe") have no GE price of their own;
-- recipe_cost.lua prices them from their ingredients instead.
local RecipeCost = require("src/methods/recipe_cost")
local Loot = require("src/methods/loot")

local Income = {}

-- True for real numbers from 0 upwards. Rejects nil, strings, infinity and NaN
-- (NaN fails `>= 0`), which is what we need anywhere a price or quantity goes.
local function nonNegativeFinite(value)
    return type(value) == "number" and value >= 0 and value < math.huge
end

-- A fallback trade more than this many times away from the other side's hourly
-- average is treated as a one-off, not a real price. Same limit as Monster Lookup.
local MAX_DRIFT = 3

-- How many times apart two prices are, whichever is bigger.
local function drift(price, reference)
    return math.max(price / reference, reference / price)
end

-- The last hour's averages for one item, or nil if GEPL can't give them (an older
-- GEPL without the getter, the hourly data not loaded yet, or no entry for the
-- item). Missing averages are fine: we just use the latest trades instead.
local function hourlyAverage(library, itemId)
    if type(library.getOneHourAverage) ~= "function" or not library.isReady("1h") then
        return nil
    end

    local ok, average = pcall(library.getOneHourAverage, itemId)

    return ok and type(average) == "table" and average or nil
end

-- One side's hourly average, if that side actually traded in the last hour.
local function averageSide(average, price, volume)
    local value = average and average[price]
    local traded = average and average[volume]

    if nonNegativeFinite(value) and value > 0 and type(traded) == "number" and traded > 0 then
        return value
    end
end

-- Asks GEPL for one item's prices and turns the answer into a plain table with a
-- status: "available", "partial" (only one side usable), "loading", "unavailable",
-- "invalid" or "error". Nothing here ever invents a price.
--
-- Each usable side has a price and a source ("hour" for the hourly average,
-- "latest" for a single trade). A latest side always has its trade's timestamp;
-- an hour side has one only when the item has a latest trade too, because GEPL's
-- hourly data carries no times of its own. A side we refused or couldn't find
-- says why in its message (highMessage / lowMessage).
--
-- GEPL keeps its latest and hourly data apart, and an item can be in one but not
-- the other. So we ask for both, and either one is enough for a price.
function Income.inspectQuote(library, itemId)
    -- GEPL is a required dependency, but guard anyway: a missing or disabled
    -- library must show "unavailable", never crash or invent a price.
    if not library then
        return { status = "unavailable", message = "GE Price Library is not enabled." }
    end

    if type(itemId) ~= "number" or itemId % 1 ~= 0 or itemId <= 0 then
        return { status = "invalid", message = "A positive integer item ID is required." }
    end

    -- isReady can throw on a broken library; wrap everything so any library error
    -- becomes a readable message instead of stopping the screen.
    local ok, result = pcall(function()
        local latestReady = library.isReady("latest")
        local quote, latestProblem

        -- GEPL throws "Price not found" for an item it has no latest entry for,
        -- and returns nil for one that only has hourly data. getLatest may also
        -- kick off GEPL's own cache refresh.
        if latestReady then
            local fetched, value = pcall(library.getLatest, itemId)

            if fetched and type(value) == "table" then
                quote = value
            elseif not fetched and not tostring(value):find("Price not found", 1, true) then
                latestProblem = "GE Price Library: " .. tostring(value)
            end
        end

        local average = hourlyAverage(library, itemId)

        -- Nothing to go on: say whether that's GEPL still loading, a library
        -- error, or simply no GE prices for this item.
        if not quote and not average then
            if not latestReady then
                return { status = "loading", message = "GE Price Library is still loading prices." }
            end

            if latestProblem then
                return { status = "error", message = latestProblem }
            end

            return { status = "unavailable", message = "GE Price Library has no prices for this item. "
                .. "It may not be tradeable on the Grand Exchange." }
        end

        -- A latest trade only counts if both its price and its timestamp look sane.
        local highValid = quote ~= nil and nonNegativeFinite(quote.high) and nonNegativeFinite(quote.highTime)
        local lowValid = quote ~= nil and nonNegativeFinite(quote.low) and nonNegativeFinite(quote.lowTime)

        -- Copy the values into our own table rather than keeping GEPL's object.
        local result = { itemId = itemId }

        -- An hour side borrows a latest trade's time when there is one (its own
        -- side's first). That time only says "this item is trading".
        local anyTime = highValid and quote.highTime or lowValid and quote.lowTime or nil

        for _, side in ipairs({
            { key = "high", valid = highValid, average = averageSide(average, "avgHighPrice", "highPriceVolume") },
            { key = "low", valid = lowValid, average = averageSide(average, "avgLowPrice", "lowPriceVolume") },
        }) do
            local time = side.key .. "Time"

            if side.average then
                result[side.key] = side.average
                result[time] = side.valid and quote[time] or anyTime
                result[side.key .. "Source"] = "hour"
            elseif side.valid then
                result[side.key] = quote[side.key]
                result[time] = quote[time]
                result[side.key .. "Source"] = "latest"
            else
                -- Neither an hourly average nor a usable latest trade on this side.
                result[side.key .. "Message"] = side.key == "high"
                    and "No recent instant-buy trades for this item."
                    or "No recent instant-sell trades for this item."
            end
        end

        -- A side that fell back to one trade gets checked against the other side's
        -- hourly average. If they're more than MAX_DRIFT times apart, that trade
        -- is almost certainly a dump or a misclick, so we don't use it.
        for _, pair in ipairs({ { "high", "low", "buy" }, { "low", "high", "sell" } }) do
            local key, other, name = pair[1], pair[2], pair[3]

            if result[key .. "Source"] == "latest" and result[other .. "Source"] == "hour"
                and result[key] > 0 and drift(result[key], result[other]) > MAX_DRIFT then
                result[key], result[key .. "Time"], result[key .. "Source"] = nil, nil, nil
                result[key .. "Message"] = "The latest " .. name .. " trade looks like a one-off, and there were no "
                    .. name .. " trades in the last hour."
            end
        end

        if result.high == nil and result.low == nil then
            return { status = "unavailable", message = result.highMessage or result.lowMessage
                or "No usable trade prices for this item." }
        end

        result.status = result.high ~= nil and result.low ~= nil and "available" or "partial"

        return result
    end)

    if not ok then
        return { status = "error", message = "GE Price Library: " .. tostring(result) }
    end

    return result
end

-- Turns what the player typed into a rate. Returns nil plus a message if it's not
-- a usable number (empty, negative, "abc", "inf" and so on).
function Income.parseRate(text)
    local rate = type(text) == "string" and tonumber(text) or nil

    if not nonNegativeFinite(rate) then
        return nil, "Enter a finite number of actions per hour, zero or greater."
    end

    return rate
end

-- Fetches one quote per distinct item in the method. If an item is both an input
-- and an output we only ask once, so both sides use the exact same snapshot.
--
-- `shared` is optional: a table of quotes already fetched for other methods in the
-- same refresh (Browse prices every method at once). Items found there are reused
-- instead of asking GEPL again, and new ones are added for the next method.
--
-- A recipe-priced row doesn't need its own item's price (it can't be traded);
-- instead we fetch every GE ingredient in its recipe, all the way down.
function Income.captureQuotes(library, model, shared)
    local quotes = {}

    local function fetch(itemId)
        if not quotes[itemId] then
            quotes[itemId] = shared and shared[itemId] or Income.inspectQuote(library, itemId)

            if shared then
                shared[itemId] = quotes[itemId]
            end
        end
    end

    for _, lines in ipairs({ model.inputs, Loot.outputs(model) }) do
        for _, line in ipairs(lines) do
            if line.pricing == "recipe" then
                -- Sorted so the fetch order (and any test counting it) is stable.
                local ids = {}

                for itemId in pairs(RecipeCost.itemIds(line.recipe)) do
                    ids[#ids + 1] = itemId
                end

                table.sort(ids)

                for _, itemId in ipairs(ids) do
                    fetch(itemId)
                end
            elseif line.item_id and line.pricing ~= "fixed" then
                fetch(line.item_id)
            end
        end
    end

    return quotes
end

-- Works out the hourly numbers for a method at a given rate (e.g. smelts/hour).
--
-- `model` is the method's income data, already checked when the catalogue was built,
-- so we don't re-validate it here. `quotes` is the snapshot from captureQuotes.
--
-- If the source recipe itself is incomplete, there's no total profit. A missing
-- price is different: one thinly traded potion or rare drop shouldn't hide a
-- whole method. When most of a side's priced rows (supplies, or outputs) have
-- prices, the missing ones count as 0 GP and the result names them. When most
-- don't (or the only one doesn't), that side has no total, so neither does the
-- profit. A missing output counted as 0 can only make the profit look worse; a
-- missing supply can make it look a little better, and its row says so.
function Income.calculate(model, rate, quotes)
    if not nonNegativeFinite(rate) then
        return { status = "invalid", message = "Rate must be finite and zero or greater." }
    end

    local calculated = { inputs = {}, outputs = {}, rate = rate }

    -- Set if a silly-big rate pushes any number to infinity; we report that below.
    local overflow = false

    -- Prices every row on one side of the recipe. `side` is "high" for supplies and
    -- "low" for outputs. Returns the rows plus the subtotal and tax subtotal; the
    -- subtotals are nil if any row couldn't be priced.
    local function calculateLines(source, side)
        local rows = {}
        local total = 0
        local taxTotal = 0
        local complete = true

        for _, line in ipairs(source) do
            -- "action" rows scale with the rate (1 ore per smelt). "hour" rows are a
            -- fixed amount per hour whatever the rate.
            local quantity = line.quantity * (line.basis == "action" and rate or 1)

            if not nonNegativeFinite(quantity) then
                overflow = true
            end

            local quote, price, timestamp, recipeProblem, hourly

            if line.pricing == "fixed" then
                -- Coin drops and alchemy proceeds have a fixed GP value, no GE
                -- quote timestamp, and no sale tax. Their source value is bundled.
                price = line.unit_value
            elseif line.pricing == "recipe" then
                -- Priced from its ingredients. On failure the second value is why.
                price, timestamp = RecipeCost.price(line.recipe, line.portion, quotes)

                if not price then
                    recipeProblem, timestamp = timestamp, nil
                end
            else
                quote = line.item_id and quotes[line.item_id]

                local usable = quote and (quote.status == "available" or quote.status == "partial")
                price = usable and quote[side] or nil
                timestamp = usable and quote[side .. "Time"] or nil

                -- An hourly average proves the item traded without a timestamp
                -- (see inspectQuote), so it counts as current on its own.
                hourly = usable and quote[side .. "Source"] == "hour"
            end

            local row = {
                name = line.name, itemId = line.item_id, quantity = quantity, basis = line.basis,
                unitPrice = price, timestamp = timestamp,
                creationCost = line.pricing == "recipe" or nil,
            }

            if quantity == 0 then
                -- Zero of something costs nothing, even if we don't know its price.
                row.gross = 0
                row.tax = 0
                row.value = 0
            -- Fixed values need no timestamp, and a recipe cost that came back at
            -- all already checked every ingredient's price.
            elseif nonNegativeFinite(price) and (line.pricing == "fixed" or line.pricing == "recipe"
                or hourly or nonNegativeFinite(timestamp)) then
                -- GE tax works per item and is rounded down: floor(price / 50) for a
                -- 2% tax. Round per item first, then multiply, or the totals drift
                -- from the Wiki's numbers.
                local unitTax = line.tax_denominator and math.floor(price / line.tax_denominator) or 0

                row.gross = quantity * price
                row.tax = quantity * unitTax
                row.value = row.gross - row.tax

                if not nonNegativeFinite(row.gross) or not nonNegativeFinite(row.tax)
                    or not nonNegativeFinite(row.value) then
                    overflow = true
                end
            else
                -- No usable price, so this side can't have a total. Say why.
                complete = false
                row.message = recipeProblem or line.valuation
                    or (quote and (quote[side .. "Message"] or quote.message)) or "Price unavailable."
            end

            if row.value then
                total = total + row.value
                taxTotal = taxTotal + row.tax
            end

            rows[#rows + 1] = row
        end

        if not nonNegativeFinite(total) or not nonNegativeFinite(taxTotal) then
            overflow = true
        end

        return rows, complete and total or nil, complete and taxTotal or nil
    end

    -- Rows counted as 0 because they have no price: { names }, if any.
    local uncounted = {}

    -- Sums one side's rows that have prices, if they're most of them. Fixed
    -- values (coins) don't count towards "most": a pile of coins says nothing
    -- about what the missing items are worth. Returns nil when there are too few.
    -- `effect` finishes each missing row's message, saying what the 0 means.
    local function countMissingAsZero(rows, lines, effect)
        local priced, missing, total, tax, names = 0, 0, 0, 0, {}

        for index, row in ipairs(rows) do
            if row.value then
                total = total + row.value
                tax = tax + row.tax

                if lines[index].pricing ~= "fixed" and row.quantity > 0 then
                    priced = priced + 1
                end
            else
                missing = missing + 1
                names[#names + 1] = row.name
            end
        end

        if priced <= missing then
            return nil
        end

        -- Each row still says why it has no price, and now what that means.
        for _, row in ipairs(rows) do
            if not row.value then
                row.countedAsZero = true
                row.message = row.message .. " " .. effect
            end
        end

        for _, name in ipairs(names) do
            uncounted[#uncounted + 1] = name
        end

        return total, tax
    end

    local outputLines = Loot.outputs(model)

    calculated.inputs, calculated.cost = calculateLines(model.inputs, "high")
    calculated.outputs, calculated.revenue, calculated.tax = calculateLines(outputLines, "low")

    if calculated.cost == nil then
        calculated.cost = countMissingAsZero(calculated.inputs, model.inputs,
            "Counted as 0 GP in the total, since most supplies have prices, so the profit may be a little high.")
    end

    if calculated.revenue == nil then
        calculated.revenue, calculated.tax = countMissingAsZero(calculated.outputs, outputLines,
            "Counted as 0 GP in the total, since most outputs have prices.")
    end

    if overflow then
        return { status = "invalid", message = "This rate produces values too large to calculate." }
    end

    -- Gross is revenue before tax, i.e. after-tax revenue with the tax added back.
    calculated.gross = calculated.revenue and (calculated.revenue + calculated.tax) or nil

    if calculated.gross and not nonNegativeFinite(calculated.gross) then
        return { status = "invalid", message = "This rate produces values too large to calculate." }
    end

    -- We only give a profit number when the recipe is complete AND both sides priced.
    if model.coverage == "complete" and calculated.cost and calculated.revenue then
        calculated.status = "available"
        calculated.profit = calculated.revenue - calculated.cost

        -- ROI = profit as a % of what you spent on supplies. With no spend (zero
        -- cost) it doesn't mean anything, so we leave it empty rather than show
        -- infinity. The final check catches a huge profit divided by a tiny cost.
        if calculated.cost > 0 then
            local roi = calculated.profit / calculated.cost * 100

            if roi == roi and math.abs(roi) < math.huge then
                calculated.roi = roi
            end
        end

        -- Say what was left out, so nobody takes the profit as exact.
        if #uncounted > 0 then
            local named = uncounted[1] .. (#uncounted > 1 and (" and " .. (#uncounted - 1) .. " more") or "")

            calculated.uncounted = uncounted
            calculated.note = "Counted as 0 (no price): " .. named .. "."
        end
    else
        calculated.status = "partial"

        if model.coverage ~= "complete" then
            calculated.message = "Source model is incomplete; total profit is unavailable."
        else
            -- Name what's missing, so nobody has to hunt through both tables.
            local missing = {}

            for _, row in ipairs(calculated.inputs) do
                if row.message then
                    missing[#missing + 1] = row.name
                end
            end

            for _, row in ipairs(calculated.outputs) do
                if row.message then
                    missing[#missing + 1] = row.name
                end
            end

            local named = missing[1] or "some items"

            if #missing > 1 then
                named = named .. " and " .. (#missing - 1) .. " more"
            end

            calculated.message = "No price for " .. named .. " - hover it for why."
        end
    end

    return calculated
end

return Income
