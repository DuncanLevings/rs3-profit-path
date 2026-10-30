-- Native dropdown lists (ui.List), with the workarounds this client needs. Used by
-- the Browse sort/filter row and the method page's version picker.
--
-- Two things worth knowing, both found in game:
--
--   1. Entry IDs must count from 0 in list order (0, 1, 2...). Selecting ID 1
--      highlighted the SECOND entry, so the client seems to count from 0 whatever
--      ID we pass to Add. Numbering from 0 makes both readings agree.
--
--   2. Reading the selection inside the change hook can still see the OLD
--      selection, and the documented `selectedEntries` hands back numbers that
--      aren't always our IDs. So we wait one logic tick, then ask the list about
--      each of our own IDs with GetEntrySelected(id).
local Dropdown = {}

-- Builds a dropdown on the native component `parent` and returns it, plus a
-- release() function that cancels any pending change callback (call it when the
-- screen goes away).
--
-- options:
--   x, y, xAnchor      position (xAnchor 0.5 measures x from the parent's centre)
--   width              in interface units
--   compact            smaller, quieter header for a secondary selector
--   entries            { { id = 0, label = "..." }, { id = 1, ... }, ... }
--   selected           the ID to show selected at first
--   owner              a unique name for this dropdown's logic-tick callback
--   guarded            the screen's callback wrapper (drops stale callbacks)
--   onChange(id)       called once per change, with the newly selected ID
--   isClosed()         optional: true once the screen is gone
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
