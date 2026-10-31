-- Everything Profit Path saves: personal rates, favourites, methods hidden from
-- recommendations, Recommend for me's settings and history, which character uses
-- which profile, and the browser's sort choice.
--
-- How profiles work: PersistentDB is shared by every character on this computer,
-- so saved rates and favourites live under a "profile". When a window opens we
-- read the character's visible name and look up (or create) its profile. We never
-- use the tracking ID, which needs a permission we don't ask for.
--
-- Each rate lives under its own key rather than in one big record, so a failed save
-- or a reset can only ever touch that one rate. Treat the key formats below as a
-- contract: changing them would silently lose everyone's saved settings.
local Preferences = {}

-- Storage keys. Profile-specific keys add "/<length>:<profile>" on the end.
local PROFILE_KEY = "profit-path.profile.v1"
local BROWSER_KEY = "profit-path.browser.v1"
local CHARACTERS_KEY = "profit-path.characters.v1"
local FAVOURITES_KEY = "profit-path.favourites.v1"
local HIDDEN_KEY = "profit-path.hidden.v1"
local RECOMMEND_KEY = "profit-path.recommend.v1"

-- Difficulty and intensity used to be sorts too; they're filters now, so an old
-- saved "difficulty"/"intensity" sort just falls back to the profit default.
local sortKeys = { profit = true, roi = true }

-- Recommend for me's settings, and what a fresh profile starts with. Comfort is
-- the hardest PvM level (1-10) the player is happy with (nil until they're
-- asked); learning shows the next level up as labelled learning opportunities;
-- group is "solo-preferred" (groups allowed, after solo), "solo-only" or "either".
local function validComfort(level)
    -- Stored numbers can come back as floats (4.0), so check the value, not the type.
    return type(level) == "number" and level == math.floor(level) and level >= 1 and level <= 10
end

-- Builds before the 1-10 ladder saved one of four bands. Each becomes the top
-- of its band, so "GWD2-level bosses" still means what the player picked.
local oldComfort = { Easy = 2, Medium = 4, Hard = 7, Elite = 10 }
local groupChoices = { ["solo-preferred"] = true, ["solo-only"] = true, either = true }
local activities = { pvm = true, skilling = true, production = true, recurring = true }

local function recommendDefaults()
    return { comfort = nil, learning = true, group = "solo-preferred", history = {} }
end

-- The same rule as favourites use for a stored method ID.
local function validId(id)
    return type(id) == "string" and id:match("^[a-z0-9][a-z0-9._-]*$") ~= nil
end

-- Older builds let players type a profile name, stored at PROFILE_KEY. We only
-- read it now, so the first character keeps those settings. It was limited to
-- 1-40 letters, digits, spaces, _ or -, and not all spaces.
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

    -- Restore the profile an older build last had selected. If it can't be read, or
    -- it's junk, fall back to Default and keep a warning for the UI. bindCharacter()
    -- picks the real profile once the window opens.
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

    -- A per-profile key, e.g. "profit-path.favourites.v1/7:Default".
    local function profileKey(base)
        return base .. "/" .. #self.profile .. ":" .. self.profile
    end

    -- Favourites and hidden methods are both just a set of method IDs, saved as
    -- { schema = 1, ids = { [id] = true } }. These two helpers load and save one.
    -- `what` names the list in messages ("Favourites", "Hidden activities").
    --
    -- Loading keeps valid IDs even if they aren't in this bundle, so an update
    -- won't erase choices. It returns ids, warning, writable. `writable` is false
    -- when what's stored couldn't be read or understood; saving then refuses to
    -- write, so a glitch can never replace a real list with an empty one.
    local function loadIds(base, what)
        local key = profileKey(base)

        local success, stored, exists = pcall(function()
            return db:GetStructuredData(key), db:CheckExists(key)
        end)

        if not success then
            return {}, what .. " could not be loaded: " .. tostring(stored), false
        end

        if stored == nil and not exists then
            return {}, nil, true
        end

        if type(stored) ~= "table" or stored.schema ~= 1 or type(stored.ids) ~= "table" then
            return {}, "Saved " .. what:lower() .. " have an unsupported format; no changes were made.", false
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
            return ids, "Some saved " .. what:lower() .. " were invalid; valid choices were kept.", true
        end

        return ids, nil, true
    end

    -- Re-reads before writing so a failed load can't accidentally replace the
    -- player's saved list with an empty one. This touches no rates or sort keys.
    local function saveId(base, what, id, selected)
        local ids, warning, writable = loadIds(base, what)

        if not writable then
            return false, warning
        end

        ids[id] = selected or nil

        local success, written = pcall(function()
            return db:SetStructuredData(profileKey(base), { schema = 1, ids = ids })
        end)

        if not success or written ~= true then
            return false, what .. " could not be saved: " .. tostring(written)
        end

        return true
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

    -- Switches to the profile for character `name`, creating one if it's new. No
    -- saved rate is ever rewritten here: we only decide which profile to read from.
    --
    -- The stored record is { schema, owner, bindings = { [name] = profile } }:
    --   * the first character ever bound becomes the "owner" and keeps the old
    --     profile (usually "Default"), so settings from older builds aren't lost;
    --   * every later character gets a profile named after itself.
    -- It's all one record, so a failed write can't leave half a migration behind.
    function self:bindCharacter(name)
        if not validCharacterText(name) then
            return false, "Character name is unavailable or contains invalid text. Try opening again."
        end

        local ok, stored, exists = pcall(function()
            return db:GetStructuredData(CHARACTERS_KEY), db:CheckExists(CHARACTERS_KEY)
        end)

        if not ok then
            return false, "Character settings could not be read: " .. tostring(stored)
        end

        -- Load and check the existing bindings. If anything looks off we stop and
        -- write nothing, rather than risk overwriting the player's real setup.
        local bindings = {}
        local owner

        if stored ~= nil or exists then
            local validRecord = type(stored) == "table" and stored.schema == 1
                and type(stored.bindings) == "table" and validCharacterText(stored.owner)

            if not validRecord then
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

        -- New character: work out its profile and save the binding.
        if not profile then
            profile = owner and name or self.profile

            -- Another character might already use a profile with this name (say, an
            -- old typed profile). Prefix "_" until it's unique, so two characters
            -- never share rates or favourites by accident.
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
                return db:SetStructuredData(CHARACTERS_KEY, { schema = 1, owner = owner, bindings = bindings })
            end)

            if not success or written ~= true then
                return false, "Character settings could not be saved: " .. tostring(written)
            end
        end

        self.profile = profile
        self.characterName = name

        return true
    end

    -- Saves one method's personal rate under the current profile. Returns true, or
    -- false plus a message for the UI if storage refused the write.
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

    -- Recommend for me's record for this profile: settings plus, per activity,
    -- the rotation history { shown = { id, ... }, last = id }. "shown" is every
    -- method suggested in the current cycle, so unseen ones come first; "last" is
    -- the latest suggestion, so a new request doesn't repeat it straight away.
    --
    -- Returns record, warning, writable, like loadIds: valid fields survive a
    -- partly broken record, and an unreadable one is never written over.
    function self:loadRecommend()
        local key = profileKey(RECOMMEND_KEY)
        local record = recommendDefaults()

        local success, stored, exists = pcall(function()
            return db:GetStructuredData(key), db:CheckExists(key)
        end)

        if not success then
            return record, "Recommendation settings could not be loaded: " .. tostring(stored), false
        end

        if stored == nil and not exists then
            return record, nil, true
        end

        if type(stored) ~= "table" or stored.schema ~= 1 then
            return record, "Saved recommendation settings have an unsupported format; no changes were made.", false
        end

        -- Take each field on its own; anything odd falls back to its default.
        local invalid = false

        if stored.comfort ~= nil then
            if validComfort(stored.comfort) then
                record.comfort = math.floor(stored.comfort)
            elseif oldComfort[stored.comfort] then
                record.comfort = oldComfort[stored.comfort]
            else
                invalid = true
            end
        end

        if type(stored.learning) == "boolean" then
            record.learning = stored.learning
        elseif stored.learning ~= nil then
            invalid = true
        end

        if groupChoices[stored.group] then
            record.group = stored.group
        elseif stored.group ~= nil then
            invalid = true
        end

        if type(stored.history) == "table" then
            for activity, entry in pairs(stored.history) do
                if activities[activity] and type(entry) == "table" and type(entry.shown) == "table" then
                    local shown = {}

                    for _, id in ipairs(entry.shown) do
                        if validId(id) then
                            shown[#shown + 1] = id
                        else
                            invalid = true
                        end
                    end

                    record.history[activity] = { shown = shown, last = validId(entry.last) and entry.last or nil }
                else
                    invalid = true
                end
            end
        elseif stored.history ~= nil then
            invalid = true
        end

        if invalid then
            return record, "Some saved recommendation settings were invalid; valid choices were kept.", true
        end

        return record, nil, true
    end

    -- Saves the whole record (the caller passes the full, updated record). Like
    -- saveId, it re-reads first and refuses to write over a record it couldn't read.
    function self:saveRecommend(record)
        assert(record.comfort == nil or validComfort(record.comfort), "Invalid internal comfort")
        assert(type(record.learning) == "boolean" and groupChoices[record.group], "Invalid internal setting")

        local _, warning, writable = self:loadRecommend()

        if not writable then
            return false, warning
        end

        -- Copy just what's stored, so nothing else on the record leaks in.
        local history = {}

        for activity, entry in pairs(record.history or {}) do
            assert(activities[activity], "Invalid internal activity")

            local shown = {}

            for index, id in ipairs(entry.shown or {}) do
                shown[index] = id
            end

            history[activity] = { shown = shown, last = entry.last }
        end

        local success, written = pcall(function()
            return db:SetStructuredData(profileKey(RECOMMEND_KEY), {
                schema = 1, comfort = record.comfort, learning = record.learning,
                group = record.group, history = history,
            })
        end)

        if not success or written ~= true then
            return false, "Recommendation settings could not be saved: " .. tostring(written)
        end

        return true
    end

    -- The current profile's favourite IDs, read without a catalogue scan.
    -- Returns ids, warning, writable (see loadIds).
    function self:loadFavourites()
        return loadIds(FAVOURITES_KEY, "Favourites")
    end

    -- Adds (selected = true) or removes one favourite.
    function self:saveFavourite(id, selected)
        return saveId(FAVOURITES_KEY, "Favourites", id, selected)
    end

    -- Methods this profile has hidden from recommendations. Hiding is for that
    -- one method ID only: another version of the same method stays shown.
    function self:loadHidden()
        return loadIds(HIDDEN_KEY, "Hidden activities")
    end

    -- Hides (hidden = true) or restores one method.
    function self:saveHidden(id, hidden)
        return saveId(HIDDEN_KEY, "Hidden activities", id, hidden)
    end

    return self
end

return Preferences
