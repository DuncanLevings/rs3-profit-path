-- Reads which tools are on the tool belt (hatchets, pickaxes...) using the
-- client's own item enums. account.lua owns the caching and subscriptions;
-- this just returns plain counts.
local Toolbelt = {}

-- Game variables can come back nil or junk. 0 is a real enum key for some
-- tools, so it doesn't mean "no tool".
local function integer(value)
    return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end

-- Watch both the varbit and its base: the client can transmit a changed base
-- bitset rather than a separate notification for the particular tool's varbit.
local function watch(setting, watched)
    watched[setting.id] = true

    if setting.isVarBit then
        watched[setting.baseVar.id] = true
    end
end

-- Called once Account knows we're logged in. `definitions` is bundled data:
-- which variables and enums to read, and their key offsets.
function Toolbelt.read(definitions)
    local result = { counts = {}, slots = {}, watched = {}, complete = true }

    for family, definition in pairs(definitions) do
        local ok, slot = pcall(function()
            if definition.presence_variable then
                local presence = var.VarPlayer[definition.presence_variable]

                if not presence then
                    return { status = "unknown", message = "Tool-belt presence is unavailable." }
                end

                watch(presence, result.watched)
                local present = presence.value

                if present == 0 then
                    return { status = "available" }
                end

                if present ~= 1 then
                    return { status = "unknown", message = "Tool-belt presence has an unrecognised value." }
                end
            end

            local setting = var.VarPlayer[definition.value_variable]

            if not setting then
                return { status = "unknown", message = "Tool-belt selection is unavailable." }
            end

            watch(setting, result.watched)
            local value = setting.value

            if not integer(value) then
                return { status = "unknown", message = "Tool-belt selection is not a valid integer." }
            end

            -- Hatchets/pickaxes use zero-based keys. Mattocks store one more than
            -- their enum key; this offset is reference data verified in the client.
            local key = value + definition.value_offset

            if key < 0 then
                return { status = "unknown", message = "No mapped tool-belt selection is available." }
            end

            local mapping = config.Enum[definition.items_enum]

            -- ValueType IDs: INTEGER=0, OBJ=33. If the enum isn't the one we
            -- expect, skip it rather than count some unrelated item.
            if not mapping or mapping.configName ~= definition.items_enum
                or mapping.inputValueType ~= 0 or mapping.outputValueType ~= 33 then
                return { status = "unknown", message = "Tool-belt item mapping is unavailable or has changed." }
            end

            local object = mapping:GetOutputValue(math.tointeger(key))

            if not object or not integer(object.id) or object.id <= 0
                or type(object.name) ~= "string" or object.name == "" then
                return { status = "unknown", message = "Tool-belt value has no known item mapping." }
            end

            return { status = "available", itemId = object.id, name = object.name }
        end)

        if not ok then
            slot = { status = "error", message = "Tool-belt read failed: " .. tostring(slot) }
        end

        result.slots[family] = slot
        result.complete = result.complete and slot.status == "available"

        if slot.status ~= "available" and not result.message then
            result.message = family .. ": " .. slot.message
        end

        if slot.itemId then
            -- A belt tool counts as one, even if two entries map to the same item.
            result.counts[slot.itemId] = 1
        end
    end

    return result
end

return Toolbelt
