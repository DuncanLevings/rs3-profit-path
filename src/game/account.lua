-- Reads what the account has (items, skills, quests, unlocks) and owns the event
-- subscriptions that say when those change. The bank can only be read while it's
-- open, and even a full read doesn't cover every storage spot or tool-belt category.
local Toolbelt = require("src/game/toolbelt")
local Account = {}

-- Above this many unread items, a container is read slot by slot instead of with one
-- GetTotal call per item.
local SLOT_SCAN_THRESHOLD = 200

-- The containers we read item counts from (see readOwnership).
local WATCHED_CONTAINERS = { "INV", "WORN", "BANK" }

-- True when `inventoryConfig` is one of the containers above. Shops, loot
-- windows, the GE and so on also fire inventory events, but can't change
-- anything we show, so they shouldn't trigger a refresh.
local function isWatched(inventoryConfig)
    local id = inventoryConfig and inventoryConfig.id

    for _, name in ipairs(WATCHED_CONTAINERS) do
        local definition = config.Inv[name]

        if definition and definition.id == id then
            return true
        end
    end

    return false
end

-- App supplies the optional snapshot owner and validated tool-belt bindings;
-- tests can leave them out without importing the whole catalogue.
function Account.new(onChanged, snapshot, toolbeltBindings)
    local self = {
        active = true,

        -- Item counts read for the item borders, per container ("INV", "WORN",
        -- "BANK"). Each entry is { configId, counts = { [itemId] = total } } and is
        -- thrown away as soon as that container changes. Lives only in memory.
        ownershipCache = {},

        -- This login's last open-bank read, used while the bank is closed. It can go
        -- stale (deposit boxes, say). `all` holds every item seen on that visit, so a
        -- newly watched custom requirement can still be answered; after logout only
        -- the saved, already-watched items are known.
        sessionBank = nil,
        snapshot = snapshot,
        questVariables = {},
        toolbeltBindings = toolbeltBindings or {},
        toolbeltVariables = {},
        toolbeltCache = nil,
    }

    -- Every event we subscribe to, so destroy() can unsubscribe all of them.
    local subscriptions = {}

    -- Only pass changes on while we're alive; after shutdown, stay quiet.
    local function notify(reason)
        if self.active then
            onChanged(reason)
        end
    end

    -- Subscribes under one shared name and remembers the event for destroy().
    local function subscribe(event, callback)
        event.Subscribe("profit-path-account", callback)
        subscriptions[#subscriptions + 1] = event
    end

    -- Any change to a container (an item gained, banked, equipped...) makes our
    -- cached counts for it stale, so drop them; the next border refresh re-reads.
    local function inventoryChanged(kind, event)
        if not self.active then
            return
        end

        local inventoryConfig = event.inv

        if not isWatched(inventoryConfig) then
            return
        end

        -- A removed bank is a useful checkpoint for the last observed contents.
        if kind == "Removed" and self.snapshot then
            self.snapshot:flush()
        end

        for name, snapshot in pairs(self.ownershipCache) do
            if snapshot.configId == inventoryConfig.id then
                self.ownershipCache[name] = nil
            end
        end

        notify("inventory")
    end

    -- Reads base (unboosted) levels for the skills named in `names`, a set like
    -- { SMITHING = true }. Names the client doesn't recognise are skipped, and when
    -- logged out we return an empty table, which callers treat as "unknown", not 0.
    function self:readSkills(names)
        local skills = {}

        if not self.active or not Player.IsAvailable() then
            return skills
        end

        for name in pairs(names) do
            local skill = SkillType[name]

            if skill ~= nil then
                skills[name] = { status = "available", level = Player.GetLevelUncapped(skill) }
            end
        end

        return skills
    end

    -- Our own visible name, for the window and My account, and the key that
    -- picks this character's settings profile (see Preferences:bindCharacter).
    -- Don't retain the entity proxy.
    function self:readCharacterName()
        if not self.active or not Player.IsAvailable() then
            return nil, "Enter a game world before opening Profit Path."
        end

        local ok, name = pcall(function()
            local player = Player.GetEntity()

            if player and player.isValid then
                return player.displayName
            end
        end)

        if not ok then
            return nil, "Character name could not be read: " .. tostring(name)
        end

        if type(name) ~= "string" or not name:find("%S") then
            return nil, "Character name is not available yet. Try opening again in a moment."
        end

        return name
    end

    -- Tool-belt contents, cached until one of its game variables changes. Not
    -- saved: the belt can always be read live.
    function self:readToolbelt()
        if not self.active or not Player.IsAvailable() then
            return { counts = {}, slots = {}, complete = false, message = "Tool belt is unavailable outside a game world." }
        end

        if not self.toolbeltCache then
            self.toolbeltCache = Toolbelt.read(self.toolbeltBindings)
            self.toolbeltVariables = self.toolbeltCache.watched
        end

        return self.toolbeltCache
    end

    -- Counts the wanted items across backpack, worn gear, bank and tool belt,
    -- caching each container until an inventory event says it changed.
    -- `complete` only means those places were all read. A failed read never proves
    -- an item is missing; saved counts and lastKnownAbsent are last-seen hints.
    function self:readOwnership(wanted)
        local totals, savedCounts, sources = {}, {}, {}
        local lastKnownAbsent = {}

        -- After the bank closes, an item can keep its red "not there last time"
        -- border, but only if every container saved an explicit 0 for it (no entry
        -- means unknown). It's just a display hint; it never fails a check.
        for itemId in pairs(wanted) do
            lastKnownAbsent[itemId] = true
        end

        if next(wanted) == nil then
            return { counts = totals, complete = false }
        end

        local complete = self.active and Player.IsAvailable()

        if not complete then
            return { counts = totals, complete = false }
        end

        for _, name in ipairs(WATCHED_CONTAINERS) do
            local snapshot = self.ownershipCache[name]

            -- Native reads can fail (e.g. the bank isn't sent until opened), so
            -- protect them. Any bad answer means "couldn't read this container".
            local ok, read = pcall(function()
                local definition = config.Inv[name]
                local inventory = definition and Inventory.Find(definition)

                if not inventory or not inventory.isValid then
                    return nil
                end

                -- Start from what's cached and only ask about items we haven't yet.
                local counts = snapshot and snapshot.counts or {}
                local missing = 0

                for itemId in pairs(wanted) do
                    if counts[itemId] == nil then
                        missing = missing + 1
                    end
                end

                -- Scan large watched sets once instead of asking for every item
                -- separately. Always scan the whole bank after a change so new
                -- watched items can use this visit's evidence.
                local needAll = name == "BANK" and not (snapshot and snapshot.all)
                local slots = (missing > SLOT_SCAN_THRESHOLD or needAll) and inventory.GetSlots and inventory:GetSlots()
                local all = snapshot and snapshot.all

                if slots then
                    local found = {}

                    for _, slot in pairs(slots) do
                        local itemId = slot.obj and slot.obj.id
                        local count = slot.count

                        if type(itemId) == "number" and type(count) == "number" and count > 0 then
                            found[itemId] = (found[itemId] or 0) + count
                        end
                    end

                    -- Only the bank keeps the whole list; the others are read live.
                    if name == "BANK" then
                        all = found
                    end

                    for itemId in pairs(wanted) do
                        if counts[itemId] == nil then
                            counts[itemId] = found[itemId] or 0
                        end
                    end
                end

                for itemId in pairs(wanted) do
                    if counts[itemId] == nil then
                        local total = inventory:GetTotal(itemId)

                        if type(total) ~= "number" or total < 0 or total >= math.huge or total % 1 ~= 0 then
                            return nil
                        end

                        counts[itemId] = total
                    end
                end

                return { configId = definition.id, counts = counts, all = all }
            end)

            -- Use the latest session or saved bank read while closed. It must
            -- cover every wanted item, including zeros, to establish last-seen
            -- absence. Cache this coverage check until the bank or wanted set
            -- changes.
            local lastBank

            if not (ok and read) and name == "BANK" then
                local saved = self.snapshot and self.snapshot.data.BANK
                local counts = self.sessionBank and self.sessionBank.counts or saved
                local known = self.bankCoverage

                if counts and not (known and known.counts == counts and known.wanted == wanted) then
                    local covered = true

                    -- The session snapshot includes the whole bank, so a newly
                    -- watched item is present or known absent. Older saved
                    -- snapshots cover only their watched set.
                    local all = self.sessionBank and self.sessionBank.counts == counts and self.sessionBank.all

                    local filled = false

                    for itemId in pairs(wanted) do
                        if counts[itemId] == nil then
                            if all then
                                counts[itemId] = all[itemId] or 0
                                filled = true
                            else
                                covered = false
                                break
                            end
                        end
                    end

                    -- Save the answers too, so the next login knows them.
                    if filled and self.snapshot then
                        self.snapshot:observe(name, counts)
                    end

                    known = { counts = counts, wanted = wanted, covered = covered }
                    self.bankCoverage = known
                end

                if counts and known.covered then
                    lastBank = { counts = counts }
                end
            end

            if lastBank then
                sources[name] = "from your last bank visit"
                read = lastBank

                for itemId in pairs(wanted) do
                    totals[itemId] = (totals[itemId] or 0) + read.counts[itemId]
                    lastKnownAbsent[itemId] = lastKnownAbsent[itemId] and read.counts[itemId] == 0
                end
            elseif ok and read then
                self.ownershipCache[name] = read
                sources[name] = "live"

                if name == "BANK" then
                    self.sessionBank = read
                end

                if self.snapshot then
                    self.snapshot:observe(name, read.counts)
                end

                for itemId in pairs(wanted) do
                    totals[itemId] = (totals[itemId] or 0) + read.counts[itemId]
                    lastKnownAbsent[itemId] = lastKnownAbsent[itemId] and read.counts[itemId] == 0
                end
            else
                self.ownershipCache[name] = nil
                complete = false
                local remembered = self.snapshot and self.snapshot.data[name]
                sources[name] = remembered and "saved" or "unavailable"

                -- Saved counts from different places might be the same item that
                -- moved, so never add them up or add them to live counts.
                for itemId in pairs(wanted) do
                    local recorded = remembered and remembered[itemId]
                    local quantity = recorded or 0
                    lastKnownAbsent[itemId] = lastKnownAbsent[itemId] and recorded == 0

                    if quantity > (savedCounts[itemId] or 0) then
                        savedCounts[itemId] = quantity
                    end
                end
            end
        end

        local toolbelt = self:readToolbelt()
        sources.TOOLBELT = toolbelt.complete and "live" or "partly checked"

        for itemId in pairs(wanted) do
            if toolbelt.counts[itemId] then
                -- The belt shows you can use the tool, not that you own another
                -- copy, so it counts as 1 at most.
                totals[itemId] = math.max(totals[itemId] or 0, 1)
                lastKnownAbsent[itemId] = false
            end
        end

        return { counts = totals, complete = complete and toolbelt.complete, savedCounts = savedCounts,
            sources = sources, lastKnownAbsent = lastKnownAbsent, toolbelt = toolbelt }
    end

    -- Called only after Preferences has identified and bound the current player.
    function self:bindProfile(profile)
        self.ownershipCache = {}
        self.sessionBank = nil
        self.questVariables = {}
        self.toolbeltCache = nil
        self.toolbeltVariables = {}

        if self.snapshot then
            self.snapshot:bind(profile)
        end
    end

    -- Reads whether a quest is done and watches its progress variables. A value
    -- we can't read stays unknown rather than counting as "not done".
    function self:readQuest(name)
        if not self.active then
            return { status = "stopped" }
        end

        if type(name) ~= "string" or not name:match("^[A-Z][A-Z0-9_]*$") then
            return { status = "invalid", message = "Not a valid quest config name: " .. tostring(name) }
        end

        if not Player.IsAvailable() then
            return { status = "unavailable", message = "Log into a game world first." }
        end

        local ok, result = pcall(function()
            local quest = config.Quest[name]

            if not quest then
                return { status = "unknown", message = "Quest config is not available: " .. name }
            end

            if quest.deprecated then
                return { status = "unknown", message = "This quest config is deprecated; use its replacement." }
            end

            -- Only watch this quest's own variables, so unrelated variable
            -- changes don't refresh everything.
            for _, descriptor in pairs(quest.masterQuestVars or {}) do
                if descriptor.varPlayer then
                    self.questVariables[descriptor.varPlayer.id] = true
                end
            end

            local completed = quest.hasFinishedQuest
            local started = quest.hasStartedQuest

            if type(completed) ~= "boolean" or type(started) ~= "boolean" then
                return { status = "unknown", message = "Quest progress is unavailable." }
            end

            return {
                status = "available",
                name = quest.name,
                completed = completed,
                started = started,
            }
        end)

        if not ok then
            result = { status = "error", message = "Quest read failed: " .. tostring(result) }
        end

        return result
    end

    -- Safe to call twice. Unsubscribes first, so no event can arrive mid-teardown.
    function self:destroy()
        if not self.active then
            return
        end

        self.active = false
        self.ownershipCache = {}
        self.sessionBank = nil
        self.toolbeltCache = nil
        self.toolbeltVariables = {}

        if self.snapshot then
            self.snapshot:unbind()
        end

        for _, event in ipairs(subscriptions) do
            event.Unsubscribe("profit-path-account")
        end

        subscriptions = {}
    end

    -- Unlock flags: game variables such as ARCH_RELIC_DEATH_NOTE_UNLOCKED, read by
    -- name. Only names found in the client's variable list are ever asked for;
    -- a missing or unreadable one is unknown, never "not unlocked".
    function self:readFlags(names)
        local flags = {}

        if not self.active or not Player.IsAvailable() then
            return flags
        end

        for name in pairs(names) do
            local ok, value = pcall(function()
                local setting = var.VarPlayer[name]
                return setting and setting.value
            end)

            if ok and type(value) == "number" then
                flags[name] = { status = "available", value = value }
            else
                flags[name] = { status = "unknown" }
            end
        end

        return flags
    end

    -- Achievement completion by in-game ID (config.Achievement). Its progress is
    -- COMPLETE (-2) when done; GRACE (-3) also counts as done. DEPRECATED (-4)
    -- can't be done any more, so it never blocks a diary tier.
    function self:readAchievements(ids)
        local achievements = {}

        if not self.active or not Player.IsAvailable() then
            return achievements
        end

        for achievementId in pairs(ids) do
            local ok, progress = pcall(function()
                local achievement = config.Achievement.FromID(achievementId)
                return achievement and achievement.progress
            end)

            if ok and type(progress) == "number" then
                achievements[achievementId] = {
                    status = "available",
                    complete = progress == -2 or progress == -3,
                    retired = progress == -4,
                }
            else
                achievements[achievementId] = { status = "unknown" }
            end
        end

        return achievements
    end

    -- The player's combat level, straight from the client (Player.GetCombatLevel).
    -- The client applies its own rules, including free-to-play worlds, so we don't
    -- work it out ourselves.
    function self:readCombatLevel()
        if not self.active or not Player.IsAvailable() then
            return { status = "unavailable" }
        end

        local ok, level = pcall(Player.GetCombatLevel)

        if not ok or type(level) ~= "number" or level < 1 or level % 1 ~= 0 then
            return { status = "unknown", message = "Combat level is unavailable." }
        end

        return { status = "available", level = level }
    end

    -- An inventory event only clears that container's cached counts; they're
    -- re-read when next needed.
    subscribe(Event.InventoryAdded, function(event)
        inventoryChanged("Added", event)
    end)

    subscribe(Event.InventoryUpdated, function(event)
        inventoryChanged("Updated", event)
    end)

    subscribe(Event.InventoryRemoved, function(event)
        inventoryChanged("Removed", event)
    end)

    subscribe(Event.VarTransmit, function(event)
        if self.toolbeltVariables[event.var.id] then
            self.toolbeltCache = nil
            notify("inventory")
        end

        if self.questVariables[event.var.id] then
            notify("quests")
        end
    end)

    -- A skill changed: just tell the UI, which re-reads the skills it shows.
    subscribe(Event.SkillTransmit, function()
        notify("skills")
    end)

    -- Login, logout, world hop and so on. Anything we read before might belong to a
    -- different session now, so forget all of it.
    subscribe(Event.GameStateChanged, function()
        if not self.active then
            return
        end

        if self.snapshot then
            self.snapshot:unbind()
        end

        self.questVariables = {}
        self.toolbeltCache = nil
        self.toolbeltVariables = {}
        self.ownershipCache = {}
        self.sessionBank = nil

        notify("game_state")
    end)

    return self
end

return Account
