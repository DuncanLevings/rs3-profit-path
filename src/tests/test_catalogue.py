"""Data-pipeline cases independent of the installed game and source checkout."""
# Tests for src/tools/catalogue.py: packing monsters, reading them back, and rejecting
# bad method data. They use small hand-made fixtures, not the real 12 MB data, so
# they run fast and each case is easy to follow. src/tools/test.py runs them.
import copy
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from lupa.lua54 import LuaRuntime

import catalogue


def fixture():
    # One made-up monster that exercises the awkward cases at once. The title holds
    # quotes, a backslash, a non-ASCII character, a newline and a control character
    # (escaping), and the section has a mode, conditions, notes, a roll count, a
    # quantity range and an untradeable drop with unknown values.
    return {
        "schema": 1, "source": {"built": "2026-10-22"},
        "monsters": [{
            "title": 'Boss "quoted" \\ 雪\n\x017', "npc_ids": [10, 20],
            "sections": [{
                "title": "Hard mode", "description": "Conditions apply", "afterword": "Afterword",
                "drop_mode": "Hard", "drop_switch": 1, "drop_threshold": -1,
                "notes": ["Requires eligibility"], "note_ids": {"note": 1},
                "drops": [{
                    "name": "Fixture item", "item_id": 42, "quantity": "2–4", "rate": "2 × 1/128",
                    "notes": "Requires eligibility", "note_marker": "1", "chance": "0.78125",
                    "rolls": 2, "quantity_low": 2, "quantity_high": 4,
                }, {
                    "name": "Unpriced item", "quantity": "Unknown", "rate": "Rare",
                    "untradeable": True,
                }],
            }],
        }],
    }


def reader(source):
    # Packs `source` and loads it through the real monster_data.lua, the same code
    # the plugin uses, so these tests check the actual reader and not a copy of it.
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.loaded["data/monsters"] = lua.execute(catalogue.build_text(source))

    return lua.execute((catalogue.ROOT / "src" / "data" / "monster_data.lua").read_text(encoding="utf-8"))


class CatalogueTests(unittest.TestCase):
    """Monster packing and reading."""

    def test_preserves_conditions_modes_rolls_ranges_and_escaped_text(self):
        # Pack, read back and compare. Every field must survive unchanged.
        source = fixture()
        decoded = reader(source).find(source["monsters"][0]["title"])

        self.assertEqual(catalogue.decode_record(decoded, catalogue.MONSTER_FIELDS), source["monsters"][0])

    def test_shares_rows_without_sharing_mutable_results(self):
        # Two monsters with identical drops should share one stored section and one
        # copy of each drop row...
        source = fixture()
        other = copy.deepcopy(source["monsters"][0])
        other["title"] = "Another boss"
        source["monsters"].append(other)

        lua = LuaRuntime(unpack_returned_tuples=True)
        packed = lua.execute(catalogue.build_text(source))

        self.assertEqual(len(packed.sections), 1)
        self.assertEqual(len(packed.drops), 2)

        # ...but editing one lookup result must not change what the other returns.
        lookup = reader(source)
        first = lookup.find(source["monsters"][0]["title"])
        first.sections[1].drops[1].name = "Mutated"
        first.npc_ids[1] = 999

        second = lookup.find("Another boss")

        self.assertEqual(second.sections[1].drops[1].name, "Fixture item")
        self.assertEqual(second.npc_ids[1], 10)

    def test_unknown_and_known_empty_tables_are_distinct(self):
        # "We don't have this monster" and "this monster drops nothing" are different.
        source = fixture()
        source["monsters"].append({"title": "Empty", "npc_ids": [], "sections": [], "no_drops": "none"})

        lookup = reader(source)

        self.assertEqual(lookup.find("Missing"), (None, "unknown"))

        empty = lookup.find("Empty")

        self.assertEqual(empty.no_drops, "none")
        self.assertEqual(len(empty.sections), 0)

    def test_generation_is_deterministic_and_preserves_input(self):
        # Same input, same output every time (so `verify` can compare files), and
        # building must not modify the source data.
        source = fixture()
        original = copy.deepcopy(source)

        first = catalogue.build_text(source)

        self.assertEqual(first, catalogue.build_text(source))
        self.assertEqual(source, original)

    def test_rejects_duplicate_identity_bad_ids_and_unknown_fields(self):
        source = fixture()
        source["monsters"].append(copy.deepcopy(source["monsters"][0]))

        with self.assertRaisesRegex(ValueError, "duplicate"):
            catalogue.build_text(source)

        # True is technically an int in Python, so this checks we don't accept it.
        source = fixture()
        source["monsters"][0]["npc_ids"] = [True]

        with self.assertRaisesRegex(ValueError, "NPC ID"):
            catalogue.build_text(source)

        # Prices are deliberately not imported, so a price field is an error.
        source = fixture()
        source["monsters"][0]["sections"][0]["drops"][0]["price"] = 123

        with self.assertRaisesRegex(ValueError, "Unrecognized drop"):
            catalogue.build_text(source)

    def test_nonfinite_numbers_cannot_enter_the_bundle(self):
        source = fixture()
        source["monsters"][0]["sections"][0]["drop_threshold"] = float("nan")

        with self.assertRaises(ValueError):
            catalogue.build_text(source)

    def test_rejects_malformed_drop_conditions_flags_and_ranges(self):
        # Wrong types, plus a range where low (10) is above high (4).
        mutations = [
            ("chance", 0.5), ("notes", ["wrong shape"]), ("untradeable", "yes"),
            ("quantity_low", 10),
        ]

        for field, value in mutations:
            with self.subTest(field=field):
                source = fixture()
                source["monsters"][0]["sections"][0]["drops"][0][field] = value

                with self.assertRaises(ValueError):
                    catalogue.build_text(source)

        source = fixture()
        source["monsters"][0]["sections"][0]["notes"] = "not a list"

        with self.assertRaisesRegex(ValueError, "section notes"):
            catalogue.build_text(source)


class MethodTests(unittest.TestCase):
    """Method catalogue validation. Each test breaks one thing in a valid method."""

    def setUp(self):
        # A minimal valid method that touches every validated area: requirements,
        # income rows with both bases, and a loot selector pointing at the fixture
        # monster. Tests copy this and break one thing at a time.
        self.monsters = fixture()
        self.methods = {
            "schema": 1, "items": {"42": {"name": "Fixture item"}},
            "methods": [{
                "id": "fixture-method", "schema": 1, "origin": "bundled", "source": {"revision": 123},
                "title": "Fixture method", "category": "pvm", "source_category": "Combat",
                "members": True, "intensity": "Low", "instructions": ["Fixture step"],
                "location": {"text": "Fixture location", "coverage": "complete"},
                "requirements": {
                    "coverage": "complete",
                    "access": {"kind": "all", "text": "Required", "children": [
                        {"kind": "skill", "skill": "PRAYER", "level": 92, "text": "92 Prayer"},
                    ]},
                    "recommended": {"kind": "all", "text": "Recommended", "children": []},
                },
                "income": {
                    "coverage": "partial", "period": "hour", "assumptions": [],
                    "rate": {"key": "kills_per_hour", "default": 10, "unit": "kills/hour"},
                    "inputs": [{"name": "Fixture item", "item_id": 42, "quantity": 2, "basis": "hour"}],
                    "outputs": [{"name": "Fixture item", "item_id": 42, "quantity": 1, "basis": "action"}],
                    "loot": {"monster": self.monsters["monsters"][0]["title"], "selection": [
                        {"section": "Hard mode", "item": "Fixture item", "rows": 1},
                    ]},
                    "unresolved": [],
                },
            }],
        }

    def test_named_minimum_icon_cannot_be_an_arbitrary_high_end_example(self):
        items = {"42": {"name": "Minimum"}, "43": {"name": "Upgrade"}}
        equipment = {"fixture": {"candidates": [
            {"item_id": 42, "tier": 80}, {"item_id": 43, "tier": 90},
        ]}}
        requirement = {"kind": "gear", "text": "T80+", "equipment_scope": "flexible",
                       "equipment_group": "fixture", "minimum_tier": 80, "minimum_item_id": 42}
        catalogue.validate_requirement(requirement, items, equipment)
        requirement["minimum_item_id"] = 43

        with self.assertRaisesRegex(ValueError, "lowest qualifying"):
            catalogue.validate_requirement(requirement, items, equipment)

        requirement["minimum_item_id"] = 42
        requirement.pop("minimum_tier")

        with self.assertRaisesRegex(ValueError, "explicit minimum tier"):
            catalogue.validate_requirement(requirement, items, equipment)

    def test_toolbelt_bindings_require_verified_names_offsets_and_provenance(self):
        binding = {"presence_variable": "TOOLBELT_PRESENT", "value_variable": "TOOLBELT_LEVEL",
                   "items_enum": "TOOLBELT_ITEMS", "value_offset": 0, "source": "Native metadata fixture"}
        self.methods["toolbelt"] = {"fixture": binding}
        catalogue.methods_text(self.methods, self.monsters)

        for field, value in (("value_variable", "VAR()"), ("items_enum", None),
                             ("presence_variable", 1), ("value_offset", True),
                             ("value_offset", 2), ("source", "")):
            with self.subTest(field=field):
                original = copy.deepcopy(binding)
                binding[field] = value

                with self.assertRaises(ValueError):
                    catalogue.methods_text(self.methods, self.monsters)

                binding.clear()
                binding.update(original)

    def test_equipment_groups_require_resolved_candidates_and_valid_use_levels(self):
        candidate = {"item_id": 42, "tier": 80, "skills": {"DEFENCE": 80}}
        group = {"complete": False, "note": "Unverified variants stay unknown.", "candidates": [candidate]}
        self.methods["equipment"] = {"body": group}
        check = {"kind": "gear", "text": "T80+ body", "equipment_scope": "flexible",
                 "equipment_group": "body", "minimum_tier": 80, "slot": "body", "style": "melee"}
        self.methods["methods"][0]["requirements"]["access"]["children"].append(check)
        catalogue.methods_text(self.methods, self.monsters)

        for field, bad in (("item_id", 999), ("tier", 0), ("skills", {"DEFENCE": -1}), ("slot", 4)):
            with self.subTest(field=field):
                original = copy.deepcopy(candidate)
                candidate[field] = bad

                with self.assertRaises(ValueError):
                    catalogue.methods_text(self.methods, self.monsters)

                candidate.clear()
                candidate.update(original)

        group["candidates"].append(copy.deepcopy(candidate))

        with self.assertRaisesRegex(ValueError, "duplicate"):
            catalogue.methods_text(self.methods, self.monsters)

    def test_equipment_requirements_reject_unknown_groups_and_bad_minimum_tiers(self):
        check = {"kind": "gear", "text": "Tool", "equipment_scope": "flexible", "equipment_group": "missing"}

        with self.assertRaisesRegex(ValueError, "Unresolved equipment"):
            catalogue.validate_requirement(check, self.methods["items"])

        check.pop("equipment_group")

        for tier in (0, -1, True, 1.5):
            check["minimum_tier"] = tier

            with self.assertRaises(ValueError):
                catalogue.validate_requirement(check, self.methods["items"])

    def test_recipe_priced_rows_must_name_a_known_recipe_with_matching_doses(self):
        recipes = catalogue.choose_recipes(recipe_fixture())
        line = self.methods["methods"][0]["income"]["inputs"][0]
        line.update({"pricing": "recipe", "recipe": "Potion", "portion": 4})
        catalogue.methods_text(self.methods, self.monsters, recipes)

        # The recipe has to exist...
        line["recipe"] = "Missing potion"

        with self.assertRaisesRegex(ValueError, "Unknown recipe"):
            catalogue.methods_text(self.methods, self.monsters, recipes)

        # ...doses have to be given when the recipe counts doses...
        line["recipe"] = "Potion"
        del line["portion"]

        with self.assertRaisesRegex(ValueError, "Doses"):
            catalogue.methods_text(self.methods, self.monsters, recipes)

        # ...and only supplies (inputs) can be priced this way.
        line["portion"] = 4
        output = self.methods["methods"][0]["income"]["outputs"][0]
        output.update({"pricing": "recipe", "recipe": "Potion", "portion": 4})

        with self.assertRaisesRegex(ValueError, "Only input rows"):
            catalogue.methods_text(self.methods, self.monsters, recipes)

    def test_versions_sharing_a_title_need_distinct_labels_and_one_category(self):
        second = copy.deepcopy(self.methods["methods"][0])
        second["id"] = "fixture-method.other"
        self.methods["methods"].append(second)

        # Same title, no labels: the version dropdown would have nothing to show.
        with self.assertRaisesRegex(ValueError, "distinct variant labels"):
            catalogue.methods_text(self.methods, self.monsters)

        self.methods["methods"][0]["variant"] = "First"
        second["variant"] = "First"

        with self.assertRaisesRegex(ValueError, "distinct variant labels"):
            catalogue.methods_text(self.methods, self.monsters)

        second["variant"] = "Second"
        catalogue.methods_text(self.methods, self.monsters)

        second["category"] = "skilling"

        with self.assertRaisesRegex(ValueError, "share an activity category"):
            catalogue.methods_text(self.methods, self.monsters)

    def test_ownership_variants_reject_invalid_native_ids(self):
        for aliases in ([], [True], [0], [-1], [1.5], "42"):
            with self.subTest(aliases=aliases):
                self.methods["items"]["42"]["ownership_ids"] = aliases

                with self.assertRaisesRegex(ValueError, "ownership IDs"):
                    catalogue.methods_text(self.methods, self.monsters)

        self.methods["items"]["42"]["ownership_ids"] = [42, 43]
        catalogue.methods_text(self.methods, self.monsters)

    def test_flexible_equipment_cannot_turn_an_example_into_a_fixed_item(self):
        access = self.methods["methods"][0]["requirements"]["access"]
        requirement = {"kind": "gear", "text": "Use your best suitable tool",
                       "equipment_scope": "flexible"}
        access["children"] = [requirement]
        catalogue.methods_text(self.methods, self.monsters)

        requirement["display_items"] = [42]

        with self.assertRaisesRegex(ValueError, "Flexible equipment"):
            catalogue.methods_text(self.methods, self.monsters)

        requirement["equipment_scope"] = "specific"
        catalogue.methods_text(self.methods, self.monsters)

        for scope in (None, "guess", True, [], {}):
            requirement["equipment_scope"] = scope

            with self.assertRaisesRegex(ValueError, "equipment scope"):
                catalogue.methods_text(self.methods, self.monsters)

    def test_requirement_icons_must_resolve_to_known_sprite_names(self):
        requirement = self.methods["methods"][0]["requirements"]["access"]["children"][0]

        for icon in ("../save", "missing_icon", 42, []):
            requirement["display_icon"] = icon

            with self.assertRaisesRegex(ValueError, "icon name"):
                catalogue.methods_text(self.methods, self.monsters)

        requirement["display_icon"] = "perk_honed"
        catalogue.methods_text(self.methods, self.monsters)

    def test_validates_monster_selection_and_explicit_units(self):
        text = catalogue.methods_text(self.methods, self.monsters)

        self.assertIn('"hour"', text)

        # The fixture only has one matching drop row, so asking for 2 must fail.
        # This is what catches a re-import that silently changed a monster's table.
        self.methods["methods"][0]["income"]["loot"]["selection"][0]["rows"] = 2

        with self.assertRaisesRegex(ValueError, "Loot selector changed"):
            catalogue.methods_text(self.methods, self.monsters)

    def test_unresolved_costs_cannot_be_labelled_complete(self):
        # An input with no item ID can't be priced, so the model can't be "complete".
        income = self.methods["methods"][0]["income"]
        income["coverage"] = "complete"
        del income["loot"]
        del income["inputs"][0]["item_id"]

        with self.assertRaisesRegex(ValueError, "unresolved item valuations"):
            catalogue.methods_text(self.methods, self.monsters)

        # Marking it honestly as partial is fine.
        income["coverage"] = "partial"
        catalogue.methods_text(self.methods, self.monsters)

    def test_bad_units_references_and_duplicate_methods_fail(self):
        income = self.methods["methods"][0]["income"]

        # "trip" isn't a supported basis yet.
        income["inputs"][0]["basis"] = "trip"

        with self.assertRaisesRegex(ValueError, "quantity/basis"):
            catalogue.methods_text(self.methods, self.monsters)

        # Item 999 isn't in the items table.
        income["inputs"][0]["basis"] = "hour"
        income["inputs"][0]["item_id"] = 999

        with self.assertRaisesRegex(ValueError, "item reference"):
            catalogue.methods_text(self.methods, self.monsters)

        income["inputs"][0]["item_id"] = 42
        self.methods["methods"].append(copy.deepcopy(self.methods["methods"][0]))

        with self.assertRaisesRegex(ValueError, "duplicate method"):
            catalogue.methods_text(self.methods, self.monsters)

    def test_icon_references_are_validated_separately_from_income_items(self):
        method = self.methods["methods"][0]
        method["requirements"]["access"]["display_items"] = [999]

        with self.assertRaisesRegex(ValueError, "display item"):
            catalogue.methods_text(self.methods, self.monsters)

        del method["requirements"]["access"]["display_items"]
        method["income"]["inputs"][0]["display_item_id"] = 999

        with self.assertRaisesRegex(ValueError, "display item"):
            catalogue.methods_text(self.methods, self.monsters)

    def test_invalid_rates_are_not_emitted(self):
        for rate in (True, -1, float("inf"), float("nan")):
            self.methods["methods"][0]["income"]["rate"]["default"] = rate

            with self.assertRaisesRegex(ValueError, "method rate"):
                catalogue.methods_text(self.methods, self.monsters)

    def test_tax_rounding_parameter_requires_a_positive_integer(self):
        for denominator in (0, -1, True, 0.5):
            self.methods["methods"][0]["income"]["outputs"][0]["tax_denominator"] = denominator

            with self.assertRaisesRegex(ValueError, "tax denominator"):
                catalogue.methods_text(self.methods, self.monsters)

    def test_rejects_requirement_definitions_before_the_runtime_can_misread_them(self):
        # Each of these would confuse requirements.lua at runtime, so the build must
        # refuse them: bad levels, an empty ANY, children that aren't a list, a quest
        # name that isn't a config name, an unknown item, an unsupported kind.
        checks = [
            {"kind": "skill", "skill": "PRAYER", "level": value, "text": "Prayer"}
            for value in (True, -1, "92", 92.5)
        ] + [
            {"kind": "any", "text": "Alternative", "children": []},
            {"kind": "all", "text": "All", "children": "not a list"},
            {"kind": "quest", "quest": "Not a client config", "text": "Quest"},
            {"kind": "item", "itemId": 999, "quantity": 1, "text": "Missing item"},
            {"kind": "unknown-condition", "text": "Unsupported"},
        ]

        access = self.methods["methods"][0]["requirements"]["access"]

        for check in checks:
            with self.subTest(check=check):
                access["children"] = [check]

                with self.assertRaises(ValueError):
                    catalogue.methods_text(self.methods, self.monsters)

    def test_rejects_blank_requirement_labels_and_non_hourly_periods(self):
        requirement = self.methods["methods"][0]["requirements"]["access"]["children"][0]
        requirement["text"] = ""

        with self.assertRaisesRegex(ValueError, "Requirement text"):
            catalogue.methods_text(self.methods, self.monsters)

        requirement["text"] = "92 Prayer"
        self.methods["methods"][0]["income"]["period"] = "run"

        with self.assertRaisesRegex(ValueError, "Only hourly"):
            catalogue.methods_text(self.methods, self.monsters)

    def test_input_tax_is_rejected_and_validated_loot_can_be_complete(self):
        income = self.methods["methods"][0]["income"]

        # You don't pay sale tax on things you buy.
        income["inputs"][0]["tax_denominator"] = 50

        with self.assertRaisesRegex(ValueError, "only valid on output"):
            catalogue.methods_text(self.methods, self.monsters)

        # Complete loot is allowed once the shared quantities/rates resolve.
        del income["inputs"][0]["tax_denominator"]
        income["coverage"] = "complete"

        catalogue.methods_text(self.methods, self.monsters)

        income["coverage"] = "partial"
        income["loot"] = {}

        with self.assertRaisesRegex(ValueError, "Loot monster"):
            catalogue.methods_text(self.methods, self.monsters)

    def test_loot_rejects_ambiguous_rates_duplicate_rows_and_invalid_fixed_values(self):
        base = copy.deepcopy(self.methods)

        for change in ("ambiguous", "infinite", "duplicate", "fixed", "tax"):
            methods = copy.deepcopy(base)
            selected = methods["methods"][0]["income"]["loot"]["selection"]

            if change == "ambiguous":
                selected[0]["rate"] = "1/10; 1/20"
            elif change == "infinite":
                selected[0]["rate"] = "1/" + "9" * 500
            elif change == "duplicate":
                selected.append(copy.deepcopy(selected[0]))
            elif change == "fixed":
                selected[0].update(pricing="fixed", unit_value=-1, valuation_note="Coins")
            else:
                selected[0].update(pricing="fixed", unit_value=1, valuation_note="Coins", tax_denominator=50)

            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "Invalid loot model"):
                catalogue.methods_text(methods, self.monsters)

    def test_required_view_fields_and_schema_types_are_checked(self):
        self.methods["schema"] = True

        with self.assertRaisesRegex(ValueError, "Unsupported method schema"):
            catalogue.methods_text(self.methods, self.monsters)

        self.methods["schema"] = 1
        self.methods["methods"][0]["location"] = None

        with self.assertRaisesRegex(ValueError, "Method location"):
            catalogue.methods_text(self.methods, self.monsters)

    def test_invalid_methods_leave_both_generated_files_unchanged(self):
        # Runs the real `build` command against temporary copies of every file, with
        # a bad method (an ID with spaces). It must fail without touching either output.
        page = short_page()
        page["versions"][0]["id"] = "Not a valid ID"
        short = {"schema": 2, "items": {"42": {"name": "Fixture item"}}, "pages": [page]}

        # Use a known writable workspace parent; Windows sandbox temp can be read-only.
        with TemporaryDirectory(dir=catalogue.ROOT) as directory:
            root = Path(directory)
            self.assertEqual(root.resolve().parent, catalogue.ROOT.resolve())

            source = root / "monsters.json"
            methods = root / "methods.json"
            output = root / "monsters.lua"
            method_output = root / "methods.lua"

            source.write_text(catalogue.json_text(self.monsters), encoding="utf-8")
            methods.write_text(catalogue.source_text(short) + "\n", encoding="utf-8")
            output.write_text("old monsters", encoding="utf-8")
            method_output.write_text("old methods", encoding="utf-8")

            # Point catalogue.py's paths at the temp files and pretend we ran `build`.
            with patch.multiple(catalogue, SOURCE=source, METHOD_SOURCE=methods,
                                OUTPUT=output, METHOD_OUTPUT=method_output,
                                RECIPE_SOURCE=root / "no-recipes.json"), \
                    patch.object(sys, "argv", ["catalogue.py", "build"]):
                with self.assertRaisesRegex(ValueError, "Invalid/duplicate method ID"):
                    catalogue.main()

            self.assertEqual(output.read_text(encoding="utf-8"), "old monsters")
            self.assertEqual(method_output.read_text(encoding="utf-8"), "old methods")


def short_page():
    """One Wiki page in the short method source, with a single version."""
    return {
        "page": "Money making guide/Fixture", "revision": 123,
        "title": "Fixture method", "category": "pvm", "source_category": "Combat",
        "members": True, "intensity": "Low", "instructions": ["Fixture step"],
        "location": {"text": "Fixture location", "coverage": "complete"},
        "requirements": {"coverage": "complete", "access": ["skill:PRAYER:92"]},
        "income": {
            "coverage": "partial",
            "rate": {"key": "kills_per_hour", "default": 10, "unit": "kills/hour"},
            "inputs": [{"item_id": 42, "quantity": 2, "basis": "hour"}],
        },
        "versions": [{"id": "fixture-method"}],
    }


class ShortSourceTests(unittest.TestCase):
    """The short method source: what the build fills in, and the packed runtime file."""

    def setUp(self):
        self.items = {"42": {"name": "Fixture item"}, "43": {"name": "Other item"}}

    def expand(self, *pages):
        return catalogue.expand_methods({"schema": 2, "items": self.items, "pages": list(pages)})

    def test_short_requirements_get_their_text_icons_and_recommended_ending(self):
        page = short_page()
        page["requirements"]["access"].append({"kind": "any", "children": ["item:42", "item:43"]})
        page["requirements"]["recommended"] = [
            "skill:ATTACK:90",
            {"kind": "all", "children": ["item:42", "item:43"]},
            {"kind": "any", "text": "Either skill", "children": ["skill:MAGIC:80", "skill:RANGED:80"]},
        ]
        requirements = self.expand(page)["methods"][0]["requirements"]

        access = requirements["access"]
        self.assertEqual(access["text"], "Required")
        self.assertEqual(access["children"][0], {"kind": "skill", "skill": "PRAYER", "level": 92, "text": "92 Prayer"})
        self.assertEqual(access["children"][1]["text"], "Fixture item or Other item")
        self.assertEqual(access["children"][1]["display_items"], [42, 43])

        # Only the direct children of "recommended" get the ending; nested ones don't.
        recommended = requirements["recommended"]["children"]
        self.assertEqual(recommended[0]["text"], "90 Attack (recommended)")
        self.assertEqual(recommended[1]["text"], "Fixture item; Other item (recommended)")
        self.assertEqual(recommended[2]["text"], "Either skill (recommended)")
        self.assertEqual(recommended[2]["children"][0]["text"], "80 Magic")
        self.assertNotIn("display_items", recommended[2])
        self.assertEqual(requirements["unresolved"], [])

    def test_versions_only_store_their_differences(self):
        page = short_page()
        page["versions"] = [
            {"id": "fixture.slow", "variant": "Slow", "income": {"rate": {"default": 5}}},
            {"id": "fixture.fast", "variant": "Fast", "income": {"rate": {"default": 20}, "inputs": []}},
        ]
        slow, fast = self.expand(page)["methods"]

        # Records merge key by key, so each keeps the page's rate key and unit.
        self.assertEqual(slow["income"]["rate"], {"key": "kills_per_hour", "default": 5, "unit": "kills/hour"})
        self.assertEqual(fast["income"]["rate"]["default"], 20)

        # Lists are replaced whole: the fast version has no inputs at all.
        self.assertEqual(len(slow["income"]["inputs"]), 1)
        self.assertEqual(fast["income"]["inputs"], [])

        # Everything else is shared, and versions never share one mutable table.
        self.assertEqual(slow["requirements"], fast["requirements"])
        self.assertIsNot(slow["requirements"], fast["requirements"])

        for method in (slow, fast):
            self.assertEqual(method["schema"], 1)
            self.assertEqual(method["origin"], "bundled")
            self.assertEqual(method["source"]["url"],
                             "https://runescape.wiki/w/Money_making_guide/Fixture?oldid=123")
            self.assertEqual(method["income"]["period"], "hour")
            self.assertEqual(method["location"]["routes"], [])

    def test_income_rows_and_items_fill_in_names_and_links(self):
        self.items["44"] = {"name": "Potion (6)", "page": "Potion", "revision": 7}
        page = short_page()
        page["income"]["inputs"].append({"item_id": 44, "name": "Potion", "quantity": 1, "basis": "hour"})
        expanded = self.expand(page)

        inputs = expanded["methods"][0]["income"]["inputs"]
        self.assertEqual(inputs[0]["name"], "Fixture item")
        self.assertEqual(inputs[1]["name"], "Potion")
        self.assertEqual(expanded["items"]["44"], {"name": "Potion (6)", "source": "https://runescape.wiki/w/Potion?oldid=7"})

    def test_bad_short_source_is_reported(self):
        for change, message in (
            (lambda page: page["requirements"]["access"].append("skill:PRAYER"), "shorthand"),
            (lambda page: page.pop("revision"), "Wiki revision"),
            (lambda page: page.update(versions=[]), "at least one version"),
            (lambda page: page["requirements"].update(access={"kind": "all"}), "must be a list"),
        ):
            with self.subTest(message=message):
                page = short_page()
                change(page)

                with self.assertRaisesRegex(ValueError, message):
                    self.expand(page)

        with self.assertRaisesRegex(ValueError, "schema 2"):
            catalogue.expand_methods({"schema": 1, "items": {}, "methods": []})

    def test_layout_keeps_short_records_on_one_line(self):
        text = catalogue.source_text({"pages": [short_page()]})

        self.assertIn('"access": ["skill:PRAYER:92"]', text)
        self.assertIn('{"item_id": 42, "quantity": 2, "basis": "hour"}', text)
        self.assertTrue(all(len(line) <= 110 for line in text.splitlines()))

        # Layout only changes spacing, never the data.
        self.assertEqual(json.loads(text), {"pages": [short_page()]})

    def test_packed_methods_read_back_exactly(self):
        # Tricky text on purpose: quotes, backslashes, a newline and non-English
        # letters must all survive. Numbers and booleans must not turn into text.
        page = short_page()
        page["title"] = 'Fixture "quoted" \\ method\nwith Ünïcode'
        page["instructions"] = ["One", "One", "Two"]
        page["income"]["inputs"][0]["quantity"] = 0.041666666666666664
        catalogue_data = self.expand(page)
        catalogue_data["equipment"] = {}
        packed = catalogue.pack_methods(catalogue_data)

        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().package.path = catalogue.ROOT.as_posix() + "/?.lua"
        lua.execute("package.loaded['data/methods'] = ...", lua.execute(packed))
        loaded = lua.eval('require("src/data/method_data")')
        reader = loaded[0] if isinstance(loaded, tuple) else loaded

        method = catalogue_data["methods"][0]
        self.assertEqual(catalogue.from_lua(reader.find("fixture-method")), catalogue.plain(method))
        self.assertEqual(catalogue.from_lua(reader["items"]), catalogue.plain(catalogue_data["items"]))
        self.assertIs(reader.find("fixture-method")["members"], True)
        self.assertIsNone(reader.find("missing"))

        # Repeated text is stored once.
        self.assertEqual(packed.count('"One"'), 1)

    def test_packing_refuses_lists_that_mix_text_and_numbers(self):
        with self.assertRaisesRegex(ValueError, "cannot mix text"):
            catalogue.pack_methods({"items": {}, "methods": [{"id": "x", "mixed": ["a", 1]}]})


def recipe_fixture():
    """A tiny recipe source: Potion is made from Base (its own recipe), a GE herb
    and a free flower. Potion also has a second, later recipe that must be ignored."""
    def recipe(page, sequence, output, materials):
        return {"page": page, "sequence": sequence, "url": "https://runescape.wiki/w/" + page,
                "output": output, "materials": materials}

    return {
        "schema": 1, "retrieved": "2026-10-29", "licence": "Fixture licence.",
        "recipes": [
            recipe("Potion", 1, {"name": "Potion (4)", "quantity": 1, "portion": 4, "item_id": 100}, [
                {"name": "Base (3)", "page": "Base", "quantity": 1, "portion": 3, "pricing": "recipe"},
                {"name": "Herb", "page": "Herb", "quantity": 2, "pricing": "ge", "item_id": 200},
                {"name": "Flower", "page": "Flower", "quantity": 1, "pricing": "free"},
            ]),
            recipe("Potion", 2, {"name": "Potion (4)", "quantity": 5, "portion": 4}, [
                {"name": "Herb", "page": "Herb", "quantity": 1, "pricing": "ge", "item_id": 200},
            ]),
            recipe("Base", 1, {"name": "Base (3)", "quantity": 1, "portion": 3}, [
                {"name": "Herb", "page": "Herb", "quantity": 1, "pricing": "ge", "item_id": 200},
            ]),
        ],
    }


class RecipeTests(unittest.TestCase):
    # The build picks one recipe per item and refuses data the calculator couldn't
    # price safely: loops, missing recipes and GE ingredients without an item ID.

    def test_first_listed_recipe_is_chosen_and_the_runtime_copy_loads(self):
        chosen = catalogue.choose_recipes(recipe_fixture())

        self.assertEqual(chosen["Potion"]["sequence"], 1)

        runtime = LuaRuntime().execute(catalogue.recipes_text(recipe_fixture()))
        potion = runtime["Potion"]

        self.assertEqual(potion["portion"], 4)
        self.assertEqual(potion["materials"][1]["page"], "Base")
        self.assertEqual(potion["materials"][2]["item_id"], 200)
        self.assertEqual(potion["materials"][3]["pricing"], "free")

    def test_recipe_loops_are_rejected(self):
        source = recipe_fixture()
        source["recipes"][2]["materials"].append(
            {"name": "Potion (4)", "page": "Potion", "quantity": 1, "pricing": "recipe"})

        with self.assertRaisesRegex(ValueError, "Recipe loop"):
            catalogue.choose_recipes(source)

    def test_missing_recipes_and_unidentified_ge_items_are_rejected(self):
        source = recipe_fixture()
        source["recipes"][0]["materials"][0]["page"] = "Nowhere"

        with self.assertRaisesRegex(ValueError, "no recipe for"):
            catalogue.choose_recipes(source)

        source = recipe_fixture()
        del source["recipes"][2]["materials"][0]["item_id"]

        with self.assertRaisesRegex(ValueError, "needs an item ID"):
            catalogue.choose_recipes(source)

    def test_bad_quantities_and_pricing_are_rejected(self):
        for field, value, message in (("quantity", 0, "above zero"), ("pricing", "guess", "unknown pricing"),
                                      ("portion", 1.5, "whole number")):
            with self.subTest(field=field):
                source = recipe_fixture()
                source["recipes"][0]["materials"][0][field] = value

                with self.assertRaisesRegex(ValueError, message):
                    catalogue.choose_recipes(source)


if __name__ == "__main__":
    unittest.main()
