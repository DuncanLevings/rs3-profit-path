-- Account-readiness tests run outside the client. They exercise historical storage,
-- event invalidation and the same requirement/filter code used by the workbench.
return function(test, equal, client, pretty)
    local Snapshot = require("src/storage/account_snapshot")
    local Account = require("src/game/account")
    local Requirements = require("src/game/requirements")
    local ToolbeltProbe = require("src/game/toolbelt_probe")
    local Toolbelt = require("src/game/toolbelt")

    local function key(profile)
        return "profit-path.account.v1/" .. #profile .. ":" .. profile
    end

    test("item snapshots wait for checkpoints and survive reload without retaining caller tables", function()
        local state = client()
        local snapshot = Snapshot.new(PersistentDB)
        snapshot:bind("First")
        local counts = { [42] = 3 }
        snapshot:observe("BANK", counts)
        counts[42] = 99
        equal(state.db[key("First")], nil)
        snapshot:flush()
        equal(state.db[key("First")].containers.BANK["42"], 3)
        equal(snapshot.dirty, false)
        snapshot:observe("BANK", { [42] = 3 })
        equal(snapshot.dirty, false)

        local restored = Snapshot.new(PersistentDB)
        restored:bind("First")
        equal(restored.data.BANK[42], 3)
        equal(restored.dirty, false)
        restored:observe("BANK", { [42] = 4 })
        equal(state.db[key("First")].containers.BANK["42"], 3)
    end)

    test("snapshot profile switches isolate evidence and unbind blocks late writes", function()
        local state = client()
        local snapshot = Snapshot.new(PersistentDB)
        snapshot:bind("First")
        snapshot:observe("INV", { [42] = 2 })
        snapshot:bind("Second")
        equal(state.db[key("First")].containers.INV["42"], 2)
        equal(snapshot.data.INV, nil)
        snapshot:observe("INV", { [42] = 8 })
        snapshot:unbind()
        equal(state.db[key("Second")].containers.INV["42"], 8)
        snapshot:observe("INV", { [42] = 100 })
        equal(snapshot.dirty, false)
        snapshot:bind("First")
        equal(snapshot.data.INV[42], 2)
    end)

    test("corrupt snapshots recover valid containers but protect the stored record", function()
        local state = client()
        local original = { schema = 1, containers = { INV = { ["42"] = 2 }, BANK = { ["43"] = -1 } } }
        state.db[key("First")] = original
        local snapshot = Snapshot.new(PersistentDB)
        snapshot:bind("First")
        equal(snapshot.data.INV[42], 2)
        equal(snapshot.data.BANK, nil)
        equal(snapshot.writable, false)
        assert(snapshot.message)
        snapshot:observe("INV", { [42] = 8 })
        snapshot:flush()
        equal(state.db[key("First")], original)
        equal(original.containers.INV["42"], 2)

        state.db[key("Future")] = { schema = 9, containers = {} }
        snapshot:bind("Future")
        equal(snapshot.writable, false)
    end)

    test("snapshot read failures oversized data and failed writes remain diagnosable", function()
        local state = client()
        local huge = {}

        for i = 1, 4097 do
            huge[tostring(i)] = 1
        end

        state.db[key("Huge")] = { schema = 1, containers = { BANK = huge } }
        local snapshot = Snapshot.new(PersistentDB)
        snapshot:bind("Huge")
        equal(snapshot.writable, false)
        equal(snapshot.data.BANK, nil)
        state.failRead = true
        snapshot:bind("Unreadable")
        equal(snapshot.writable, false)
        state.failRead = false
        snapshot:bind("Retry")
        snapshot:observe("INV", { [42] = 1 })
        state.failWrite = true
        snapshot:flush()
        equal(snapshot.dirty, true)
        assert(snapshot.message)
        state.failWrite = false
        snapshot:flush()
        equal(snapshot.dirty, false)
        equal(snapshot.message, nil)
        equal(state.db[key("Retry")].containers.INV["42"], 1)
    end)

    test("saved containers never add to live counts or to each other", function()
        local state = client()
        local snapshot = Snapshot.new(PersistentDB)
        snapshot:bind("First")
        snapshot:observe("BANK", { [42] = 3 })
        snapshot:observe("WORN", { [42] = 3 })
        local live = { INV = { [42] = 1 } }
        Inventory.Find = function(definition)
            local counts = live[definition.configName]

            if counts then
                return { isValid = true, GetTotal = function(_, id) return counts[id] or 0 end }
            end
        end

        local account = Account.new(function() end, snapshot)
        local result = account:readOwnership({ [42] = true })
        equal(result.counts[42], 1)
        equal(result.savedCounts[42], 3)
        equal(result.complete, false)
        equal(result.sources.BANK, "saved")
        equal(result.sources.INV, "live")
        equal(state.db[key("First")], nil)

        -- A live empty bank replaces its old hint. The worn snapshot remains
        -- historical until that container is read too.
        live.BANK = {}
        result = account:readOwnership({ [42] = true })
        equal(result.savedCounts[42], 3)
        equal(result.sources.BANK, "live")
        live.WORN = {}
        result = account:readOwnership({ [42] = true })
        equal(result.savedCounts[42], nil)
        equal(result.complete, true)
        account:destroy()
        equal(state.db[key("First")].containers.BANK["42"], 0)
    end)

    test("last-checked absence survives a closed bank but not an unchecked ID or positive count", function()
        client()
        local snapshot = Snapshot.new(PersistentDB)
        snapshot:bind("First")
        local bankAvailable = false
        local backpack = 0
        Inventory.Find = function(definition)
            if definition.configName == "BANK" and not bankAvailable then
                return nil
            end

            return { isValid = true, GetTotal = function(_, itemId)
                return definition.configName == "INV" and itemId == 42 and backpack or 0
            end }
        end
        local account = Account.new(function() end, snapshot)
        equal(account:readOwnership({ [42] = true }).lastKnownAbsent[42], false)
        bankAvailable = true
        equal(account:readOwnership({ [42] = true }).lastKnownAbsent[42], true)
        bankAvailable = false
        Event.InventoryRemoved.emit({ inv = config.Inv.BANK })
        local result = account:readOwnership({ [42] = true, [43] = true })
        equal(result.lastKnownAbsent[42], true)
        equal(result.lastKnownAbsent[43], false)
        equal(result.complete, false)
        backpack = 1
        Event.InventoryUpdated.emit({ inv = config.Inv.INV })
        equal(account:readOwnership({ [42] = true }).lastKnownAbsent[42], false)
        account:bindProfile("Second")
        backpack = 0
        equal(account:readOwnership({ [42] = true }).lastKnownAbsent[42], false)
        account:destroy()
    end)

    -- The real discovery path must not depend on ID namespace iteration. Only
    -- documented FromID lookups and enum.values are available in this fixture.
    local function discoveryClient()
        local calls = 0
        id.Enum, id.VarPlayer = nil, nil
        var = { VarPlayer = { FromID = function(index)
            calls = calls + 1

            if index == -7 then
                error("native hole")
            elseif index == -18523 then
                return { id = index, configName = "TOOLBELT_FIXTURE", value = 2,
                    isVarBit = true, baseVar = { id = 20, configName = "FIXTURE_BASE" }, varBitMask = 15 }
            elseif index == -10 then
                return setmetatable({ configName = "TASK_PICKAXE_UNLOCKED" }, { __index = function()
                    error("Unrelated account values must not be read")
                end })
            end
        end } }
        config.Enum = { FromID = function(index)
            calls = calls + 1

            if index == 12 then
                return { id = index, configName = "TOOLBELT_FIXTURE", values = { { 0, 100 }, { 1, 101 }, { 2, 102 } },
                    GetInputValues = function() error("Reverse lookup requires an output value") end }
            end
        end }
        config.Param = { FromID = function() calls = calls + 1 end }
        config.Inv.FromID = function() calls = calls + 1 end

        return function() return calls end
    end

    test("tool-belt discovery batches direct ID reads including negative varbits and all enum pairs", function()
        client()
        local calls = discoveryClient()
        local lines, completed = {}, nil
        local cancel = ToolbeltProbe.start(function(line) lines[#lines + 1] = line end, function() end, function(result) completed = result end)
        equal(calls(), 0)
        Event.Logic.emit({})
        equal(calls(), 100)

        for _ = 1, 1400 do
            Event.Logic.emit({})
        end

        assert(completed)
        equal(completed.status, "complete")
        equal(completed.failures, 1)
        equal(completed.matched, 2)
        equal(completed.scanned, 122005)
        local text = table.concat(lines, "\n")
        assert(text:find("0 -> 100", 1, true))
        assert(text:find("2 -> 102", 1, true))
        assert(text:find("current value: 2", 1, true))
        assert(text:find("FIXTURE_BASE [20]; mask: 15", 1, true))
        assert(not text:find("TASK_PICKAXE_UNLOCKED", 1, true))
        equal(completed.items, nil)
        equal(Event.Logic.count(), 0)
        cancel()
        equal(completed.status, "complete")
    end)

    test("a busy discovery range does not starve enum mappings or later config types", function()
        client()
        discoveryClient()
        local order, completed = {}, nil
        config.Enum.FromID = function(index)
            if index < 128 then
                order[#order + 1] = "Enum"
                return { id = index, configName = "TOOLBELT_MAP_" .. index, values = {}, valueCount = 0 }
            end
        end
        var.VarPlayer.FromID = function(index)
            if index == -1 then
                order[#order + 1] = "VarPlayer"
                return { id = index, configName = "TOOLBELT_PRESENT", value = 1 }
            end
        end
        config.Param.FromID = function(index)
            if index == 1 then
                order[#order + 1] = "Param"
                return { id = index, configName = "TOOLBELT_PARAM" }
            end
        end
        config.Inv.FromID = function(index)
            if index == 1 then
                order[#order + 1] = "Inv"
                return { id = index, configName = "TOOLBELT_INV" }
            end
        end
        ToolbeltProbe.start(function() end, function() end, function(value) completed = value end)

        for _ = 1, 1400 do
            Event.Logic.emit({})
        end

        equal(completed.status, "partial")
        equal(completed.matched, 131)
        equal(order[1], "Enum")
        equal(order[129], "VarPlayer")
        equal(order[130], "Param")
        equal(order[131], "Inv")
        equal(Event.Logic.count(), 0)
    end)

    test("an oversized enum is marked partial without stopping the remaining scan", function()
        client()
        discoveryClient()
        local values, lines, completed = {}, {}, nil

        for index = 1, 129 do
            values[index] = { index, index + 100 }
        end

        config.Enum.FromID = function(index)
            if index == 12 then
                return { id = index, configName = "TOOLBELT_MAP", values = values, valueCount = 129 }
            end
        end
        ToolbeltProbe.start(function(line) lines[#lines + 1] = line end, function() end, function(value) completed = value end)

        for _ = 1, 1400 do
            Event.Logic.emit({})
        end

        equal(completed.status, "partial")
        equal(completed.scanned, 122005)
        equal(completed.matched, 2)
        local text = table.concat(lines, "\n")
        assert(text:find("128 -> 228", 1, true))
        assert(not text:find("129 -> 229", 1, true))
        assert(text:find("current value: 2", 1, true))
        equal(Event.Logic.count(), 0)
    end)

    test("tool-belt discovery cancels on close navigation and shutdown without late native reads", function()
        client()
        local calls = discoveryClient()
        prettyui = pretty()
        gepl = nil
        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1000, height = 740 } })
        prettyui:findButton("Diagnostics")()
        prettyui:findButton("Inspect tool-belt metadata")()
        equal(Event.Logic.count(), 2)
        Event.Logic.emit({})
        equal(calls(), 100)
        prettyui.windows[1]:Close()
        equal(Event.Logic.count(), 0)
        Event.Logic.emit({})
        equal(calls(), 100)
        prettyui:findButton("Open Profit Path")()
        prettyui:findButton("Inspect tool-belt metadata")()
        prettyui:findButton("Back to methods")()
        equal(Event.Logic.count(), 1)
        Event.Logic.emit({})
        equal(calls(), 100)
        prettyui:findButton("Diagnostics")()
        prettyui:findButton("Inspect tool-belt metadata")()
        PluginShutdown()
        equal(Event.Logic.count(), 0)
        Event.Logic.emit({})
        equal(calls(), 100)
    end)

    test("tool-belt discovery skips offline reads and stops if the player becomes unavailable", function()
        local state = client()
        local calls = discoveryClient()
        local result
        state.available = false
        ToolbeltProbe.start(function() end, function() end, function(value) result = value end)
        equal(result.status, "unavailable")
        equal(calls(), 0)
        state.available = true
        ToolbeltProbe.start(function() end, function() end, function(value) result = value end)
        state.available = false
        Event.Logic.emit({})
        equal(result.status, "cancelled")
        equal(calls(), 0)
        equal(Event.Logic.count(), 0)
    end)

    -- Native mappings from the supplied metadata, not special cases in runtime.
    -- Tests mutate the native variables to exercise upgrades and removal events.
    local function toolbeltClient()
        local settings = {
            TOOLBELT_HATCHET = { id = -2986, value = 1, isVarBit = true, baseVar = { id = 1102 } },
            TOOLBELT_HATCHET_LEVEL = { id = -18523, value = 0, isVarBit = true, baseVar = { id = 7903 } },
            TOOLBELT_PICKAXE = { id = -2984, value = 1, isVarBit = true, baseVar = { id = 1102 } },
            TOOLBELT_PICKAXE_LEVEL = { id = -18522, value = 5, isVarBit = true, baseVar = { id = 7903 } },
            TOOLBELT_MATTOCK = { id = -46000, value = 1, isVarBit = true, baseVar = { id = 1102 } },
        }
        local hatchets = { 1351, 1349, 1353, 1361, 1355, 1357, 1359, 6739, 58073, 58075, 32645, 58077, 54890, 58079, 58244, 58081, 58247 }
        local definitions = require("src/data/method_data").items
        local calls = 0
        var = { VarPlayer = settings }
        config.Enum = {}

        for _, name in ipairs({ "TOOLBELT_HATCHETS", "TOOLBELT_PICKAXES", "TOOLBELT_MATTOCKS" }) do
            config.Enum[name] = {
                configName = name, inputValueType = 0, outputValueType = 33,
                GetOutputValue = function(_, key)
                    calls = calls + 1
                    local itemId, itemName

                    if name == "TOOLBELT_HATCHETS" then
                        itemId = hatchets[key + 1]
                        itemName = itemId and definitions[tostring(itemId)].name
                    elseif name == "TOOLBELT_PICKAXES" and key == 5 then
                        itemId, itemName = 45467, "Steel pickaxe"
                    elseif name == "TOOLBELT_MATTOCKS" and key == 0 then
                        itemId, itemName = 49539, "Bronze mattock"
                    end

                    return itemId and { id = itemId, name = itemName } or nil
                end,
            }
        end

        return settings, hatchets, function() return calls end
    end

    test("tool-belt reader uses native mappings for every listed hatchet and verified family offsets", function()
        client()
        local settings, hatchets = toolbeltClient()
        local bindings = require("src/data/method_data").toolbelt
        local first = Toolbelt.read(bindings)
        equal(first.slots.hatchet.itemId, 1351)
        equal(first.slots.pickaxe.itemId, 45467)
        equal(first.slots.mattock.itemId, 49539)
        equal(first.complete, true)
        assert(first.watched[1102] and first.watched[7903] and first.watched[-18523])

        for index, itemId in ipairs(hatchets) do
            settings.TOOLBELT_HATCHET_LEVEL.value = index - 1
            local result = Toolbelt.read(bindings)
            equal(result.slots.hatchet.itemId, itemId)
            equal(result.counts[itemId], 1)
        end
    end)

    test("tool-belt presence guards zero keys and unknown selections never become bronze", function()
        client()
        local settings = toolbeltClient()
        local bindings = require("src/data/method_data").toolbelt
        settings.TOOLBELT_HATCHET.value = 0
        local absent = Toolbelt.read(bindings)
        equal(absent.slots.hatchet.status, "available")
        equal(absent.counts[1351], nil)
        settings.TOOLBELT_HATCHET.value = 1

        for _, value in ipairs({ -1, "0", math.huge, 0/0, 99 }) do
            settings.TOOLBELT_HATCHET_LEVEL.value = value
            local result = Toolbelt.read(bindings)
            equal(result.slots.hatchet.status, "unknown")
            equal(result.counts[1351], nil)
            equal(result.complete, false)
            equal(result.slots.pickaxe.itemId, 45467)
        end

        settings.TOOLBELT_MATTOCK.value = 0
        equal(Toolbelt.read(bindings).slots.mattock.status, "unknown")
    end)

    test("tool-belt native failures and changed enums remain visible without erasing other families", function()
        client()
        toolbeltClient()
        local bindings = require("src/data/method_data").toolbelt
        config.Enum.TOOLBELT_HATCHETS.outputValueType = 73
        local changed = Toolbelt.read(bindings)
        equal(changed.slots.hatchet.status, "unknown")
        equal(changed.counts[1351], nil)
        equal(changed.slots.pickaxe.itemId, 45467)
        assert(changed.message)
        config.Enum.TOOLBELT_HATCHETS.outputValueType = 33
        config.Enum.TOOLBELT_HATCHETS.GetOutputValue = function() error("native enum failure") end
        local failed = Toolbelt.read(bindings)
        equal(failed.slots.hatchet.status, "error")
        assert(failed.message:find("native enum failure", 1, true))
        equal(failed.counts[49539], 1)
    end)

    test("account caches tool-belt evidence invalidates watched base vars and avoids virtual quantity inflation", function()
        client()
        local settings, _, calls = toolbeltClient()
        local inventoryReads, updates = 0, 0
        Inventory.Find = function(definition)
            return { isValid = true, GetTotal = function(_, itemId)
                inventoryReads = inventoryReads + 1
                return definition.configName == "INV" and itemId == 1351 and 1 or 0
            end }
        end
        local account = Account.new(function(reason)
            equal(reason, "inventory")
            updates = updates + 1
        end, nil, require("src/data/method_data").toolbelt)
        local wanted = { [1351] = true, [1359] = true }
        equal(account:readOwnership(wanted).counts[1351], 1)
        local baselineReads, baselineCalls = inventoryReads, calls()
        account:readOwnership(wanted)
        equal(calls(), baselineCalls)
        Event.VarTransmit.emit({ var = { id = 999999 } })
        equal(updates, 0)
        settings.TOOLBELT_HATCHET_LEVEL.value = 6
        Event.VarTransmit.emit({ var = { id = 7903 } })
        equal(updates, 1)
        local result = account:readOwnership(wanted)
        equal(result.counts[1359], 1)
        equal(result.lastKnownAbsent[1359], false)
        equal(inventoryReads, baselineReads)
        equal(calls(), baselineCalls + 3)
        local afterUpdate = calls()
        account:bindProfile("Other")
        account:readOwnership(wanted)
        equal(calls(), afterUpdate + 3)
        account:destroy()
        equal(Event.VarTransmit.count(), 0)
        equal(account:readToolbelt().complete, false)
    end)

    test("tool-belt evidence never becomes a saved inventory or bank count", function()
        local state = client()
        toolbeltClient()
        Inventory.Find = function()
            return { isValid = true, GetTotal = function() return 0 end }
        end
        local snapshot = Snapshot.new(PersistentDB)
        local account = Account.new(function() end, snapshot, require("src/data/method_data").toolbelt)
        account:bindProfile("First")
        equal(account:readOwnership({ [1351] = true }).counts[1351], 1)
        account:destroy()

        for _, container in ipairs({ "INV", "WORN", "BANK" }) do
            equal(state.db[key("First")].containers[container]["1351"], 0)
        end
    end)

    test("source tool matching compares cutting power and use levels rather than combat tiers", function()
        client()
        local evidence = { equipment = require("src/data/method_data").equipment,
            skills = { WOODCUTTING = { status = "available", level = 60 } },
            items = {
                [6739] = { status = "available", quantity = 1, toolbelt = true },
                [58073] = { status = "available", quantity = 1 },
                [1359] = { status = "available", quantity = 1 },
            },
        }
        local requirement = { kind = "gear", equipment_group = "hatchet", text = "Use your highest-tier hatchet" }
        local result = Requirements.evaluate(requirement, evidence)
        equal(result.evidence[1].itemId, 6739)
        equal(result.evidence[1].tier, 63)
        equal(result.evidence[1].toolbelt, true)
        evidence.skills.WOODCUTTING.level = 55
        equal(Requirements.evaluate(requirement, evidence).evidence[1].itemId, 1359)
    end)

    test("the actual Requirements page shows a tool-belt hatchet and follows upgrades without rebuilding", function()
        client()
        local settings = toolbeltClient()
        SkillType.WOODCUTTING = 8
        prettyui = pretty()
        gepl = nil
        Inventory.Find = function(definition)
            if definition.configName ~= "BANK" then
                return { isValid = true, GetTotal = function() return 0 end }
            end
        end
        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1000, height = 740 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findMethod("Cutting elder logs")()
        local detail = prettyui.views[#prettyui.views]
        local page = detail.tabs[1].pages[2]

        local function match(itemId)
            for _, section in ipairs(page.children) do
                for _, slot in ipairs(section.items or {}) do
                    if not slot.destroyed and slot.object.id == itemId then
                        return slot
                    end
                end
            end
        end

        local original = match(1351)
        assert(original)
        equal(original.tooltip, "Bronze hatchet")
        local foundLabel = false

        for _, label in ipairs(page:allTexts()) do
            foundLabel = foundLabel or label.content == "On your tool belt"
        end

        assert(foundLabel)
        settings.TOOLBELT_HATCHET_LEVEL.value = 6
        Event.VarTransmit.emit({ var = { id = 7903 } })
        assert(match(1359))
        assert(original.destroyed)
        assert(not detail.destroyed)
        equal(match(1359).tooltip, "Rune hatchet")
        PluginShutdown()
    end)

    test("named equipment minima show a missing icon then switch to the actual owned upgrade", function()
        client()
        toolbeltClient()
        prettyui = pretty()
        gepl = nil
        local bankAvailable, ownsUpgrade = false, false
        Inventory.Find = function(definition)
            if definition.configName == "BANK" and not bankAvailable then
                return nil
            end

            return { isValid = true, GetTotal = function(_, itemId)
                return definition.configName == "INV" and itemId == 34772 and ownsUpgrade and 1 or 0
            end }
        end
        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1000, height = 740 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findMethod("Killing abyssal demons")()
        local page = prettyui.views[#prettyui.views].tabs[1].pages[2]
        local function find(itemId)
            for _, section in ipairs(page.children) do
                for _, slot in ipairs(section.items or {}) do
                    if not slot.destroyed and slot.object.id == itemId then
                        for _, border in ipairs(section.rectangles or {}) do
                            if not border.destroyed and border.x == slot.options.x and border.y == slot.options.y then
                                return slot, border
                            end
                        end
                    end
                end
            end
        end
        local minimum, border = find(34769)
        assert(minimum and border)
        equal(minimum.tooltip, "Spring cleaner 2000")
        local Style = require("src/ui/view_style")
        equal(border.rgba, Style.muted)
        bankAvailable = true
        Event.InventoryAdded.emit({ inv = config.Inv.BANK })
        equal(border.rgba, Style.bad)
        bankAvailable = false
        Event.InventoryRemoved.emit({ inv = config.Inv.BANK })
        equal(border.rgba, Style.bad)
        ownsUpgrade = true
        Event.InventoryUpdated.emit({ inv = config.Inv.INV })
        local upgrade, ownedBorder = find(34772)
        assert(upgrade and minimum.destroyed)
        equal(upgrade.tooltip, "Spring cleaner 9000")
        equal(ownedBorder.rgba, Style.good)
        PluginShutdown()
    end)

    test("historical gear absence is only a display hint and does not fabricate owned minimum evidence", function()
        local check = { kind = "gear", text = "Minimum tool", minimum_tier = 80, minimum_item_id = 42, equipment_group = "fixture" }
        local evidence = { equipment = { fixture = { complete = false, candidates = {
            { item_id = 42, tier = 80, skills = {} }, { item_id = 43, tier = 90, skills = {} },
        } } }, items = { [42] = { status = "unknown", lastKnownAbsent = true }, [43] = { status = "unknown", lastKnownAbsent = true } } }
        local checked = Requirements.evaluate(check, evidence)
        equal(checked.status, "unknown")
        equal(checked.lastKnownAbsent, true)
        equal(#checked.evidence, 0)
        evidence.items[43].lastKnownAbsent = false
        equal(Requirements.evaluate(check, evidence).lastKnownAbsent, false)
    end)

    test("quest updates watch only mapped progress variables and stop on session change", function()
        client()
        local updates = 0
        config.Quest.FIXTURE_QUEST.masterQuestVars = { { varPlayer = { id = 321 } } }
        local account = Account.new(function(reason)
            equal(reason, "quests")
            updates = updates + 1
        end)
        equal(account:readQuest("FIXTURE_QUEST").completed, true)
        equal(account.questInspection, nil)
        Event.VarTransmit.emit({ var = { id = 999 } })
        equal(updates, 0)
        Event.VarTransmit.emit({ var = { id = 321 } })
        equal(updates, 1)
        config.Quest.FIXTURE_QUEST.hasFinishedQuest = false
        equal(account:readQuest("FIXTURE_QUEST").completed, false)
        account:bindProfile("Another")
        Event.VarTransmit.emit({ var = { id = 321 } })
        equal(updates, 1)
        account:destroy()
        equal(Event.VarTransmit.count(), 0)
    end)

    test("tool-belt probe reports raw values without inferring an owned hatchet", function()
        local state = client()
        local reads = 0
        var = { VarPlayer = setmetatable({}, { __index = function(_, name)
            equal(name, "TOOLBELT_HATCHET_LEVEL")
            reads = reads + 1
            return { id = -18523, value = 7 }
        end }) }
        local account = Account.new(function() end)
        state.available = false
        equal(account:inspectToolbeltHatchet().status, "unavailable")
        equal(reads, 0)
        state.available = true
        local result = account:inspectToolbeltHatchet()
        equal(result.value, 7)
        equal(result.itemId, nil)
        var.VarPlayer = setmetatable({}, { __index = function() error("native failure") end })
        equal(account:inspectToolbeltHatchet().status, "error")
        account:destroy()
        equal(account:inspectToolbeltHatchet().status, "unavailable")
    end)

    -- Deliberately synthetic: these verify the matching rules, not actual game
    -- tiers. Shipped tools and their use levels are verified separately in data.
    local function equipmentFixture()
        local check = { kind = "gear", text = "T80+ melee body", equipment_group = "test", minimum_tier = 80, style = "melee", slot = "body" }
        local evidence = { skills = { DEFENCE = { status = "available", level = 85 } }, items = {}, equipment = {
            test = { complete = true, candidates = {
                { item_id = 1, tier = 70, style = "melee", slot = "body", skills = {} },
                { item_id = 2, tier = 80, style = "melee", slot = "body", skills = { DEFENCE = 80 } },
                { item_id = 3, tier = 90, style = "melee", slot = "body", skills = { DEFENCE = 90 } },
                { item_id = 4, tier = 99, style = "ranged", slot = "body", skills = {} },
                { item_id = 5, tier = 99, style = "melee", slot = "legs", skills = {} },
            } },
        } }

        for i = 1, 5 do
            evidence.items[i] = { status = "available", quantity = 1, complete = true }
        end

        return check, evidence
    end

    test("equipment matching respects minimum tier style slot and use levels", function()
        local check, evidence = equipmentFixture()
        local result = Requirements.evaluate(check, evidence)
        equal(result.status, "met")
        equal(result.evidence[1].itemId, 2)
        equal(result.text, check.text)
        evidence.skills.DEFENCE.level = 99
        equal(Requirements.evaluate(check, evidence).evidence[1].itemId, 3)
        evidence.items[2].quantity = 0
        evidence.items[3].quantity = 0
        equal(Requirements.evaluate(check, evidence).status, "unmet")
        evidence.equipment.test.complete = false
        equal(Requirements.evaluate(check, evidence).status, "unknown")
    end)

    test("saved equipment and unknown levels cannot prove readiness", function()
        local check, evidence = equipmentFixture()
        evidence.items[2] = { status = "unknown", savedQuantity = 1, complete = false }
        evidence.items[3].quantity = 0
        local result = Requirements.evaluate(check, evidence)
        equal(result.status, "unknown")
        equal(result.evidence[1].itemId, 2)
        equal(result.evidence[1].saved, true)
        evidence.skills.DEFENCE = nil
        equal(Requirements.evaluate(check, evidence).status, "unknown")
        evidence.items[2] = { status = "available", quantity = math.huge, complete = true }
        evidence.skills.DEFENCE = { status = "available", level = 99 }
        equal(Requirements.evaluate(check, evidence).status, "unknown")
    end)

    test("saved named items stay unknown and an owned alternative can satisfy ANY", function()
        local required = { kind = "item", text = "A", itemId = 42, quantity = 1 }
        local evidence = { items = { [42] = { status = "unknown", savedQuantity = 3 } } }
        local result = Requirements.evaluate(required, evidence)
        equal(result.status, "unknown")
        equal(result.evidence[1].saved, true)
        evidence.items[43] = { status = "available", quantity = 1, complete = false }
        local alternatives = { kind = "any", text = "Either", children = {
            required, { kind = "item", text = "B", itemId = 43, quantity = 1 },
        } }
        equal(Requirements.evaluate(alternatives, evidence).status, "met")
    end)

    -- Integration: use the actual entry point so evidence refresh and Browse
    -- cannot accidentally drift into separate caches.
    test("browse readiness follows live levels and inventory changes without reopening", function()
        client()
        prettyui = pretty()
        gepl = nil
        SkillType.WOODCUTTING = 8
        SkillType.SLAYER = 18
        local woodcutting = 80
        local originalLevel = Player.GetLevelUncapped
        Player.GetLevelUncapped = function(skill)
            return skill == 8 and woodcutting or originalLevel(skill)
        end
        local hasHatchet = false
        Inventory.Find = function(definition)
            return { isValid = true, GetTotal = function(_, id)
                return definition.configName == "INV" and id == 1359 and hasHatchet and 1 or 0
            end }
        end

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1000, height = 740 } })
        prettyui:findButton("Open Profit Path")()
        equal(pcall(function() prettyui:findButton("All readiness") end), false)
        equal(pcall(function() prettyui:findButton("Access met") end), false)
        assert(prettyui:findMethod("Cutting elder logs"))

        local header = prettyui.views[2].children[2]
        local requirementsFilter = header.nativeLists[5]
        equal(requirementsFilter.entries.All, 0)
        equal(requirementsFilter.entries.Met, 1)
        equal(requirementsFilter.x, header.nativeLists[4].x + 140)
        equal(requirementsFilter.y, header.nativeLists[4].y)
        requirementsFilter:SetEntrySelected(1, true)
        Event.Logic.emit({})
        assert(not prettyui:findMethod("Cutting elder logs"))
        assert(prettyui:findMethod("Smelting steel bars"))

        for _, label in ipairs(prettyui.views[2]:allTexts()) do
            assert(label.content ~= "Access met" and label.content ~= "Missing requirements" and label.content ~= "Needs checking")
        end

        woodcutting = 99
        hasHatchet = true
        Event.SkillTransmit.emit({})
        Event.InventoryUpdated.emit({ inv = config.Inv.INV })
        assert(prettyui:findMethod("Cutting elder logs"))
        prettyui:findMethod("Cutting elder logs")()
        local detail = prettyui.views[#prettyui.views]
        local lines = {}

        for _, label in ipairs(detail.tabs[1].pages[2]:allTexts()) do
            lines[#lines + 1] = label.content
        end

        assert(table.concat(lines, "\n"):find("Usable owned match", 1, true))

        -- A match disappearing removes only its own slot. No requirement ever
        -- receives a decorative empty inventory box, and returning creates one slot.
        local function hatchetSlots()
            local count = 0

            for _, section in ipairs(detail.tabs[1].pages[2].children) do
                for _, slot in ipairs(section.items or {}) do
                    if not slot.destroyed then
                        assert(slot.object, "No empty equipment slots")

                        if slot.object.id == 1359 then
                            count = count + 1
                        end
                    end
                end
            end

            return count
        end

        equal(hatchetSlots(), 1)
        hasHatchet = false
        Event.InventoryUpdated.emit({ inv = config.Inv.INV })
        equal(hatchetSlots(), 0)
        hasHatchet = true
        Event.InventoryUpdated.emit({ inv = config.Inv.INV })
        equal(hatchetSlots(), 1)
        PluginShutdown()

        for _, sourceEvent in pairs(Event) do
            equal(sourceEvent.count(), 0)
        end
    end)

    test("closing checkpoints bank evidence and reload shows only a historical hint", function()
        local state = client()
        prettyui = pretty()
        gepl = nil
        SkillType.WOODCUTTING = 8
        Inventory.Find = function(definition)
            return { isValid = true, GetTotal = function(_, id)
                return definition.configName == "BANK" and id == 1359 and 1 or 0
            end }
        end

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1000, height = 740 } })
        prettyui:findButton("Open Profit Path")()
        equal(state.db[key("Default")], nil)
        prettyui.windows[1]:Close()
        equal(state.db[key("Default")].containers.BANK["1359"], 1)
        PluginShutdown()

        -- Reload with an unreadable bank: do not infer the same hatchet still
        -- exists there, even though the saved record knows its last location.
        local database = state.db
        client(database)
        prettyui = pretty()
        SkillType.WOODCUTTING = 8
        Inventory.Find = function(definition)
            if definition.configName ~= "BANK" then
                return { isValid = true, GetTotal = function() return 0 end }
            end
        end

        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1000, height = 740 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findMethod("Cutting elder logs")()
        local requirements = prettyui.views[#prettyui.views].tabs[1].pages[2]
        local foundHint = false

        for _, label in ipairs(requirements:allTexts()) do
            foundHint = foundHint or label.content == "Saved match - verify in game"
        end

        assert(foundHint)
        PluginShutdown()
    end)

    test("a mapped quest changes its method requirement colour on the native event", function()
        client()
        prettyui = pretty()
        gepl = nil
        config.Quest.TEMPLE_AT_SENNTISTEN = {
            name = "The Temple at Senntisten", deprecated = false,
            hasFinishedQuest = false, hasStartedQuest = true,
            masterQuestVars = { { varPlayer = { id = 333 } } },
        }
        dofile("main.lua")
        Event.ContentLayerReady.emit({ component = { width = 1000, height = 740 } })
        prettyui:findButton("Open Profit Path")()
        prettyui:findMethod("Killing abyssal demons")()
        local requirements = prettyui.views[#prettyui.views].tabs[1].pages[2]
        local questLabel

        for _, label in ipairs(requirements:allTexts()) do
            if label.content:find("Temple at Senntisten", 1, true) then
                questLabel = label
            end
        end

        assert(questLabel)
        local Style = require("src/ui/view_style")
        equal(questLabel.rgba, Style.bad)
        config.Quest.TEMPLE_AT_SENNTISTEN.hasFinishedQuest = true
        Event.VarTransmit.emit({ var = { id = 333 } })
        equal(questLabel.rgba, Style.good)
        PluginShutdown()
    end)

end
