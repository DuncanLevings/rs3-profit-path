-- Protected reads and writes of PersistentDB records, shared by everything that
-- saves (preferences, custom activities, the account snapshot). Any client call
-- can throw, and a write can also just return false, so every save needs the
-- same two checks.
local Database = {}

-- Reads one structured record. Returns true, value, exists; or false plus the
-- error text. `exists` tells "nothing saved" apart from a saved value we got
-- back as nil.
function Database.read(db, key)
    local ok, value, exists = pcall(function()
        return db:GetStructuredData(key), db:CheckExists(key)
    end)

    if not ok then
        return false, tostring(value)
    end

    return true, value, exists
end

-- Writes one structured record. Returns true, or false plus why it failed.
function Database.write(db, key, value)
    local ok, written = pcall(function()
        return db:SetStructuredData(key, value)
    end)

    if not ok then
        return false, tostring(written)
    end

    if written ~= true then
        return false, "the client didn't accept the write"
    end

    return true
end

return Database
