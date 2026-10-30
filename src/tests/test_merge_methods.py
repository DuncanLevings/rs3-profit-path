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


class RequirementTests(unittest.TestCase):
    def convert(self, requirements, capabilities=None):
        ctx = context(capabilities=capabilities)
        method = merge_methods.convert_guide(guide(requirements=requirements), ctx, "pvm")

        return method["requirements"], ctx.items

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

        # Optional requirements sit with the recommended ones, marked optional.
        self.assertEqual(requirements["recommended"]["children"][0]["text"], "A team of 1-3 other players (optional)")

    def test_the_wikis_own_wording_wins_and_recommended_isnt_said_twice(self):
        requirements, _ = self.convert({
            "required": [{"req": "item:Coins", "text": "Coins or above"}],
            "recommended": [{"req": "quest:Priest in Peril", "text": "Priest in Peril recommended for teleports"}],
        })

        self.assertEqual(requirements["access"]["children"][0]["text"], "Coins or above")
        self.assertEqual(requirements["recommended"]["children"][0]["text"], "Priest in Peril recommended for teleports")


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

    def test_wiki_advice_pages_become_notes_not_checks(self):
        requirements = self.convert({
            "required": ["item:Armoury", ["any", "item:Coins", "item:Recommended equipment for PvM/Magic"]],
            "recommended": [{"req": "item:Armoury", "text": "Armoury for the best gear"}],
        })

        # The advice-only requirement is gone, and the group keeps its real option.
        children = requirements["access"]["children"]
        self.assertEqual(len(children), 1)
        self.assertEqual(children[0]["children"][0]["itemId"], 995)
        self.assertEqual(requirements["recommended"]["children"], [])

        # Each advice page once, in the guide's order; the Wiki's wording wins.
        self.assertEqual(requirements["advice"],
                         ["Armoury", "Recommended equipment for PvM: Magic", "Armoury for the best gear"])

    def test_classified_capabilities_say_what_they_are(self):
        requirements = self.convert({"required": ["item:Master camouflage outfit", "item:Something else"]})
        outfit, other = requirements["access"]["children"]

        self.assertEqual(outfit["capability_kind"], "outfit")
        self.assertNotIn("capability_kind", other)


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
