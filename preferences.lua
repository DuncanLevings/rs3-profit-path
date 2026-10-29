-- Saves the player's own rate overrides (e.g. "I do 1,500 smelts/hour, not 2,000").
--
-- Why manual profiles? PersistentDB is shared by every character on this computer,
-- and we deliberately don't read character identity. So the player picks a profile
-- name per character, and each profile gets its own saved rates.
--
-- Each rate lives under its own key rather than in one big record, so a failed save
-- or a reset can only ever touch that one rate. Treat the key formats below as a
-- contract: changing them would silently lose everyone's saved rates.
local Preferences = {}

local PROFILE_KEY = "profit-path.profile.v1"

-- Profile names end up inside storage keys, so we only allow a small, readable set
-- of characters: 1-40 letters, digits, spaces, _ or -, and not all spaces.
local function validProfile(name)
    return type(name) == "string" and #name <= 40
        and name:match("^[%w _-]+$") ~= nil and name:find("%S") ~= nil
end

-- Anything read back from storage is untrusted: it could be from an older version,
-- hand-edited or corrupted. Check the shape and that the units still match this
-- method's (a rate saved as kills/hour means nothing if the method now uses trips).
-- `value == value` is the standard Lua trick for rejecting NaN.
local function validStoredRate(stored, unit)
    if type(stored) ~= "table" or stored.schema ~= 1 or stored.unit ~= unit then
        return false
    end

    local value = stored.value

    return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

-- `db` is the client's PersistentDB. It's passed in rather than used as a global so
-- tests can hand in a fake one.
function Preferences.new(db)
    local self = { profile = "Default", warning = nil }

    -- Restore the last selected profile. If it can't be read, or it's junk, fall back
    -- to Default and keep a warning so the UI can tell the player what happened.
    local ok, savedProfile, exists = pcall(function()
        return db:GetString(PROFILE_KEY), db:CheckExists(PROFILE_KEY)
    end)

    if not ok then
        self.warning = "Profile could not be loaded: " .. tostring(savedProfile)
    elseif savedProfile ~= nil or exists then
        if validProfile(savedProfile) then
            self.profile = savedProfile
        else
            self.warning = "Saved profile name is invalid; using Default."
        end
    end

    -- Builds the storage key for one method's rate under the current profile, e.g.
    -- "profit-path.rate.v1/7:Default/smelting-steel-bars.basic/smelts_per_hour".
    -- The "7:" is the profile name's length. That keeps each key unambiguous
    -- (where the profile ends and the method starts) even if the allowed profile
    -- characters change later.
    local function rateKey(method)
        return "profit-path.rate.v1/" .. #self.profile .. ":" .. self.profile
            .. "/" .. method.id .. "/" .. method.income.rate.key
    end

    -- Returns rate, isSaved, message. With nothing saved we quietly use the source
    -- default. With something saved but broken we also use the default, but return
    -- a message so the player knows their old value was ignored.
    function self:loadRate(method)
        local definition = method.income.rate

        local success, stored, exists = pcall(function()
            local key = rateKey(method)
            return db:GetStructuredData(key), db:CheckExists(key)
        end)

        if not success then
            return definition.default, false, "Saved rate could not be loaded: " .. tostring(stored)
        end

        if stored == nil and not exists then
            return definition.default, false
        end

        if not validStoredRate(stored, definition.unit) then
            return definition.default, false, "Saved rate is invalid or its units changed; using the source default."
        end

        return stored.value, true
    end

    -- Switches profile and remembers the choice for next time. If the save fails we
    -- stay on the old profile, so the screen never claims something that isn't true.
    function self:selectProfile(name)
        if not validProfile(name) then
            return false, "Use 1-40 letters, numbers, spaces, underscores or hyphens for the profile."
        end

        local success, written = pcall(function()
            return db:SetString(PROFILE_KEY, name)
        end)

        if not success or written ~= true then
            return false, "Profile could not be saved: " .. tostring(written)
        end

        self.profile = name
        self.warning = nil

        return true
    end

    function self:saveRate(method, rate)
        -- The calculator already validated this. If it's bad here, that's a bug in
        -- our code, so fail loudly instead of writing garbage to storage.
        assert(type(rate) == "number" and rate >= 0 and rate < math.huge, "Invalid internal rate")

        local success, written = pcall(function()
            return db:SetStructuredData(rateKey(method), {
                schema = 1, unit = method.income.rate.unit, value = rate,
            })
        end)

        if not success or written ~= true then
            return false, "Rate could not be saved: " .. tostring(written)
        end

        return true
    end

    -- Deletes just this method's saved rate. Every other rate and profile is untouched.
    function self:resetRate(method)
        local success, deleted = pcall(function()
            local key = rateKey(method)

            -- Nothing was saved, so there's nothing to delete. That still counts as done.
            if not db:CheckExists(key) then
                return true
            end

            return db:Delete(key)
        end)

        if not success or deleted ~= true then
            return false, "Saved rate could not be reset: " .. tostring(deleted)
        end

        return true
    end

    return self
end

return Preferences
