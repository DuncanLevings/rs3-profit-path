-- The browser's state and ordering, with no native UI objects in here. It owns
-- the current filters, the return-to-list position and estimates for this window.
-- Opening/reopening captures prices; filtering never fetches prices.
local Recommendations = require("src/methods/recommendations")
local Browser = {}

-- Filter levels for the Intensity and Difficulty dropdowns. The source says both
-- "Moderate" and "Medium" for the same middle intensity, so they share a level.
-- Labels we don't recognise get no level: they only show under "Any".
Browser.intensityLevels = { "Low", "Moderate", "High" }
Browser.difficultyLevels = { "Easy", "Medium", "Hard", "Elite" }

local intensityLevel = { Low = "Low", Moderate = "Moderate", Medium = "Moderate", High = "High" }

-- Sorting is only by money now (profit or ROI). A method without a usable estimate
-- has no value, and those always go last.
local function sortValue(method, estimates, key)
    local estimate = estimates[method.id]

    if estimate and estimate.status == "available" then
        return estimate[key]
    end
end

-- Whether a method counts per run (a recurring daily/weekly) rather than per hour.
local function perRun(method)
    return method.income ~= nil and method.income.period == "run"
end

-- "any" lets everything through. Otherwise the method's label has to match; a
-- method with no difficulty rating never matches a specific difficulty.
local function matchesLevel(chosen, value)
    return chosen == "any" or chosen == value
end

-- Keep this window's browsing state in memory. Only explicit sort and favourite
-- changes go to storage; search and scrolling don't produce database writes.
function Browser.new(methods, preferences, estimateMethod)
    local settings, warning = preferences:loadBrowser()
    local self = {
        methods = methods,

        -- What the player is looking at: sidebar section, activity filter, search
        -- text and the list's scroll position (kept for coming back from a method).
        section = "browse",
        category = "all",
        search = "",
        scroll = 0,

        -- Which page of results is showing (Browse shows them a page at a time).
        page = 1,

        -- Difficulty and intensity filters ("any", or one of the levels above).
        -- Like search, these only live for this window and aren't saved.
        difficulty = "any",
        intensity = "any",

        -- Saved sort choice (a device-wide setting).
        sort = settings.sort,
        descending = settings.descending,

        -- Profit estimates by method ID, and the latest problem to show the player.
        estimates = {},
        readiness = {},
        availability = "any",
        message = warning,
    }

    -- Favourites belong to the character's profile, just like saved rates. Reload
    -- them when the window opens or after a method, in case the character changed.
    -- The methods hidden from recommendations are per profile too, so they come
    -- along in the same reload.
    function self:loadFavourites()
        -- A profile switch also changes every personal rate. Old list estimates
        -- must go even when this reload came from the detail's favourite button.
        if self.profile and self.profile ~= preferences.profile then
            self.estimates = {}
        end

        local hiddenWarning
        self.favourites, self.message = preferences:loadFavourites()
        self.hidden, hiddenWarning = preferences:loadHidden()
        self.message = self.message or hiddenWarning
        self.profile = preferences.profile
    end

    -- Store sort changes on selection, never on a frame or while typing search.
    -- A failed save leaves the old ordering selected and gives the UI the reason.
    function self:setSort(key, descending)
        local ok, problem = preferences:saveBrowser({ sort = key, descending = descending })
        self.message = problem

        if ok then
            self.sort = key
            self.descending = descending
            self.scroll = 0
            self.page = 1
        end

        return ok
    end

    -- Only update the displayed star after storage succeeds. There's no pretend
    -- "saved" state if the native database refuses the write.
    function self:toggleFavourite(method)
        local selected = not self.favourites[method.id]
        local ok, problem = preferences:saveFavourite(method.id, selected)
        self.message = problem

        if ok then
            self.favourites[method.id] = selected or nil
        end

        return ok
    end

    -- Hides one method from recommendations, or restores it. Like favourites, the
    -- in-memory list only changes once storage has accepted the write. Hidden
    -- methods still show in Browse and Favourites; only recommendations skip them.
    function self:setHidden(id, hidden)
        local ok, problem = preferences:saveHidden(id, hidden)
        self.message = problem

        if ok then
            self.hidden[id] = hidden or nil
        end

        return ok
    end

    -- Who My account says the settings belong to: the signed-in character's
    -- name (nil before one is read) and the profile its settings are saved under.
    function self:profileInfo()
        return { character = preferences.characterName, profile = preferences.profile }
    end

    -- The hidden methods, for My account: catalogue methods in title order, then
    -- any saved ID this bundle doesn't have (still listed, so it can be restored).
    function self:hiddenMethods()
        local known, list = {}, {}

        for _, method in ipairs(methods) do
            if self.hidden[method.id] then
                known[method.id] = true
                list[#list + 1] = { id = method.id, method = method }
            end
        end

        table.sort(list, function(left, right)
            if left.method.title ~= right.method.title then
                return left.method.title < right.method.title
            end

            return left.id < right.id
        end)

        local unknown = {}

        for id in pairs(self.hidden) do
            if not known[id] then
                unknown[#unknown + 1] = id
            end
        end

        table.sort(unknown)

        for _, id in ipairs(unknown) do
            list[#list + 1] = { id = id }
        end

        return list
    end

    -- Opening/reopening refreshes the catalogue once. Search, sorting and skill
    -- events only reuse these estimates; there is no repeating price timer.
    --
    -- Hundreds of methods share the same items (coins, potions, runes), so one
    -- price snapshot is shared across the whole refresh: each item is looked up
    -- once, not once per method that uses it.
    function self:refreshEstimates()
        self.estimates = {}
        local shared = {}

        for _, method in ipairs(methods) do
            self.estimates[method.id] = estimateMethod(method, nil, shared)
        end
    end

    -- Uses the already-captured method quotes on Back. Discard an unsaved draft:
    -- list comparisons use each method's saved rate (or its source default).
    function self:returnFromMethod(method, quotes)
        if self.profile ~= preferences.profile then
            self:loadFavourites()
        end

        self.estimates[method.id] = estimateMethod(method, quotes)
    end

    -- Filter into a new array so sorting never rearranges the bundled catalogue.
    -- Search is plain text, not a Lua pattern ("[" should be safe to type).
    function self:rows()
        local rows = {}
        local query = self.search:lower()

        for _, method in ipairs(methods) do
            local matchesCategory = self.category == "all" or method.category == self.category
            -- Hidden methods aren't filtered out here on purpose: they stay
            -- browsable (and favouritable). Only recommendations skip them.
            local matchesSection = self.section ~= "favourites" or self.favourites[method.id]

            local matchesFilters = matchesLevel(self.difficulty, method.difficulty)
                and matchesLevel(self.intensity, intensityLevel[method.intensity])

            local readiness = self.readiness[method.id]
            local matchesAccess = self.availability == "any"
                or self.availability == (readiness and readiness.status or "unknown")

            local searchable = (method.title .. " " .. (method.variant or "") .. " " .. method.source_category):lower()

            if matchesCategory and matchesSection and matchesFilters and matchesAccess and searchable:find(query, 1, true) then
                rows[#rows + 1] = method
            end
        end

        table.sort(rows, function(left, right)
            -- Recurring (per-run) methods always come after hourly ones, in both
            -- directions: a 2-minute daily's "per run" isn't comparable to per hour.
            local leftRuns = perRun(left)

            if leftRuns ~= perRun(right) then
                return not leftRuns
            end

            local a = sortValue(left, self.estimates, self.sort)
            local b = sortValue(right, self.estimates, self.sort)

            -- Missing estimates go last in BOTH directions. Reversing an
            -- ascending array would put them first.
            if a == nil or b == nil then
                if a ~= b then
                    return a ~= nil
                end
            elseif a ~= b then
                if self.descending then
                    return a > b
                end

                return a < b
            end

            if left.title ~= right.title then
                return left.title < right.title
            end

            return left.id < right.id
        end)

        return rows
    end

    self:loadFavourites()
    self.message = self.message or warning

    -- Recommend for me's state lives here too, so a trip to a method page and
    -- Back (which rebuilds the screen) keeps the same suggestion on show.
    self.recommendations = Recommendations.new(methods, self, preferences)

    return self
end

return Browser
