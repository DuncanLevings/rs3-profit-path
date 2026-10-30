-- Player-account reads live here. This file owns the client event subscriptions
-- (inventory, skills, quests, game state) and tells its owner which evidence
-- changed. It never does money maths or decides recommendations.
--
-- Bank data may be unavailable while closed. Readable backpack/worn/bank contents
-- and mapped tool-belt families still don't establish full account ownership.
local Toolbelt = require("src/game/toolbelt")
local Account = {}

-- Above this many unread items, a container is read slot by slot instead of with one
-- GetTotal call per item.
local SLOT_SCAN_THRESHOLD = 200

-- App supplies the optional snapshot owner and validated tool-belt bindings;
-- tests can leave them out without importing the whole catalogue.
function Account.new(onChanged, snapshot, toolbeltBindings)
    local self = {
        active = true,

        -- Item counts read for the item borders, per container ("INV", "WORN",
        -- "BANK"). Each entry is { configId, counts = { [itemId] = total } } and is
        -- thrown away as soon as that container changes. Lives only in memory.
        ownershipCache = {},
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

    -- Read only our own visible name. Don't retain the entity proxy and never
    -- use the tracking ID: it needs a permission this plugin doesn't request.
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

    -- Keep plain tool-belt evidence until one of its watched variables changes.
    -- It is live state, never written into the bank/inventory snapshot records.
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

    -- How many of each item in `wanted` (a set like { [2353] = true }) the player
    -- can use across backpack (INV), worn gear (WORN), bank (BANK) and mapped
    -- tool-belt families. The three inventory config names are verified.
    --
    -- Returns { counts = { [itemId] = total }, complete = true/false }. `complete`
    -- means the three containers and mapped belt families were readable. It does
    -- NOT cover Diango, the house or other belt categories. Unreadable live state
    -- can't establish absence; lastKnownAbsent separately preserves saved zeros.
    --
    -- Counts are cached per container until an inventory event says it changed, so
    -- refreshing the borders doesn't hit the client for every item every time.
    -- Saved counts are returned separately and never count towards live ownership.
    function self:readOwnership(wanted)
        local totals, savedCounts, sources = {}, {}, {}
        local lastKnownAbsent = {}

        -- A red border can retain a last-checked absence after the bank closes.
        -- Each container must explicitly record zero for this item; a missing key
        -- is unknown, not zero. This display hint never qualifies access checks.
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

        for _, name in ipairs({ "INV", "WORN", "BANK" }) do
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

                -- With many items to ask about (the combat equipment group has
                -- thousands), one pass over the container's slots is far cheaper
                -- than one GetTotal call per item. Items not in any slot are 0.
                local slots = missing > SLOT_SCAN_THRESHOLD and inventory.GetSlots and inventory:GetSlots()

                if slots then
                    local found = {}

                    for _, slot in pairs(slots) do
                        local itemId = slot.obj and slot.obj.id
                        local count = slot.count

                        if type(itemId) == "number" and type(count) == "number" and count > 0 and wanted[itemId] then
                            found[itemId] = (found[itemId] or 0) + count
                        end
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

                return { configId = definition.id, counts = counts }
            end)

            if ok and read then
                self.ownershipCache[name] = read
                sources[name] = "live"

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

                -- Historical locations can contain the SAME moved item. Never sum
                -- them or add them to live counts; they are only a last-seen hint.
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
                -- The belt proves a usable tool, not another tradeable copy.
                -- Do not inflate named-item quantities by adding a virtual stack.
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
        self.questVariables = {}
        self.toolbeltCache = nil
        self.toolbeltVariables = {}

        if self.snapshot then
            self.snapshot:bind(profile)
        end
    end

    -- Read documented quest completion flags and watch only their progress variables.
    -- Unknown native values stay unknown rather than becoming an incomplete quest.
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

            -- Track only this quest's progress variables. Other variable traffic
            -- must not trigger a catalogue-wide refresh.
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

    -- Inventory events invalidate only the affected presence cache. Native item
    -- totals are re-read on demand while a method is visible, never each frame.
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

    -- This may well fire on every XP drop while skilling (not checked in game yet),
    -- so keep the reaction cheap: the UI just re-reads the few skills on screen.
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

        notify("game_state")
    end)

    return self
end

return Account
