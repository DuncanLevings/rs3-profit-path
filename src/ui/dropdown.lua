-- Owns native dropdowns and their delayed selection callbacks.
-- This client expects entry IDs in zero-based list order. Read selection one
-- Logic tick after a change using GetEntrySelected(id): the change hook can still
-- see the old value, and selectedEntries is unreliable here.
local Dropdown = {}

-- Build a dropdown and return it with release(), which cancels pending callbacks
-- when the screen closes.
-- options gives its position/width, entries ({ id, label }), selected ID, unique
-- callback owner, guarded wrapper and onChange(id). compact changes the header
-- style; isClosed() optionally checks its owner's lifetime.
function Dropdown.new(parent, options)
    local entries = options.entries

    for index, entry in ipairs(entries) do
        assert(entry.id == index - 1, "Dropdown entry IDs must count from 0 in list order")
    end

    local control = ui.List.new(parent)
    control.stylesheetID = id.StyleSheet.DROPDOWN_DEFAULT
    control:SetPos(options.x, options.y, options.xAnchor or 0, 0)
    control:SetSize(options.width, options.compact and 24 or 30)

    -- A method version is secondary to its title. Soften only the native frame
    -- and arrow; keep the control active and its selected text fully readable.
    if options.compact then
        control.headerSprite.alpha = 0.45
        control.buttonSprite.alpha = 0.65
        control.dropdownButtonSize = 14
        control.entryHeight = 24
        control.entryText.rgba = 0xB5B1A2FF
    end

    control.dropdownMaxVisibleEntries = #entries

    for _, entry in ipairs(entries) do
        assert(control:Add(entry.label, entry.id), "Could not add dropdown option")
    end

    control:SetEntrySelected(options.selected, true)

    local owner = options.owner
    local guarded = options.guarded

    local function closed()
        return options.isClosed ~= nil and options.isClosed()
    end

    control:Subscribe(ui.Hook.ONSELECTIONCHANGED, guarded(function()
        if closed() then
            return
        end

        -- Repeated clicks replace the same pending callback. This is not a
        -- poller: it runs once, on the next logic tick, then unsubscribes.
        Event.Logic.Unsubscribe(owner)
        Event.Logic.Subscribe(owner, function()
            Event.Logic.Unsubscribe(owner)

            guarded(function()
                if closed() then
                    return
                end

                for _, entry in ipairs(entries) do
                    if control:GetEntrySelected(entry.id) then
                        options.onChange(entry.id)
                        break
                    end
                end
            end)()
        end)
    end))

    local function release()
        Event.Logic.Unsubscribe(owner)
    end

    return control, release
end

return Dropdown
