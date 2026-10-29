-- Saves personal rates, favourites, character bindings and browser ordering.
-- PersistentDB is shared across characters on a device. Visible character names
-- choose separate profiles, retaining the legacy selected profile on first bind.
-- Tracking IDs are never used, and existing rate keys remain unchanged.
--
-- Each rate lives under its own key rather than in one big record, so a failed save
-- or a reset can only ever touch that one rate. Treat the key formats below as a
-- contract: changing them would silently lose everyone's saved rates.
local Preferences = {}

local PROFILE_KEY = "profit-path.profile.v1"
local BROWSER_KEY = "profit-path.browser.v1"
local sortKeys = { profit = true, roi = true, difficulty = true, intensity = true }

-- Profile names end up inside storage keys, so we only allow a small, readable set
-- of characters: 1-40 letters, digits, spaces, _ or -, and not all spaces.
local function validProfile(name)
    return type(name) == "string" and #name <= 40
        and name:match("^[%w _-]+$") ~= nil and name:find("%S") ~= nil
end

-- Character display names aren't manually chosen profile labels. Keep their
-- native text (including non-breaking spaces) rather than applying the old ASCII
-- whitelist. We don't decode it: the client doesn't expose Lua's utf8 library.
-- Profiles are flat database keys with byte-length prefixes, not paths.
local function validCharacterText(value)
    return type(value) == "string" and value:find("%S") ~= nil
        and not value:find("%c")
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

    -- Bind a character to a storage profile without rewriting any saved rates.
    -- The first character keeps the previously selected profile; later characters
    -- get their own. One record keeps this migration from being half-written.
    function self:bindCharacter(name)
        if not validCharacterText(name) then
            return false, "Character name is unavailable or contains invalid text. Try opening again."
        end

        local key = "profit-path.characters.v1"
        local ok, stored, exists = pcall(function()
            return db:GetStructuredData(key), db:CheckExists(key)
        end)

        if not ok then
            return false, "Character settings could not be read: " .. tostring(stored)
        end

        local bindings = {}
        local owner

        if stored ~= nil or exists then
            if type(stored) ~= "table" or stored.schema ~= 1 or type(stored.bindings) ~= "table" or not validCharacterText(stored.owner) then
                return false, "Saved character bindings are invalid; existing settings were left untouched."
            end

            owner = stored.owner

            for character, profile in pairs(stored.bindings) do
                if not validCharacterText(character) or not validCharacterText(profile) then
                    return false, "Saved character bindings are invalid; existing settings were left untouched."
                end

                bindings[character] = profile
            end
        end

        -- Lua's byte-wise lower() can damage UTF-8 under the Windows locale.
        -- Fold ASCII capitals only and leave every multibyte sequence untouched.
        local normalized = name:gsub("[A-Z]", function(letter)
            return string.char(letter:byte() + 32)
        end)
        local profile = bindings[normalized]

        if not profile then
            profile = owner and name or self.profile

            -- An older manually named profile might already have this name. Don't
            -- bind a second character to it and mix their rates/favourites.
            local used = {}

            for _, existing in pairs(bindings) do
                used[existing] = true
            end

            while used[profile] do
                profile = "_" .. profile
            end

            bindings[normalized] = profile
            owner = owner or normalized

            local success, written = pcall(function()
                return db:SetStructuredData(key, { schema = 1, owner = owner, bindings = bindings })
            end)

            if not success or written ~= true then
                return false, "Character settings could not be saved: " .. tostring(written)
            end
        end

        self.profile = profile
        self.characterName = name

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

    -- Sorting is a device preference; favourites and rates are per profile.
    -- Keep these separate from rate keys so existing saves need no migration.
    function self:loadBrowser()
        local defaults = { sort = "profit", descending = true }
        local success, stored, exists = pcall(function()
            return db:GetStructuredData(BROWSER_KEY), db:CheckExists(BROWSER_KEY)
        end)

        if not success then
            return defaults, "Browser settings could not be loaded: " .. tostring(stored)
        end

        if stored == nil and not exists then
            return defaults
        end

        if type(stored) ~= "table" or stored.schema ~= 1 then
            return defaults, "Saved browser settings are invalid; using Profit, highest first."
        end

        -- Recover either valid field independently instead of resetting both.
        local validSort = type(stored.sort) == "string" and sortKeys[stored.sort]
        local validDirection = type(stored.descending) == "boolean"
        local settings = {
            sort = validSort and stored.sort or defaults.sort,
            descending = defaults.descending,
        }

        if validDirection then
            settings.descending = stored.descending
        end

        if not validSort or not validDirection then
            return settings, "Some browser settings were invalid; valid choices were kept."
        end

        return settings
    end

    -- Called only after the player changes a sort control.
    function self:saveBrowser(settings)
        assert(sortKeys[settings.sort] and type(settings.descending) == "boolean", "Invalid internal sort")

        local success, written = pcall(function()
            return db:SetStructuredData(BROWSER_KEY, {
                schema = 1, sort = settings.sort, descending = settings.descending,
            })
        end)

        if not success or written ~= true then
            return false, "Browser settings could not be saved: " .. tostring(written)
        end

        return true
    end

    -- Read a profile's favourite IDs without needing a catalogue scan. Keep valid
    -- IDs even if they aren't in this bundle, so an update won't erase choices.
    function self:loadFavourites()
        local key = "profit-path.favourites.v1/" .. #self.profile .. ":" .. self.profile
        local success, stored, exists = pcall(function()
            return db:GetStructuredData(key), db:CheckExists(key)
        end)

        if not success then
            return {}, "Favourites could not be loaded: " .. tostring(stored), false
        end

        if stored == nil and not exists then
            return {}, nil, true
        end

        if type(stored) ~= "table" or stored.schema ~= 1 or type(stored.ids) ~= "table" then
            return {}, "Saved favourites have an unsupported format; no changes were made.", false
        end

        local ids = {}
        local invalid = false

        for id, selected in pairs(stored.ids) do
            if type(id) == "string" and id:match("^[a-z0-9][a-z0-9._-]*$") and selected == true then
                ids[id] = true
            else
                invalid = true
            end
        end

        if invalid then
            return ids, "Some saved favourites were invalid; valid choices were kept.", true
        end

        return ids, nil, true
    end

    -- Re-read before writing so a failed load can't accidentally replace the
    -- player's saved list with an empty one. This touches no rates or sort keys.
    function self:saveFavourite(id, selected)
        local ids, warning, writable = self:loadFavourites()

        if not writable then
            return false, warning
        end

        ids[id] = selected or nil

        local key = "profit-path.favourites.v1/" .. #self.profile .. ":" .. self.profile
        local success, written = pcall(function()
            return db:SetStructuredData(key, { schema = 1, ids = ids })
        end)

        if not success or written ~= true then
            return false, "Favourite could not be saved: " .. tostring(written)
        end

        return true
    end

    return self
end

return Preferences
