-- Tests for the data readers behind the custom activity editor (item search and
-- thieving loot), using the real shipped data/ge_items.lua and data/thieving.lua.
-- The expected values come from the 4 Nov Wiki import.
return function(test, equal)
    local ItemNames = require("src/data/item_names")
    local Thieving = require("src/data/thieving_data")
    local Monsters = require("src/data/monster_data")

    test("item search finds GE items by any part of their name, ignoring case", function()
        local results, total = ItemNames.search("  MONK'S ROBE ", 10)

        -- Both robes, told apart by their page names, in label order.
        equal(total, 2)
        equal(results[1].label, "Monk's robe (bottom)")
        equal(results[2].label, "Monk's robe (top)")
        equal(ItemNames.label(results[2].id), "Monk's robe (top)")

        -- The limit caps the list but not the count, so the editor can say
        -- "showing 5 of N".
        local some, many = ItemNames.search("rune", 5)

        equal(#some, 5)
        assert(many > 5, "expected many rune items")

        -- Brackets and dashes are plain characters, not search patterns.
        local dosed = ItemNames.search("super attack (", 10)
        assert(#dosed > 0, "expected dose items")

        -- A blank query lists nothing, and unknown IDs have no label.
        equal(select(2, ItemNames.search("   ", 10)), 0)
        equal(ItemNames.label(-1), nil)
    end)

    test("thieving targets read back with their Thieving level and drop tables", function()
        local farmer = Thieving.find("Master Farmer")

        equal(farmer.level, 38)
        equal(farmer.sections[#farmer.sections].title, "Pickpocketing")

        -- Coins use the same item ID as the monster snapshot.
        local coins

        for _, row in ipairs(farmer.sections[#farmer.sections].drops) do
            if row.name == "Coins" then
                coins = row
            end
        end

        equal(coins.item_id, 995)
        equal(coins.quantity_low, 50)
        equal(coins.quantity_high, 100)

        -- Dig-site versions are separate targets; unknown titles say so.
        assert(Thieving.find("Archaeologist (Kharid-et)"), "expected a dig-site version")
        equal(Thieving.find("Archaeologist"), nil)
        equal(select(2, Thieving.find("Nobody")), "unknown")
    end)

    test("the thieving reader keeps its own data apart from the monster snapshot", function()
        -- Both use the same reader code, but each opens its own file.
        equal(Monsters.find("Master Farmer"), nil)
        assert(Monsters.find("Abomination"), "monster snapshot still reads")
        equal(Monsters.find("Abomination").level, nil)
        equal(Thieving.find("Abomination"), nil)
        assert(Thieving.info().monsters > 100, "expected the thieving targets")
    end)
end
