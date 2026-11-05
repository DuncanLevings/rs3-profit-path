-- The two sharing screens (Phase 9, slice 7):
--   * Export: one custom activity as a line of text in a box, to copy out with Ctrl+C;
--   * Import: a box to paste someone's line into, a review of what it holds, and
--     "Add as new activity".
-- custom_share.lua does the writing and checking; this file only draws.
--
-- Both screens sit under the workbench's header row (its Back arrow is at the top
-- left), in a scrolling nested view, like the editor.
local CustomShare = require("src/methods/custom_share")
local Style = require("src/ui/view_style")

local ShareView = {}

local HEADER_HEIGHT = 44

-- The import box waits for a pause in typing before it checks the text again
-- (a paste arrives in one go, so this mostly just lets typing finish). 10 logic
-- ticks is 0.2 s.
local SETTLE_TICKS = 10
local SETTLE_EVENT = "profit-path-import-settle"

-- How many problems the review lists before saying "and N more".
local MOST_PROBLEMS = 8

-- What the review calls each category (the same words as the editor).
local CATEGORY_LABELS = { pvm = "PvM", skilling = "Skilling", production = "Production", recurring = "Daily / weekly" }

-- A rate like 120 or 0.5, without a trailing ".0".
local function numberText(value)
    if type(value) ~= "number" then
        return "?"
    end

    return string.format("%g", value)
end

-- "60 kills/hour", or "1 run every week" for a daily/weekly one.
local function throughputText(record)
    local rate = record.rate

    if record.category == "recurring" then
        local every = record.recurrence and record.recurrence.every or "day"
        local runs = rate.default == 1 and " run every " or " runs every "

        return numberText(rate.default) .. runs .. every
    end

    return numberText(rate.default) .. " " .. rate.unit
end

-- "1 output" / "3 outputs". `plural` when it isn't just word .. "s".
local function count(number, word, plural)
    return number .. " " .. (number == 1 and word or plural or word .. "s")
end

-- Draws the screen's title on the header row, clear of the Back arrow.
local function title(view, text)
    view:AddTitle({
        text = text, absolute = true,
        x = 44, y = 10, width = -88, widthAnchor = 1, height = 28,
    })
end

-- Returns a scrolling body under the header, plus an unmount() that destroys it
-- (nested views go before the screen's own view; see method_editor.lua).
local function body(library, view)
    local page = library.SimpleView.new(view.content, {
        x = 0, y = HEADER_HEIGHT, width = 0, height = -HEADER_HEIGHT, widthAnchor = 1, heightAnchor = 1,
        scrollable = true, layout = { startY = 8, padding = 20, rowGap = 10 },
    })

    return page, function()
        page:Destroy()
    end
end

-- ---- Export ---------------------------------------------------------------------

-- `record` is a saved custom activity. Returns unmount().
function ShareView.export(library, view, record, guarded)
    title(view, "Share " .. record.title)

    local page, unmount = body(library, view)
    local line, problem, length = CustomShare.encode(record)

    -- Too big for the text box: say so, and what to cut.
    if not line then
        page:AddText({ text = problem, colour = Style.bad })
        return unmount
    end

    page:AddText("Click the box, press Ctrl+A to select all of it, then Ctrl+C to copy it. "
        .. "Anyone with Profit Path can paste it into Import activity.")

    -- The box is only there to copy from. Typing in it would spoil the line, so
    -- any change puts the line straight back.
    local field

    field = page:AddTextField({
        text = line,
        onChange = guarded(function(_, _, text)
            if text ~= line then
                field:SetText(line, false)
            end
        end),
    })

    page:AddText({ text = length .. " characters.", colour = Style.muted })
    page:AddText({ text = "Only the activity is shared: its name, rows, requirements and notes. "
        .. "Your own GE prices, saved rates, favourites and account are not.", colour = Style.muted })

    return unmount
end

-- ---- Import ---------------------------------------------------------------------

-- What the import screen remembers across its own redraws: the pasted text, and a
-- message from a failed add.
function ShareView.importState()
    return { text = "" }
end

-- `actions`:
--   rebuild()      draw this screen again from `state`
--   add(record)    save it as a new activity; returns the saved record, or nil plus
--                  a message (or a list of problems)
--   done(saved)    leave, opening the new activity
-- Returns unmount().
function ShareView.import(library, view, state, guarded, actions)
    title(view, "Import a custom activity")

    local page, destroyPage = body(library, view)
    local waiting = false

    local function stopWaiting()
        if waiting then
            waiting = false
            Event.Logic.Unsubscribe(SETTLE_EVENT)
        end
    end

    local function unmount()
        stopWaiting()
        destroyPage()
    end

    -- Check the text again: a redraw, which draws the review for `state.text`.
    local function review()
        stopWaiting()
        state.message = nil
        actions.rebuild()
    end

    page:AddText("Paste a custom activity someone shared with you (click the box, then press Ctrl+V). "
        .. "It's checked before anything is added.")

    page:AddTextField({
        text = state.text,
        placeholder = "Paste the shared text here",

        -- Each change restarts the pause; the review redraws once it's quiet.
        onChange = guarded(function(_, _, text)
            state.text = text or ""

            local quiet = 0

            stopWaiting()
            waiting = true

            Event.Logic.Subscribe(SETTLE_EVENT, guarded(function()
                quiet = quiet + 1

                if quiet >= SETTLE_TICKS then
                    review()
                end
            end))
        end),

        onSubmit = guarded(function(_, text)
            state.text = text or ""
            review()
        end),
    })

    -- Nothing pasted yet: nothing to review.
    if not state.text:find("%S") then
        return unmount
    end

    local result = CustomShare.review(state.text)

    -- Refused: say why. Nothing has been saved.
    if #result.problems > 0 then
        page:AddText({ text = "This can't be imported:", colour = Style.bad, marginTop = 8 })

        for index = 1, math.min(#result.problems, MOST_PROBLEMS) do
            page:AddText({ text = tostring(result.problems[index]), colour = Style.bad })
        end

        if #result.problems > MOST_PROBLEMS then
            page:AddText({ text = "...and " .. (#result.problems - MOST_PROBLEMS) .. " more.", colour = Style.bad })
        end

        return unmount
    end

    -- It's fine: show what it holds, so the player knows what they're adding.
    local record = result.record
    local required, recommended = #record.requirements.required, #record.requirements.recommended

    page:AddTitle({ text = record.title, marginTop = 8 })
    page:AddText(CATEGORY_LABELS[record.category] .. ", " .. throughputText(record) .. ".")
    page:AddText(count(#record.outputs, "output") .. ", " .. count(#record.supplies, "supply", "supplies")
        .. ". " .. count(required, "required check") .. ", " .. count(recommended, "recommended check") .. ".")

    if record.source then
        page:AddText({ text = "Drops loaded from " .. record.source.title .. ".", colour = Style.muted })
    end

    for _, warning in ipairs(result.warnings) do
        page:AddText({ text = warning, colour = Style.muted })
    end

    page:AddText({ text = "It's added as a new custom activity of your own. Prices come from the GE as usual.",
        colour = Style.muted })

    if state.message then
        page:AddText({ text = state.message, colour = Style.bad })
    end

    page:AddSimpleButton("Add as new activity", guarded(function()
        local saved, problem = actions.add(record)

        if saved then
            actions.done(saved)
            return
        end

        -- A list of problems (from the store's own checks) or one message.
        state.message = type(problem) == "table" and tostring(problem[1]) or tostring(problem or "Couldn't add it. Try again.")
        actions.rebuild()
    end), { width = 200, height = 32 })

    return unmount
end

return ShareView
