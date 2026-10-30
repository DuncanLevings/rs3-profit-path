-- Lasting player-account reads and small manual probes live here. The temporary
-- toolbelt_probe.lua separately owns batched native-config discovery. This file
-- owns the client event subscriptions (inventory, skills, quests, game state) and
-- tells its owner which evidence changed. It never does money maths or decides
-- recommendations.
--
-- Bank data may be unavailable while closed. Readable backpack/worn/bank contents
-- and mapped tool-belt families still don't establish full account ownership.
local Toolbelt = require("src/game/toolbelt")
local Account = {}

-- App supplies the optional snapshot owner and validated tool-belt bindings;
-- isolated native probes can omit them without importing the whole catalogue.
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

        -- Temporary diagnostics state; see the probe section below.
        eventCount = 0,
        lastEvent = "No inventory events observed yet.",
        inspection = nil,
        questInspection = nil,
        lastInventoryName = nil,
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

        self.lastInventoryName = inventoryConfig.configName
        self.eventCount = self.eventCount + 1
        self.lastEvent = kind .. ": " .. inventoryConfig.configName

        -- If the inventory we last read just changed, that read is out of date.
        -- Drop it rather than keep showing old contents as if they were current.
        if self.inspection and self.inspection.configId == inventoryConfig.id then
            self.inspection = nil
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
            return { status = "invalid", message = "Enter a current, non-deprecated quest config name." }
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

        self.inspection = nil
        self.questInspection = nil
        self.lastInventoryName = nil

        subscriptions = {}
    end

    -- Temporary development probes, used only by diagnostics.lua. Remove these
    -- functions and the diagnostics state above together with that module.

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

    function self:readPlayer()
        if not self.active then
            return { status = "stopped" }
        end
        if not Player.IsAvailable() then
            return { status = "unavailable" }
        end

        return {
            status = "available",
            prayer = Player.GetLevelUncapped(SkillType.PRAYER),
            herblore = Player.GetLevelUncapped(SkillType.HERBLORE),
            combat = self:readCombatLevel().level,
        }
    end

    function self:inspectInventory(name)
        if not self.active then
            return { status = "stopped" }
        end
        self.inspection = nil
        if type(name) ~= "string" or not name:match("^[A-Z][A-Z0-9_]*$") then
            return { status = "invalid", message = "Use an inventory config name such as BANK or INV." }
        end
        if not Player.IsAvailable() then
            return { status = "unavailable", message = "Log into a game world first." }
        end

        -- Config resolution and inventory lifetime are the uncertain native boundary.
        -- Preserve the failure reason instead of treating failed reads as an empty bank.
        local ok, result = pcall(function()
            local inventoryConfig = config.Inv[name]
            if not inventoryConfig then
                return { status = "unknown", message = "Inventory config is not available: " .. name }
            end

            local inventory = Inventory.Find(inventoryConfig)
            if not inventory or not inventory.isValid then
                return { status = "unavailable", configId = inventoryConfig.id, message = name .. " is not transmitted." }
            end

            local slots = inventory:GetSlots()
            if not slots then
                return { status = "unavailable", configId = inventoryConfig.id, message = name .. " slots are unavailable." }
            end

            local items = {}
            for slotIndex, slot in pairs(slots) do
                if slot.obj and slot.count > 0 then
                    items[#items + 1] = {
                        slot = slotIndex,
                        itemId = slot.obj.id,
                        name = slot.obj.name,
                        quantity = slot.count,
                    }
                end
            end

            table.sort(items, function(left, right)
                return left.slot < right.slot
            end)

            return {
                status = "available",
                configId = inventoryConfig.id,
                name = name,
                slotCount = inventory.slotCount,
                items = items,
                completeness = "unverified",
            }
        end)

        if not ok then
            result = { status = "error", message = "Inventory read failed: " .. tostring(result) }
        end
        self.inspection = result
        return result
    end

    -- Temporary read-only probe. The config name is verified in Skill Tips, but
    -- its numeric values aren't mapped yet, so this must not qualify equipment.
    function self:inspectToolbeltHatchet()
        if not self.active or not Player.IsAvailable() then
            return { status = "unavailable", message = "Enter a game world first." }
        end

        local ok, result = pcall(function()
            local setting = var.VarPlayer.TOOLBELT_HATCHET_LEVEL

            if not setting then
                return { status = "unknown", message = "The tool-belt hatchet variable is unavailable." }
            end

            local value = setting.value

            if type(value) ~= "number" or value < 0 or value >= math.huge or value % 1 ~= 0 then
                return { status = "unknown", message = "The tool-belt hatchet value is unavailable or not an integer." }
            end

            return { status = "available", value = value, configId = setting.id }
        end)

        if not ok then
            return { status = "error", message = "Tool-belt read failed: " .. tostring(result) }
        end

        return result
    end

    -- Temporary diagnostics wrapper; the native reader above is lasting code.
    function self:inspectQuest(name)
        -- Invalid input and offline reads should clear the previous probe result.
        -- Lasting requirement reads use readQuest without touching this UI state.
        self.questInspection = nil
        local result = self:readQuest(name)

        if result.status ~= "invalid" and result.status ~= "unavailable" and result.status ~= "stopped" then
            self.questInspection = result
        end

        return result
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
        self.inspection = nil
        self.questInspection = nil
        self.lastInventoryName = nil
        self.lastEvent = "Game state changed; inspect inventories again."
        self.ownershipCache = {}

        notify("game_state")
    end)

    return self
end

return Account
