-- Shared colours, formatting and icon helpers. Controls belong to their parent
-- view; missing-icon warnings are kept for the session.
-- Copy the catalogue and hand-picked sprite aliases into one lookup without
-- changing either source.
local iconNames = {}

for alias, sprite in pairs(require("src/data/method_data").icons or {}) do
    iconNames[alias] = sprite
end

for alias, sprite in pairs(require("data/icons")) do
    iconNames[alias] = sprite
end

local Style = {
    text = 0xEEE9DAFF,
    muted = 0xB5B1A2FF,
    gold = 0xE3BF70FF,
    good = 0xB7D8A6FF,
    bad = 0xE4A099FF,
    -- Softer money colours for secondary figures, so the headline stands out.
    subtleGood = 0x8FA184FF,
    subtleBad = 0xAA8580FF,
    -- Activity colours for titles and sidebar buttons: PvM red, skilling green,
    -- production blue and recurring (daily/weekly) a subtle orange.
    categories = { pvm = 0xDEA19AFF, skilling = 0xACCEA0FF, production = 0x9EBEDFFF, recurring = 0xDDB487FF },
}

-- The Coins item, and the fonts PrettyUI uses for body text and titles. We
-- measure text so things can sit right next to it (a coin, a dropdown).
local COINS_ITEM_ID = 995
local BODY_FONT = "MUSEO_SANS_15PT_REGULAR"
local TITLE_FONT = "CINZEL_13PT_BOLD"

-- Bigger, bolder client fonts for headline numbers (the profit per hour and ROI).
-- Both are used by other RS3 plugins, but Style.setFont still checks they exist.
Style.HEADLINE_FONT = "MUSEO_SANS_19PT_BOLD"
Style.SUBHEADLINE_FONT = "MUSEO_SANS_17PT_BOLD"

-- Gap between a coin and the number it belongs to, in interface units.
local COIN_GAP = 4

-- The client picks Coins art from the stack size: 1 coin looks like a single
-- coin, a big stack looks like the full pile. Any amount this big gets the pile.
local COIN_PILE_QUANTITY = 1000000

-- PrettyUI exposes its native layer as parent.content. Native rectangles and
-- coins attached there are destroyed with the view.

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

-- Resize registered panels after all content is added. A scrollbar narrows the
-- page, but panel contents keep their original width until SetSize is called.
-- padding is the page inset; gap separates half-width panels. fit() uses the
-- final page width to keep right-aligned labels inside their panels.
function Style.panelFitter(host, padding, gap)
    local panels = {}
    local fitter = {}

    -- `size` says how wide the panel is. Returns the panel.
    --   nil         the full page width
    --   true        half the page, for one of two side-by-side panels
    --   { fixed = n } always n wide, for a small panel at the start of a row
    --   { rest = n }  whatever's left of the row beside an n-wide fixed panel
    function fitter:add(panel, height, size)
        panels[#panels + 1] = { panel = panel, height = height, size = size }

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
            local size = entry.size
            local panelWidth = full

            if size == true then
                panelWidth = half
            elseif type(size) == "table" and size.fixed then
                panelWidth = size.fixed
            elseif type(size) == "table" and size.rest then
                panelWidth = full - size.rest - (gap or 0)
            end

            entry.panel:SetSize(panelWidth, entry.height)
        end
    end

    return fitter
end

-- Looks up one of our icon names in the client's sprite table. A missing name
-- can throw, so the read is protected. Each missing name is warned about once;
-- callers then fall back to text or no icon.
local reportedSprites = {}

local function resolveIcon(alias)
    local name = iconNames[alias]

    if not name then
        return nil
    end

    -- FLOORSHADOWS (1243) is known to crash this client. Keep the exclusion even
    -- though none of our configured icons use it.
    if name == "FLOORSHADOWS" then
        return nil
    end

    local ok, sprite = pcall(function()
        return id.Sprite[name]
    end)

    if ok and type(sprite) == "number" and sprite >= 0 and sprite < math.huge
        and sprite == math.floor(sprite) and sprite ~= 1243 then
        return sprite
    end

    if not reportedSprites[name] then
        reportedSprites[name] = true
        pcall(print, "[Profit Path] UI sprite unavailable: " .. name
            .. (ok and "" or (" - " .. tostring(sprite))))
    end

    return nil
end

-- PrettyUI draws the sprite and owns it. A missing icon is fine: the text
-- beside it still says what it is.
function Style.icon(parent, name, options)
    local sprite = resolveIcon(name)

    if not sprite then
        return nil
    end

    return parent:AddSprite(sprite, options)
end

-- The native sprite ID for one of our named icons, or nil if this client
-- doesn't have it (callers then show text instead).
function Style.spriteId(name)
    return resolveIcon(name)
end

function Style.iconButtonWidth(name)
    return resolveIcon(name) and 28 or 64
end

-- Draw a boxed icon, falling back to text if the sprite is missing.
-- With no place, flow inline. A position table sets y and the right inset; "line"
-- starts a separate row.
function Style.iconButton(parent, name, fallbackText, tooltip, action, place)
    local sprite = resolveIcon(name)
    local width = Style.iconButtonWidth(name)
    local options = { width = width, height = 28, iconSize = 20, tooltip = tooltip }

    if place == "line" then
        options.marginTop = 8
    elseif place then
        options.x = -(place.right + width)
        options.xAnchor = 1
        options.y = place.y

        -- On a screen's header row (not a flowing page), like the favourite star.
        options.absolute = place.absolute
    else
        options.inline = true
    end

    return parent:AddSimpleButton(sprite or fallbackText, action, options)
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

-- Draws a Coins pile with no quantity number, and returns the native sprite so
-- placeCoin can move it beside the total. Each native step is tried on its own;
-- if the item picture fails we hide it and use the plain COINS sprite instead.
-- (This client rejects the two-argument SetAssociatedObject call, so step 2
-- sets the quantity separately.)
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

    local spriteId = resolveIcon("coins")

    if not spriteId then
        return nil
    end

    -- The fallback is a plain client sprite. Like the item picture above, its
    -- parent owns it and it can be moved when the money label changes width.
    local fallback
    local fallbackDrawn = coinStep("fallback sprite", function()
        fallback = ui.Sprite.new(parent.content)
        fallback:SetPos(x, y, xAnchor, 0)
        fallback:SetSize(size, size)
        fallback.clickthrough = true
        fallback.sprite = spriteId
    end)

    if not fallbackDrawn and fallback then
        pcall(function()
            fallback.hidden = true
        end)
    end

    return fallbackDrawn and fallback or nil
end

-- Use the first available named client font. If none exists, leave PrettyUI's
-- default font in place.
function Style.setFont(label, ...)
    for _, name in ipairs({ ... }) do
        local ok, font = pcall(function()
            return id.Font[name]
        end)

        if ok and font ~= nil then
            label.font = font
            return label
        end
    end

    return label
end

-- How wide `text` is on screen, from the client's own font measurement
-- (config.Font:GetStringWidth). `title` = true for title text. If measuring fails
-- we guess about 8 units per character (10 for titles): worst case a gap is off.
function Style.textWidth(text, title)
    -- Nothing to measure is no width (rather than an error mid-draw).
    text = text or ""

    local ok, width = pcall(function()
        return config.Font[title and TITLE_FONT or BODY_FONT]:GetStringWidth(text, false)
    end)

    if not ok or type(width) ~= "number" then
        return #text * (title and 10 or 8)
    end

    return width
end

-- Place the coin just left of a right-aligned total. rightEdge is a negative
-- offset from the parent's right edge (xAnchor 1).
-- Measure with the client font, or estimate eight units per character if
-- measurement fails.
function Style.placeCoin(coin, text, options)
    if not coin then
        return
    end

    local width = Style.textWidth(text)
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
-- `unit` is what the figure is per: "h" (the default) or "run" for recurring methods.
function Style.compact(value, unit)
    local per = " / " .. (unit or "h")

    if value == nil then
        return "Not estimated"
    end

    local magnitude = math.abs(value)

    if magnitude >= 1000000000 then
        return string.format("%.1fb", value / 1000000000) .. per
    end

    if magnitude >= 1000000 then
        return string.format("%.1fm", value / 1000000) .. per
    end

    if magnitude >= 1000 then
        return string.format("%.1fk", value / 1000) .. per
    end

    return Style.number(value, 0) .. per
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
