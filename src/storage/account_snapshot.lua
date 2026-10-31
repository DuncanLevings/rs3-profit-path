-- Saves only catalogue-relevant item counts, separately for backpack, worn gear
-- and bank. The saved bank stands in for the bank whenever it's closed (the game
-- only sends it while open; see readOwnership in account.lua). The saved backpack
-- and worn gear are only last-seen hints: those are always readable live.
-- This object owns the loaded profile record and a dirty flag, not native proxies.
local Snapshot = {}
local containers = { "INV", "WORN", "BANK" }

-- Application bounds, not claimed client/database limits. Reject oversized
-- records rather than walking arbitrary persisted data or overwriting it silently.
-- MAX_ITEMS caps items actually held; MAX_CHECKED caps everything checked, since
-- the tiered gear checks alone look for about 2,900 pieces.
local MAX_ITEMS = 4096
local MAX_CHECKED = 20000

-- Record layout. Schema 1 saved every checked item as its own key, zeros too:
-- thousands of entries per container once tiered gear arrived. Schema 2 keeps
-- held items as keys and folds every zero into one "absent" string of IDs
-- ("1351,1359,..."), so a record stays small. Schema 1 records still load.
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

    -- Reusing the character's existing profile binding preserves rename/profile
    -- behaviour. Length prefixes make this a flat, unambiguous database key.
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

    -- Copy plain counts only. Identical reads do not create new persistence work.
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

    -- Checkpoints happen on close, bank removal, character change and shutdown;
    -- never on each inventory event or logic tick. Keep failed writes retryable.
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

    -- A world/character transition ends the live binding. The next explicit open
    -- binds again, so late inventory events cannot save under the previous player.
    function self:unbind()
        self:flush()
        self.profile = nil
        self.data = {}
        self.dirty = false
    end

    return self
end

return Snapshot
