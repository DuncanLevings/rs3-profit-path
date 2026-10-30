"""Tests for src/tools/wiki_methods.py, the Wiki money making guide importer."""
# These never touch the network. Each test feeds the importer a small hand-made
# bucket row shaped like the Wiki's, so it's easy to see what goes in and out.
# src/tools/test.py runs them.
import json
import unittest
from unittest.mock import patch

import wiki_methods


def skill(name, level, importance=""):
    return (f'<span class="mmg-req mmg-skill" data-mmg-skill="{name}" data-mmg-level="{level}" '
            f'data-mmg-imp="{importance}">{level}&nbsp;[[File:{name}-icon.png|21x21px]]</span>')


def item(name, number="1", importance=""):
    return (f'<span class="mmg-req mmg-item" data-mmg-item="{name}" data-mmg-num="{number}" '
            f'data-mmg-imp="{importance}">[[File:{name}.png|25x25px]]&nbsp;[[{name}|{name}]]</span>')


def row(page="Money making guide/Fixture", **guide):
    """One money_making_guide bucket row. Keyword arguments go into its JSON."""
    data = {"activity": "Fixture [[thing]]s", "members": True, "category": "Combat/Mid",
            "inputs": [], "outputs": [], "prices": {}}
    flags = {key: guide.pop(key) for key in ("obsolete", "recurring") if key in guide}
    data.update(guide)

    return {"page_name": page, "page_name_sub": page, "value": "1000", "json": json.dumps(data), **flags}


REVISIONS = {"Money making guide/Fixture": 123, "Money making guide/Other": 456}


class RequirementTests(unittest.TestCase):
    def test_skills_items_quests_and_or_groups_become_short_strings(self):
        quest = ('<span class="mmg-req mmg-quest" data-mmg-quest="Priest in Peril" '
                 'data-mmg-imp="recommended">[[Priest in Peril]]</span>')
        group = f'<span class="mmg-req mmg-req-or" data-mmg-imp="">{item("Gem bag (upgraded)")} or {item("Coins", "500")}</span>'

        requirements = wiki_methods.parse_requirements([
            f"* {skill('slayer', 85)}\n* {skill('combat level', 90, 'recommended')}",
            f"* {group}",
            quest,
            None,
        ])

        self.assertEqual(requirements["required"],
                         ["skill:SLAYER:85", ["any", "item:Gem bag (upgraded)", "item:Coins:500"]])

        # "combat level" becomes COMBAT_LEVEL; a quest marked recommended goes there.
        self.assertEqual(requirements["recommended"], ["skill:COMBAT_LEVEL:90", "quest:Priest in Peril"])
        self.assertNotIn("optional", requirements)

    def test_custom_item_labels_preserve_tiers_instead_of_becoming_advice_links(self):
        labelled = item("Armoury").replace("[[Armoury|Armoury]]", "[[Armoury|Tier 90+ weapon]]")
        requirements = wiki_methods.parse_requirements([labelled])
        self.assertEqual(requirements["required"], [
            {"req": "item:Armoury", "text": "Tier 90+ weapon"},
        ])

        group = '<span class="mmg-req mmg-req-or">' + labelled + ' or ' + item("Logs") + '</span>'
        requirements = wiki_methods.parse_requirements([group])
        self.assertEqual(requirements["required"][0]["text"], "Tier 90+ weapon or Logs")

    def test_wording_the_spans_dont_cover_is_kept_beside_the_requirement(self):
        requirements = wiki_methods.parse_requirements([f"* {item('Spring cleaner 2000')} or above"])

        self.assertEqual(requirements["required"],
                         [{"req": "item:Spring cleaner 2000", "text": "Spring cleaner 2000 or above"}])

        # Joining words and importance labels alone aren't extra wording.
        requirements = wiki_methods.parse_requirements([f"{skill('herblore', 59)} ({skill('herblore', 99, 'recommended')} recommended)"])
        self.assertEqual(requirements, {"required": ["skill:HERBLORE:59"], "recommended": ["skill:HERBLORE:99"]})

    def test_plain_text_requirements_are_kept_but_empty_words_and_headings_are_not(self):
        requirements = wiki_methods.parse_requirements([
            "* Farming equipment on tool belt\n* None\n* N/A\n* [[File:Yes.png|20px]] Needed:\n"
            "* A cape is optional\n* Lunar spells recommended",
        ])

        self.assertEqual(requirements, {
            "required": [{"text": "Farming equipment on tool belt"}],
            "optional": [{"text": "A cape is optional"}],
            "recommended": [{"text": "Lunar spells recommended"}],
        })


class GuideTests(unittest.TestCase):
    def build(self, rows, item_ids=None):
        text, meta = wiki_methods.build(rows, REVISIONS, item_ids or {}, "2026-10-29")

        return [json.loads(line) for line in text.splitlines()], meta

    def test_per_kill_guides_mark_each_row_per_action_or_per_hour(self):
        guides, _ = self.build([row(
            isperkill=True, prices={"default_kph": 900}, version="Melee",
            inputs=[{"name": "Spring", "qty": 0.25, "isph": False, "pricetype": "gemw", "value": 4835},
                    {"name": "Aggroverload (6)", "qty": 1.5, "isph": True, "pricetype": "calcvalue",
                     "value": 159457, "raw_value": "{potioncost�Aggroverload}"}],
            outputs=[{"name": "Coins", "qty": 2000, "isph": False, "pricetype": "value", "value": 1}],
        )])

        guide = guides[0]
        self.assertEqual(guide["revision"], 123)
        self.assertEqual(guide["activity"], "Fixture things")
        self.assertEqual(guide["version"], "Melee")
        self.assertEqual(guide["kph"], 900)
        self.assertEqual(guide["inputs"][0], ["Spring", 0.25, "action", "ge", 4835])

        # A calculated value keeps the Wiki's note, with its odd separator tidied.
        self.assertEqual(guide["inputs"][1], ["Aggroverload (6)", 1.5, "hour", "calc", 159457, "potioncost|Aggroverload"])
        self.assertEqual(guide["outputs"][0], ["Coins", 2000, "action", "value", 1])
        self.assertEqual(guide["wiki_profit"], 1000.0)

    def test_recurring_guides_count_per_run_and_keep_their_cycle(self):
        guides, meta = self.build([row(
            recurring="", recurrence="4 hours", time=7.33,
            inputs=[{"name": "Grimy dwarf weed", "qty": 4000, "isph": True, "pricetype": "gemw", "value": 9390}],
        )])

        self.assertEqual(guides[0]["recurring"], {"every": "4 hours", "minutes": 7.33})
        self.assertEqual(guides[0]["inputs"][0][2], "run")
        self.assertNotIn("kph", guides[0])
        self.assertEqual(meta["counts"]["recurring"], 1)

    def test_obsolete_guides_are_left_out_but_counted(self):
        guides, meta = self.build([row(), row("Money making guide/Other", obsolete="")])

        self.assertEqual([guide["page"] for guide in guides], ["Money making guide/Fixture"])
        self.assertEqual(meta["counts"]["obsolete_skipped"], 1)
        self.assertEqual(meta["counts"]["guides"], 1)

    def test_two_guides_with_the_same_label_are_numbered_and_reported(self):
        guides, meta = self.build([row(), row()])

        self.assertEqual([guide["version"] for guide in guides], ["Variant 1", "Variant 2"])
        self.assertEqual(meta["unlabelled_versions"], ["Money making guide/Fixture"])

    def test_item_ids_and_unresolved_names_are_listed_in_meta(self):
        rows = [row(inputs=[{"name": "Coins", "qty": 1, "isph": True, "pricetype": "gemw", "value": 1},
                            {"name": "Simple parts", "qty": 1, "isph": True, "pricetype": "gemw", "value": 1}])]
        _, meta = self.build(rows, {"Coins": 995})

        self.assertEqual(meta["items"], {"Coins": 995})
        self.assertEqual(meta["unresolved"], ["Simple parts"])

    def test_bad_rows_are_refused_before_anything_is_written(self):
        for guide, message in (
            ({"inputs": [{"name": "X", "qty": 1, "isph": True, "pricetype": "barter", "value": 1}]}, "price type"),
            ({"inputs": [{"name": "X", "qty": float("nan"), "isph": True, "pricetype": "gemw", "value": 1}]}, "finite"),
            ({"inputs": [{"name": "X", "qty": 1, "isph": False, "pricetype": "gemw", "value": 1}]}, "kills per hour"),
        ):
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                self.build([row(**guide)])

        with self.assertRaisesRegex(ValueError, "money making guide"):
            wiki_methods.validate_guide({"page": "Abyssal demon", "revision": 1, "activity": "x", "inputs": [], "outputs": []})


class ItemLookupTests(unittest.TestCase):
    def test_lower_case_names_are_looked_up_with_a_capital_and_mapped_back(self):
        asked = []

        def bucket(query):
            asked.append(query)

            # Both lookups select item_name; only the first one filters on it.
            if "{'item_name'," in query:
                return [{"page_name": "Coins", "item_name": "Coins", "item_id": [995]}]

            # Page lookup: one page with a single item, one with two (ambiguous).
            return [{"page_name": "Bucket of sand", "item_name": "Bucket of sand", "item_id": [1783]},
                    {"page_name": "Super defence", "item_name": "Super defence (4)", "item_id": [2442]},
                    {"page_name": "Super defence", "item_name": "Super defence (3)", "item_id": [163]}]

        with patch.object(wiki_methods, "bucket", bucket):
            found, families, names = wiki_methods.fetch_item_ids({"coins", "bucket of sand", "Super defence"})

        # Super defence is a dose family: its ID is the biggest dose, and owning any
        # dose counts.
        self.assertEqual(found, {"coins": 995, "bucket of sand": 1783, "Super defence": 2442})
        self.assertEqual(families, {"Super defence": [163, 2442]})

        # Each item keeps its own name for the in-game check, whatever the guide wrote.
        self.assertEqual(names[995], "Coins")
        self.assertEqual(names[2442], "Super defence (4)")
        self.assertIn("'Coins'", asked[0])

    def test_a_page_with_unrelated_items_is_too_ambiguous_to_guess(self):
        def bucket(query):
            if "{'item_name'," in query:
                return []

            return [{"page_name": "Armour", "item_name": "Bronze helm", "item_id": [1]},
                    {"page_name": "Armour", "item_name": "Iron helm", "item_id": [2]}]

        with patch.object(wiki_methods, "bucket", bucket):
            self.assertEqual(wiki_methods.fetch_item_ids({"Armour"})[:2], ({}, {}))

    def test_odd_capitals_are_retried_in_sentence_case(self):
        def bucket(query):
            if "{'item_name','Adamant pickaxe'}" in query:
                return [{"page_name": "Adamant pickaxe", "item_name": "Adamant pickaxe", "item_id": [1271]}]

            return []

        with patch.object(wiki_methods, "bucket", bucket):
            self.assertEqual(wiki_methods.fetch_item_ids({"Adamant Pickaxe"}),
                             ({"Adamant Pickaxe": 1271}, {}, {1271: "Adamant pickaxe"}))


class OutfitTests(unittest.TestCase):
    def test_set_pieces_reads_one_piece_per_slot_from_the_set_template(self):
        wikitext = "\n".join([
            "{{Redirect|Mco}}",
            "{{Infobox Set",
            "|name = Master camouflage outfit",
            "|release = [[3 May]] [[2016]]",
            "|head = [[Master camouflage head]]",
            "|head2 = Keldagrim camouflage head",
            "|body1 = Master camouflage body",
            "|feet = Master camouflage feet",
            "|tradeable = No",
            "}}",
            "The master camouflage outfit is an elite skilling outfit.",
        ])

        # Pieces come out in body order; numbered versions after the first and
        # non-slot fields (release, tradeable) are skipped.
        self.assertEqual(wiki_methods.set_pieces(wikitext), [
            ("head", "Master camouflage head"), ("body", "Master camouflage body"), ("feet", "Master camouflage feet"),
        ])

    def test_a_page_without_a_set_template_has_no_pieces(self):
        self.assertEqual(wiki_methods.set_pieces("{{Infobox Item\n|name = Trapper top\n}}"), [])
        self.assertEqual(wiki_methods.set_pieces(None), [])


if __name__ == "__main__":
    unittest.main()
