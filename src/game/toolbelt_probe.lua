-- Temporary developer-only discovery. This owns one short-lived Logic scan and
-- returns plain metadata, never an ownership verdict. Diagnostics cancels it on
-- close/navigation/shutdown. Remove this file with the development probes.
local Probe = {}
local SUBSCRIPTION = "profit-path-toolbelt-discovery"
local PER_TICK = 100

-- Application search windows, not claims about API limits. Negative VarPlayer
-- IDs are varbits. These ranges follow the user's Skilling Coach discovery probe;
-- a completed scan says nothing about configs outside these windows.
local ranges = {
    -- Resolve item/tier mappings first; account-variable volume must not starve them.
    { kind = "Enum", first = 0, last = 20000, step = 1 },
    { kind = "VarPlayer", first = -1, last = -70001, step = -1 },
    { kind = "VarPlayer", first = 0, last = 20000, step = 1 },
    { kind = "Param", first = 0, last = 10000, step = 1 },
    { kind = "Inv", first = 0, last = 2000, step = 1 },
}

local function relevant(kind, name)
    if type(name) ~= "string" then
        return false
    end

    -- Variables for quests, collections and cosmetic unlocks can mention a tool
    -- without describing the tool belt. Only read the actual tool-belt state.
    if kind == "VarPlayer" then
        return name:match("^TOOLBELT_") ~= nil or name:match("^TOOL_BELT_") ~= nil
    end

    return name:find("TOOLBELT", 1, true) or name:find("TOOL_BELT", 1, true)
        or name:find("HATCHET", 1, true) or name:find("PICKAXE", 1, true)
        or name:find("MATTOCK", 1, true)
end

-- Read one config through the documented FromID boundary. Native holes/errors
-- are expected during discovery. Read current values only AFTER the name matches;
-- unrelated account variables aren't collected or printed. `matches` decides which
-- names are relevant (the tool-belt test unless a scan supplies its own).
local function read(kind, index, matches)
    local namespace = kind == "VarPlayer" and var.VarPlayer or config[kind]
    local found = namespace.FromID(index)
    local name = found and found.configName

    if type(name) ~= "string" or not matches(kind, name) then
        return nil
    end

    local lines = { kind .. "." .. name .. " = " .. found.id }
    local truncated = false

    if kind == "VarPlayer" then
        lines[#lines + 1] = "  current value: " .. tostring(found.value)

        if found.isVarBit then
            local base = found.baseVar
            lines[#lines + 1] = "  base: " .. base.configName .. " [" .. base.id
                .. "]; mask: " .. tostring(found.varBitMask)
        end
    elseif kind == "Enum" then
        lines[#lines + 1] = "  input type: " .. tostring(found.inputValueType)
            .. "; output type: " .. tostring(found.outputValueType)

        -- values contains ALL input/output pairs. GetInputValues(output) is a
        -- reverse lookup and cannot be called without an output argument.
        for index, pair in ipairs(found.values) do
            local value = pair[2]
            local description = tostring(value)

            if type(value) == "userdata" then
                description = value.configName .. " [" .. value.id .. "]"
            end

            lines[#lines + 1] = "  " .. tostring(pair[1]) .. " -> " .. description

            if index >= 128 and index < found.valueCount then
                truncated = true
                lines[#lines + 1] = "  Entry limit reached; mapping is incomplete."
                break
            end
        end
    end

    return { lines = lines, truncated = truncated }
end

-- Starts only after an explicit click. The caller owns the returned cancellation
-- function; callbacks must belong to the same screen lifetime as the scan.
--
-- `options` is optional, for other discovery scans: { ranges = {...}, matches =
-- function(kind, name), limit = candidates per range }. Without it, this is the
-- tool-belt scan exactly as before.
function Probe.start(onLine, onProgress, onDone, options)
    options = options or {}
    local ranges = options.ranges or ranges
    local matches = options.matches or relevant
    local limit = options.limit or 128
    local active = true
    local rangeIndex, nextId = 1, ranges[1].first
    local scanned, matched, failures = 0, 0, 0
    local firstFailure
    local rangeMatches = 0
    local truncated = false

    -- Release the subscription BEFORE reporting completion, including cancellation.
    local function finish(status, message)
        if not active then
            return
        end

        active = false
        Event.Logic.Unsubscribe(SUBSCRIPTION)
        onDone({ status = status, message = message, scanned = scanned, matched = matched,
            failures = failures, firstFailure = firstFailure })
    end

    -- A busy variable range must not prevent the remaining config types from
    -- running. Report the partial range and move on using its independent budget.
    local function advanceRange(limited)
        local range = ranges[rangeIndex]
        truncated = truncated or limited
        onLine(range.kind .. " range " .. range.first .. ".." .. range.last .. ": "
            .. rangeMatches .. " candidates; " .. (limited and "candidate limit reached (partial)." or "inspected."))
        rangeIndex = rangeIndex + 1
        rangeMatches = 0
        range = ranges[rangeIndex]

        if not range then
            local message = truncated and "Search finished with limits; some metadata is incomplete."
                or "Search windows complete; this is metadata, not verified ownership."
            finish(truncated and "partial" or "complete", message)
            return false
        end

        nextId = range.first
        return true
    end

    local function tick()
        if not active then
            return
        end

        if not Player.IsAvailable() then
            finish("cancelled", "Player unavailable; scan stopped.")
            return
        end

        for _ = 1, PER_TICK do
            local range = ranges[rangeIndex]
            local ok, record = pcall(read, range.kind, nextId, matches)
            scanned = scanned + 1

            if not ok then
                failures = failures + 1
                firstFailure = firstFailure or tostring(record)
            elseif record then
                matched = matched + 1
                rangeMatches = rangeMatches + 1
                truncated = truncated or record.truncated

                for _, line in ipairs(record.lines) do
                    onLine(line)
                end
            end

            nextId = nextId + range.step
            local exhausted = (range.step > 0 and nextId > range.last)
                or (range.step < 0 and nextId < range.last)
            local limited = rangeMatches >= limit and not exhausted

            if exhausted or limited then
                if not advanceRange(limited) then
                    return
                end
            end
        end

        -- A progress label once per 1,000 lookups, not one console line per ID.
        if scanned % 1000 == 0 then
            onProgress(scanned, matched)
        end
    end

    if Player.IsAvailable() then
        Event.Logic.Subscribe(SUBSCRIPTION, tick)
    else
        finish("unavailable", "Enter a game world first.")
    end

    return function()
        finish("cancelled", "Scan cancelled; run it again when ready.")
    end
end

return Probe
