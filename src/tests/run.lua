-- Profit Path's Lua behavior tests. src/tools/test.py runs this file inside an embedded
-- Lua 5.4, outside the game.
--
-- There's no real client here, so we build fakes: client() swaps in pretend versions
-- of the game globals (Player, Event, PersistentDB...) and pretty() is a pretend
-- PrettyUI that records what got drawn. The tests then poke the real plugin code
-- and check what it did.
--
-- Passing here means the logic is right. It doesn't prove anything renders or
-- behaves correctly in the real client; that still needs checking in game.
local Account = require("src/game/account")
local Income = require("src/methods/income")
local UI = require("src/ui/workbench")
local Requirements = require("src/game/requirements")

local passed = 0

local function equal(actual, expected)
    assert(actual == expected, "Expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

-- Runs one test. The first failure stops everything, with the test's name attached.
local function test(name, callback)
    local ok, failure = pcall(callback)

    if not ok then
        error(name .. ": " .. tostring(failure), 0)
    end

    passed = passed + 1
    print("PASS " .. name)
end

-- A fake client event. Like the real one, it allows one handler per name. It also
-- lets tests fire the event (emit) and count live handlers, which is how we check
-- that shutdown really unsubscribed everything.
local function event()
    local handlers = {}

    return {
        Subscribe = function(name, callback)
            assert(not handlers[name], "Duplicate subscription: " .. name)
            handlers[name] = callback
        end,

        Unsubscribe = function(name)
            handlers[name] = nil
        end,

        emit = function(payload)
            for _, callback in pairs(handlers) do
                callback(payload)
            end
        end,

        count = function()
            local count = 0

            for _ in pairs(handlers) do
                count = count + 1
            end

            return count
        end,
    }
end

-- Installs a fresh fake game client as globals and returns its `state` table.
-- Tests flip fields on `state` to simulate things: state.available = false for
-- logged out, state.failWrite = true for a storage failure, and so on.
-- `database` optionally pre-fills PersistentDB, to simulate a reload.
local function client(database)
    local state = { available = true, permitted = false, identity = nil, inventory = nil, reads = 0, db = database or {} }

    Event = {}

    for _, name in ipairs({ "InventoryAdded", "InventoryUpdated", "InventoryRemoved", "SkillTransmit", "GameStateChanged", "ContentLayerReady", "Logic" }) do
        Event[name] = event()
    end

    -- Fixture IDs are arbitrary; only BANK/INV names are used by production code.
    config = { Inv = { BANK = { id = 100, configName = "BANK" }, INV = { id = 101, configName = "INV" }, WORN = { id = 102, configName = "WORN" } } }
    config.Quest = { FIXTURE_QUEST = {
        name = "Fixture quest", deprecated = false, hasFinishedQuest = true, hasStartedQuest = true,
    } }

    -- Fake levels: Prayer (5) is 92, every other skill is 96.
    Player = {
        IsAvailable = function()
            state.reads = state.reads + 1
            return state.available
        end,

        -- Booby-trapped: the plugin must never read tracking IDs, so this throws.
        GetTrackingID = function()
            error("Tracking ID reads are disabled after the reported client crash")
        end,

        GetLevelUncapped = function(skill)
            assert(state.available, "Skill read while logged out")
            return skill == 5 and 92 or 96
        end,
        GetEntity = function()
            return { isValid = state.available, displayName = state.characterName or "Fixture" }
        end,
    }

    SkillType = { PRAYER = 5, HERBLORE = 15, SMITHING = 13 }

    -- In-memory PersistentDB. The fail* flags let tests simulate storage errors:
    -- reads throw, while writes and deletes return false like a failed native call.
    PersistentDB = {
        GetString = function(_, key)
            if state.failRead then
                error("Storage read failed")
            end

            return type(state.db[key]) == "string" and state.db[key] or nil
        end,

        GetStructuredData = function(_, key)
            if state.failRead then
                error("Storage read failed")
            end

            return type(state.db[key]) == "table" and state.db[key] or nil
        end,

        CheckExists = function(_, key)
            if state.failRead then
                error("Storage read failed")
            end

            return state.db[key] ~= nil
        end,

        SetString = function(_, key, value)
            if state.failWrite then
                return false
            end

            state.db[key] = value
            return true
        end,

        SetStructuredData = function(_, key, value)
            if state.failWrite then
                return false
            end

            state.db[key] = value
            return true
        end,

        Delete = function(_, key)
            if state.failDelete then
                return false
            end

            state.db[key] = nil
            return true
        end,
    }

    PluginPermissions = { trackingAccess = "trackingAccess" }
    Plugin = { HasPermission = function()
        return state.permitted
    end }

    -- The fake exposes only the rsprite API we use: name lookups, plus drawing one
    -- native sprite (the coin). No search index or startup work should be requested
    -- for this fixed set of icons. Every name in data/icons.lua gets a made-up ID.
    local spriteIDs = {}
    state.spriteLookups = {}
    local nextSpriteID = 1000

    for _, name in pairs(require("data/icons")) do
        spriteIDs[name] = nextSpriteID
        nextSpriteID = nextSpriteID + 1
    end

    -- A native sprite as rsprite returns it. It records where it was moved to, and
    -- belongs to the PrettyUI view whose native `.content` layer it was drawn on.
    local function nativeSprite(parent, source, options)
        assert(parent.testOwner, "Native sprites must be drawn on a view's content layer")

        local sprite = { source = source, options = options, x = options.x, y = options.y }

        function sprite:SetPos(x, y)
            self.x, self.y = x, y
        end

        parent.testOwner.nativeSprites = parent.testOwner.nativeSprites or {}
        table.insert(parent.testOwner.nativeSprites, sprite)

        return sprite
    end

    rsprite = {
        version = "0.1.2",

        Get = function(name)
            assert(type(name) == "string", "rsprite.Get expects a native sprite name")
            state.spriteLookups[name] = (state.spriteLookups[name] or 0) + 1
            return spriteIDs[name]
        end,

        Draw = function(parent, name, options)
            return nativeSprite(parent, { name = name }, options), 1
        end,
    }

    -- Fake font measurement: 7 units per character is close enough for checking
    -- that a coin moves when the number next to it gets longer.
    local font = { GetStringWidth = function(_, text)
        return #text * 7
    end }

    config.Font = { MUSEO_SANS_15PT_REGULAR = font, CINZEL_13PT_BOLD = font }

    -- Whatever a test puts in state.inventory is what every inventory lookup returns.
    Inventory = { Find = function()
        return state.inventory
    end }

    -- The game area our window hangs off. Tests can set state.gameArea = nil to
    -- simulate it not existing.
    state.gameArea = { width = 1280, height = 900, interfaceID = 1 }
    id = { Component = { TOPLEVEL_V2__GAME_AREA = 123 }, StyleSheet = { DROPDOWN_DEFAULT = 456 } }
    ui = { Interfaces = { GetComponent = function(_, componentId)
        equal(componentId, id.Component.TOPLEVEL_V2__GAME_AREA)
        return state.gameArea
    end } }

    -- Plain native sprites (the coin). They record the item and quantity they were
    -- given, and land in the same nativeSprites list as rsprite's drawings.
    ui.ObjectQuantityDisplayMode = { NEVER = "never", ALWAYS = "always", MULTIPLE = "multiple" }
    ui.Sprite = { new = function(parent)
        local sprite = nativeSprite(parent, {}, {})

        function sprite:SetSize(width, height)
            self.width, self.height = width, height
        end

        -- Like the real client: only the one-argument form exists, even though
        -- the docs list an optional quantity.
        function sprite:SetAssociatedObject(itemId, quantity)
            if quantity ~= nil then
                error("sol: no matching function call takes this number of arguments and the specified types")
            end

            self.source = { item = itemId }
        end

        return sprite
    end }

    ui.Hook = { ONSELECTIONCHANGED = "selection" }
    ui.AlignMode = { BOTTOMRIGHT = "right", CENTRE = "centre" }
    ui.Rectangle = { new = function(parent)
        local rectangle = {}

        function rectangle:SetPos(x, y)
            self.x, self.y = x, y
        end

        function rectangle:SetSize(width, height)
            self.width, self.height = width, height
        end

        parent.testOwner.rectangles = parent.testOwner.rectangles or {}
        table.insert(parent.testOwner.rectangles, rectangle)

        return rectangle
    end }
    ui.SelectionChangeEvent = { SELECTED = 1, DESELECTED = 0 }
    ui.List = { new = function(parent)
        local list = { selectedID = nil, entries = {} }
        parent.testOwner.nativeLists = parent.testOwner.nativeLists or {}
        table.insert(parent.testOwner.nativeLists, list)

        function list:SetPos(x, y)
            self.x, self.y = x, y
        end

        function list:SetSize(width, height)
            self.width, self.height = width, height
        end

        function list:SetEntries(entries, selectedID)
            self.entries = entries
            self.selectedID = selectedID
            return true
        end

        -- In game, selecting ID 1 highlighted the second entry: the client counts
        -- entries from 0. Insist our IDs follow that, so 1-based IDs fail here.
        function list:Add(label, id)
            self.count = (self.count or 0) + 1
            equal(id, self.count - 1, "Dropdown entry IDs must count from 0 in list order")

            self.entries[label] = id
            return true
        end

        function list:GetEntrySelected(id)
            return self.selectedID == id
        end

        function list:Subscribe(_, callback)
            self.callback = callback
        end

        -- Native lists report both deselection and selection. Reproduce those
        -- events, including on programmatic rollback after a failed settings save.
        function list:SetEntrySelected(id, selected)
            self.selectionWrites = (self.selectionWrites or 0) + 1
            if not selected or self.selectedID == id then
                return true
            end

            local previous = self.selectedID
            if self.callback then
                self.callback(self, previous, ui.SelectionChangeEvent.DESELECTED)
                self.callback(self, id, ui.SelectionChangeEvent.SELECTED)
            end

            -- Reproduce the client's problematic ordering: the hook can precede
            -- the update of the selected-entry collection.
            self.selectedID = id
            -- The real client's selectedEntries holds plain numbers that don't
            -- reliably match our entry IDs, so the fake makes them useless on
            -- purpose: code must ask GetEntrySelected(id) instead.
            self.selectedEntries = { id + 1 }

            return true
        end

        return list
    end }

    -- Item configs for every catalogue item.
    config.Obj = { FromID = function(itemId)

        local item = require("data/methods").items[tostring(itemId)]

        if item then
            return { id = itemId, name = item.name }
        end
    end }

    return state
end

-- A fake valid inventory holding `slots`. Pass nil to simulate GetSlots failing.
local function container(slots)
    return {
        isValid = true,
        slotCount = 28,
        GetSlots = function()
            return slots
        end,
    }
end

-- A fake PrettyUI. It doesn't draw anything; it just records every view, label,
-- button, field and tab that was created, so tests can inspect them and "click"
-- buttons by calling them directly. It also asserts nothing is destroyed twice.
-- Set library.failTitle = true to make AddTitle throw, to simulate a failed build.
local function pretty()
    -- views contains top-level screens; allViews also includes the browser's
    -- nested columns. Tests find actions by label instead of layout coordinates.
    local library = { views = {}, allViews = {}, windows = {}, failTitle = false }

    function library:findButton(label)
        for index = #self.allViews, 1, -1 do
            local view = self.allViews[index]

            if not view.destroyed and view.buttons[label] then
                return view.buttons[label]
            end
        end

        error("No live button: " .. label)
    end

    -- Method actions share a short label; identify the containing row by its
    -- title, just as a player would, rather than assuming a list position.
    function library:findMethod(title)
        for index = #self.allViews, 1, -1 do
            local row = self.allViews[index]

            if not row.destroyed and row.buttons["View method"] then
                for _, label in ipairs(row.texts) do
                    if label.content:find(title, 1, true) then
                        return row.buttons["View method"]
                    end
                end
            end
        end
    end

    -- One drawable surface: a SimpleView, or a tab page (tab pages are surfaces too).
    local function surface()
        local view = { texts = {}, buttons = {}, fields = {}, tabs = {}, combos = {}, children = {}, destroyed = false, scrollY = 0 }
        view.content = { testOwner = view }

        function view:AddText(text)
            local label = { content = type(text) == "table" and text.text or text, options = text }
            self.texts[#self.texts + 1] = label

            return label
        end

        function view:AddSprite(resource, options)
            local sprite = { resource = resource, options = options }
            self.sprites = self.sprites or {}
            table.insert(self.sprites, sprite)
            return sprite
        end

        function view:AddTitle(text)
            if library.failTitle then
                error("Constructor failure")
            end

            return self:AddText(text)
        end

        -- Buttons are stored by label, so a test clicks with view.buttons["Save"]().
        function view:AddSimpleButton(text, callback, options)
            local sprite = type(text) == "number" and text or nil
            text = sprite and options.tooltip or text
            self.buttons[text] = callback

            -- PrettyUI exposes SetText on its button; keep the lookup in sync.
            local button = { active = options and options.active == true, sprite = sprite }

            function button:SetActive(active)
                self.active = active
            end

            -- SetText updates the surface's lookup, not a field on the button.
            local owner = self
            button.SetText = function(_, replacement)
                owner.buttons[text] = nil
                owner.buttons[replacement] = callback
                text = replacement
            end

            self.buttonControls = self.buttonControls or {}
            self.buttonControls[text] = button

            return button
        end

        -- Sprite actions are located by their tooltip, rather than a visible text
        -- caption. SetDisabled on a toggle controls its state, not its clickability.
        function view:AddSpriteButton(sprite, callback, options)
            local button = self:AddSimpleButton(options.tooltip, callback, options)
            button.sprite = sprite

            function button:SetDisabled(disabled)
                self.disabled = disabled
            end

            function button:SetTooltip(text)
                self:SetText(text)
            end

            return button
        end

        -- Panels are owned children. Native destruction of a parent tears these
        -- down too; tests also record them for finding actions and evidence.
        function view:AddPanel(options)
            local panel = surface()
            panel.options = options
            self.children[#self.children + 1] = panel
            library.allViews[#library.allViews + 1] = panel

            return panel
        end

        function view:AddItemSlot(object, options)
            local slot = { object = object, tooltip = options.tooltip, options = options }
            self.items = self.items or {}
            self.items[#self.items + 1] = slot

            function slot:SetTooltip(text)
                self.tooltip = text
            end

            return slot
        end

        -- Collect visible copy without coupling behavior checks to layout nesting.
        function view:allTexts()
            local labels = {}

            for _, label in ipairs(self.texts) do
                labels[#labels + 1] = label
            end

            for _, child in ipairs(self.children) do
                if not child.destroyed then
                    for _, label in ipairs(child:allTexts()) do
                        labels[#labels + 1] = label
                    end
                end
            end

            return labels
        end

        function view:SetScrollPosition(y)
            self.scrollY = y
        end

        -- Selection changes can be silent, which lets a failed save restore the
        -- old control without accidentally writing a second time.
        function view:AddComboBox(options)
            local control = { selectedID = options.selectedID }
            local ids = {}

            -- PrettyUI forwards these IDs to native ComboField, which takes Int,
            -- not strings. Checking this catches a mock/native mismatch early.
            for _, entry in ipairs(options.entries) do
                assert(math.type(entry.id) == "integer", "Combo IDs must be integers")
                ids[entry.id] = true
            end

            function control:Select(id, notify)
                assert(ids[id], "Unknown combo selection")
                self.selectedID = id

                if notify and options.onChange then
                    options.onChange(self, id)
                end
            end

            self.combos[#self.combos + 1] = control
            return control
        end

        -- Mirrors the real TextField: SetText only fires onChange when notify is true.
        function view:AddTextField(options)
            local field = { text = options.text }

            function field:GetText()
                return self.text
            end

            function field:SetText(text, notify)
                self.text = text

                if notify == true and options.onChange then
                    options.onChange(self, "change", text)
                end
            end

            -- Test-only helper: simulates the player pressing Enter.
            function field:Submit()
                if options.onSubmit then
                    options.onSubmit(self, self.text)
                end
            end

            self.fields[#self.fields + 1] = field
            return field
        end

        function view:AddTabs(entries, options)
            local tabs = { entries = entries, pages = {}, activeIndex = options.activeIndex }

            for index in ipairs(entries) do
                tabs.pages[index] = surface()
            end

            function tabs:GetPage(index)
                return self.pages[index]
            end

            self.tabs[#self.tabs + 1] = tabs
            return tabs
        end

        -- Destroying a view also destroys its tab pages, like the real library does.
        function view:Destroy()
            assert(not self.destroyed, "Double destruction")

            self.destroyed = true

            for _, child in ipairs(self.children) do
                if not child.destroyed then
                    child:Destroy()
                end
            end

            for _, tabs in ipairs(self.tabs) do
                for _, page in ipairs(tabs.pages) do
                    page:Destroy()
                end
            end
        end

        return view
    end

    -- Also checks the size options the plugin passes: views that fill the window
    -- use anchors, and the launcher matches its parent's size.
    library.SimpleView = { new = function(parent, options)
        if options.x ~= nil then
            -- Nested columns use a fixed sidebar and anchored offsets for the
            -- remaining width/height; they're not standalone screens.
            assert(parent.testOwner)
        elseif options.widthAnchor == 1 then
            equal(options.width, 0)
            equal(options.height, 0)
            equal(options.heightAnchor, 1)
        else
            equal(options.width, parent.width)
            equal(options.height, parent.height)
        end

        local view = surface()
        view.options = options
        library.allViews[#library.allViews + 1] = view

        if parent.testOwner then
            local children = parent.testOwner.children
            children[#children + 1] = view
        else
            library.views[#library.views + 1] = view
        end

        return view
    end }

    -- Close() hides and calls onClose, like the real window's X button. Destroy()
    -- is permanent.
    library.Window = { new = function(parent, options)
        local window = {
            options = options, hidden = false, destroyed = false,
            content = { width = options.width - 20, height = options.height - 48 },
        }

        function window:Show()
            assert(not self.destroyed, "Show after destruction")
            self.hidden = false
        end

        function window:Close()
            self.hidden = true
            options.onClose(self)
        end

        function window:Destroy()
            assert(not self.destroyed, "Window double destruction")
            self.destroyed = true
        end

        library.windows[#library.windows + 1] = window
        return window
    end }

    return library
end

-- Account reads (account.lua) ------------------------------------------------

-- Logged out means "unavailable", never zero levels or an empty bank.
test("logged-out player never reads skills or identity", function()
    local state = client()
    state.available = false

    local account = Account.new(function() end)

    equal(account:readPlayer().status, "unavailable")
    equal(account:inspectInventory("BANK").status, "unavailable")

    account:destroy()
end)

-- Even if the player granted trackingAccess before, we must not read the ID
-- (the fake GetTrackingID throws if anyone tries).
test("player status never reads tracking identity, even with an existing grant", function()
    local state = client()
    local account = Account.new(function() end)

    equal(account:readPlayer().status, "available")

    state.permitted = true
    local result = account:readPlayer()

    equal(result.identity, nil)
    equal(result.trackingId, nil)
    equal(result.prayer, 92)

    account:destroy()
end)

-- "We couldn't read the bank" and "the bank is empty" must stay different answers.
test("unavailable and known empty inventories differ", function()
    local state = client()
    local account = Account.new(function() end)

    equal(account:inspectInventory("BANK").status, "unavailable")

    state.inventory = container({})
    local result = account:inspectInventory("BANK")

    equal(result.status, "available")
    equal(#result.items, 0)
    equal(result.completeness, "unverified")

    account:destroy()
end)

-- Slots can have gaps (slot 1, then 7). We must copy the values out, not keep
-- references to native objects that might change underneath us.
test("sparse slots are copied as plain item evidence", function()
    local state = client()
    local obj = { id = 42, name = "Fixture weapon" }
    state.inventory = container({ [1] = { obj = obj, count = 3 }, [7] = { obj = { id = 43 }, count = 2 } })

    local account = Account.new(function() end)
    local result = account:inspectInventory("BANK")

    equal(#result.items, 2)
    equal(result.items[1].slot, 1)
    equal(result.items[1].name, "Fixture weapon")

    -- Change the "native" object afterwards; our copy must not change with it.
    obj.name = "Changed name"
    equal(result.items[1].name, "Fixture weapon")

    obj.id = 999

    for _, item in ipairs(result.items) do
        assert(item.itemId ~= 999)
        equal(item.obj, nil)
    end

    account:destroy()
end)

test("invalid config names and unknown configs are explicit", function()
    local state = client()
    state.inventory = container({})

    local account = Account.new(function() end)
    account:inspectInventory("BANK")

    -- A bad name also clears the previous successful read.
    equal(account:inspectInventory("BANK()").status, "invalid")
    equal(account.inspection, nil)

    equal(account:inspectInventory("NOT_A_CONFIG").status, "unknown")

    account:destroy()
end)

-- A crashing native read must show up as an error, not look like an empty bank.
test("native failure is not converted to an empty bank", function()
    client()
    Inventory.Find = function()
        error("Native read failed")
    end

    local account = Account.new(function() end)
    local result = account:inspectInventory("BANK")

    equal(result.status, "error")
    assert(result.message:find("Native read failed", 1, true))

    account:destroy()
end)

test("nil and invalid native inventories remain unavailable", function()
    local state = client()
    local account = Account.new(function() end)

    state.inventory = { isValid = false }
    equal(account:inspectInventory("BANK").status, "unavailable")

    state.inventory = container(nil)
    equal(account:inspectInventory("BANK").status, "unavailable")

    account:destroy()
end)

-- An INV change mustn't throw away our BANK read; a BANK change must.
test("changes invalidate only the inspected container", function()
    local state = client()
    state.inventory = container({})

    local notifications = 0
    local account = Account.new(function()
        notifications = notifications + 1
    end)

    account:inspectInventory("BANK")

    Event.InventoryUpdated.emit({ inv = config.Inv.INV })
    assert(account.inspection)

    Event.InventoryRemoved.emit({ inv = config.Inv.BANK })
    equal(account.inspection, nil)

    equal(notifications, 2)

    account:destroy()
end)

-- Login/logout/world hop: everything we read before is forgotten.
test("game-state changes discard inspected account evidence", function()
    local state = client()
    state.inventory = container({})

    local account = Account.new(function() end)
    account:inspectInventory("BANK")
    account:inspectQuest("FIXTURE_QUEST")

    Event.InventoryUpdated.emit({ inv = config.Inv.INV })
    equal(account.lastInventoryName, "INV")

    Event.GameStateChanged.emit({ oldState = 30, newState = 20 })

    equal(account.inspection, nil)
    equal(account.questInspection, nil)
    equal(account.lastInventoryName, nil)

    account:destroy()
end)

-- destroy() can safely run twice, leaves zero subscriptions, and makes the
-- account ignore anything that happens afterwards.
test("account teardown is idempotent and removes subscriptions", function()
    client()

    local notifications = 0
    local account = Account.new(function()
        notifications = notifications + 1
    end)

    account:destroy()
    account:destroy()

    for _, source in pairs(Event) do
        equal(source.count(), 0)
    end

    Event.InventoryAdded.emit({ inv = config.Inv.BANK })

    equal(notifications, 0)
    equal(account:inspectInventory("BANK").status, "stopped")
end)

test("quest flags preserve completed, started and not-started states", function()
    client()

    local account = Account.new(function() end)
    local result = account:inspectQuest("FIXTURE_QUEST")

    equal(result.status, "available")
    equal(result.completed, true)

    -- An earlier result is a snapshot; changing the config later doesn't alter it.
    config.Quest.FIXTURE_QUEST.hasFinishedQuest = false
    equal(result.completed, true)
    equal(account:inspectQuest("FIXTURE_QUEST").started, true)

    config.Quest.FIXTURE_QUEST.hasStartedQuest = false
    result = account:inspectQuest("FIXTURE_QUEST")

    equal(result.started, false)
    equal(result.completed, false)

    account:destroy()
    equal(account:inspectQuest("FIXTURE_QUEST").status, "stopped")
end)

-- Missing or deprecated quest data means "we don't know", never "not completed".
test("missing or deprecated quest data is unknown rather than incomplete", function()
    client()

    local account = Account.new(function() end)
    account:inspectQuest("FIXTURE_QUEST")

    equal(account:inspectQuest("FIXTURE_QUEST()").status, "invalid")
    equal(account.questInspection, nil)

    equal(account:inspectQuest("UNKNOWN_QUEST").status, "unknown")

    config.Quest.FIXTURE_QUEST.deprecated = true
    equal(account:inspectQuest("FIXTURE_QUEST").status, "unknown")

    config.Quest.FIXTURE_QUEST.deprecated = false
    config.Quest.FIXTURE_QUEST.hasFinishedQuest = nil
    equal(account:inspectQuest("FIXTURE_QUEST").status, "unknown")

    account:destroy()
end)

test("quest reads respect login availability and preserve native errors", function()
    local state = client()
    local account = Account.new(function() end)

    -- Any quest config lookup now throws, like a broken native read.
    state.available = false
    config.Quest = setmetatable({}, { __index = function()
        error("Quest native failure")
    end })

    -- Logged out: we bail out before touching the config at all.
    equal(account:inspectQuest("FIXTURE_QUEST").status, "unavailable")

    state.available = true
    local result = account:inspectQuest("FIXTURE_QUEST")

    equal(result.status, "error")
    assert(result.message:find("Quest native failure", 1, true))

    account:destroy()
end)

-- Diagnostics screen (temporary probes) ---------------------------------------

test("probe buttons inspect the observed inventory and quest", function()
    local state = client()
    local account = Account.new(function() end)
    local library = pretty()

    local ui = UI.new(library, account, function() end, function(name)
        return account:inspectQuest(name)
    end)

    ui.screen = "diagnostics"
    ui:mount({ width = 600, height = 800 })

    local buttons = library.views[1].buttons

    -- Nothing has changed yet, so there's no "last changed inventory" to read.
    buttons["Inspect last changed inventory"]()
    equal(account.inspection, nil)

    state.inventory = container({ [4] = { obj = { id = 42, name = "Fixture armour" }, count = 1 } })
    Event.InventoryUpdated.emit({ inv = config.Inv.INV })

    buttons["Inspect last changed inventory"]()
    equal(account.inspection.name, "INV")

    -- fields[2] is the quest name box. Empty is rejected; a real name works.
    equal(library.views[1].fields[2].text, "COOKS_ASSISTANT")

    library.views[1].fields[2].text = ""
    buttons["Inspect quest"]()
    equal(account.questInspection, nil)

    library.views[1].fields[2].text = "FIXTURE_QUEST"
    buttons["Inspect quest"]()
    equal(account.questInspection.completed, true)

    -- Both results should now be visible somewhere on the screen.
    local output = {}

    for _, label in ipairs(library.views[1].texts) do
        output[#output + 1] = label.content
    end

    local text = table.concat(output, "\n")

    assert(text:find("Fixture armour [42] x1", 1, true))
    assert(text:find("Fixture quest: Completed", 1, true))

    ui:destroy()
    account:destroy()
end)

-- Requirement checks (requirements.lua) ---------------------------------------

test("skill checks use available base levels and preserve source wording", function()
    local requirement = { kind = "skill", skill = "PRAYER", level = 92, text = "92 Prayer" }
    local account = { skills = { PRAYER = { status = "available", level = 92 } } }

    local checked = Requirements.evaluate(requirement, account)

    equal(checked.status, "met")
    equal(checked.text, "92 Prayer")
    equal(checked.evidence[1].level, 92)

    -- The evidence in a result is a copy, so later changes don't rewrite it.
    account.skills.PRAYER.level = 91
    equal(checked.evidence[1].level, 92)
    equal(Requirements.evaluate(requirement, account).status, "unmet")

    -- Anything not marked "available" (stale, missing) is unknown.
    account.skills.PRAYER.status = "stale"
    equal(Requirements.evaluate(requirement, account).status, "unknown")
    equal(Requirements.evaluate(requirement, {}).status, "unknown")
end)

-- Negative, fractional, infinite, NaN (0/0) or text "levels" must never pass a check.
test("invalid numerical evidence cannot qualify a requirement", function()
    for _, value in ipairs({ -1, 2.5, math.huge, 0 / 0, "99" }) do
        local account = {
            skills = { PRAYER = { status = "available", level = value } },
            items = { [42] = { status = "available", quantity = value, complete = true } },
        }

        equal(Requirements.evaluate({ kind = "skill", skill = "PRAYER", level = 92 }, account).status, "unknown")
        equal(Requirements.evaluate({ kind = "item", itemId = 42, quantity = 1 }, account).status, "unknown")
    end
end)

test("quest checks distinguish incomplete, unknown and completed evidence", function()
    local requirement = { kind = "quest", quest = "FIXTURE_QUEST", text = "Complete fixture quest" }

    equal(Requirements.evaluate(requirement, {}).status, "unknown")

    local account = { quests = { FIXTURE_QUEST = { status = "available", completed = false } } }
    equal(Requirements.evaluate(requirement, account).status, "unmet")

    account.quests.FIXTURE_QUEST.completed = true
    equal(Requirements.evaluate(requirement, account).status, "met")

    account.quests.FIXTURE_QUEST.status = "error"
    equal(Requirements.evaluate(requirement, account).status, "unknown")
end)

-- The key ownership rule: seeing enough proves "met", but seeing too few only
-- proves "unmet" when we know we've looked everywhere (complete = true).
test("item checks prove presence but need complete coverage to prove absence", function()
    local requirement = { kind = "item", itemId = 42, quantity = 2, text = "Two fixture items" }

    equal(Requirements.evaluate(requirement, {}).status, "unknown")

    local entry = { status = "available", quantity = 2, complete = false }
    local account = { items = { [42] = entry } }

    equal(Requirements.evaluate(requirement, account).status, "met")

    entry.quantity = 1
    equal(Requirements.evaluate(requirement, account).status, "unknown")

    entry.complete = true
    equal(Requirements.evaluate(requirement, account).status, "unmet")

    entry.quantity = 0
    equal(Requirements.evaluate(requirement, account).status, "unmet")

    entry.quantity = 100
    entry.status = "stale"
    equal(Requirements.evaluate(requirement, account).status, "unknown")
end)

-- Checks every combination of two children (met/unmet/unknown) for both ALL and
-- ANY against a written-out truth table, so a mistake in one case can't hide.
test("ALL and ANY apply three-state rules for every pair of results", function()
    local allExpected = {
        met = { met = "met", unmet = "unmet", unknown = "unknown" },
        unmet = { met = "unmet", unmet = "unmet", unknown = "unmet" },
        unknown = { met = "unknown", unmet = "unmet", unknown = "unknown" },
    }

    local anyExpected = {
        met = { met = "met", unmet = "met", unknown = "met" },
        unmet = { met = "met", unmet = "unmet", unknown = "unknown" },
        unknown = { met = "met", unmet = "unknown", unknown = "unknown" },
    }

    -- Quest evidence that produces each of the three results.
    local entries = {
        met = { status = "available", completed = true },
        unmet = { status = "available", completed = false },
        unknown = { status = "unavailable" },
    }

    for first, row in pairs(allExpected) do
        for second, expected in pairs(row) do
            local account = { quests = { FIRST = entries[first], SECOND = entries[second] } }
            local requirement = { kind = "all", children = {
                { kind = "quest", quest = "FIRST" }, { kind = "quest", quest = "SECOND" },
            } }

            equal(Requirements.evaluate(requirement, account).status, expected)

            requirement.kind = "any"
            equal(Requirements.evaluate(requirement, account).status, anyExpected[first][second])
        end
    end
end)

test("nested alternatives retain individual evidence and empty groups stay explicit", function()
    local requirement = { kind = "all", text = "Access", children = {
        { kind = "any", text = "One route", children = {
            { kind = "quest", quest = "FIXTURE_QUEST", text = "Quest route" },
            { kind = "capability", capability = "UNVERIFIED", text = "Unverified route" },
        } },
    } }
    local account = { quests = { FIXTURE_QUEST = { status = "available", completed = true } } }

    local checked = Requirements.evaluate(requirement, account)

    -- The quest route passes, so ANY passes, even though the capability is unknown.
    equal(checked.status, "met")
    equal(checked.children[1].text, "One route")
    equal(checked.children[1].children[1].evidence[1].quest, "FIXTURE_QUEST")
    equal(checked.children[1].children[2].status, "unknown")

    -- Edge cases: an empty ALL has nothing to fail; an empty ANY tells us nothing.
    equal(Requirements.evaluate({ kind = "all", children = {} }, {}).status, "met")
    equal(Requirements.evaluate({ kind = "any", children = {} }, {}).status, "unknown")
    equal(Requirements.evaluate({ kind = "gear" }, {}).status, "unknown")
end)

-- GE quotes (income.lua) ------------------------------------------------------
-- Each `library` table below is a fake GEPL with just isReady and getLatest.

test("missing and loading GE dependency do not invent a price", function()
    equal(Income.inspectQuote(nil, 49430).status, "unavailable")

    -- While GEPL isn't ready we mustn't even ask it for a price.
    local library = { isReady = function(endpoint)
        equal(endpoint, "latest")
        return false
    end, getLatest = function()
        error("Not ready: getter must not be called")
    end }

    equal(Income.inspectQuote(library, 49430).status, "loading")
end)

test("invalid item IDs never reach the GE dependency", function()
    local library = { isReady = function()
        error("Unexpected dependency call")
    end }

    for _, id in ipairs({ 0, -1, 1.5, math.huge, "49430" }) do
        equal(Income.inspectQuote(library, id).status, "invalid")
    end
end)

-- Buy and sell sides stay separate with their own timestamps, and we copy them
-- rather than keep GEPL's table.
test("GE quote retains distinct values and original timestamps", function()
    local original = { high = 120, highTime = 100, low = 90, lowTime = 80 }
    local library = { isReady = function()
        return true
    end, getLatest = function(itemId)
        equal(itemId, 49430)
        return original
    end }

    local quote = Income.inspectQuote(library, 49430)

    equal(quote.status, "available")
    equal(quote.high, 120)
    equal(quote.lowTime, 80)

    original.high = 999
    equal(quote.high, 120)
end)

-- A price of 0 is a real (if odd) price; infinity or NaN is junk and gets dropped.
test("missing and non-finite trade sides remain partial/unavailable", function()
    local quote = { high = 0, highTime = 100, low = math.huge, lowTime = 100 }
    local library = { isReady = function()
        return true
    end, getLatest = function()
        return quote
    end }

    local result = Income.inspectQuote(library, 49430)

    equal(result.status, "partial")
    equal(result.high, 0)
    equal(result.low, nil)

    quote = { high = 0 / 0, highTime = 100 }
    equal(Income.inspectQuote(library, 49430).status, "unavailable")
end)

test("GE item errors preserve a useful diagnostic", function()
    local library = { isReady = function()
        return true
    end, getLatest = function()
        error("Price not found")
    end }

    local result = Income.inspectQuote(library, 49430)

    equal(result.status, "error")
    assert(result.message:find("Price not found", 1, true))
end)

-- UI lifetime (ui.lua) ----------------------------------------------------------

-- Old buttons must go dead once their view is replaced (the "generation" guard),
-- and everything must go dead after destroy().
test("remount destroys old UI and old callbacks become inert", function()
    client()

    local account = Account.new(function() end)
    local library = pretty()
    local quotes = 0

    local screen = UI.new(library, account, function()
        quotes = quotes + 1
        return { status = "unavailable", message = "Unavailable" }
    end)

    screen.screen = "diagnostics"
    screen:mount({ width = 700, height = 500 })
    local old = library.views[1]

    screen:mount({ width = 600, height = 400 })
    assert(old.destroyed)

    old.buttons["Check chronotes quote"]()
    equal(quotes, 0)

    library.views[2].buttons["Check chronotes quote"]()
    equal(quotes, 1)

    screen:destroy()
    screen:destroy()

    library.views[2].buttons["Check chronotes quote"]()
    equal(quotes, 1)

    account:destroy()
end)

-- If building a screen throws halfway, the half-built view is cleaned up and
-- the error still reaches the caller.
test("failed UI construction destroys the partial view and reports failure", function()
    client()

    local account = Account.new(function() end)
    local library = pretty()
    library.failTitle = true

    local screen = UI.new(library, account, function() end)

    local ok, failure = pcall(function()
        screen:mount({ width = 700, height = 500 })
    end)

    equal(ok, false)
    assert(tostring(failure):find("Constructor failure", 1, true))
    assert(library.views[1].destroyed)
    equal(screen.view, nil)

    account:destroy()
end)

-- Whole plugin (main.lua) ---------------------------------------------------------

-- Simulates enabling the plugin three times in a row: load main.lua, remount the
-- launcher, open the window, use a screen, shut down. Every cycle must end with
-- zero subscriptions and everything destroyed, or repeated reloads would leak.
test("plugin enable/remount/shutdown cycles release all owned resources", function()
    for _ = 1, 3 do
        client()
        prettyui = pretty()
        gepl = nil

        dofile("main.lua")
        equal(Event.ContentLayerReady.count(), 1)

        -- Two launcher mounts in a row: the first launcher must be replaced, and
        -- neither may open the window by itself.
        Event.ContentLayerReady.emit({ component = { width = 700, height = 500 } })
        Event.ContentLayerReady.emit({ component = { width = 650, height = 450 } })

        assert(prettyui.views[1].destroyed)
        equal(#prettyui.windows, 0)

        -- views[2] is the launcher, views[3] the Browse screen, views[4] Diagnostics.
        prettyui.views[2].buttons["Open Profit Path"]()
        prettyui:findButton("Diagnostics")()

        local latest = prettyui.views[4]
        latest.fields[2].text = "FIXTURE_QUEST"
        latest.buttons["Inspect quest"]()

        local found = false

        for _, label in ipairs(latest.texts) do
            if label.content:find("Requirement: met.", 1, true) then
                found = true
            end
        end

        assert(found, "Main must connect quest evidence to the shared requirement checker")

        PluginShutdown()
        PluginShutdown()

        for _, source in pairs(Event) do
            equal(source.count(), 0)
        end

        assert(prettyui.views[4].destroyed)
        assert(prettyui.windows[1].destroyed)
    end
end)

-- Bank availability and item absence must never be treated as the same thing.
test("item presence caches requested totals and invalidates the changed container", function()
    client()
    local calls = 0
    local bankAvailable = false
    local backpackCount = 1
    local inventories = {}

    for _, name in ipairs({ "INV", "WORN", "BANK" }) do
        inventories[name] = {
            isValid = true,
            GetTotal = function(_, itemId)
                calls = calls + 1
                return name == "INV" and itemId == 42 and backpackCount or 0
            end,
        }
    end

    Inventory.Find = function(definition)
        if definition.configName == "BANK" and not bankAvailable then
            return nil
        end

        return inventories[definition.configName]
    end

    local account = Account.new(function() end)
    local wanted = { [42] = true, [43] = true }
    local first = account:readOwnership(wanted)
    equal(first.counts[42], 1)
    equal(first.complete, false)
    equal(calls, 4)
    account:readOwnership(wanted)
    equal(calls, 4)

    bankAvailable = true
    local complete = account:readOwnership(wanted)
    equal(complete.complete, true)
    equal(complete.counts[43], 0)
    equal(calls, 6)

    backpackCount = 0
    Event.InventoryUpdated.emit({ inv = config.Inv.INV })
    equal(account:readOwnership(wanted).counts[42], 0)
    equal(calls, 8)

    Event.GameStateChanged.emit({})
    account:readOwnership(wanted)
    equal(calls, 14)
    account:destroy()
    equal(account:readOwnership(wanted).complete, false)
end)

-- The calculator, saved-rate and window tests live in their own file but share
-- these helpers.
dofile("src/tests/calculator.lua")(test, equal, client, pretty)
dofile("src/tests/browser.lua")(test, equal, client, pretty)

print(string.format("%d behavior tests passed.", passed))
