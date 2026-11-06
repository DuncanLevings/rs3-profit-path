-- Saves last-seen item counts per profile (backpack, worn gear and bank), so the
-- next login knows what was in the bank. Saved backpack and worn counts are only
-- hints, since those can always be read live.
local Snapshot = {}
local containers = { "INV", "WORN", "BANK" }

-- Our own size caps (not client limits), so a huge or damaged save is refused
-- rather than walked or quietly overwritten. MAX_ITEMS caps items held;
-- MAX_CHECKED caps everything checked (tiered gear alone checks ~2,900 pieces).
local MAX_ITEMS = 4096
local MAX_CHECKED = 20000

-- Schema 2 stores held counts by item ID and packs checked zeros into one
-- comma-separated absent string. Schema 1's individual zero entries still load.
local SCHEMA = 2

local function validCount(value)
    return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end

-- A saved item ID. Keys are written as strings, but accept a number too in case
-- the client's storage hands numeric-looking keys back as numbers.
local function savedItemId(key)
    local itemId = tonumber(key)

    if not itemId or itemId <= 0 or itemId % 1 ~= 0 then
        return nil
    end

    if type(key) == "string" and tostring(itemId) ~= key then
        return nil
    end

    return itemId
end

-- Reads one saved container into a plain { [itemId] = count } table, zeros
-- included. Returns nil if anything in it looks wrong.
local function readContainer(record, schema)
    if type(record) ~= "table" then
        return nil
    end

    local counts, size = {}, 0
    local held = schema == 1 and record or record.counts

    if type(held) ~= "table" then
        return nil
    end

    for key, quantity in pairs(held) do
        size = size + 1
        local itemId = savedItemId(key)

        if size > MAX_ITEMS or not itemId or counts[itemId] ~= nil or not validCount(quantity) then
            return nil
        end

        counts[itemId] = quantity
    end

    -- Schema 2: the zeros, as one comma-separated string.
    if schema == 2 and record.absent ~= nil then
        if type(record.absent) ~= "string" then
            return nil
        end

        for key in record.absent:gmatch("[^,]+") do
            size = size + 1
            local itemId = savedItemId(key)

            if size > MAX_CHECKED or not itemId or counts[itemId] ~= nil then
                return nil
            end

            counts[itemId] = 0
        end
    end

    return counts
end

function Snapshot.new(db)
    local self = { data = {}, dirty = false, writable = true }

    -- Uses the same profile as the rest of the settings. The length prefix keeps
    -- the key unambiguous whatever the name contains.
    function self:bind(profile)
        if self.profile == profile then
            return
        end

        self:flush()
        self.profile = profile
        self.key = "profit-path.account.v1/" .. #profile .. ":" .. profile
        self.data, self.dirty, self.writable, self.message = {}, false, true, nil

        local ok, stored, exists = pcall(function()
            return db:GetStructuredData(self.key), db:CheckExists(self.key)
        end)

        if ok and stored == nil and not exists then
            return
        end

        local schema = type(stored) == "table" and stored.schema

        if not ok or (schema ~= 1 and schema ~= SCHEMA) or type(stored.containers) ~= "table" then
            self.writable = false
            self.message = "Saved item evidence could not be read; it will not be overwritten."
            return
        end

        for _, name in ipairs(containers) do
            local record = stored.containers[name]

            if record ~= nil then
                local counts = readContainer(record, schema)

                if counts then
                    self.data[name] = counts
                else
                    self.writable = false
                    self.message = "Some saved item evidence is invalid; the stored record is protected."
                end
            end
        end
    end

    -- Remembers one container's counts. A read identical to the last one changes
    -- nothing, so there's nothing new to save.
    function self:observe(name, counts)
        if not self.profile then
            return
        end

        local old = self.data[name] or {}
        local copy, different, size, held = {}, false, 0, 0

        for itemId, quantity in pairs(counts) do
            copy[itemId] = quantity
            size = size + 1
            held = held + (quantity > 0 and 1 or 0)
            different = different or old[itemId] ~= quantity
        end

        for itemId in pairs(old) do
            different = different or counts[itemId] == nil
        end

        if held > MAX_ITEMS or size > MAX_CHECKED then
            self.message = "Too many item checks to save this snapshot."
            return
        end

        if different then
            self.data[name] = copy
            self.dirty = true
        end
    end

    -- Writes any unsaved counts. Called when the window or bank closes, the
    -- character changes or the plugin shuts down. A failed write stays pending.
    function self:flush()
        if not self.profile or not self.dirty or not self.writable then
            return
        end

        local record = { schema = SCHEMA, containers = {} }

        for _, name in ipairs(containers) do
            if self.data[name] then
                local held, absent = {}, {}

                for itemId, quantity in pairs(self.data[name]) do
                    if quantity > 0 then
                        held[tostring(itemId)] = quantity
                    else
                        absent[#absent + 1] = itemId
                    end
                end

                -- Sorted so the same contents always save as the same string.
                table.sort(absent)
                record.containers[name] = { counts = held, absent = table.concat(absent, ",") }
            end
        end

        local ok, written = pcall(function()
            return db:SetStructuredData(self.key, record)
        end)

        if ok and written == true then
            self.dirty = false
            self.message = nil
        else
            self.message = "Item evidence could not be saved; current checks still work."
        end
    end

    -- Called on login, logout or world hop. Nothing is saved until the window binds
    -- the next character, so a late event can't save under the old one.
    function self:unbind()
        self:flush()
        self.profile = nil
        self.data = {}
        self.dirty = false
    end

    return self
end

return Snapshot
