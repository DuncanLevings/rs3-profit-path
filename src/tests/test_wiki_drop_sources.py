"""Tests for src/tools/wiki_drop_sources.py: GE item names and thieving loot."""
# These cover the conversion rules only, on small made-up Wiki rows, so they never
# touch the network. Each test names the real case that made the rule necessary.
# src/tools/test.py runs them.
import json
import unittest

from lupa.lua54 import LuaRuntime

import catalogue
import wiki_drop_sources as sources


def item_row(name, page, ids, version="DEFAULT"):
    # One infobox_item bucket row, as the Wiki returns it.
    return {"item_name": name, "page_name": page, "item_id": ids, "version_anchor": version}


def drop(item, dropped_from, rarity="1/10", low=1, high=1, level=38, drop_type="thieving", **extra):
    # One dropsline bucket row. drop_json is a JSON string, like the real thing.
    details = {
        "Dropped from": dropped_from, "Dropped item": item, "Drop type": [drop_type],
        "Rarity": rarity, "Rolls": 1, "Quantity Low": low, "Quantity High": high,
        "Drop Quantity": str(low) if low == high else f"{low}–{high}", "Drop level": [[level]],
        "Rarity Notes": [], "Quantity Notes": [], "Approx": False, "Alt Rarity": "",
    }
    details.update(extra)

    return {"page_name": dropped_from.split("#")[0], "item_name": item, "drop_json": json.dumps(details)}


class ItemTests(unittest.TestCase):
    def test_shared_names_use_page_names_and_versions(self):
        # Two GE items called "Monk's robe" are told apart by their pages; two on
        # the same page are told apart by their version.
        items, conflicts = sources.convert_items([
            item_row("Monk's robe", "Monk's robe (top)", [544]),
            item_row("Monk's robe", "Monk's robe (bottom)", [542]),
            item_row("Super attack", "Super attack", [2436], "4 dose"),
            item_row("Super attack", "Super attack", [149], "1 dose"),
            item_row("Rune bar", "Rune bar", [2363]),
        ])

        self.assertEqual(conflicts, [])
        self.assertEqual({entry["id"]: entry["label"] for entry in items}, {
            544: "Monk's robe (top)", 542: "Monk's robe (bottom)",
            2436: "Super attack (4 dose)", 149: "Super attack (1 dose)", 2363: "Rune bar",
        })

        # Sorted by label, ignoring case, so search results come out in order.
        self.assertEqual([entry["label"] for entry in items],
                         sorted((entry["label"] for entry in items), key=str.casefold))

    def test_confusing_ids_are_left_out_not_guessed(self):
        # 60374 is two different items on the Wiki; Blurberry Special lists two IDs
        # on one page with no version. Neither can be labelled honestly.
        items, conflicts = sources.convert_items([
            item_row("Apex hide armour set", "Apex hide armour set", [60374]),
            item_row("Apex hide armour set + 1", "Apex hide armour set + 1", [60374]),
            item_row("Blurberry Special", "Blurberry Special", [2064, 9520]),
            item_row("Incomplete stew", "Incomplete stew", None),
            item_row("Rune bar", "Rune bar", [2363]),
        ])

        self.assertEqual(conflicts, [2064, 9520, 60374])
        self.assertEqual([entry["id"] for entry in items], [2363])

    def test_drop_names_match_pages_or_item_names_but_never_guess(self):
        # Drop rows name a page ("Cake") or a dose item ("Super attack (1)", whose
        # page is "Super attack"). A name fitting several items maps to None.
        lookup = sources.ge_lookup([
            {"id": 1891, "name": "Cake", "page": "Cake", "label": "Cake"},
            {"id": 1893, "name": "2/3 cake", "page": "Cake", "label": "2/3 cake"},
            {"id": 149, "name": "Super attack (1)", "page": "Super attack", "label": "Super attack (1)"},
            {"id": 145, "name": "Super attack (3)", "page": "Super attack", "label": "Super attack (3)"},
            {"id": 544, "name": "Monk's robe", "page": "Monk's robe (top)", "label": "Monk's robe (top)"},
            {"id": 542, "name": "Monk's robe", "page": "Monk's robe (bottom)", "label": "Monk's robe (bottom)"},
        ])

        self.assertEqual(lookup["Cake"], 1891)
        self.assertEqual(lookup["Super attack (1)"], 149)
        self.assertEqual(lookup["Monk's robe (top)"], 544)
        self.assertIsNone(lookup["Super attack"])
        self.assertIsNone(lookup["Monk's robe"])

    def test_bucket_names_with_apostrophes_use_double_quotes(self):
        # The bucket parser rejected "Baker\'s stall" with a backslash escape.
        self.assertEqual(sources.bucket_text("Baker's stall"), '"Baker\'s stall"')
        self.assertEqual(sources.bucket_text("Master Farmer"), "'Master Farmer'")

        with self.assertRaises(ValueError):
            sources.bucket_text("A 'very' \"odd\" name")


class ThievingTests(unittest.TestCase):
    GE = {"Coins": None, "Guam seed": 5291, "Cake": None}

    def convert(self, rows, other=None):
        return sources.convert_thieving(rows, self.GE, other or {})

    def test_versions_get_the_shared_table_plus_their_own(self):
        # Archaeologist: one shared table on the page, plus one per dig site. Each
        # dig site becomes its own target with both tables; there's no target for
        # the shared table alone.
        targets, _ = self.convert([
            drop("Coins", "Archaeologist", level=50),
            drop("Guam seed", "Archaeologist#Kharid-et", level=50),
            drop("Cake", "Archaeologist#Everlight", level=50),
        ])

        self.assertEqual([target["title"] for target in targets],
                         ["Archaeologist (Everlight)", "Archaeologist (Kharid-et)"])

        kharid = targets[1]
        self.assertEqual([section["title"] for section in kharid["sections"]], ["Loot", "Kharid-et"])
        self.assertEqual([[row["name"] for row in section["drops"]] for section in kharid["sections"]],
                         [["Coins"], ["Guam seed"]])
        self.assertEqual(kharid["level"], 50)

    def test_pickpocketing_anchor_is_the_shared_table_and_combat_rows_are_ignored(self):
        # Master Farmer: the loot is under #Pickpocketing, an event drop sits on the
        # page itself, and the same page's combat drops aren't thieving loot.
        targets, _ = self.convert([
            drop("Coins", "Master Farmer#Pickpocketing", "695/1,000", 50, 100),
            drop("Flame fragment (farmer)", "Master Farmer", "32/128"),
            drop("Bones", "Master Farmer", "Always", drop_type="combat"),
        ])

        self.assertEqual(len(targets), 1)
        self.assertEqual([section["title"] for section in targets[0]["sections"]], ["Loot", "Pickpocketing"])

        coins = targets[0]["sections"][1]["drops"][0]
        self.assertEqual((coins["item_id"], coins["quantity_low"], coins["quantity_high"], coins["rate"]),
                         (sources.COINS_ID, 50, 100, "695/1,000"))
        self.assertNotIn("untradeable", coins)

    def test_rows_say_what_they_are_and_never_claim_too_much(self):
        targets, _ = self.convert([
            # A GE item with a known ID.
            drop("Guam seed", "Farmer#Pickpocketing"),
            # Sold on the GE, but in several versions: no ID, not "untradeable".
            drop("Cake", "Farmer#Pickpocketing"),
            # Not on the GE: marked untradeable, keeping its own ID when it has one.
            drop("Dodgy flyer", "Farmer#Pickpocketing", "Common", Approx=True, **{
                "Rarity Notes": [{"content": "Only before [[Buyers and Cellars]] or '''[[Lost Her Marbles|LHM]]'''."}],
                "Alt Rarity": "1/4,900",
            }),
        ], other={"Dodgy flyer": 30000})

        guam, cake, flyer = targets[0]["sections"][0]["drops"]

        self.assertEqual(guam["item_id"], 5291)
        self.assertNotIn("untradeable", guam)

        self.assertNotIn("item_id", cake)
        self.assertNotIn("untradeable", cake)
        self.assertIn("several versions", cake["notes"])

        self.assertEqual((flyer["item_id"], flyer["untradeable"]), (30000, True))

        # Word rarities stay words: no probability is made up for "Common".
        self.assertEqual(flyer["rate"], "Common")

        # Notes are plain text, plus the Wiki's approximate flag and second rate.
        self.assertEqual(flyer["notes"].split("\n"), [
            "Only before Buyers and Cellars or LHM.",
            "The Wiki marks this rate as approximate.",
            "The Wiki also lists a rate of 1/4,900.",
        ])

    def test_extra_rolls_are_written_into_the_rate_like_the_monster_snapshot(self):
        targets, _ = self.convert([drop("Guam seed", "Farmer", "8/260", Rolls=2)])

        row = targets[0]["sections"][0]["drops"][0]
        self.assertEqual((row["rate"], row["rolls"]), ("2 × 8/260", 2))

    def test_a_target_without_one_clear_level_has_no_level(self):
        # No false greens: if the rows disagree, we don't pick one.
        targets, report = self.convert([
            drop("Coins", "Odd target", level=10),
            drop("Guam seed", "Odd target", level=20),
        ])

        self.assertNotIn("level", targets[0])
        self.assertEqual(report["unclear_level"], ["Odd target"])

    def test_targets_pack_and_read_back_through_the_real_reader(self):
        # The same packing and reader as the monster snapshot, plus the level.
        targets, _ = self.convert([
            drop("Coins", "Master Farmer#Pickpocketing", "695/1,000", 50, 100),
            drop("Guam seed", "Master Farmer#Pickpocketing", level=38),
        ])
        document = {"schema": 1, "source": {"retrieved": "2026-11-04T20:00:00Z"},
                    "targets": [dict(target, revision=1) for target in targets]}

        source = catalogue.thieving_as_monsters(document)
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().package.loaded["data/thieving"] = lua.execute(catalogue.build_text(source))

        reader = lua.execute((catalogue.ROOT / "src" / "data" / "monster_data.lua").read_text(encoding="utf-8"))
        decoded = reader.open("data/thieving").find("Master Farmer")

        self.assertEqual(decoded.level, 38)
        self.assertEqual(catalogue.decode_record(decoded, catalogue.MONSTER_FIELDS), source["monsters"][0])

        # Provenance stays in the JSON, not the runtime file.
        self.assertNotIn("revision", source["monsters"][0])


if __name__ == "__main__":
    unittest.main()
