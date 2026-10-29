-- Saves only catalogue-relevant item counts, separately for backpack, worn gear
-- and bank. Saved data is historical evidence, never a claim of current ownership.
-- This object owns the loaded profile record and a dirty flag, not native proxies.
local Snapshot = {}
local containers = { "INV", "WORN", "BANK" }

-- An application bound, not a claimed client/database limit. Reject oversized
-- records rather than walking arbitrary persisted data or overwriting it silently.
local MAX_ITEMS = 4096

local function validCount(value)
    return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
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

        if not ok or type(stored) ~= "table" or stored.schema ~= 1 or type(stored.containers) ~= "table" then
            self.writable = false
            self.message = "Saved item evidence could not be read; it will not be overwritten."
            return
        end

        for _, name in ipairs(containers) do
            local record = stored.containers[name]

            if record ~= nil then
                local counts, size = {}, 0
                local valid = type(record) == "table"

                if valid then
                    for key, quantity in pairs(record) do
                        size = size + 1
                        local itemId = type(key) == "string" and tonumber(key) or nil

                        if size > MAX_ITEMS or not itemId or itemId <= 0 or itemId % 1 ~= 0
                            or tostring(itemId) ~= key or counts[itemId] ~= nil or not validCount(quantity) then
                            valid = false
                            break
                        end

                        counts[itemId] = quantity
                    end
                end

                if valid then
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
        local copy, different, size = {}, false, 0

        for itemId, quantity in pairs(counts) do
            copy[itemId] = quantity
            size = size + 1
            different = different or old[itemId] ~= quantity
        end

        for itemId in pairs(old) do
            different = different or counts[itemId] == nil
        end

        if size > MAX_ITEMS then
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

        local record = { schema = 1, containers = {} }

        for _, name in ipairs(containers) do
            if self.data[name] then
                record.containers[name] = {}

                for itemId, quantity in pairs(self.data[name]) do
                    record.containers[name][tostring(itemId)] = quantity
                end
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
