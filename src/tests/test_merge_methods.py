"""Tests for src/tools/merge_methods.py: turning Wiki guides into method records."""
# Each test converts a small hand-made guide (shaped like one line of
# catalogue-source/wiki/guides.jsonl) and checks the record that comes out. The
# real merge of every guide is checked by src/tools/test.py through the validator.
import unittest

import catalogue
import merge_methods


def guide(**fields):
    base = {"page": "Money making guide/Fixture", "revision": 123, "activity": "Fixture",
            "category": "Processing", "intensity": "Low", "members": True, "wiki_profit": 1000,
            "inputs": [], "outputs": []}
    base.update(fields)

    return base


def context(recipes=None, capabilities=None, quests=None):
    meta = {
        "retrieved": "2026-10-29",
        "items": {"Coins": 995, "Logs": 1511, "Aggroverload": 48239, "Gem bag (upgraded)": 31455,
                  "Artificer's measure": 50805},
        "item_families": {"Aggroverload": [48229, 48239]},
    }

    return merge_methods.Context({}, meta, capabilities or {}, recipes or {}, quests or {})


class IncomeTests(unittest.TestCase):
    def test_per_hour_guides_scale_with_a_pace_percentage(self):
        ctx = context()
        method = merge_methods.convert_guide(guide(
            inputs=[["Logs", 1000, "hour", "ge", 50]],
            outputs=[["Coins", 250000, "hour", "value", 1], ["Mystery item", 10, "hour", "ge", 5]],
        ), ctx, "production")
        income = method["income"]

        # 100% is the guide's pace, so each amount is stored per 1%.
        self.assertEqual(income["rate"], {"key": "guide_pace", "unit": "% of guide pace", "default": 100})
        self.assertEqual(income["inputs"][0], {"name": "Logs", "quantity": 10, "basis": "action", "item_id": 1511})

        # The Wiki's fixed value stays fixed and pays no tax.
        coins = income["outputs"][0]
        self.assertEqual((coins["pricing"], coins["unit_value"], coins["quantity"]), ("fixed", 1, 2500))
        self.assertNotIn("tax_denominator", coins)

        # A GE item without an ID can't be priced, so the income is partial.
        self.assertEqual(income["coverage"], "partial")
        self.assertEqual(income["unresolved"], ["No item ID found for Mystery item."])

    def test_per_kill_guides_keep_their_rate_and_tax_their_sales(self):
        ctx = context()
        pvm = merge_methods.convert_guide(guide(kph=900, outputs=[["Logs", 0.5, "action", "ge", 50]]), ctx, "pvm")
        skilling = merge_methods.convert_guide(guide(kph=300), ctx, "skilling")

        self.assertEqual(pvm["income"]["rate"], {"key": "kills_per_hour", "unit": "kills/hour", "default": 900})
        self.assertEqual(pvm["income"]["outputs"][0]["tax_denominator"], 50)
        self.assertEqual(pvm["income"]["coverage"], "complete")
        self.assertEqual(skilling["income"]["rate"]["unit"], "actions/hour")

    def test_untradeables_use_our_recipe_only_when_the_doses_agree(self):
        recipes = {"Aggroverload": {"output": {"portion": 6}}, "Plain mix": {"output": {}}}
        ctx = context(recipes)
        method = merge_methods.convert_guide(guide(kph=900, inputs=[
            ["Aggroverload (6)", 1, "hour", "calc", 159457, "potioncost|Aggroverload"],
            ["Aggroverload", 1, "hour", "calc", 159457],
            ["Plain mix", 1, "hour", "calc", 10],
        ]), ctx, "pvm")
        dosed, undosed, plain = method["income"]["inputs"]

        self.assertEqual((dosed["pricing"], dosed["recipe"], dosed["portion"]), ("recipe", "Aggroverload", 6))
        self.assertEqual((plain["pricing"], plain["recipe"]), ("recipe", "Plain mix"))

        # No dose to match a 6-dose recipe: fall back to the Wiki's own figure.
        self.assertEqual((undosed["pricing"], undosed["unit_value"]), ("fixed", 159457))
        self.assertIn("calculated value", undosed["valuation_note"])

    def test_potioncost_rows_follow_the_templates_meaning(self):
        recipes = {"Aggroverload": {"output": {"name": "Aggroverload (6)", "portion": 6}},
                   "Adrenaline renewal potion": {"output": {"name": "Adrenaline renewal potion (4)"}}}
        ctx = context(recipes)
        method = merge_methods.convert_guide(guide(kph=900, inputs=[
            # {{potioncost}} with no dose is one finished potion: a whole 6-dose one.
            ["Aggroverload", 1, "hour", "calc", 159457, "potioncost|Aggroverload"],
            # A recipe without doses that makes exactly this item.
            ["Adrenaline renewal potion (4)", 1, "hour", "calc", 50000, "potioncost|Adrenaline renewal potion (4)"],
            # An improved recipe tier is cheaper than our standard recipe.
            ["Adrenaline renewal potion (4)", 1, "hour", "calc", 40000, "potioncost|adrenaline renewal 2"],
        ]), ctx, "pvm")
        whole, exact, improved = method["income"]["inputs"]

        self.assertEqual((whole["pricing"], whole["recipe"], whole["portion"]), ("recipe", "Aggroverload", 6))
        self.assertEqual((exact["pricing"], exact["recipe"]), ("recipe", "Adrenaline renewal potion"))
        self.assertNotIn("portion", exact)
        self.assertEqual((improved["pricing"], improved["unit_value"]), ("fixed", 40000))


class RequirementTests(unittest.TestCase):
    def convert(self, requirements, capabilities=None):
        ctx = context(capabilities=capabilities)
        method = merge_methods.convert_guide(guide(requirements=requirements), ctx, "pvm")

        return method["requirements"], ctx.items

    def test_recommendations_in_the_required_source_list_are_not_access_checks(self):
        requirements, _ = self.convert({"required": [
            {"req": "item:Aggroverload", "text": "Aggroverload strongly recommended"},
            {"req": "skill:PRAYER:99", "text": "99 Prayer (recommended)"},
            {"text": "A team recommended"},
        ]})

        self.assertEqual(requirements["access"]["children"], [])
        self.assertEqual(requirements["notes"], [])
        self.assertEqual(len(requirements["recommended"]["children"]), 2)
        self.assertEqual(requirements["tips"], [{"text": "A team recommended"}])

    def test_recommended_upgrades_do_not_remove_the_required_minimum(self):
        requirements, _ = self.convert({"required": [
            {"req": "skill:MINING:90", "text": "90 Mining (99 recommended for Mining cape)"},
        ]})

        self.assertEqual(len(requirements["access"]["children"]), 1)
        self.assertEqual(requirements["recommended"]["children"], [])
        self.assertFalse(merge_methods.wording_is_suggestion(
            "Tier 80+ pickaxe (Augmentable pickaxe highly recommended)"))
        self.assertTrue(merge_methods.wording_is_suggestion(
            "Diviner's outfit (Optional when making Sign of the Porters)"))

    def test_access_research_is_variant_pinned_and_keeps_recommendations(self):
        ctx = context()
        ctx.access_research["fixture.standard"] = {
            "page": "Money making guide/Fixture", "version": "", "revision": 123,
            "additional_required": ["skill:MINING:16"], "notes": [], "sources": [],
        }
        result = merge_methods.convert_guide(guide(requirements={"recommended": ["skill:MINING:40"]}), ctx, "skilling")
        self.assertEqual(result["requirements"]["access"]["children"][0]["level"], 16)
        self.assertEqual(result["requirements"]["recommended"]["children"][0]["level"], 40)
        ctx.access_research["fixture.standard"]["revision"] = 124

        with self.assertRaisesRegex(ValueError, "pinned guide"):
            merge_methods.convert_guide(guide(), ctx, "skilling")

    def test_choice_labels_keep_tier_checks_when_all_links_are_advice_pages(self):
        requirements, _ = self.convert({"required": [{
            "req": ["any", "item:Magic weapon", "item:Ranged weapon"],
            "text": "Tier 20+ Magic or Ranged weapon",
        }]}, capabilities={"Magic weapon": {"kind": "guidance"}, "Ranged weapon": {"kind": "guidance"}})
        check = requirements["access"]["children"][0]
        self.assertEqual(check["kind"], "any")
        self.assertEqual({child["style"] for child in check["children"]}, {"magic", "ranged"})
        self.assertEqual({child["minimum_tier"] for child in check["children"]}, {20})

    def test_weaponry_labels_are_real_gear_requirements(self):
        for text, tier in [("Tier 10+ melee weaponry", 10), ("Tier 70+ magic weaponry", 70)]:
            requirements, _ = self.convert({"required": [{"text": text}]})
            check = requirements["access"]["children"][0]
            self.assertEqual(check["kind"], "gear")
            self.assertEqual(check["minimum_tier"], tier)
            self.assertEqual(check["slot"], "weapon")

    def test_checkable_requirements_become_skill_and_item_checks(self):
        requirements, items = self.convert({
            "required": ["skill:SLAYER:85", ["any", "item:Gem bag (upgraded)", "item:Artificer's measure"],
                         "item:Coins:500"],
            "recommended": ["item:Aggroverload"],
        })
        slayer, bag, coins = requirements["access"]["children"]

        self.assertEqual(slayer, {"kind": "skill", "skill": "SLAYER", "level": 85, "text": "85 Slayer"})
        self.assertEqual(bag["text"], "Gem bag (upgraded) or Artificer's measure")
        self.assertEqual(bag["display_items"], [31455, 50805])
        self.assertEqual((coins["quantity"], coins["text"]), (500, "500 Coins"))

        # A single item shows its icon (with an owned / missing border); a stack keeps
        # its text so the amount is visible.
        self.assertNotIn("display_items", coins)
        self.assertEqual(bag["children"][0]["display_items"], [31455])

        # A dose-less potion is any dose: its item lists every dose to own.
        self.assertEqual(requirements["recommended"]["children"][0]["text"], "Aggroverload (recommended)")
        self.assertEqual(items["48239"]["ownership_ids"], [48229, 48239])

        # The Wiki's list is a start, not a verified list.
        self.assertEqual(requirements["coverage"], "partial")

    def test_everything_else_is_an_unknown_capability_with_its_sprite_or_the_quest_icon(self):
        requirements, _ = self.convert({
            "required": ["skill:TOTAL_LEVEL:1500", "quest:Priest in Peril", "item:Death Note",
                         "item:Armour/Magic armour#High level equipment (61+)"],
            "optional": [{"text": "A team of 1-3 other players"}],
        }, {"Death Note": {"kind": "relic", "sprite": "ARCH_ICON_RELIC_64PX_DEATH_NOTE"}})
        combat, quest, relic, page = requirements["access"]["children"]

        self.assertEqual(combat, {"kind": "capability", "text": "1500 Total level"})
        self.assertEqual(quest["display_icon"], "quest")
        self.assertEqual(relic["display_icon"], catalogue.capability_icon("ARCH_ICON_RELIC_64PX_DEATH_NOTE"))
        self.assertEqual(page["text"], "Magic armour: High level equipment (61+)")

        # An optional (or recommended) thing that can't be checked is a tip, not a check.
        self.assertEqual(requirements["tips"], [{"text": "A team of 1-3 other players"}])
        self.assertEqual(requirements["recommended"]["children"], [])

    def test_the_wikis_own_wording_wins_and_recommended_isnt_said_twice(self):
        requirements, _ = self.convert({
            "required": [{"req": "item:Coins", "text": "Coins or above"}],
            "recommended": [{"req": "quest:Priest in Peril", "text": "Priest in Peril recommended for teleports"}],
        })

        self.assertEqual(requirements["access"]["children"][0]["text"], "Coins or above")
        self.assertEqual(requirements["tips"][0]["text"], "Priest in Peril recommended for teleports")
        self.assertEqual(requirements["tips"][0]["icons"], ["quest"])


class ResearchTests(unittest.TestCase):
    """How research/quests.json and capabilities.json change a converted method."""

    def convert(self, requirements):
        ctx = context(
            capabilities={
                "Armoury": {"kind": "guidance"},
                "Recommended equipment for PvM/Magic": {"kind": "guidance"},
                "Master camouflage outfit": {"kind": "outfit"},
            },
            quests={"Priest in Peril": "PRIEST_IN_PERIL", "New Foundations": "QUEST_FORT_INTRO"},
        )
        method = merge_methods.convert_guide(guide(requirements=requirements), ctx, "pvm")

        return method["requirements"]

    def test_mapped_quests_become_real_quest_checks_even_when_linked_as_items(self):
        requirements = self.convert({"required": ["quest:Priest in Peril", "item:New Foundations",
                                                  "quest:Some Unmapped Quest"]})
        priest, foundations, unmapped = requirements["access"]["children"]

        self.assertEqual(priest, {"kind": "quest", "quest": "PRIEST_IN_PERIL", "text": "Priest in Peril",
                                  "display_icon": "quest"})
        self.assertEqual(foundations["quest"], "QUEST_FORT_INTRO")

        # An unmapped quest stays unknown, but still says it's a quest.
        self.assertEqual((unmapped["kind"], unmapped["capability_kind"]), ("capability", "quest"))

    def test_bare_wiki_advice_links_are_dropped_and_worded_advice_kept(self):
        requirements = self.convert({
            "required": ["item:Armoury", ["any", "item:Coins", "item:Recommended equipment for PvM/Magic"],
                         {"req": "item:Armoury", "text": "Weight-reducing clothing"},
                         {"req": "item:Armoury", "text": "Armoury"}],
            "recommended": [{"req": "item:Armoury", "text": "Hybrid armour recommended (suggested warpriest armour)"}],
        })

        # The advice-only requirement is gone, and the group's one real option is
        # left (as itself: "any one of" a single thing is just that thing).
        children = requirements["access"]["children"]
        self.assertEqual(len(children), 1)
        self.assertEqual(children[0]["itemId"], 995)
        self.assertEqual(requirements["recommended"]["children"], [])

        # No "See also" links. The guide's own words survive: required ones for
        # the player to judge, recommended ones as tips.
        self.assertNotIn("advice", requirements)
        self.assertEqual(requirements["notes"], ["Weight-reducing clothing"])
        self.assertEqual(requirements["tips"], [{"text": "Hybrid armour recommended (suggested warpriest armour)"}])

    def test_classified_capabilities_say_what_they_are(self):
        requirements = self.convert({"required": ["item:Master camouflage outfit", "item:Something else"]})
        outfit, other = requirements["access"]["children"]

        self.assertEqual(outfit["capability_kind"], "outfit")
        self.assertNotIn("capability_kind", other)


class DropCheckTests(unittest.TestCase):
    """Comparing a guide's per-kill drops with the monster's drop table."""

    def setUp(self):
        self.tables = merge_methods.monster_tables({"monsters": [{"title": "Fixture beast", "sections": [
            {"title": "Main", "drops": [
                {"name": "Bones", "quantity": "1", "rate": "Always"},
                {"name": "Coins", "quantity": "100-300", "quantity_low": 100, "quantity_high": 300, "rate": "1/4"},
                {"name": "Coins", "quantity": "1000", "rate": "1/100"},
            ]},
            {"title": "Unique", "drops": [{"name": "Fixture blade", "quantity": "1", "rate": "1/284–1/1,988"}]},
        ]}]})

    def check(self, outputs, version=None, page="Money making guide/Killing fixture beasts"):
        return merge_methods.check_drops(guide(page=page, version=version, kph=100, outputs=outputs), self.tables)

    def test_matching_fixed_rate_drops_are_checked(self):
        # Coins: 1/4 x 200 + 1/100 x 1000 = 60 per kill, summed over both rows.
        result = self.check([["Bones", 1, "action", "ge", 1], ["Coins", 58, "action", "value", 1]])
        self.assertEqual((result["status"], result["agree"]), ("drops checked", 2))

    def test_condition_dependent_rare_drops_leave_it_partly_checked(self):
        result = self.check([["Bones", 1, "action", "ge", 1], ["Fixture blade", 0.003, "action", "ge", 1]])
        self.assertEqual((result["status"], result["conditional"]), ("drops partly checked", 1))

    def test_a_fixed_rate_drop_that_doesnt_match_is_listed(self):
        result = self.check([["Coins", 120, "action", "value", 1], ["Dragon bones", 1, "action", "ge", 1]])
        self.assertEqual(result["status"], "drops differ")
        self.assertEqual(result["differ"], ["Coins", "Dragon bones"])

    def test_settings_the_base_table_cant_check_and_missing_monsters(self):
        self.assertEqual(self.check([["Bones", 9, "action", "ge", 1]], version="2000 Enrage")["status"], "setting-specific")
        self.assertEqual(self.check([], version="Hard mode")["status"], "setting-specific")
        self.assertEqual(self.check([], page="Money making guide/Killing ghosts")["status"], "no drop table")

        # Plural guide names find the singular monster.
        self.assertEqual(merge_methods.monster_for("Money making guide/Killing fixture beasts", self.tables)["title"],
                         "Fixture beast")


class RecurringTests(unittest.TestCase):
    def test_recurring_guides_count_per_run_with_a_yield_and_their_cycle(self):
        ctx = context()
        method = merge_methods.convert_guide(guide(
            recurring={"every": "24 Hours", "minutes": 2},
            inputs=[["Coins", 500, "run", "value", 1]],
            outputs=[["Logs", 100, "run", "ge", 50]],
        ), ctx, "skilling")
        income = method["income"]

        self.assertEqual(income["period"], "run")
        self.assertEqual(income["rate"], {"key": "guide_yield", "unit": "% of guide yield", "default": 100})
        self.assertEqual(income["recurrence"], {"every": "24 hours", "minutes": 2})

        # Stored per 1% of yield, like a pace: 100% gives the guide's own amounts.
        self.assertEqual((income["outputs"][0]["quantity"], income["outputs"][0]["basis"]), (1, "action"))
        self.assertIn("Can be done every 24 hours; a run takes about 2 minutes.", income["assumptions"])

        catalogue.validate_methods({"schema": 1, "items": ctx.items, "methods": [method]}, {"monsters": []})

    def test_per_run_income_needs_its_cycle_and_hourly_income_has_none(self):
        ctx = context()
        method = merge_methods.convert_guide(guide(recurring={"every": "7 days", "minutes": 5}), ctx, "skilling")
        del method["income"]["recurrence"]

        with self.assertRaisesRegex(ValueError, "Recurring income"):
            catalogue.validate_methods({"schema": 1, "items": ctx.items, "methods": [method]}, {"monsters": []})

        hourly = merge_methods.convert_guide(guide(), ctx, "skilling")
        hourly["income"]["recurrence"] = {"every": "1 day", "minutes": 1}

        with self.assertRaisesRegex(ValueError, "Only per-run"):
            catalogue.validate_methods({"schema": 1, "items": ctx.items, "methods": [hourly]}, {"monsters": []})


class CombatTests(unittest.TestCase):
    def test_combat_and_melee_levels_become_checks(self):
        ctx = context()
        method = merge_methods.convert_guide(guide(requirements={
            "required": ["skill:COMBAT:70", "skill:MELEE:90"],
            "recommended": [{"req": "skill:COMBAT:40", "text": "40 recommended for Dragon Slayer"}],
        }), ctx, "pvm")
        combat, melee = method["requirements"]["access"]["children"]

        self.assertEqual(combat, {"kind": "combat_level", "level": 70, "text": "70 Combat"})

        # "Melee" means both melee skills at that level.
        self.assertEqual(melee["kind"], "all")
        self.assertEqual(melee["text"], "90 Melee (Attack and Strength)")
        self.assertEqual([(c["skill"], c["level"]) for c in melee["children"]], [("ATTACK", 90), ("STRENGTH", 90)])

        # The Wiki's own wording is kept, and it already says "recommended".
        self.assertEqual(method["requirements"]["recommended"]["children"][0]["text"], "40 recommended for Dragon Slayer")

        catalogue.validate_methods({"schema": 1, "items": ctx.items, "methods": [method]}, {"monsters": []})

    def test_constitution_uses_the_clients_hitpoints_skill_name(self):
        ctx = context()
        method = merge_methods.convert_guide(guide(requirements={"required": ["skill:CONSTITUTION:80"]}), ctx, "pvm")

        # Checked as HITPOINTS (the client's SkillType), but players read "Constitution".
        self.assertEqual(method["requirements"]["access"]["children"][0],
                         {"kind": "skill", "skill": "HITPOINTS", "level": 80, "text": "80 Constitution"})

    def test_combat_level_above_the_maximum_is_refused(self):
        with self.assertRaisesRegex(ValueError, "1 to 152"):
            catalogue.validate_requirement({"kind": "combat_level", "level": 200, "text": "200 Combat"}, {})


class OutfitTests(unittest.TestCase):
    def test_a_known_outfit_becomes_all_of_its_pieces(self):
        ctx = context(capabilities={"Ghost hunter equipment": {"kind": "outfit"}})
        ctx.outfits = {"Ghost hunter equipment": [
            ["head", "Ghost hunter goggles", 32386],
            ["body", "Ghost hunter body", 32380, [32378, 32380]],
        ]}
        method = merge_methods.convert_guide(guide(requirements={"recommended": ["item:Ghost hunter equipment"]}),
                                             ctx, "pvm")
        outfit = method["requirements"]["recommended"]["children"][0]

        self.assertEqual(outfit["kind"], "all")
        self.assertEqual(outfit["text"], "Ghost hunter equipment (recommended)")
        self.assertEqual(outfit["display_items"], [32386, 32380])
        self.assertEqual([child["itemId"] for child in outfit["children"]], [32386, 32380])

        # Owning any charge level of a piece counts.
        self.assertEqual(ctx.items["32380"]["ownership_ids"], [32378, 32380])
        self.assertEqual(ctx.items["32386"]["name"], "Ghost hunter goggles")

        # And it passes the same validator as curated methods.
        catalogue.validate_methods({"schema": 1, "items": ctx.items, "methods": [method]}, {"monsters": []})


class NamingTests(unittest.TestCase):
    def test_ids_categories_and_names(self):
        self.assertEqual(merge_methods.method_id(guide(version="Hard Mode w/ Flight Skip")),
                         "fixture.hard-mode-w-flight-skip")
        self.assertEqual(merge_methods.method_id(guide()), "fixture.standard")

        self.assertEqual(merge_methods.activity_category("Combat/High"), "pvm")
        self.assertEqual(merge_methods.activity_category("Processing"), "production")
        self.assertEqual(merge_methods.activity_category("Collecting"), "skilling")
        self.assertEqual(merge_methods.activity_category(None), "skilling")

    def test_merged_records_pass_the_curated_validator(self):
        # One converted guide, checked exactly like a curated method.
        ctx = context()
        method = merge_methods.convert_guide(guide(kph=10, requirements={"required": ["skill:SLAYER:85"]},
                                                   outputs=[["Logs", 1, "action", "ge", 50]]), ctx, "pvm")
        catalogue.validate_methods({"schema": 1, "items": ctx.items, "methods": [method]}, {"monsters": []})


if __name__ == "__main__":
    unittest.main()


class UnlockTests(unittest.TestCase):
    def test_relics_with_a_verified_flag_and_mapped_achievements_become_checks(self):
        ctx = context(capabilities={
            "Death Note": {"kind": "relic", "flag": "ARCH_RELIC_DEATH_NOTE_UNLOCKED"},
            "Hard Ardougne achievements": {"kind": "achievement"},
        })
        ctx.achievements = {"Hard Ardougne achievements": [101, 102]}
        method = merge_methods.convert_guide(guide(requirements={
            "required": ["item:Death Note", "item:Hard Ardougne achievements"],
        }), ctx, "pvm")
        relic, diary = method["requirements"]["access"]["children"]

        self.assertEqual(relic, {"kind": "flag", "var": "ARCH_RELIC_DEATH_NOTE_UNLOCKED", "text": "Death Note"})
        self.assertEqual(diary, {"kind": "achievement", "ids": [101, 102], "text": "Hard Ardougne achievements"})

        catalogue.validate_methods({"schema": 1, "items": ctx.items, "methods": [method]}, {"monsters": []})

    def test_bad_flag_names_and_achievement_ids_are_refused(self):
        with self.assertRaisesRegex(ValueError, "game variable"):
            catalogue.validate_requirement({"kind": "flag", "var": "lower case", "text": "Relic"}, {})

        with self.assertRaisesRegex(ValueError, "achievement IDs"):
            catalogue.validate_requirement({"kind": "achievement", "ids": [], "text": "Diary"}, {})


class SpellTests(unittest.TestCase):
    def test_a_spell_with_known_unlocks_becomes_its_quest_and_level(self):
        ctx = context(capabilities={"Vampyrism": {"kind": "spell", "requires": ["quest:Desert Treasure", "skill:MAGIC:69"]}},
                      quests={"Desert Treasure": "DESERT_TREASURE"})
        method = merge_methods.convert_guide(guide(requirements={"required": ["item:Vampyrism"]}), ctx, "pvm")
        spell = method["requirements"]["access"]["children"][0]

        self.assertEqual(spell["kind"], "all")
        self.assertEqual(spell["text"], "Vampyrism (Desert Treasure, 69 Magic)")
        self.assertEqual([child["kind"] for child in spell["children"]], ["quest", "skill"])

        catalogue.validate_methods({"schema": 1, "items": ctx.items, "methods": [method]}, {"monsters": []})


class FreeTextTests(unittest.TestCase):
    def test_free_text_is_researched_dropped_or_listed_for_the_player(self):
        ctx = context(capabilities={
            "Lunar spellbook active": {"kind": "spell", "requires": ["quest:Lunar Diplomacy"]},
            "Strategies": {"kind": "noise"},
        }, quests={"Lunar Diplomacy": "LUNAR_DIPLOMACY"})
        method = merge_methods.convert_guide(guide(requirements={
            "required": [{"text": "Lunar spellbook active"}, {"text": "Strategies"}, {"text": "A team of 1-3 other players"}],
            "recommended": [{"text": "A cannon"}],
        }), ctx, "pvm")
        requirements = method["requirements"]

        # Researched words become a real check; noise disappears.
        lunar, = requirements["access"]["children"]
        self.assertEqual(lunar["text"], "Lunar spellbook active (Lunar Diplomacy)")
        self.assertEqual(lunar["children"][0]["kind"], "quest")

        # Required words nobody can check are for the player to judge; recommended
        # ones are tips as before.
        self.assertEqual(requirements["notes"], ["A team of 1-3 other players"])
        self.assertEqual(requirements["tips"], [{"text": "A cannon"}])

        catalogue.validate_methods({"schema": 1, "items": ctx.items, "methods": [method]}, {"monsters": []})



class TieredGearTests(unittest.TestCase):
    def labels(self, check):
        if check["kind"] == "gear":
            return check["text"]

        return [self.labels(child) for child in check["children"]]

    def test_tier_lines_become_gear_checks_on_the_combat_group(self):
        weapon = merge_methods.tiered_gear("Tier 90+ magic weapon ( Inquisitor staff is best in slot)")

        self.assertEqual(weapon["kind"], "gear")
        self.assertEqual((weapon["minimum_tier"], weapon["style"], weapon["slot"]), (90, "magic", "weapon"))
        self.assertEqual(weapon["equipment_group"], "combat_equipment")

        # Two tiers need both; one tier for "weapon and armour" covers both pieces.
        self.assertEqual(self.labels(merge_methods.tiered_gear("Tier 90+ weapon and Tier 80+ armour, perked.")),
                         ["T90+ weapon", "T80+ body armour"])
        self.assertEqual(self.labels(merge_methods.tiered_gear("Tier 90+ magic weapon and armour")),
                         ["T90+ magic weapon", "T90+ magic body armour"])

        # Listed styles are alternatives.
        either = merge_methods.tiered_gear("Tier 90+ melee weapon, ranged weapon or magic weapon")
        self.assertEqual(either["kind"], "any")
        self.assertEqual(self.labels(either), ["T90+ melee weapon", "T90+ ranged weapon", "T90+ magic weapon"])

    def test_wiki_armour_links_take_their_style_from_the_page(self):
        armour = merge_methods.tiered_gear("Armour/Magic armour#High-level equipment (61+)")
        self.assertEqual((armour["minimum_tier"], armour["style"], armour["slot"]), (61, "magic", "body"))
        self.assertEqual(armour["text"], "Magic armour: High-level equipment (61+)")

        # The Wiki's "High level equipment" section is 61+ even without the number.
        self.assertEqual(merge_methods.tiered_gear("Necromancy weapons#High level equipment")["minimum_tier"], 61)

        tank = merge_methods.tiered_gear("T90+ magic tank armour, perked")
        self.assertEqual(tank["armour_type"], "Tank armour")

    def test_tiered_things_that_are_not_gear_are_left_alone(self):
        for text in ("Tier 4 Luck", "Tier 3 Slayer Lodge recommended", "Tier 80+ pickaxe",
                     "Tier 7 Reputation for access to the VIP skilling area", "High-level PvM items and unlocks"):
            self.assertIsNone(merge_methods.tiered_gear(text), text)

    def test_plain_high_level_armour_and_shields_are_the_wikis_61_plus(self):
        armour = merge_methods.tiered_gear("High-level power armour")
        self.assertEqual((armour["minimum_tier"], armour["slot"], armour["armour_type"]), (61, "body", "Power armour"))

        shield = merge_methods.tiered_gear("Any high level shield required")
        self.assertEqual((shield["minimum_tier"], shield["slot"]), (61, "shield"))

        # No tier and no "high level": still only the player can judge it.
        self.assertIsNone(merge_methods.tiered_gear("Any shield required"))

    def test_the_group_keeps_weapons_shields_and_bodies_with_their_style(self):
        ctx = context()
        group = merge_methods.combat_gear_group([
            {"name": "Noxious scythe", "item_ids": [31725], "tier": 90, "slot": "2h weapon", "style": "melee"},
            {"name": "Tectonic robe top", "item_ids": [28608], "tier": 90, "slot": "torso", "style": "magic",
             "type": "Tank armour"},
            {"name": "Tectonic mask", "item_ids": [28611], "tier": 90, "slot": "head", "style": "magic"},
            {"name": "Off-hand drygore", "item_ids": [26580], "tier": 90, "slot": "off-hand weapon", "style": "melee"},
        ], ctx)

        self.assertEqual([(c["item_id"], c["slot"]) for c in group["candidates"]], [(31725, "weapon"), (28608, "body")])
        self.assertEqual(group["candidates"][1]["armour_type"], "Tank armour")
        self.assertEqual(ctx.items["31725"]["name"], "Noxious scythe")


    def test_a_tier_line_linked_to_an_advice_page_is_still_a_gear_check(self):
        ctx = context(capabilities={"Armoury": {"kind": "guidance"}})
        method = merge_methods.convert_guide(guide(requirements={
            "required": [{"req": "item:Armoury", "text": "Tier 95+ ranged weapons, perked"}],
        }), ctx, "pvm")
        weapon, = method["requirements"]["access"]["children"]

        self.assertEqual((weapon["kind"], weapon["minimum_tier"], weapon["style"]), ("gear", 95, "ranged"))
        self.assertNotIn("advice", method["requirements"])


class ToolTests(unittest.TestCase):
    """Pickaxe and hatchet lines that accept any good enough tool."""

    def ctx(self):
        ctx = context()
        ctx.meta["items"].update({"Crystal pickaxe": 32646, "Elder rune pickaxe + 5": 45652,
                                  "Pickaxe of earth and song": 44834})
        ctx.tool_tiers = {"pickaxe": {32646: 700, 45652: 905, 44834: 909}, "hatchet": {}}

        return ctx

    def test_any_better_and_tiered_tool_lines_check_the_tool_group(self):
        ctx = self.ctx()
        any_pickaxe = merge_methods.tool_check("Any pickaxe", None, ctx)
        self.assertEqual((any_pickaxe["equipment_group"], any_pickaxe.get("minimum_tier")), ("pickaxe", None))

        better = merge_methods.tool_check("Crystal pickaxe or better", "item:Crystal pickaxe", ctx)
        self.assertEqual(better["minimum_tier"], 700)

        # "+ 5 or better" means at least the + 5, not any elder rune pickaxe.
        plus = merge_methods.tool_check("Elder rune pickaxe + 5 or better", "item:Elder rune pickaxe + 5", ctx)
        self.assertEqual(plus["minimum_tier"], 905)

        self.assertEqual(merge_methods.tool_check("Tier 80+ pickaxe", "item:pickaxe", ctx)["minimum_tier"], 800)
        self.assertEqual(ctx.uses_tools, {"pickaxe"})

    def test_a_named_tool_without_better_stays_that_item(self):
        ctx = self.ctx()

        for text in ("Pickaxe of earth and song with Honed 6",
                     "Mining: Pickaxe of earth and song or Pickaxe of life and death"):
            self.assertIsNone(merge_methods.tool_check(text, "item:Pickaxe of earth and song", ctx), text)

    def test_pickaxe_tiers_rank_upgrades_and_perked_pickaxes(self):
        tier = merge_methods.pickaxe_tier

        self.assertLess(tier({"name": "Elder rune pickaxe", "level": 90}),
                        tier({"name": "Elder rune pickaxe + 5", "level": 90}))
        self.assertLess(tier({"name": "Elder rune pickaxe + 5", "level": 90}),
                        tier({"name": "Pickaxe of earth and song", "level": 90}))
        self.assertLess(tier({"name": "Pickaxe of earth and song", "level": 90}),
                        tier({"name": "Primal pickaxe", "level": 100}))


class SplitLineTests(unittest.TestCase):
    """One Wiki line with several links is one requirement, not several copies."""

    def joined(self, *entries):
        return merge_methods.join_split_lines(list(entries))

    def test_links_from_one_line_join_as_all_or_any_by_the_wording(self):
        text = "Built a plank maker then a high capacity plank maker"
        both, = self.joined({"req": "item:Plank maker", "text": text}, {"req": "item:High capacity plank maker", "text": text})
        self.assertEqual(both["req"], ["all", "item:Plank maker", "item:High capacity plank maker"])

        text = "Woodcutting boosts such as Sana's fyrtorch recommended, Ring of Whispers recommended, etc. recommended"
        either, = self.joined({"req": "item:Sana's fyrtorch", "text": text}, {"req": "item:Ring of Whispers", "text": text})
        self.assertEqual(either["req"][0], "any")

        # "or their attuned versions" isn't a choice between the listed pieces.
        text = "Crystal helm, body, gloves, and boots or their attuned versions"
        armour, = self.joined({"req": "item:Crystal helm", "text": text}, {"req": "item:Crystal body", "text": text})
        self.assertEqual(armour["req"][0], "all")

    def test_links_only_in_brackets_are_side_notes(self):
        text = "Tier 80+ pickaxe ( Augmentable pickaxe highly recommended)"
        line, = self.joined({"req": "item:pickaxe", "text": text}, {"req": "item:Augmentable pickaxe", "text": text})
        self.assertEqual(line["req"], "item:pickaxe")

        text = "77 (105 for Expansive pouch and max level of Savvy runecrafting)"
        line, = self.joined({"req": "skill:RUNECRAFTING:77", "text": text}, {"req": "skill:RUNECRAFTING:105", "text": text})
        self.assertEqual(line["req"], "skill:RUNECRAFTING:77")

    def test_the_same_link_twice_and_a_bare_name_beside_its_qualified_one_are_one(self):
        text = "Ring of imbuing for 10% more rune output"
        line, = self.joined({"req": "item:Ring of imbuing", "text": text}, {"req": "item:Ring of imbuing", "text": text})
        self.assertEqual(line["req"], "item:Ring of imbuing")

        self.assertEqual(self.joined("item:Undead Slayer", "item:Undead Slayer (ability)"), ["item:Undead Slayer (ability)"])

        # Two different qualifiers are two different things.
        self.assertEqual(len(self.joined("item:Dragon Slayer (perk)", "item:Dragon Slayer (ability)")), 2)

    def test_repeated_recommended_is_said_once(self):
        tidy = merge_methods.tidy_wording

        self.assertEqual(tidy("Salve amulet (e) recommended recommended for increased damage"),
                         "Salve amulet (e) recommended for increased damage")
        self.assertEqual(tidy("Dive or Bladed Dive recommended (highly recommended)"),
                         "Dive or Bladed Dive (highly recommended)")
        self.assertEqual(tidy("Sana's fyrtorch recommended, Ring of Whispers recommended, etc. recommended"),
                         "Sana's fyrtorch, Ring of Whispers, etc. recommended")
        self.assertEqual(tidy("Tier 80+ pickaxe ( Augmentable pickaxe highly recommended)"),
                         "Tier 80+ pickaxe (Augmentable pickaxe highly recommended)")

    def test_a_joined_line_keeps_its_own_tier_over_its_gear_link(self):
        ctx = context(capabilities={"Scavenging": {"kind": "perk"}})
        text = "T70+ magic armour with Scavenging"
        method = merge_methods.convert_guide(guide(requirements={"required": [
            {"req": "item:Magic_armour#High_level_equipment_(61+)", "text": text},
            {"req": "item:Scavenging", "text": text},
        ]}), ctx, "pvm")
        line, = method["requirements"]["access"]["children"]

        self.assertEqual(line["kind"], "all")
        self.assertEqual(line["children"][0]["minimum_tier"], 70)
        self.assertEqual(line["text"], text)

class ChoiceTests(unittest.TestCase):
    """Guides whose rows depend on GE prices become choices made from live prices."""

    def shop_guide(self, coins=170, runes=10):
        # Bought air runes (10 at 17 GP = 170 coins); mind runes weren't worth it.
        return guide(recurring={"every": "1 week", "minutes": 10},
                     inputs=[["Coins", coins, "run", "value", 1]],
                     outputs=[["Air rune", runes, "run", "ge", 20], ["Mind rune", 0, "run", "ge", 4]])

    def shops(self):
        return {"revision": 123, "shops": [{"name": "Air rune", "stock": 10, "free": 0, "price": 17},
                                           {"name": "Mind rune", "stock": 5, "free": 0, "price": 17}]}

    def context(self):
        ctx = context()
        ctx.meta["items"].update({"Air rune": 556, "Mind rune": 558, "Bones": 526, "Big bones": 532})
        return ctx

    def test_a_shop_run_buys_each_item_at_its_shop_price_or_not_at_all(self):
        ctx = self.context()
        ctx.income_choices = {("Money making guide/Fixture", ""): self.shops()}
        income = merge_methods.convert_guide(self.shop_guide(), ctx, "recurring")["income"]

        self.assertEqual(income["choices"], [
            {"label": "Air rune", "options": ["Buy from the shops", "Don't buy"], "picked": 1},
            {"label": "Mind rune", "options": ["Buy from the shops", "Don't buy"], "picked": 2},
        ])

        # One Coins supply stays: the plugin adds it up from the items it buys.
        coins, = income["inputs"]
        self.assertEqual((coins["name"], coins["pricing"], coins["unit_value"], coins["shop_coins"]),
                         ("Coins", "fixed", 1, True))

        # Each item carries its shop price. Mind runes are still listed, so the
        # plugin can buy them if prices change.
        self.assertEqual([(line["name"], line["quantity"], line["option"], line["shop_price"])
                          for line in income["outputs"]], [("Air rune", 0.1, 1, 17), ("Mind rune", 0.05, 1, 17)])
        self.assertIn("Bought from the shops at 17 GP each", income["outputs"][0]["valuation_note"])

        catalogue.validate_methods({"schema": 1, "items": ctx.items,
                                    "methods": [merge_methods.convert_guide(self.shop_guide(), ctx, "recurring")]},
                                   {"monsters": []})

    def test_shop_research_that_doesnt_reproduce_the_guide_is_refused(self):
        ctx = self.context()
        ctx.income_choices = {("Money making guide/Fixture", ""): self.shops()}

        # The coins don't add up to what the bought items cost.
        with self.assertRaisesRegex(ValueError, "spent 999"):
            merge_methods.convert_guide(self.shop_guide(coins=999), ctx, "recurring")

        # An amount that's neither the stock nor nothing.
        with self.assertRaisesRegex(ValueError, "neither bought"):
            merge_methods.convert_guide(self.shop_guide(runes=7), ctx, "recurring")

        # Research for another revision of the page.
        ctx.income_choices[("Money making guide/Fixture", "")]["revision"] = 122

        with self.assertRaisesRegex(ValueError, "another revision"):
            merge_methods.convert_guide(self.shop_guide(), ctx, "recurring")

    def test_alternatives_keep_every_option_and_the_guides_own_pick(self):
        ctx = self.context()
        research = {"revision": 123, "choices": [{"label": "Bones to use", "options": [
            {"label": "Bones", "inputs": [["Bones", 100]]},
            {"label": "Big bones", "inputs": [["Big bones", 100]]}]}]}
        ctx.income_choices = {("Money making guide/Fixture", ""): research}
        bananas = guide(inputs=[["Big bones", 100, "hour", "ge", 300], ["Logs", 5, "hour", "ge", 50]])
        income = merge_methods.convert_guide(bananas, ctx, "production")["income"]

        # Both bones, where the guide's one was; the guide picked big bones.
        self.assertEqual(income["choices"][0]["picked"], 2)
        self.assertEqual([(line["name"], line.get("option")) for line in income["inputs"]],
                         [("Bones", 1), ("Big bones", 2), ("Logs", None)])

        # Research that matches none of the imported rows is out of date.
        bananas["inputs"][0][1] = 90

        with self.assertRaisesRegex(ValueError, "no option of 'Bones to use'"):
            merge_methods.convert_guide(bananas, ctx, "production")


class DifficultyTests(unittest.TestCase):
    """PvM methods take their researched difficulty; nothing else is rated."""

    def test_a_pvm_method_takes_its_rating_and_others_are_left_alone(self):
        ratings = {("Money making guide/Fixture", "solo"): "Hard"}
        used = set()

        boss = {"id": "fixture.solo", "category": "pvm"}
        merge_methods.apply_difficulty(boss, "Money making guide/Fixture", "Solo", ratings, used)
        self.assertEqual(boss["difficulty"], "Hard")
        self.assertEqual(used, {("Money making guide/Fixture", "solo")})

        # Skilling is never rated, even when a rating exists for its page.
        skilling = {"id": "fixture.solo", "category": "skilling"}
        merge_methods.apply_difficulty(skilling, "Money making guide/Fixture", "Solo", ratings, set())
        self.assertNotIn("difficulty", skilling)

    def test_a_pvm_method_without_research_stops_the_build(self):
        with self.assertRaisesRegex(ValueError, "No difficulty research"):
            merge_methods.apply_difficulty({"id": "fixture.duo", "category": "pvm"},
                                           "Money making guide/Fixture", "Duo", {}, set())

    def test_the_research_file_uses_the_scale_and_explains_every_rating(self):
        ratings = merge_methods.load_difficulty()
        self.assertTrue(ratings)
        self.assertLessEqual(set(ratings.values()), set(merge_methods.DIFFICULTY_SCALE))
