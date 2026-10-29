-- Shared look-and-feel for the Browse and method screens: colours, number
-- formatting, and a few small decorations (icons, coin, boxed icon buttons).
--
-- Ownership: every control made here is a child of the `parent` passed in, so it
-- gets cleaned up when that parent view is destroyed. Nothing here keeps state
-- between calls.
local iconNames = require("data/icons")

local Style = {
    text = 0xEEE9DAFF,
    muted = 0xB5B1A2FF,
    gold = 0xE3BF70FF,
    good = 0xB7D8A6FF,
    bad = 0xE4A099FF,
    categories = { pvm = 0xDEA19AFF, skilling = 0xACCEA0FF, production = 0x9EBEDFFF },
}

-- The Coins item, and the font PrettyUI uses for body text. We measure numbers in
-- that font so a coin can sit right next to right-aligned text.
local COINS_ITEM_ID = 995
local BODY_FONT = "MUSEO_SANS_15PT_REGULAR"

-- Gap between a coin and the number it belongs to, in interface units.
local COIN_GAP = 4

-- The client picks Coins art from the stack size: 1 coin looks like a single
-- coin, a big stack looks like the full pile. Any amount this big gets the pile.
local COIN_PILE_QUANTITY = 1000000

-- A heads-up on `parent.content`: PrettyUI views expose their native component
-- layer as `.content`, and we draw a few plain native shapes (rectangles, the coin)
-- straight onto it. The rest of the app already parents native children there.
-- Those shapes die with the view, just like PrettyUI's own controls.

-- Native rectangles give tables their quiet row bands and item slots a coloured
-- border. Clickthrough keeps them from stealing hovers and clicks.
function Style.rectangle(parent, options)
    local rectangle = ui.Rectangle.new(parent.content)

    rectangle:SetPos(options.x or 0, options.y or 0, options.xAnchor or 0, 0)
    rectangle:SetSize(options.width, options.height, options.widthAnchor or 0, options.heightAnchor or 0)
    rectangle.rgba = options.colour
    rectangle.fill = options.fill ~= false
    rectangle.clickthrough = true

    return rectangle
end

-- Keeps panels the right width when their page grows a scrollbar.
--
-- The problem: a panel works out its inner width once, when it's created. If the
-- page later gets taller than the window, PrettyUI adds a scrollbar and the page
-- gets narrower. The panel's outline shrinks with it, but its insides keep the old
-- width, so right-aligned text (like the ROI) gets cut off at the panel's edge.
--
-- The fix PrettyUI documents is Panel:SetSize. So a screen registers its panels
-- here while it builds, then calls fit() once everything is added (by then we
-- know whether a scrollbar appeared) and every panel is sized to the page's final
-- width. `padding` is the page's side padding; `gap` is the space between two
-- half-width panels sitting side by side.
function Style.panelFitter(host, padding, gap)
    local panels = {}
    local fitter = {}

    -- `half` = true for one of two side-by-side panels. Returns the panel.
    function fitter:add(panel, height, half)
        panels[#panels + 1] = { panel = panel, height = height, half = half }

        return panel
    end

    function fitter:fit()
        local width = host.content.width

        -- Not measurable (shouldn't happen in game): leave the panels as built.
        if type(width) ~= "number" then
            return
        end

        local full = width - padding * 2
        local half = math.floor(width / 2) - padding - math.floor((gap or 0) / 2)

        for _, entry in ipairs(panels) do
            entry.panel:SetSize(entry.half and half or full, entry.height)
        end
    end

    return fitter
end

-- Draws one of our named sprites (see data/icons.lua). rsprite finds the sprite's ID
-- and warns once if it's missing; PrettyUI draws it. If the sprite doesn't exist we
-- just skip it, because every icon sits next to text that still makes sense alone.
function Style.icon(parent, name, options)
    local sprite = rsprite.Get(iconNames[name])

    if not sprite then
        return nil
    end

    return parent:AddSprite(sprite, options)
end

-- A small boxed button showing a native sprite, like the Save and Reset buttons by
-- the rate box. If the sprite is missing in this client build we show a plain text
-- button instead, so the action never disappears.
function Style.iconButton(parent, name, fallbackText, tooltip, action)
    local sprite = rsprite.Get(iconNames[name])

    return parent:AddSimpleButton(sprite or fallbackText, action, {
        inline = true,
        width = sprite and 28 or 64,
        height = 28,
        iconSize = 20,
        tooltip = tooltip,
    })
end

-- The y that vertically centres an icon of `size` on a text box starting at `textY`
-- with height `textHeight`. Text sits in the middle of its box, so icons placed at
-- the box's top looked like they were floating above the words.
function Style.middle(textY, textHeight, size)
    return textY + math.floor((textHeight - size) / 2)
end

-- Problems hit while drawing the coin, reported once per session so a fallback
-- never happens silently. Keyed by step, e.g. "quantity".
local reportedCoinProblems = {}

local function reportCoinProblem(step, problem)
    if reportedCoinProblems[step] then
        return
    end

    reportedCoinProblems[step] = true

    pcall(print, "[Profit Path] coin icon: " .. step .. " failed: " .. tostring(problem))
end

-- Runs one native step and reports it if it throws. Returns true on success.
local function coinStep(step, action)
    local ok, problem = pcall(action)

    if not ok then
        reportCoinProblem(step, problem)
    end

    return ok
end

-- Draws the Coins item on `parent` as a big pile and returns the native sprite.
-- The client picks Coins art from the stack size, so we give it a huge quantity
-- and hide the quantity label so no number shows.
--
-- Heads-up: the docs list SetAssociatedObject(id, quantity), but this client
-- rejects the two-argument form ("no matching function call"). Attaching the item
-- and setting `associatedObjectQuantity` as a property does give the pile, so
-- that's what we do.
--
-- Each native step is tried on its own. Worst case we still show the Coins item
-- itself (the plain one-coin art); only if the item can't be drawn at all do we
-- fall back to the COINS sprite.
--
-- It's a native sprite rather than a PrettyUI one so callers can slide it with
-- SetPos when the number beside it changes length; see Style.placeCoin.
function Style.coins(parent, options)
    local x = options.x or 0
    local y = options.y or 0
    local xAnchor = options.xAnchor or 0
    local size = options.size or 20

    -- Step 1: make and place the sprite. Without this there's nothing to draw on.
    local coin
    local created = coinStep("create", function()
        coin = ui.Sprite.new(parent.content)
        coin:SetPos(x, y, xAnchor, 0)
        coin:SetSize(size, size)
    end)

    -- Coins are decoration: hovers and clicks should go to whatever is underneath.
    if created then
        coinStep("clickthrough", function()
            coin.clickthrough = true
        end)
    end

    -- Step 2: attach the Coins item at pile size. The quantity is set both before
    -- and after attaching: this combination is what worked in game, and we don't
    -- know which of the two the client actually uses to pick the art.
    local drawn = false

    if created then
        coinStep("quantity before item", function()
            coin.associatedObjectQuantity = COIN_PILE_QUANTITY
        end)

        drawn = coinStep("item", function()
            coin:SetAssociatedObject(COINS_ITEM_ID)
        end)

        if drawn then
            coinStep("quantity after item", function()
                coin.associatedObjectQuantity = COIN_PILE_QUANTITY
            end)
        end
    end

    -- Step 3: hide the quantity number. If this fails we'd show "1,000,000" on the
    -- icon, so treat it as "can't draw the item" and use the fallback sprite.
    if drawn then
        drawn = coinStep("hide quantity", function()
            coin.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER
        end)
    end

    if drawn then
        return coin
    end

    -- Half-made sprite? Hide it so it can't show a stray number or blank box.
    if coin then
        pcall(function()
            coin.hidden = true
        end)
    end

    if not rsprite.Get(iconNames.coins) then
        return nil
    end

    local drawOptions = { x = x, y = y, xAnchor = xAnchor, size = size, placeholder = false }

    return (rsprite.Draw(parent.content, iconNames.coins, drawOptions))
end

-- Slides a coin so it sits just left of a right-aligned number, instead of at a
-- fixed spot with a big gap when the number is short. `rightEdge` is the label's
-- right edge measured from the parent's right side (a negative x with xAnchor 1).
--
-- Text width comes from the client's own font measurement. If that fails for some
-- reason we guess about 8 units per character: worst case the gap is a bit off.
function Style.placeCoin(coin, text, options)
    if not coin then
        return
    end

    local ok, width = pcall(function()
        return config.Font[BODY_FONT]:GetStringWidth(text, false)
    end)

    if not ok or type(width) ~= "number" then
        width = #text * 8
    end

    local size = options.size or 20
    local x = options.rightEdge - width - COIN_GAP - size

    coin:SetPos(x, options.y, 1, 0)
end

-- Full numbers with thousands separators, for the Income breakdown. We round first
-- and only then add commas, so the separators can't change the decimals or the sign.
function Style.number(value, decimals)
    if value == nil then
        return "Unavailable"
    end

    local text = string.format("%." .. (decimals or 0) .. "f", value)
    local sign, whole, fraction = text:match("^(-?)(%d+)(.*)$")
    local grouped = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")

    return sign .. grouped .. fraction
end

-- Short numbers like "1.2m / h" for the Browse list, where space is tight. The
-- title font shows it as "1.2M / H". The full figure is in the Income tab.
function Style.compact(value)
    if value == nil then
        return "Not estimated"
    end

    local magnitude = math.abs(value)

    if magnitude >= 1000000000 then
        return string.format("%.1fb / h", value / 1000000000)
    end

    if magnitude >= 1000000 then
        return string.format("%.1fm / h", value / 1000000)
    end

    if magnitude >= 1000 then
        return string.format("%.1fk / h", value / 1000)
    end

    return Style.number(value, 0) .. " / h"
end

-- Quantities can be fractional (e.g. 0.04 potion doses an hour), unlike GP. Show up
-- to two decimals, but drop trailing zeros so whole amounts don't read "12.00".
function Style.quantity(value)
    if value == nil then
        return "Unavailable"
    end

    if value == math.floor(value) then
        return Style.number(value)
    end

    return Style.number(value, 2):gsub("0+$", ""):gsub("%.$", "")
end

-- Green for met, red for unmet, grey for unknown. The text always says the same
-- thing too, so nobody has to rely on telling colours apart.
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
