-- Recommend for me: which methods match, their order, rotation, saved settings
-- and the screen. The methods here are test fixtures with made-up numbers, not
-- researched ratings for real bosses.
return function(test, equal, client, pretty)
    local Recommendations = require("src/methods/recommendations")
    local Preferences = require("src/storage/preferences")

    -- A small PvM catalogue: one per difficulty, a group version and a loser.
    local function method(id, fields)
        local record = {
            id = id, title = fields.title or id, category = fields.category or "pvm",
            difficulty = fields.difficulty, difficulty_level = fields.difficulty_level, team = fields.team, intensity = "Low",
            income = { period = fields.period or "hour" },
        }

        if record.category ~= "pvm" then
            record.difficulty = nil
        end

        return record
    end

    local function catalogue()
        return {
            method("easy", { difficulty = "Easy", difficulty_level = 2 }),
            method("medium", { difficulty = "Medium", difficulty_level = 4 }),
            method("hard", { difficulty = "Hard", difficulty_level = 5 }),
            method("elite", { difficulty = "Elite", difficulty_level = 9 }),
            method("duo", { difficulty = "Easy", difficulty_level = 2, team = "Duo" }),
            method("loser", { difficulty = "Easy", difficulty_level = 1 }),
            method("unpriced", { difficulty = "Easy" }),
            method("chopping", { category = "skilling" }),
        }
    end

    local function context()
        return {
            readiness = {
                easy = { status = "met" }, medium = { status = "unknown" }, hard = { status = "met" },
                elite = { status = "met" }, duo = { status = "met" }, loser = { status = "met" },
                unpriced = { status = "met" }, chopping = { status = "unmet" },
            },
            estimates = {
                easy = { status = "available", profit = 100 }, medium = { status = "available", profit = 900 },
                hard = { status = "available", profit = 5000 }, elite = { status = "available", profit = 9000 },
                duo = { status = "available", profit = 2000 }, loser = { status = "available", profit = -5 },
                unpriced = { status = "partial" },
            },
            hidden = {},
        }
    end

    local function ids(pool)
        local values = {}

        for _, entry in ipairs(pool) do
            values[#values + 1] = entry.method.id .. (entry.learning and "*" or "")
        end

        return table.concat(values, ",")
    end

    local settings = { comfort = 4, learning = true, group = "solo-preferred" }

    -- Within comfort first (met before needs-checking, then by profit, unpriced
    -- last), then the group version, then the one learning opportunity.
    test("recommendations keep within comfort first, solo before group, then profit, with one learning band", function()
        local pool, skipped = Recommendations.pool(catalogue(), "pvm", settings, context())

        equal(ids(pool), "easy,unpriced,medium,duo,hard*")
        equal(skipped.comfort, 1)
        equal(skipped.unprofitable, 1)
        equal(pool[3].unchecked, true)

        -- Learning off: the harder band is left out too.
        pool, skipped = Recommendations.pool(catalogue(), "pvm",
            { comfort = 4, learning = false, group = "solo-preferred" }, context())
        equal(ids(pool), "easy,unpriced,medium,duo")
        equal(skipped.comfort, 2)

        -- Groups equally: the duo goes by profit like anything else.
        pool = Recommendations.pool(catalogue(), "pvm", { comfort = 4, learning = true, group = "either" }, context())
        equal(ids(pool), "duo,easy,unpriced,medium,hard*")

        -- Solo only: no group methods at all.
        pool, skipped = Recommendations.pool(catalogue(), "pvm", { comfort = 4, learning = true, group = "solo-only" }, context())
        equal(ids(pool), "easy,unpriced,medium,hard*")
        equal(skipped.group, 1)

        -- A method the ladder doesn't cover yet ("unpriced" has only a band)
        -- counts as the hardest level in its band, never easier.
        equal(Recommendations.levelOf({ difficulty = "Hard" }), 7)
        equal(Recommendations.levelOf({ difficulty = "Hard", difficulty_level = 5 }), 5)
        equal(Recommendations.levelOf({}), nil)

        -- The top level: everything that fits, and nothing above to learn.
        pool = Recommendations.pool(catalogue(), "pvm", { comfort = 10, learning = true, group = "solo-preferred" }, context())
        equal(ids(pool), "elite,hard,easy,unpriced,medium,duo")
    end)

    -- Only a definite Missing drops a method; recommended gear never does. Not
    -- recommending one method leaves its other versions alone.
    test("recommendations drop missing requirements and exact hidden IDs, and only ask PvM about comfort", function()
        local seen = context()
        seen.hidden = { easy = true }
        local pool, skipped = Recommendations.pool(catalogue(), "pvm", settings, seen)

        equal(ids(pool), "unpriced,medium,duo,hard*")
        equal(skipped.hidden, 1)

        pool, skipped = Recommendations.pool(catalogue(), "skilling", settings, seen)
        equal(#pool, 0)
        equal(skipped.missing, 1)

        -- Skilling has no difficulty, and needs no comfort.
        seen.readiness.chopping = { status = "met" }
        pool = Recommendations.pool(catalogue(), "skilling", { learning = true, group = "solo-preferred" }, seen)
        equal(ids(pool), "chopping")
    end)

    -- Unseen first; a new cycle doesn't start with the one just shown, unless
    -- it's the only match.
    test("rotation shows unseen matches before repeats and never repeats the last one when it can", function()
        local pool = Recommendations.pool(catalogue(), "pvm", { comfort = 2, learning = false, group = "solo-preferred" }, context())
        equal(ids(pool), "easy,unpriced,duo")

        local history = { shown = {} }
        local order = {}

        for _ = 1, 5 do
            order[#order + 1] = Recommendations.rotate(pool, history).method.id
        end

        equal(table.concat(order, ","), "easy,unpriced,duo,easy,unpriced")

        -- After "duo" is last, a new cycle begins with "easy", not "duo".
        history = { shown = { "easy", "unpriced", "duo" }, last = "duo" }
        equal(Recommendations.rotate(pool, history).method.id, "easy")
        history = { shown = { "easy", "unpriced", "duo" }, last = "easy" }
        equal(Recommendations.rotate(pool, history).method.id, "unpriced")

        -- One match: it can come back.
        local single = { pool[1] }
        history = { shown = { "easy" }, last = "easy" }
        equal(Recommendations.rotate(single, history).method.id, "easy")
        equal(Recommendations.rotate({}, history), nil)
    end)

    -- A fake browser: just what the recommender reads, plus hiding.
    local function fakeBrowser(prefs)
        local browser = context()
        browser.message = nil

        function browser:setHidden(id, hidden)
            local ok, problem = prefs:saveHidden(id, hidden)
            self.message = problem

            if ok then
                self.hidden[id] = hidden or nil
            end

            return ok
        end

        return browser
    end

    -- Settings and rotation are saved per profile, so a reopened window carries
    -- on where it left off. Show another changes no settings.
    test("recommendation settings and rotation survive a reload and stay per profile", function()
        local state = client()
        local prefs = Preferences.new(PersistentDB)
        local browser = fakeBrowser(prefs)
        local recommender = Recommendations.new(catalogue(), browser, prefs)

        recommender:choose("pvm")
        equal(recommender:needsComfort(), true)
        assert(recommender:setComfort(2))
        assert(recommender:setLearning(false))
        equal(recommender:needsComfort(), false)

        equal(recommender:suggestion().method.id, "easy")
        recommender:showAnother()
        equal(recommender:suggestion().method.id, "unpriced")

        -- Asking again without Show another keeps the same suggestion (Back from
        -- a method, a price refresh...).
        browser.estimates.unpriced = { status = "available", profit = 1 }
        equal(recommender:suggestion().method.id, "unpriced")
        equal(recommender:settings().comfort, 2)

        -- A reopened window: a new request carries on the cycle.
        local reopened = Recommendations.new(catalogue(), browser, Preferences.new(PersistentDB))
        equal(reopened:settings().comfort, 2)
        equal(reopened:settings().learning, false)
        reopened:choose("pvm")
        equal(reopened:suggestion().method.id, "duo")

        -- Another character starts afresh, and the first one's record is kept.
        assert(prefs:bindCharacter("First"))
        assert(prefs:bindCharacter("Other"))
        equal(recommender:settings().comfort, nil)
        equal(state.db["profit-path.recommend.v1/7:Default"].comfort, 2)

        -- A failed save changes nothing and says why.
        state.failWrite = true
        equal(recommender:setGroup("solo-only"), false)
        equal(recommender:settings().group, "solo-preferred")
        assert(recommender.message:find("could not be saved", 1, true), recommender.message)
    end)

    test("saved recommendation settings keep valid fields and protect unreadable records", function()
        local state = client()
        state.db["profit-path.recommend.v1/7:Default"] = {
            schema = 1, comfort = "Godlike", learning = false, group = "solo-only",
            history = { pvm = { shown = { "easy", 7 }, last = "easy" }, dancing = { shown = {} } },
        }

        local prefs = Preferences.new(PersistentDB)
        local record, warning, writable = prefs:loadRecommend()
        equal(record.comfort, nil)
        equal(record.learning, false)
        equal(record.group, "solo-only")
        equal(table.concat(record.history.pvm.shown, ","), "easy")
        equal(record.history.dancing, nil)
        assert(warning, "The invalid fields are reported")
        equal(writable, true)

        -- Builds before the 1-10 ladder saved a band; it becomes the top of that
        -- band. A stored float level reads back as a whole number.
        state.db["profit-path.recommend.v1/7:Default"] = { schema = 1, comfort = "Medium" }
        equal(prefs:loadRecommend().comfort, 4)
        state.db["profit-path.recommend.v1/7:Default"] = { schema = 1, comfort = 6.0 }
        equal(math.type(prefs:loadRecommend().comfort), "integer")
        state.db["profit-path.recommend.v1/7:Default"] = { schema = 1, comfort = 11 }
        equal(prefs:loadRecommend().comfort, nil)

        -- An unsupported record is never written over.
        state.db["profit-path.recommend.v1/7:Default"] = { schema = 9 }
        equal(prefs:saveRecommend({ learning = true, group = "either", history = {} }), false)
        equal(state.db["profit-path.recommend.v1/7:Default"].schema, 9)
    end)

    -- Don't recommend hides that one ID, moves on, and Undo brings the same
    -- suggestion straight back. A suggestion that stops matching is replaced,
    -- and the screen is told which one.
    test("don't recommend moves on with an undo, and a suggestion that stops matching is replaced", function()
        client()
        local prefs = Preferences.new(PersistentDB)
        local browser = fakeBrowser(prefs)
        local recommender = Recommendations.new(catalogue(), browser, prefs)
        assert(recommender:setComfort(2))
        assert(recommender:setLearning(false))
        recommender:choose("pvm")

        local first = recommender:suggestion().method
        equal(first.id, "easy")
        assert(recommender:dontRecommend(first))
        equal(browser.hidden.easy, true)
        equal(recommender.notice.method, first)
        equal(recommender:suggestion().method.id, "unpriced")

        assert(recommender:undo())
        equal(browser.hidden.easy, nil)
        equal(recommender:suggestion().method.id, "easy")

        -- A requirement now reads as missing: the next unseen one ("unpriced"
        -- was shown while "easy" was hidden), and the old one is named.
        browser.readiness.easy = { status = "unmet" }
        local entry, _, _, replaced = recommender:suggestion()
        equal(entry.method.id, "duo")
        equal(replaced.id, "easy")
    end)

    -- The screen: the sidebar entry, activities, the one-time comfort question
    -- (PvM only), the card, and Back from a method keeping the same card.
    test("recommend for me asks comfort for PvM only, shows a card and keeps it after Back", function()
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1000, height = 740 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findButton("Recommend for me")()

        local function shown(text)
            for index = #prettyui.allViews, 1, -1 do
                local view = prettyui.allViews[index]

                if not view.destroyed then
                    for _, label in ipairs(view.texts) do
                        if label.content:find(text, 1, true) then
                            return true
                        end
                    end
                end
            end

            return false
        end

        assert(shown("What do you feel like doing?"))

        -- Production: no comfort question, straight to a suggestion.
        prettyui:findButton("Production")()
        assert(not shown("How much bossing"), "Only PvM asks about bossing")
        assert(shown("Smelting steel bars"), "The one production method is suggested")
        assert(not shown("matches"), "No match count on the card")

        local card = prettyui:findMethod("Smelting steel bars")
        assert(card, "The card has View method")

        -- With one match there's nothing else to show.
        local function control(label)
            for index = #prettyui.allViews, 1, -1 do
                local view = prettyui.allViews[index]

                if not view.destroyed and view.buttonControls and view.buttonControls[label]
                    and not view.buttonControls[label].destroyed then
                    return view.buttonControls[label]
                end
            end
        end

        equal(control("Show another").disabled, true)

        -- View method, then Back: the same card.
        card()
        settleMethod()
        prettyui:findButton("Back to activities")()
        assert(shown("Smelting steel bars"), "Back keeps the suggestion")
        assert(shown("Recommend for me"))

        -- Don't recommend, then Undo.
        prettyui:findButton("Don't recommend")()
        assert(shown("won't be recommended"))
        assert(shown("Nothing matches right now"))
        prettyui:findButton("Undo")()
        assert(shown("Smelting steel bars"))

        -- The sidebar entry always starts again at the activity choice.
        prettyui:findButton("Recommend for me")()
        assert(shown("What do you feel like doing?"), "Back at the activity choice")

        -- Skilling has both elder-log versions. Show another pauses on a spinner
        -- first, then shows the other one.
        prettyui:findButton("Skilling")()

        local function spinning()
            for index = #prettyui.allViews, 1, -1 do
                local view = prettyui.allViews[index]

                if not view.destroyed and view.spinners and #view.spinners > 0 then
                    return true
                end
            end

            return false
        end

        local firstVariant = shown("With wood spirits") and "With wood spirits" or "Without wood spirits"
        local secondVariant = firstVariant == "With wood spirits" and "Without wood spirits" or "With wood spirits"

        equal(control("Show another").disabled, false)

        do
            prettyui:findButton("Show another")()
            assert(spinning(), "A spinner while finding another")
            assert(shown("Finding another..."))
            assert(not shown(firstVariant), "The old card is gone")
            settleSearch()
            settleSearch()
            assert(not shown("Finding another..."))
            assert(shown(secondVariant), "The other version is shown after the pause")
        end

        -- PvM asks first, once; the answer is the active choice in My account.
        prettyui:findButton("Change activity")()
        prettyui:findButton("PvM")()
        assert(shown("How much bossing have you done?"))
        prettyui:findButton("4: Intermediate")()
        assert(not shown("How much bossing"), "Asked once")
        assert(shown("Up to 4: Intermediate"))
        assert(shown("Solo preferred"))
        assert(shown("Learning opportunities"))

        -- Preferences on the activity strip opens My account.
        prettyui:findButton("Preferences")()
        equal(control("4: Intermediate").active, true)
        equal(control("Solo preferred").active, true)
        prettyui:findButton("Solo only")()
        equal(control("Solo only").active, true)

        -- The sidebar frames only the page you're on. The chosen activity is a
        -- filter, so it shows in its colour while the others go muted.
        local Style = require("src/ui/view_style")
        prettyui:findButton("PvM")()
        equal(control("Browse").active, true)
        equal(control("PvM").active, false)
        equal(control("PvM").textColour, Style.categories.pvm)
        equal(control("Skilling").textColour, Style.muted)
        equal(control("All activities").textColour, Style.muted)

        PluginShutdown()
    end)
end
