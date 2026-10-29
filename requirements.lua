-- Checks a method's requirements against what we know about the player. It's pure
-- logic over plain tables and never touches the game client, which makes it easy to
-- test. Callers check "access" (can you do it at all) and "recommended" (should you)
-- separately.
--
-- Every check answers one of three things:
--   "met"     - we have evidence the player meets it
--   "unmet"   - we have evidence they don't
--   "unknown" - we can't tell (logged out, data missing, check not built yet...)
-- The golden rule: missing data is "unknown", never quietly "unmet" or "met".
local Requirements = {}

-- Builds the result table every check returns, keeping the original wording so the
-- UI can show the player the source's own text next to our verdict.
local function result(requirement, status, reason, evidence, children)
    return {
        text = requirement.text,
        status = status,
        reason = reason,
        evidence = evidence or {},
        children = children,
    }
end

-- Evidence only counts if whoever gathered it marked it "available".
local function available(entry)
    return entry and entry.status == "available"
end

local function nonNegativeInteger(value)
    return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end

-- `requirement` is one node from the method data: a group ("all"/"any" with children)
-- or a single check ("skill", "quest", "item", ...). `account` holds plain evidence
-- tables: account.skills, account.quests and account.items.
function Requirements.evaluate(requirement, account)
    local kind = requirement.kind

    -- Groups: check every child first, then combine their answers.
    if kind == "all" or kind == "any" then
        local children = {}
        local met, unmet, unknown = 0, 0, 0

        for index, child in ipairs(requirement.children) do
            local checked = Requirements.evaluate(child, account)
            children[index] = checked

            if checked.status == "met" then
                met = met + 1
            elseif checked.status == "unmet" then
                unmet = unmet + 1
            else
                unknown = unknown + 1
            end
        end

        -- ALL: one definite failure sinks the whole group, even if others are unknown.
        -- ANY: one definite pass is enough, even if others are unknown.
        -- Otherwise any unknown child makes the whole group unknown.
        local status
        local reason

        if kind == "all" then
            reason = "All listed requirements must be met."

            if unmet > 0 then
                status = "unmet"
            elseif unknown > 0 then
                status = "unknown"
            else
                status = "met"
            end
        else
            reason = "One listed alternative must be met."

            -- An empty ANY has no alternatives to pass, which tells us nothing.
            if met > 0 then
                status = "met"
            elseif unknown > 0 or #children == 0 then
                status = "unknown"
            else
                status = "unmet"
            end
        end

        return result(requirement, status, reason, nil, children)
    end

    -- Skill check: compares the base level, not a temporarily boosted one.
    if kind == "skill" then
        local entry = account.skills and account.skills[requirement.skill]

        if not available(entry) or not nonNegativeInteger(entry.level) then
            return result(requirement, "unknown", "Current base level is unavailable.")
        end

        local met = entry.level >= requirement.level

        return result(requirement, met and "met" or "unmet",
            met and "Base level meets the requirement." or "Base level is below the requirement.",
            { { skill = requirement.skill, level = entry.level } })
    end

    if kind == "quest" then
        local entry = account.quests and account.quests[requirement.quest]

        if not available(entry) or type(entry.completed) ~= "boolean" then
            return result(requirement, "unknown", "Current quest completion is unavailable.")
        end

        return result(requirement, entry.completed and "met" or "unmet",
            entry.completed and "Quest completed." or "Quest not completed.",
            { { quest = requirement.quest, name = entry.name, completed = entry.completed } })
    end

    -- Item check: the tricky one. Seeing enough items proves the player has them. But
    -- NOT seeing them only proves they don't if we know we've seen everything (bank
    -- included). Otherwise the rest might be somewhere we haven't looked.
    if kind == "item" then
        local entry = account.items and account.items[requirement.itemId]

        if not available(entry) or not nonNegativeInteger(entry.quantity) then
            return result(requirement, "unknown", "Current item ownership is unavailable.")
        end

        local evidence = { { itemId = requirement.itemId, quantity = entry.quantity } }

        if entry.quantity >= requirement.quantity then
            return result(requirement, "met", "Enough owned items were observed.", evidence)
        end

        if entry.complete ~= true then
            return result(requirement, "unknown", "Not enough items observed; ownership coverage is incomplete.", evidence)
        end

        return result(requirement, "unmet", "Owned quantity is below the requirement.", evidence)
    end

    -- Anything else (gear tiers, unlocks like prayers) isn't built yet. We need
    -- verified client mappings first, so for now we're honest and say "unknown".
    return result(requirement, "unknown", "This requirement is not supported yet.")
end

return Requirements
