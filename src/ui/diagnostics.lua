-- Temporary development probes. The parent view owns all components; this module
-- only retains labels while mounted. Remove these probes before release packaging.
local ToolbeltProbe = require("src/game/toolbelt_probe")

-- Temporary: names that may hold the unlocks Wiki guides still need (lodestones,
-- Invention machines, upgrades...). Relics, War's Retreat, the Ranger's Workroom
-- and dinosaur pens are already mapped, so they're left out. Matching variable
-- names and their current values are printed, to be mapped and verified by hand.
local UNLOCK_WORDS = {
    -- Lodestones and transport
    "LODESTONE", "LODE_", "BALLOON_TRANSPORT",

    -- Invention machines (plank maker, hide tanner, generator, disassembler...)
    "PLANK_MAKER", "PLANKMAKER", "TANNER", "GENERATOR", "DISASSEMBL", "POTION_PRODUCER", "CAPACITOR",
    "MECHANISED", "MECHANIZED",

    -- Upgrades and shops
    "BONECRUSHER", "RUNE_POUCH", "SYDEKIX", "QUICK_CENSE", "QUICKCENSE", "RESTOCK", "LEGENDARY_PET",

    -- Places and areas
    "GIELINOR_HEART", "HEART_OF_GIELINOR", "SUNKEN_PYRAMID", "WELL_OF_SOULS", "HUNTER_LODGE", "BARBARIAN_TRAIN",

    -- Points
    "SLAYER_POINTS",
}

-- Families that matched a word above but only track tasks, kill counts or
-- cosmetics. Skipping them keeps the console output short enough to paste.
local UNLOCK_SKIP = {
    "LEAGUE_", "CHEEVO_", "BSLAY_", "ITEMLOG_", "COLLECTION_", "MTX", "DINO_", "COMBATV2_", "COMBAT_MASTERY",
    "BOSS_INSTANCE", "TRH", "XMAS", "LOGIN_MESSAGE", "QUEST_", "ARCH_RESTORATION", "MAKEX",
}

local function unlockName(kind, name)
    for _, prefix in ipairs(UNLOCK_SKIP) do
        if name:find(prefix, 1, true) then
            return false
        end
    end

    for _, word in ipairs(UNLOCK_WORDS) do
        if name:find(word, 1, true) then
            return true
        end
    end

    return false
end

-- Account variables only: varbits (negative IDs) and plain VarPlayers.
local UNLOCK_RANGES = {
    { kind = "VarPlayer", first = -1, last = -70001, step = -1 },
    { kind = "VarPlayer", first = 0, last = 20000, step = 1 },
}

-- Temporary: everything the client says about one achievement, to check how its
-- completion should be read before trusting it for requirements.
local function describeAchievement(achievementId)
    local lines = {}
    local achievement = config.Achievement.FromID(achievementId)

    if not achievement then
        return { "No achievement with ID " .. tostring(achievementId) .. "." }
    end

    lines[1] = achievement.name .. " (" .. achievement.configName .. ", ID " .. achievement.id .. "): progress "
        .. tostring(achievement.progress) .. ", tally " .. tostring(achievement.tallyProgress) .. "/"
        .. tostring(achievement.tallyTarget) .. ", subcategory " .. tostring(achievement.subCategory)
        .. ", sprite " .. tostring(achievement.spriteID)

    for kind, tests in pairs(achievement.achievements or {}) do
        for _, test in ipairs(tests) do
            lines[#lines + 1] = "  " .. kind .. " group " .. tostring(test.group) .. ": complete "
                .. tostring(test.isComplete) .. (test.description and (" - " .. test.description) or "")
        end
    end

    return lines
end
local Diagnostics = {}

function Diagnostics.new(account, inspectQuote, inspectQuest)
    local self = {}
    local labels = {}

    -- A hidden/destroyed Diagnostics screen must not leave discovery work running.
    function self:cancelScan()
        if self.cancelProbe then
            self.cancelProbe()
            self.cancelProbe = nil
        end
    end

    function self:unmount()
        self:cancelScan()
        labels = {}
    end

    function self:refresh()
        if not labels.player then
            return
        end
        local player = account:readPlayer()
        if player.status == "available" then
            labels.player.content = "Base levels - Prayer: " .. player.prayer .. "; Herblore: " .. player.herblore
                .. "; combat level: " .. tostring(player.combat or "unavailable") .. ". Unlock checks are not implemented."
        else
            labels.player.content = "Player data is unavailable outside a game world."
        end
        labels.events.content = "Inventory events: " .. account.eventCount .. ". " .. account.lastEvent

        local inspected = account.inspection
        if inspected and inspected.status == "available" then
            labels.inventory.content = inspected.name .. ": " .. #inspected.items .. " populated slots read out of "
                .. inspected.slotCount .. ". Completeness remains unverified."
            local preview = {}
            for index = 1, math.min(#inspected.items, 12) do
                local item = inspected.items[index]
                preview[#preview + 1] = "Slot " .. item.slot .. ": " .. (item.name or "Unnamed item")
                    .. " [" .. item.itemId .. "] x" .. item.quantity
            end
            if #inspected.items > 12 then
                preview[#preview + 1] = "Showing first 12 items."
            end
            labels.inventory.content = labels.inventory.content .. "\n" .. table.concat(preview, "\n")
        elseif inspected then
            labels.inventory.content = inspected.message or inspected.status
        else
            labels.inventory.content = "No current inventory inspection. Open the bank, then inspect BANK."
        end

        local quest = account.questInspection
        if quest and quest.status == "available" then
            local progress = quest.completed and "Completed" or (quest.started and "Started" or "Not started")
            labels.quest.content = quest.name .. ": " .. progress .. ". Compare with your quest journal."
            if quest.requirement then
                labels.quest.content = labels.quest.content .. " Requirement: " .. quest.requirement.status .. "."
            end
        elseif quest then
            labels.quest.content = quest.message or quest.status
        else
            labels.quest.content = "No current quest inspection."
        end
    end

    function self:mount(view, guarded)
        self:unmount()
        view:AddTitle("Diagnostics")
        view:AddText("Development diagnostics: account access and dependency checks.")
        labels.player = view:AddText("")
        view:AddSimpleButton("Refresh player status", guarded(function()
            self:refresh()
        end))

        view:AddTitle("Inventory availability")
        view:AddText("Reads local inventory data only. This does not establish ownership while data is unavailable.")
        local inventoryName = view:AddTextField({ text = "BANK", maxLength = 64 })
        labels.inventory = view:AddText("")
        view:AddSimpleButton("Inspect inventory", guarded(function()
            local result = account:inspectInventory(inventoryName:GetText())
            self:refresh()
            if result.status ~= "available" then
                labels.inventory.content = result.message or result.status
            end
        end))
        labels.events = view:AddText("")
        view:AddText("Equip or remove an item, then inspect the last changed inventory. Confirm its contents match your equipment.")
        view:AddSimpleButton("Inspect last changed inventory", guarded(function()
            if account.lastInventoryName then
                account:inspectInventory(account.lastInventoryName)
                self:refresh()
            else
                labels.inventory.content = "No inventory change observed yet. Equip or remove an item first."
            end
        end))

        view:AddTitle("Tool-belt hatchet")
        local toolbeltResult = view:AddText("Not checked. Raw values do not establish an owned item yet.")
        view:AddSimpleButton("Inspect tool-belt hatchet", guarded(function()
            local result = account:inspectToolbeltHatchet()

            if result.status == "available" then
                toolbeltResult.content = "Raw hatchet value: " .. result.value .. " (config " .. result.configId
                    .. "). Compare with the hatchet shown on your tool belt."
            else
                toolbeltResult.content = result.message
            end
        end))

        local resolvedTools = view:AddText("Resolved tool-belt items have not been checked.")
        view:AddSimpleButton("Read tool-belt items", guarded(function()
            local belt = account:readToolbelt()
            local lines = {}

            for family, slot in pairs(belt.slots) do
                lines[#lines + 1] = family .. ": " .. (slot.itemId and slot.name .. " [" .. slot.itemId .. "]" or slot.message or "No tool present")
            end

            table.sort(lines)
            resolvedTools.content = #lines > 0 and table.concat(lines, "\n") or belt.message or "No mapped families."
        end))

        local toolbeltMetadata = view:AddText("Shared tool-belt mapping discovery has not run.")
        view:AddSimpleButton("Inspect tool-belt metadata", guarded(function()
            self:cancelScan()
            toolbeltMetadata.content = "Scanning native configs in small batches; keep Diagnostics open."

            self.cancelProbe = ToolbeltProbe.start(guarded(function(line)
                print("[Profit Path toolbelt] " .. line)
            end), guarded(function(scanned, matched)
                toolbeltMetadata.content = "Inspected " .. scanned .. " IDs; found " .. matched .. " candidate configs."
            end), guarded(function(result)
                local summary = result.message .. " Inspected " .. result.scanned .. "; candidates " .. result.matched
                    .. "; read failures " .. result.failures .. "."
                toolbeltMetadata.content = summary
                print("[Profit Path toolbelt] " .. summary)

                if result.firstFailure then
                    print("[Profit Path toolbelt] First failed read: " .. result.firstFailure)
                end
            end))
        end))

        view:AddTitle("Quest availability")
        view:AddText("Enter a verified, non-deprecated quest config name. General unlock detection is not implemented.")
        local questName = view:AddTextField({ text = "COOKS_ASSISTANT", maxLength = 64 })
        labels.quest = view:AddText("")
        view:AddSimpleButton("Inspect quest", guarded(function()
            local result = inspectQuest(questName:GetText())
            self:refresh()
            if result.status ~= "available" then
                labels.quest.content = result.message or result.status
            end
        end))

        -- Temporary: discovery for unlocks that Wiki requirements mention.
        view:AddTitle("Unlock discovery")
        view:AddText("Lists account variables whose names mention lodestones, farm machines, War's Retreat and similar, "
            .. "with their values (console). Keep Diagnostics open while it runs.")
        local unlockStatus = view:AddText("Not scanned yet.")
        view:AddSimpleButton("Scan lodestone and farm variables", guarded(function()
            self:cancelScan()
            unlockStatus.content = "Scanning account variables in small batches..."

            self.cancelProbe = ToolbeltProbe.start(guarded(function(line)
                print("[Profit Path unlocks] " .. line)
            end), guarded(function(scanned, matched)
                unlockStatus.content = "Inspected " .. scanned .. " IDs; found " .. matched .. " candidates."
            end), guarded(function(result)
                unlockStatus.content = result.message .. " Inspected " .. result.scanned .. "; candidates "
                    .. result.matched .. "; read failures " .. result.failures .. "."
                print("[Profit Path unlocks] " .. unlockStatus.content)
            end), { ranges = UNLOCK_RANGES, matches = unlockName, limit = 2000 })
        end))

        view:AddText("Achievement ID to inspect (compare with your achievement journal):")
        local achievementField = view:AddTextField({ text = "2871", maxLength = 8 })
        local achievementStatus = view:AddText("")
        view:AddSimpleButton("Inspect achievement", guarded(function()
            local ok, lines = pcall(describeAchievement, tonumber(achievementField:GetText()))
            lines = ok and lines or { "Inspect failed: " .. tostring(lines) }

            for _, line in ipairs(lines) do
                print("[Profit Path achievement] " .. line)
            end

            achievementStatus.content = table.concat(lines, "\n")
        end))

        view:AddTitle("GE Price Library")
        view:AddText("Manual quote check. The library manages its own HTTP permission and cached refreshes.")
        labels.quote = view:AddText("Not checked. No profit valuation basis has been selected.")
        view:AddSimpleButton("Check chronotes quote", guarded(function()
            local quote = inspectQuote()
            if quote.status == "available" or quote.status == "partial" then
                -- Source is "hour" (last hour's average) or "latest" (one trade).
                labels.quote.content = "Buy: " .. tostring(quote.high or "unavailable")
                    .. " (" .. tostring(quote.highSource or "unavailable") .. ", timestamp "
                    .. tostring(quote.highTime or "unavailable") .. "); sell: "
                    .. tostring(quote.low or "unavailable") .. " (" .. tostring(quote.lowSource or "unavailable")
                    .. ", timestamp " .. tostring(quote.lowTime or "unavailable") .. "). Not a guide-price estimate."
            else
                labels.quote.content = quote.message
            end
        end))
        self:refresh()
    end

    return self
end

return Diagnostics
