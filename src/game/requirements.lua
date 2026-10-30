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
-- tables: skills, quests, items, flags, achievements, combat and equipment (see
-- refreshEvidence in src/main.lua).
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

    -- An unlock flag (a relic, say) is met when the game variable is set.
    if kind == "flag" then
        local entry = account.flags and account.flags[requirement.var]

        if not available(entry) or type(entry.value) ~= "number" then
            return result(requirement, "unknown", "Unlock status is unavailable.")
        end

        local met = entry.value >= 1

        return result(requirement, met and "met" or "unmet",
            met and "Unlocked." or "Not unlocked yet.", { { var = requirement.var, value = entry.value } })
    end

    -- One achievement, or every achievement in a diary tier, must be complete.
    if kind == "achievement" then
        local left, unknown = 0, 0

        for _, achievementId in ipairs(requirement.ids) do
            local entry = account.achievements and account.achievements[achievementId]

            if not available(entry) then
                unknown = unknown + 1
            elseif not entry.complete and not entry.retired then
                left = left + 1
            end
        end

        if left > 0 then
            return result(requirement, "unmet", left .. " of " .. #requirement.ids .. " achievements still to do.")
        elseif unknown > 0 then
            return result(requirement, "unknown", "Achievement progress is unavailable.")
        end

        return result(requirement, "met", "Achievements complete.")
    end

    -- Combat level, as the client reports it (account.combat, from
    -- Player.GetCombatLevel).
    if kind == "combat_level" then
        local entry = account.combat

        if not available(entry) or not nonNegativeInteger(entry.level) then
            return result(requirement, "unknown", "Combat level is unavailable.")
        end

        local level = entry.level
        local met = level >= requirement.level

        return result(requirement, met and "met" or "unmet",
            met and "Combat level meets the requirement." or "Combat level is below the requirement.",
            { { combat = level } })
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

    -- Gear groups describe alternatives, not a mandatory top-end example. Pick
    -- the highest owned tier that also meets its use levels and requested slot/style.
    if kind == "gear" and requirement.equipment_group then
        local group = account.equipment and account.equipment[requirement.equipment_group]

        if not group then
            return result(requirement, "unknown", "Equipment alternatives are not mapped yet.")
        end

        local best, saved, uncertain = nil, nil, false
        local lastKnownAbsent, candidateCount = true, 0

        -- The combat equipment group has thousands of pieces; bySlot (built by
        -- main.lua) lets a "T90+ weapon" check look at weapons only.
        local candidates = requirement.slot and group.bySlot and group.bySlot[requirement.slot] or group.candidates

        for _, candidate in ipairs(candidates) do
            local matches = candidate.tier >= (requirement.minimum_tier or 0)
                and (not requirement.style or candidate.style == requirement.style)
                and (not requirement.slot or candidate.slot == requirement.slot)
                and (not requirement.armour_type or candidate.armour_type == requirement.armour_type)

            local owned = account.items and account.items[candidate.item_id]

            -- A candidate whose ID the client names differently (a retired or
            -- renamed version on the Wiki) can't be trusted either way. If you
            -- don't hold it, skip it: one stale ID among thousands must not make
            -- every tier check "unknown". If you do hold it, it might be a real
            -- match, so the answer stays unknown.
            if matches and owned and owned.verified == false then
                matches = false

                if nonNegativeInteger(owned.quantity) and owned.quantity > 0 then
                    uncertain = true
                end
            end

            if matches then
                local usable = true
                candidateCount = candidateCount + 1
                lastKnownAbsent = lastKnownAbsent and owned ~= nil and owned.lastKnownAbsent == true

                for skill, level in pairs(candidate.skills) do
                    local evidence = account.skills and account.skills[skill]

                    if not available(evidence) or not nonNegativeInteger(evidence.level) then
                        usable = false
                        uncertain = true
                    elseif evidence.level < level then
                        usable = false
                    end
                end

                if available(owned) and nonNegativeInteger(owned.quantity) and owned.quantity > 0 and usable then
                    if not best or candidate.tier > best.tier then
                        best = { itemId = candidate.item_id, tier = candidate.tier, toolbelt = owned.toolbelt == true }
                    end
                elseif not available(owned) or not owned.complete or not nonNegativeInteger(owned.quantity) then
                    uncertain = true
                end

                if owned and nonNegativeInteger(owned.savedQuantity) and owned.savedQuantity > 0 and usable then
                    if not saved or candidate.tier > saved.tier then
                        saved = { itemId = candidate.item_id, tier = candidate.tier, saved = true }
                    end
                end
            end
        end

        if best then
            return result(requirement, "met", "Owned equipment meets the listed tier and use levels.", { best })
        end

        if saved then
            return result(requirement, "unknown", "A suitable item was seen in saved data; verify it in game.", { saved })
        end

        local checked

        -- Some low-tier item IDs couldn't be resolved in the source. An owned
        -- match still passes above; their absence cannot prove a low-tier failure.
        local belowCoverage = (requirement.minimum_tier or 0) < (group.minimum_complete_tier or 0)

        if uncertain or not group.complete or belowCoverage then
            checked = result(requirement, "unknown", group.note or "Equipment coverage is incomplete.")
        else
            checked = result(requirement, "unmet", "No usable matching equipment was found in checked storage.")
        end

        -- A named minimum can retain its red display border after the bank closes,
        -- but the historical hint must not become a confirmed failed access check.
        checked.lastKnownAbsent = candidateCount > 0 and lastKnownAbsent
        return checked
    end

    -- Item check: the tricky one. Seeing enough items proves the player has them. But
    -- NOT seeing them only proves they don't if we know we've seen everything (bank
    -- included). Otherwise the rest might be somewhere we haven't looked.
    if kind == "item" then
        local entry = account.items and account.items[requirement.itemId]

        if not available(entry) or not nonNegativeInteger(entry.quantity) then
            if entry and nonNegativeInteger(entry.savedQuantity) and entry.savedQuantity > 0 then
                return result(requirement, "unknown", "Seen in saved item data; current ownership needs checking.",
                    { { itemId = requirement.itemId, saved = true } })
            end

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

    -- Unmapped gear or unlocks like prayers need verified client mappings first,
    -- so for now we're honest and say "unknown".
    return result(requirement, "unknown", "This requirement is not supported yet.")
end

-- Checks listed access requirements without treating an incomplete empty list
-- as proof that a method has no requirements. Plain required notes also need the
-- player's judgement; they aren't passes just because we can't evaluate them.
function Requirements.evaluateAccess(requirements, account)
    local checked = Requirements.evaluate(requirements.access, account)

    if checked.status ~= "met" then
        return checked
    end

    local emptyIncomplete = #requirements.access.children == 0 and requirements.coverage ~= "complete"
    local unchecked = #(requirements.notes or {}) > 0 or #(requirements.unresolved or {}) > 0

    if emptyIncomplete or unchecked then
        checked.status = "unknown"
        checked.reason = "Required information is incomplete or needs your judgement."
    end

    return checked
end

return Requirements
