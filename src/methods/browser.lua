-- The browser's state and ordering, with no native UI objects in here. It owns
-- the current filters, the return-to-list position and estimates for this window.
-- Opening/reopening captures prices; filtering never fetches prices.
local Browser = {}

local intensityOrder = { Low = 1, Moderate = 2, Medium = 2, High = 3 }
local difficultyOrder = { Easy = 1, Medium = 2, Hard = 3, Elite = 4 }

-- Unknown includes unclassified labels. Guessing where a new label belongs would
-- give the player an ordering we haven't actually researched.
local function sortValue(method, estimates, key)
    if key == "intensity" then
        return intensityOrder[method.intensity]
    end

    if key == "difficulty" then
        return difficultyOrder[method.difficulty]
    end

    local estimate = estimates[method.id]

    if estimate and estimate.status == "available" then
        return estimate[key]
    end
end

-- Keep this window's browsing state in memory. Only explicit sort and favourite
-- changes go to storage; search and scrolling don't produce database writes.
function Browser.new(methods, preferences, estimateMethod)
    local settings, warning = preferences:loadBrowser()
    local self = {
        methods = methods,
        section = "browse", category = "all", search = "", scroll = 0,
        sort = settings.sort, descending = settings.descending,
        estimates = {}, message = warning,
    }

    -- Favourites belong to a manual profile, just like saved rates. Reload this
    -- when coming back from a method, where the player may have switched profile.
    function self:loadFavourites()
        -- A profile switch also changes every personal rate. Old list estimates
        -- must go even when this reload came from the detail's favourite button.
        if self.profile and self.profile ~= preferences.profile then
            self.estimates = {}
        end

        self.favourites, self.message = preferences:loadFavourites()
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

    -- Opening/reopening refreshes the catalogue once. Search, sorting and skill
    -- events only reuse these estimates; there is no repeating price timer.
    function self:refreshEstimates()
        self.estimates = {}

        for _, method in ipairs(methods) do
            self.estimates[method.id] = estimateMethod(method)
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
            local matchesSection = self.section ~= "favourites" or self.favourites[method.id]
            local searchable = (method.title .. " " .. (method.variant or "") .. " " .. method.source_category):lower()

            if matchesCategory and matchesSection and searchable:find(query, 1, true) then
                rows[#rows + 1] = method
            end
        end

        table.sort(rows, function(left, right)
            local a = sortValue(left, self.estimates, self.sort)
            local b = sortValue(right, self.estimates, self.sort)

            -- Missing estimates and not-applicable difficulty go last in BOTH
            -- directions. Reversing an ascending array would put them first.
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

    return self
end

return Browser
