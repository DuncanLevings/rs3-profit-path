-- Recommend for me: which methods suit this player, and which one to show next.
-- No native UI objects in here, and no invented scores: every rule below is one
-- the card can explain in plain words.
--
-- How a suggestion is picked:
--   1. Start from the chosen activity (PvM, Skilling, Production or Recurring).
--   2. Drop methods the player said not to recommend, ones whose Required checks
--      are definitely missing, ones a priced estimate says lose money, and group
--      methods when the player wants solo only. For PvM, also drop anything
--      above their comfort level, 1-10 (the next level up stays, labelled, if
--      they want to learn).
--      Recommended gear never drops anything; it's guidance on the method page.
--   3. Order what's left: within comfort before learning, solo before group when
--      solo is preferred, fully met requirements before "needs checking", then
--      most profitable first (unpriced methods last).
--   4. Rotate: the first method not yet shown this cycle. Once every match has
--      been shown, start a new cycle, skipping the one just shown if there's
--      another. The history is saved per profile, so it survives a reload.
local Recommendations = {}

-- PvM comfort is a level on the same 1-10 ladder as the researched difficulty
-- (catalogue-source/research/difficulty.json): the hardest level the player is
-- happy to take on. Each has the ladder's name and a few examples.
Recommendations.comfortLevels = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }

Recommendations.comfortLabels = {
    "Absolute beginner", "First PvM lessons", "Foundational", "Intermediate", "Established PvM",
    "Upper intermediate", "Advanced", "Difficult endgame", "Expert", "Extreme ceiling",
}

Recommendations.comfortAbout = {
    "Cows, Chickens, low-level Slayer tasks.",
    "King Black Dragon, God Wars 1, Barrows, most Slayer tasks.",
    "Queen Black Dragon, God Wars 2, Osseous, Corporeal Beast.",
    "Gregorovic, The Magister, Rune Dragons, Arch-Glacor.",
    "Normal Kerapac, Solo Nex, Araxxor, Elite Dungeon 2.",
    "Rasial, Normal TzKal-Zuk, Elite Dungeon 1, Normal Sanctum.",
    "Raksha, Solo Elite Dungeon 3, Hard Zemouregal & Vorkath.",
    "Solo Hard Kerapac, Hard TzKal-Zuk, Hard Sanctum, 4-player AoD.",
    "Solo Vorago, Solo Solak, 1000% Zamorak or Amascut.",
    "Solo Angel of Death, 2000% Amascut, 4000% Telos or Zamorak.",
}

-- Browse's four Difficulty bands and the ladder levels each covers (the same
-- ranges as the catalogue build, src/tools/merge_methods.py).
Recommendations.bands = {
    Easy = { 1, 2 }, Medium = { 3, 4 }, Hard = { 5, 7 }, Elite = { 8, 10 },
}

-- "4: Intermediate", for buttons and chips.
function Recommendations.comfortName(level)
    return level .. ": " .. Recommendations.comfortLabels[level]
end

-- The level a PvM method counts as. Most have a researched ladder level; the
-- few the ladder doesn't cover yet only have a band, so they count as the
-- hardest level in it (never easier than they might be). nil if unrated.
function Recommendations.levelOf(method)
    if method.difficulty_level then
        return method.difficulty_level
    end

    local band = Recommendations.bands[method.difficulty]
    return band and band[2]
end

-- Solo/group choices, in the order My account lists them.
Recommendations.groupChoices = {
    { id = "solo-preferred", label = "Solo preferred", about = "Groups are allowed, after solo activities." },
    { id = "solo-only", label = "Solo only", about = "Group activities are never recommended." },
    { id = "either", label = "Solo and groups equally", about = "Group size doesn't change the order." },
}

-- The activities a recommendation can start from (Browse's categories).
Recommendations.activities = {
    { id = "pvm", label = "PvM", about = "Bossing and combat" },
    { id = "skilling", label = "Skilling", about = "Gathering and skilling bosses" },
    { id = "production", label = "Production", about = "Turn supplies into things that sell" },
    { id = "recurring", label = "Recurring", about = "Daily and weekly runs" },
}

-- One-word label for an activity ID, e.g. "PvM".
function Recommendations.activityLabel(id)
    for _, activity in ipairs(Recommendations.activities) do
        if activity.id == id then
            return activity.label
        end
    end

    return id
end

function Recommendations.groupLabel(id)
    for _, choice in ipairs(Recommendations.groupChoices) do
        if choice.id == id then
            return choice.label
        end
    end

    return id
end

-- Whether a PvM method fits the player's comfort. Returns "within", "learning"
-- (exactly one level above, and only if they asked for learning opportunities)
-- or nil (too hard, or somehow unrated: unknown never counts as a fit).
local function difficultyFit(method, settings)
    local level, comfort = Recommendations.levelOf(method), settings.comfort

    if not level or not comfort then
        return nil
    end

    if level <= comfort then
        return "within"
    end

    if settings.learning and level == comfort + 1 then
        return "learning"
    end
end

-- The matching methods for `activity`, in the order they'd be suggested, plus
-- how many were left out for each reason (so an empty result can say why).
--
-- `context` holds what Browse already knows: readiness (Required checks by
-- method ID), estimates (profit by method ID) and hidden (Don't recommend IDs).
-- Each entry is { method, learning = bool, unchecked = bool, estimate }.
function Recommendations.pool(methods, activity, settings, context)
    local pool = {}
    local skipped = { hidden = 0, missing = 0, comfort = 0, group = 0, unprofitable = 0 }

    for _, method in ipairs(methods) do
        if method.category == activity then
            local readiness = context.readiness[method.id]
            local status = readiness and readiness.status or "unknown"
            local estimate = context.estimates[method.id]
            local priced = estimate and estimate.status == "available"
            local fit = activity ~= "pvm" and "within" or difficultyFit(method, settings)

            -- One reason per method, checked in the order the player is most
            -- likely to care about.
            if context.hidden[method.id] then
                skipped.hidden = skipped.hidden + 1
            elseif status == "unmet" then
                skipped.missing = skipped.missing + 1
            elseif not fit then
                skipped.comfort = skipped.comfort + 1
            elseif method.team and settings.group == "solo-only" then
                skipped.group = skipped.group + 1
            elseif priced and estimate.profit <= 0 then
                skipped.unprofitable = skipped.unprofitable + 1
            else
                pool[#pool + 1] = {
                    method = method,
                    learning = fit == "learning",
                    unchecked = status ~= "met",
                    estimate = priced and estimate or nil,
                }
            end
        end
    end

    -- Each rule is a plain "this before that"; the first rule that tells two
    -- methods apart decides. Ties fall back to the title, then the ID, so the
    -- order never shuffles between redraws.
    local soloFirst = settings.group == "solo-preferred"

    table.sort(pool, function(left, right)
        if left.learning ~= right.learning then
            return not left.learning
        end

        local leftGroup, rightGroup = left.method.team ~= nil, right.method.team ~= nil

        if soloFirst and leftGroup ~= rightGroup then
            return not leftGroup
        end

        if left.unchecked ~= right.unchecked then
            return not left.unchecked
        end

        -- A daily's "per run" can't be compared with per hour; hourly first.
        local leftRuns = left.method.income.period == "run"

        if leftRuns ~= (right.method.income.period == "run") then
            return not leftRuns
        end

        -- Priced before unpriced, then most profitable first.
        if (left.estimate == nil) ~= (right.estimate == nil) then
            return left.estimate ~= nil
        end

        if left.estimate and left.estimate.profit ~= right.estimate.profit then
            return left.estimate.profit > right.estimate.profit
        end

        if left.method.title ~= right.method.title then
            return left.method.title < right.method.title
        end

        return left.method.id < right.method.id
    end)

    return pool, skipped
end

-- The next suggestion from an ordered pool, given one activity's history
-- { shown = { id, ... }, last = id }. Updates the history in place and returns
-- the chosen entry (nil for an empty pool).
function Recommendations.rotate(pool, history)
    if #pool == 0 then
        return nil
    end

    local seen = {}

    for _, id in ipairs(history.shown) do
        seen[id] = true
    end

    local chosen

    for _, entry in ipairs(pool) do
        if not seen[entry.method.id] then
            chosen = entry
            break
        end
    end

    -- Everything has been shown: a new cycle. Don't open it with the method
    -- that was just shown, unless it's the only one.
    if not chosen then
        history.shown = {}

        for _, entry in ipairs(pool) do
            if #pool == 1 or entry.method.id ~= history.last then
                chosen = entry
                break
            end
        end
    end

    history.shown[#history.shown + 1] = chosen.method.id
    history.last = chosen.method.id

    return chosen
end

-- The recommendation screen's state for one window: the saved settings and
-- history, the activity being looked at and its current suggestion. Back from a
-- method keeps all of it, so the same suggestion is still there.
function Recommendations.new(methods, browser, preferences)
    local self = { activity = nil, current = {}, notice = nil }

    -- Every method ID per activity, to keep the saved history bounded by the
    -- catalogue rather than growing forever.
    local known = {}

    for _, method in ipairs(methods) do
        known[method.id] = method.category
    end

    -- Loads the current profile's settings. A character switch while the window
    -- is open brings another profile's settings and history, so start afresh.
    local function load()
        self.record, self.message = preferences:loadRecommend()
        self.profile = preferences.profile
        self.current = {}
        self.notice = nil
    end

    local function followProfile()
        if self.profile ~= preferences.profile then
            load()
        end
    end

    -- Saves the record with `changes` applied. Settings only change in memory
    -- once storage has taken them, like favourites.
    local function save(changes)
        local record = {}

        for key, value in pairs(self.record) do
            record[key] = value
        end

        for key, value in pairs(changes) do
            record[key] = value
        end

        local ok, problem = preferences:saveRecommend(record)
        self.message = problem

        if ok then
            self.record = record
        end

        return ok
    end

    function self:settings()
        followProfile()
        return self.record
    end

    function self:setComfort(level)
        followProfile()
        return save({ comfort = level })
    end

    function self:setLearning(learning)
        followProfile()
        return save({ learning = learning })
    end

    function self:setGroup(choice)
        followProfile()
        return save({ group = choice })
    end

    -- PvM needs a comfort level before its first suggestion; nothing else does.
    function self:needsComfort()
        followProfile()
        return self.activity == "pvm" and self.record.comfort == nil
    end

    -- A fresh request for an activity: always a new suggestion, never the one
    -- just shown when there's another.
    function self:choose(activity)
        followProfile()
        self.activity = activity
        self.current[activity] = nil
        self.notice = nil
    end

    -- Back to the activity chooser. The current suggestions are forgotten, so
    -- picking an activity again is a new request.
    function self:changeActivity()
        self.activity = nil
        self.current = {}
        self.notice = nil
    end

    -- Picks the next method for the current activity and saves the history. A
    -- failed history save is reported but doesn't stop the suggestion.
    local function advance(pool)
        local activity = self.activity
        local stored = self.record.history[activity] or { shown = {} }
        local history = { shown = {}, last = stored.last }

        -- Copy, dropping IDs this catalogue no longer has for this activity.
        for _, id in ipairs(stored.shown) do
            if known[id] == activity then
                history.shown[#history.shown + 1] = id
            end
        end

        local chosen = Recommendations.rotate(pool, history)

        if chosen then
            local all = {}

            for key, value in pairs(self.record.history) do
                all[key] = value
            end

            all[activity] = history

            if not save({ history = all }) then
                -- Keep rotating this session even if storage refused it.
                self.record.history[activity] = history
            end

            self.current[activity] = chosen.method.id
        end

        return chosen
    end

    -- The suggestion to show now: the current one while it still matches (so a
    -- price refresh or a trip to the method page never swaps it), otherwise the
    -- next in rotation. Returns entry, pool, skipped and, if the current one
    -- stopped matching, that method (the screen says why it changed).
    function self:suggestion()
        followProfile()

        local pool, skipped = Recommendations.pool(methods, self.activity, self.record, {
            readiness = browser.readiness, estimates = browser.estimates, hidden = browser.hidden,
        })

        local currentId = self.current[self.activity]

        for _, entry in ipairs(pool) do
            if entry.method.id == currentId then
                return entry, pool, skipped
            end
        end

        local replaced

        if currentId then
            for _, method in ipairs(methods) do
                if method.id == currentId then
                    replaced = method
                end
            end
        end

        return advance(pool), pool, skipped, replaced
    end

    -- Show another: the next method in rotation. Changes no settings.
    function self:showAnother()
        self.current[self.activity] = nil
        self.notice = nil
    end

    -- Don't recommend: saved per profile (Browse marks it, My account lists it),
    -- with an Undo that brings the same suggestion straight back.
    function self:dontRecommend(method)
        if not browser:setHidden(method.id, true) then
            self.message = browser.message
            return false
        end

        self.current[self.activity] = nil
        self.notice = { method = method }

        return true
    end

    function self:undo()
        local notice = self.notice

        if not notice or not browser:setHidden(notice.method.id, false) then
            self.message = browser.message
            return false
        end

        self.notice = nil
        self.current[self.activity] = notice.method.id

        return true
    end

    load()

    return self
end

return Recommendations
