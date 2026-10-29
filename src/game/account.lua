-- Everything we read about the player's own account goes through here. This file
-- owns the client event subscriptions (inventory, skills, game state) and tells its
-- owner when something changed, passing a reason: "skills", "inventory" or
-- "game_state". It never does money maths or decides recommendations.
--
-- Bank data may be unavailable while closed. Item borders only describe readable
-- backpack, worn gear and bank contents; they never establish full account ownership.
local Account = {}

function Account.new(onChanged)
    local self = {
        active = true,

        -- Temporary diagnostics state; see the probe section below.
        eventCount = 0,
        lastEvent = "No inventory events observed yet.",
        inspection = nil,
        questInspection = nil,
        lastInventoryName = nil,
        ownershipCache = {},
    }

    -- Every event we subscribe to, so destroy() can unsubscribe all of them.
    local subscriptions = {}

    -- Only pass changes on while we're alive; after shutdown, stay quiet.
    local function notify(reason)
        if self.active then
            onChanged(reason)
        end
    end

    local function subscribe(event, callback)
        event.Subscribe("profit-path-account", callback)
        subscriptions[#subscriptions + 1] = event
    end

    local function inventoryChanged(kind, event)
        if not self.active then
            return
        end

        local inventoryConfig = event.inv

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

    -- Read only the requested item totals, caching them until that inventory
    -- changes. INV/WORN/BANK are verified config names (also used by Skill Tips).
    -- Completeness here covers these three containers, not Diango or other stores.
    function self:readOwnership(wanted)
        local totals = {}

        if next(wanted) == nil then
            return { counts = totals, complete = false }
        end

        local complete = self.active and Player.IsAvailable()

        if not complete then
            return { counts = totals, complete = false }
        end

        for _, name in ipairs({ "INV", "WORN", "BANK" }) do
            local snapshot = self.ownershipCache[name]
            local ok, read = pcall(function()
                local definition = config.Inv[name]
                local inventory = definition and Inventory.Find(definition)

                if not inventory or not inventory.isValid then
                    return nil
                end

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

                for itemId in pairs(wanted) do
                    totals[itemId] = (totals[itemId] or 0) + read.counts[itemId]
                end
            else
                self.ownershipCache[name] = nil
                complete = false
            end
        end

        return { counts = totals, complete = complete }
    end

    -- Safe to call twice. Unsubscribes first, so no event can arrive mid-teardown.
    function self:destroy()
        if not self.active then
            return
        end

        self.active = false
        self.ownershipCache = {}

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

    -- Completion flags need comparison with the quest journal.
    function self:inspectQuest(name)
        if not self.active then
            return { status = "stopped" }
        end
        self.questInspection = nil
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
        self.questInspection = result
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
