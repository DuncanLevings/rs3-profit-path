"""Import local Monster Lookup data and build/verify Profit Path's static drop bundle.

No network access. Source JSON stays readable; generated Lua interns repeated strings,
drop rows and sections. Only import needs an existing Monster Lookup checkout.
"""
# Developer tool, never shipped with the plugin. The flow is:
#
#   import-monsters  copy monster/drop data out of a local Monster Lookup checkout
#                    into catalogue-source/monsters.json (readable, reviewable)
#   build            turn the JSON sources into data/monsters.lua, data/methods.lua and
#                    data/recipes.lua (recipes come from src/tools/wiki_recipes.py)
#   verify           rebuild in memory and check the files on disk still match, then
#                    load every monster back through the real Lua reader
#
# The idea: humans edit and review the JSON, the plugin loads the generated Lua, and
# this script makes sure those two never drift apart.
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from pathlib import Path

from lupa.lua54 import LuaRuntime


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "catalogue-source" / "monsters.json"
OUTPUT = ROOT / "data" / "monsters.lua"
METHOD_SOURCE = ROOT / "catalogue-source" / "methods.json"
METHOD_OUTPUT = ROOT / "data" / "methods.lua"
RECIPE_SOURCE = ROOT / "catalogue-source" / "recipes.json"
RECIPE_OUTPUT = ROOT / "data" / "recipes.lua"

# One small shared Lua registry keeps UI aliases and build validation in sync.
# This file is plain reference data, so loading it needs no game globals.
ICON_NAMES = set(LuaRuntime().execute((ROOT / "data" / "icons.lua").read_text(encoding="utf-8")).keys())

# Field order inside the packed Lua rows. monster_data.lua reads these by position
# (row[1], row[2]...), so if you reorder or add a field here you MUST update that
# reader too. `verify` will catch it if you forget.
DROP_FIELDS = (
    "name", "quantity", "rate", "notes", "note_marker", "item_id", "chance",
    "rolls", "quantity_low", "quantity_high", "untradeable",
)
SECTION_FIELDS = (
    "title", "description", "afterword", "drops", "notes", "note_ids",
    "drop_mode", "drop_switch", "drop_threshold",
)
MONSTER_FIELDS = ("title", "npc_ids", "sections", "no_drops")

# Text fields get swapped for a number pointing into one shared string list.
STRING_FIELDS = {
    "name", "quantity", "rate", "notes", "note_marker", "chance", "title",
    "description", "afterword", "drop_mode", "no_drops",
}


# Small checkers used by the validators below. Each raises ValueError with a
# readable message, so a bad source file tells you what's wrong instead of crashing.

def non_negative_number(value):
    # `type(...) in` rather than isinstance, because bool counts as int in Python.
    return type(value) in {int, float} and math.isfinite(value) and value >= 0


def positive_integer(value):
    return type(value) is int and value > 0


def require_text(value, field):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be nonempty text")


def require_text_list(value, field):
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise ValueError(f"{field} must be a list of text")


def require_record(value, field):
    if not isinstance(value, dict):
        raise ValueError(f"{field} must be a record")

    return value


def validate_requirement(check, items):
    """Validate definitions once at build time; runtime checks only account evidence."""
    # Mirrors the kinds requirements.lua understands. Checking them here means the
    # plugin can trust the shape at runtime and only has to worry about player data.
    if not isinstance(check, dict):
        raise ValueError("Requirement must be a record")

    require_text(check.get("text"), "Requirement text")

    if "display_items" in check:
        if not isinstance(check["display_items"], list) or not check["display_items"]:
            raise ValueError("Display items must be a non-empty list")

        for item in check["display_items"]:
            if not positive_integer(item) or str(item) not in items:
                raise ValueError("Unresolved requirement display item")

    if "display_icon" in check:
        icon = check["display_icon"]

        if (not isinstance(icon, str) or not re.fullmatch(r"[a-z][a-z0-9_]*", icon)
                or icon not in ICON_NAMES):
            raise ValueError("Unresolved requirement icon name")

    kind = check.get("kind")

    if not isinstance(kind, str):
        raise ValueError("Requirement kind must be text")

    # Equipment examples aren't necessarily requirements. Make the importer choose
    # explicitly: named items can have icons; a broad tool/tier requirement keeps
    # its source wording and must not acquire a single misleading placeholder.
    if kind == "gear":
        scope = check.get("equipment_scope")

        if not isinstance(scope, str) or scope not in {"specific", "flexible"}:
            raise ValueError("Gear requires an explicit equipment scope")

        if scope == "flexible" and "display_items" in check:
            raise ValueError("Flexible equipment must use text, not fixed item icons")

    elif "equipment_scope" in check:
        raise ValueError("Equipment scope only applies to gear requirements")

    if kind in {"all", "any"}:
        children = check.get("children")

        # An empty ANY can never pass, so it's almost certainly a data mistake.
        if not isinstance(children, list) or (kind == "any" and not children):
            raise ValueError("Requirement alternatives must be a list; ANY cannot be empty")

        for child in children:
            validate_requirement(child, items)

    elif kind == "skill":
        # Must look like a client SkillType name, e.g. SMITHING.
        name = check.get("skill")

        if not isinstance(name, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", name):
            raise ValueError("Invalid skill config name")

        if not positive_integer(check.get("level")):
            raise ValueError("Requirement level must be a positive integer")

        if "skill_" + name.lower() not in ICON_NAMES:
            raise ValueError("Unresolved skill icon name")

    elif kind == "quest":
        name = check.get("quest")

        if not isinstance(name, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", name):
            raise ValueError("Invalid quest config name")

    elif kind == "item":
        # The item must exist in methods.json's "items" table.
        item_id = check.get("itemId")

        if not positive_integer(item_id) or str(item_id) not in items:
            raise ValueError("Unresolved requirement item reference")

        if not positive_integer(check.get("quantity")):
            raise ValueError("Requirement item quantity must be a positive integer")

    elif kind in {"gear", "capability"}:
        # These keep the source's wording but can't be checked yet, so the plugin
        # always shows them as "unknown". Nothing more to validate.
        return

    else:
        raise ValueError(f"Unsupported requirement kind: {kind}")


def json_text(value, *, pretty=False):
    # sort_keys keeps output stable between runs. allow_nan=False makes NaN or
    # infinity anywhere in the data an error rather than invalid JSON.
    return json.dumps(value, ensure_ascii=False, allow_nan=False,
                      indent=2 if pretty else None, sort_keys=True,
                      separators=None if pretty else (",", ":"))


def lua_literal(value):
    # Writes a Python value as Lua source on one line. Strings are escaped by hand
    # so no data can ever break out of its quotes and become runnable Lua.
    if value is None:
        return "nil"

    if isinstance(value, bool):
        return "true" if value else "false"

    if isinstance(value, (int, float)):
        return json_text(value)

    if isinstance(value, str):
        escaped = []

        for char in value:
            if char in {'"', "\\"}:
                escaped.append("\\" + char)
            elif ord(char) < 32 or ord(char) == 127:
                # Control characters become Lua decimal escapes like \010.
                escaped.append(f"\\{ord(char):03d}")
            else:
                escaped.append(char)

        return '"' + "".join(escaped) + '"'

    if isinstance(value, list):
        return "{" + ",".join(lua_literal(item) for item in value) + "}"

    if isinstance(value, dict):
        return "{" + ",".join("[" + lua_literal(key) + "]=" + lua_literal(item)
                               for key, item in sorted(value.items())) + "}"

    raise TypeError(f"Cannot write Lua value: {type(value).__name__}")


def array(value):
    # Lua tables are 1-indexed; this turns one (via lupa) into a Python list.
    return [value[index] for index in range(1, len(value) + 1)] if value is not None else []


def readable_lua(value, depth=0):
    """Keep the small method catalogue reviewable; packed monster rows use lua_literal."""
    if not isinstance(value, (dict, list)) or not value:
        return lua_literal(value)

    indent = "    " * depth
    entries = []

    if isinstance(value, dict):
        for key, item in sorted(value.items()):
            entries.append(f"[{lua_literal(key)}] = {readable_lua(item, depth + 1)}")
    else:
        entries = [readable_lua(item, depth + 1) for item in value]

    body = "\n".join(indent + "    " + entry + "," for entry in entries)

    return "{\n" + body + "\n" + indent + "}"


def import_monsters(checkout):
    # Loads Monster Lookup's own static data reader in an embedded Lua runtime and
    # copies out only the fields we use. The reader only reads local files; it makes
    # no network or game calls.
    checkout = checkout.resolve(strict=True)
    lua = LuaRuntime(unpack_returned_tuples=True)

    # If their reader tries to log an error, stop instead of importing half-broken data.
    def report_source_error(message):
        raise RuntimeError(message)

    lua.globals().log = report_source_error
    lua.globals().package.path = checkout.as_posix() + "/?.lua"

    loaded = lua.eval('require("src/data/library/bundle/reader")')
    reader = loaded[0] if isinstance(loaded, tuple) else loaded

    titles = array(reader.titles())

    if not titles:
        raise ValueError("The source bundle has no monster titles")

    records = []

    for page, title in enumerate(titles, 1):
        record, built = reader.load(page)

        if record is None or record.title != title:
            raise ValueError(f"Source decode failed: {title}")

        monster = {"title": title, "npc_ids": array(reader.npc_ids(title)), "sections": []}

        if record.no_drops is not None:
            monster["no_drops"] = record.no_drops

        for section in array(record.sections):
            selected = {}

            for field in SECTION_FIELDS:
                value = section[field]

                if field == "drops":
                    drops = []

                    for drop in array(value):
                        row = {key: drop[key] for key in DROP_FIELDS
                               if key != "untradeable" and drop[key] is not None}

                        # We drop the source's saved prices, but keep the one useful
                        # fact they carried: "Not sold" means it can't be traded.
                        if drop.price == "Not sold":
                            row["untradeable"] = True

                        drops.append(row)

                    selected[field] = drops

                elif field == "notes":
                    selected[field] = array(value)

                elif field == "note_ids":
                    selected[field] = dict(value.items()) if value is not None else {}

                elif value is not None:
                    selected[field] = value

            monster["sections"].append(selected)

        records.append(monster)

    # Record a hash of every source file their reader loaded, plus their notices, so
    # we can always tell exactly which version of the data we copied.
    used = sorted(name for name, _ in lua.globals().package.loaded.items()
                  if isinstance(name, str) and name.startswith("src/data/library/"))
    hashes = {}

    for name in used:
        relative = name + ".lua"
        hashes[relative] = hashlib.sha256((checkout / relative).read_bytes()).hexdigest()

    notices = checkout / "THIRD_PARTY_NOTICES.txt"
    hashes[notices.name] = hashlib.sha256(notices.read_bytes()).hexdigest()

    source = {
        "schema": 1,
        "source": {
            "project": "DuncanLevings/rs3-monster-lookup", "built": built,
            "license": "CC BY-NC-SA 3.0", "sha256": hashes,
            "wiki": "https://runescape.wiki/",
            "article_revisions": "Not provided by the inherited bundle; do not invent revisions.",
            "transformation": "Keep monster identity and drops; omit stats, maps, locations, search indexes and prices. Mark source Not sold rows untradeable.",
        },
        "monsters": sorted(records, key=lambda row: row["title"]),
    }

    # Validate before writing, so a bad import never replaces a good source file.
    validate(source)

    SOURCE.parent.mkdir(parents=True, exist_ok=True)
    SOURCE.write_text(json_text(source, pretty=True) + "\n", encoding="utf-8", newline="\n")
    (SOURCE.parent / "monster-source-notices.txt").write_bytes(notices.read_bytes())

    print(f"Imported {len(records)} local monster records; no Wiki requests.")


def validate(source):
    # Checks monsters.json is the shape the packer and monster_data.lua expect:
    # known fields only, right types, no duplicate titles.
    if type(source.get("schema")) is not int or source["schema"] != 1 or not source.get("monsters"):
        raise ValueError("Unsupported or empty monster source")

    titles = set()

    for monster in source["monsters"]:
        title = monster["title"]

        # Titles are the lookup key in monster_data.find, so they must be unique.
        if not isinstance(title, str) or not title or title in titles:
            raise ValueError(f"Invalid/duplicate monster title: {title}")

        titles.add(title)

        if set(monster) - set(MONSTER_FIELDS):
            raise ValueError(f"Unrecognized monster fields: {title}")

        if "no_drops" in monster and not isinstance(monster["no_drops"], str):
            raise ValueError(f"Invalid no-drop reason: {title}")

        for npc_id in monster["npc_ids"]:
            if type(npc_id) is not int or npc_id < 0:
                raise ValueError(f"Invalid NPC ID: {title}")

        for section in monster["sections"]:
            if set(section) - set(SECTION_FIELDS):
                raise ValueError(f"Unrecognized section fields: {title}")

            for field in ("title", "description", "afterword", "drop_mode"):
                if field in section and not isinstance(section[field], str):
                    raise ValueError(f"Invalid section {field}: {title}")

            require_text_list(section.get("notes"), f"{title} section notes")

            note_ids = require_record(section.get("note_ids"), f"{title} note identifiers")

            if any(not isinstance(key, str) or type(value) is not int or value < 0
                   for key, value in note_ids.items()):
                raise ValueError(f"Invalid note identifier: {title}")

            for field in ("drop_switch", "drop_threshold"):
                if field in section and type(section[field]) is not int:
                    raise ValueError(f"Invalid section {field}: {title}")

            for drop in section["drops"]:
                if set(drop) - set(DROP_FIELDS):
                    raise ValueError(f"Unrecognized drop fields: {title}")

                # Every drop has a name, quantity and rate (kept as Wiki text, e.g.
                # "1-3" or "1/128"); the other text fields are optional.
                for key in ("name", "quantity", "rate"):
                    if not isinstance(drop.get(key), str):
                        raise ValueError(f"Invalid {key}: {title}")

                for key in ("notes", "note_marker", "chance"):
                    if key in drop and not isinstance(drop[key], str):
                        raise ValueError(f"Invalid {key}: {title}")

                for key in ("item_id", "rolls", "quantity_low", "quantity_high"):
                    if key in drop and (type(drop[key]) is not int or drop[key] < 0):
                        raise ValueError(f"Invalid {key}: {title}")

                if "untradeable" in drop and type(drop["untradeable"]) is not bool:
                    raise ValueError(f"Invalid untradeable marker: {title}")

                if "quantity_low" in drop and "quantity_high" in drop:
                    if drop["quantity_low"] > drop["quantity_high"]:
                        raise ValueError(f"Reversed drop quantity range: {title}")

    # Serialising with allow_nan=False also catches NaN or infinity hiding anywhere.
    json_text(source)


def build_text(source):
    # Packs every monster into compact Lua. "Interning" means each distinct string,
    # drop row and section is stored once in a list, and everything else refers to
    # it by its (1-based) position. That's why the output is about 20% of the JSON size.
    validate(source)

    strings, drops, sections = [], [], []
    string_ids, drop_ids, section_ids = {}, {}, {}

    def intern_string(value):
        if value not in string_ids:
            string_ids[value] = len(strings) + 1
            strings.append(value)

        return string_ids[value]

    # Rows are compared by their JSON text, so two identical drop rows share one slot.
    def intern_row(value, rows, ids):
        key = json_text(value)

        if key not in ids:
            ids[key] = len(rows) + 1
            rows.append(value)

        return ids[key]

    # Turns one record into a positional list following `fields`, interning as it goes.
    def pack(record, fields):
        row = []

        for field in fields:
            value = record.get(field)

            if field == "drops":
                value = [intern_row(pack(drop, DROP_FIELDS), drops, drop_ids) for drop in value]
            elif field == "sections":
                value = [intern_row(pack(section, SECTION_FIELDS), sections, section_ids) for section in value]
            elif field == "notes" and isinstance(value, list):
                value = [intern_string(note) for note in value]
            elif field == "note_ids":
                value = [[intern_string(key), number] for key, number in sorted(value.items())]
            elif field in STRING_FIELDS and value is not None:
                value = intern_string(value)

            row.append(value)

        # Trailing empty fields are trimmed to save space; the reader sees them as nil.
        while row and row[-1] is None:
            row.pop()

        return row

    monsters = [pack(monster, MONSTER_FIELDS) for monster in source["monsters"]]

    lines = [
        "-- Generated by src/tools/catalogue.py; do not edit.",
        "-- RuneScape Wiki contributors, CC BY-NC-SA 3.0. See THIRD_PARTY_NOTICES.txt.",
        "return {", "schema=1,", "built=" + lua_literal(source["source"]["built"]) + ",",
    ]

    for name, values in (("strings", strings), ("drops", drops), ("sections", sections), ("monsters", monsters)):
        lines.append(name + "={")
        lines.extend(lua_literal(value) + "," for value in values)
        lines.append("},")

    lines.append("}")

    return "\n".join(lines) + "\n"


def decode_record(value, fields):
    """Convert the runtime reader's plain Lua record to its source JSON shape."""
    # Used by verify() so a monster read back through monster_data.lua can be
    # compared field-for-field against the original JSON.
    result = {}

    for field in fields:
        item = value[field]

        if item is None:
            continue

        if field == "sections":
            item = [decode_record(section, SECTION_FIELDS) for section in array(item)]
        elif field == "drops":
            item = [decode_record(drop, DROP_FIELDS) for drop in array(item)]
        elif field in {"notes", "npc_ids"} and not isinstance(item, str):
            item = array(item)
        elif field == "note_ids":
            item = dict(item.items())

        result[field] = item

    return result


def verify(source):
    # Two checks:
    #   1. the generated file on disk is exactly what we'd build now (no stale data)
    #   2. every monster read through the real Lua reader matches the JSON exactly
    # The second one is what proves the packing and monster_data.lua agree.
    expected = build_text(source)

    if OUTPUT.read_text(encoding="utf-8") != expected:
        raise ValueError("Generated monster data is out of date; run build")

    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = ROOT.as_posix() + "/?.lua"

    loaded = lua.eval('require("src/data/monster_data")')
    reader = loaded[0] if isinstance(loaded, tuple) else loaded

    for original in source["monsters"]:
        decoded = reader.find(original["title"])

        if isinstance(decoded, tuple):
            decoded = decoded[0]

        if decoded is None or decode_record(decoded, MONSTER_FIELDS) != original:
            raise ValueError(f"Round-trip mismatch: {original['title']}")

    compact_bytes = len(expected.encode("utf-8"))
    compact_json_bytes = len(json_text(source["monsters"]).encode("utf-8"))

    print(f"Verified {len(source['monsters'])} complete record round trips; "
          f"{compact_bytes:,} runtime bytes ({compact_bytes / compact_json_bytes:.1%} of equivalent compact JSON).")


# ---------------------------------------------------------------------------
# Recipes: creation costs for untradeable supplies
# ---------------------------------------------------------------------------
#
# catalogue-source/recipes.json comes from src/tools/wiki_recipes.py. The Wiki often
# lists several recipes for one item (e.g. Overload: the standard one, the 120
# Herblore batch, the unfinished-potion route). We use the FIRST one listed: it's
# the standard recipe anyone can make. Other recipes stay in the source for later.

RECIPE_PRICING = {"ge", "recipe", "free"}


def choose_recipes(source):
    """Validates the recipe source and returns {page: chosen recipe}."""
    if source.get("schema") != 1 or not isinstance(source.get("recipes"), list):
        raise ValueError("Unsupported recipe source")

    chosen = {}

    for recipe in source["recipes"]:
        recipe = require_record(recipe, "Recipe")
        require_text(recipe.get("page"), "Recipe page")

        if not positive_integer(recipe.get("sequence")):
            raise ValueError(f"Recipe {recipe['page']} needs a positive sequence")

        output = require_record(recipe.get("output"), "Recipe output")

        if not non_negative_number(output.get("quantity")) or output["quantity"] <= 0:
            raise ValueError(f"Recipe {recipe['page']} output quantity must be above zero")

        if "portion" in output and not positive_integer(output["portion"]):
            raise ValueError(f"Recipe {recipe['page']} output portion must be a whole number")

        if not isinstance(recipe.get("materials"), list) or not recipe["materials"]:
            raise ValueError(f"Recipe {recipe['page']} has no materials")

        for material in recipe["materials"]:
            material = require_record(material, "Recipe material")
            require_text(material.get("name"), "Recipe material name")

            if not non_negative_number(material.get("quantity")) or material["quantity"] <= 0:
                raise ValueError(f"{recipe['page']}: {material['name']} quantity must be above zero")

            if "portion" in material and not positive_integer(material["portion"]):
                raise ValueError(f"{recipe['page']}: {material['name']} portion must be a whole number")

            if material.get("pricing") not in RECIPE_PRICING:
                raise ValueError(f"{recipe['page']}: {material['name']} has unknown pricing")

            if material["pricing"] == "ge" and not positive_integer(material.get("item_id")):
                raise ValueError(f"{recipe['page']}: GE-priced {material['name']} needs an item ID")

        # Lowest sequence wins; the source is sorted, but don't rely on that.
        current = chosen.get(recipe["page"])

        if current is None or recipe["sequence"] < current["sequence"]:
            chosen[recipe["page"]] = recipe

    # Every "follow this recipe" ingredient must have a recipe, and following them
    # must never loop back round (A needs B needs A would never finish pricing).
    def walk(page, path):
        if page in path:
            raise ValueError("Recipe loop: " + " -> ".join(path + [page]))

        for material in chosen[page]["materials"]:
            if material["pricing"] == "recipe":
                if material.get("page") not in chosen:
                    raise ValueError(f"{page}: no recipe for {material['name']}")

                walk(material["page"], path + [page])

    for page in chosen:
        walk(page, [])

    return chosen


def recipes_text(source):
    """The runtime copy: just the chosen recipe per page, with the fields the
    calculator uses. Wiki bookkeeping (cost markers, other recipes) stays in the
    JSON source."""
    chosen = choose_recipes(source)
    runtime = {}

    for page, recipe in sorted(chosen.items()):
        output = recipe["output"]
        entry = {"name": output["name"], "quantity": output["quantity"], "url": recipe["url"], "materials": []}

        for key in ("portion", "item_id"):
            if key in output:
                entry[key] = output[key]

        for material in recipe["materials"]:
            kept = {"name": material["name"], "quantity": material["quantity"], "pricing": material["pricing"]}

            if material["pricing"] == "ge":
                kept["item_id"] = material["item_id"]

            if material["pricing"] == "recipe":
                kept["page"] = material["page"]

            if "portion" in material:
                kept["portion"] = material["portion"]

            entry["materials"].append(kept)

        runtime[page] = entry

    return ("-- Generated by src/tools/catalogue.py from catalogue-source/recipes.json; do not edit.\n"
            "-- " + source.get("licence", "RuneScape Wiki contributors, CC BY-NC-SA 3.0.")
            + " See THIRD_PARTY_NOTICES.txt.\n"
            "return " + readable_lua(runtime) + "\n")


def verify_recipes(source):
    expected = recipes_text(source)

    if RECIPE_OUTPUT.read_text(encoding="utf-8") != expected:
        raise ValueError("Generated recipes are out of date; run build")

    LuaRuntime().execute(expected)

    print(f"Verified {len(choose_recipes(source))} creation-cost recipes "
          f"({len(source['recipes'])} in the source, retrieved {source.get('retrieved')}).")


def validate_methods(source, monsters, recipes=None):
    """Check the fields consumed by native views and the pure requirement/calculator code."""
    # The plugin reads these fields without re-checking them, so anything wrong has
    # to be caught here. Roughly in order: items, method identity and display text,
    # requirements, source revision, income model, then PvM loot references.
    source = require_record(source, "Method catalogue")

    if type(source.get("schema")) is not int or source["schema"] != 1:
        raise ValueError("Unsupported method schema")

    # Shared item table, keyed by item ID as text (JSON keys are always strings).
    items = source.get("items")

    if not isinstance(items, dict):
        raise ValueError("Method items must be a mapping")

    for item_id, item in items.items():
        if not isinstance(item_id, str) or not item_id.isdecimal() or int(item_id) <= 0:
            raise ValueError("Item mapping keys must be positive integer IDs")

        require_text(require_record(item, "Item definition").get("name"), "Item name")

        # Charged/worn variants can share one icon, but each presence lookup still
        # needs an explicit positive item ID. These never affect income pricing.
        if "ownership_ids" in item:
            aliases = item["ownership_ids"]

            if (not isinstance(aliases, list) or not aliases
                    or any(type(value) is not int or value <= 0 for value in aliases)):
                raise ValueError("Item ownership IDs must be positive integers")


    if not isinstance(source.get("methods"), list):
        raise ValueError("Methods must be a list")

    known = {monster["title"]: monster for monster in monsters["monsters"]}
    ids = set()

    for method in source["methods"]:
        method = require_record(method, "Method")

        # Method IDs end up in saved-rate storage keys, so they must be unique, stable
        # and limited to simple characters. Renaming one would orphan saved rates.
        method_id = method.get("id")

        if (not isinstance(method_id, str)
                or not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", method_id)
                or method_id in ids):
            raise ValueError("Invalid/duplicate method ID")

        ids.add(method_id)

        for field in ("title", "category", "source_category", "intensity"):
            require_text(method.get(field), f"{method_id}.{field}")

        if type(method.get("members")) is not bool:
            raise ValueError("Method membership must be a boolean")

        if "variant" in method:
            require_text(method["variant"], "Method variant")

        require_text_list(method.get("instructions"), "Method instructions")

        location = require_record(method.get("location"), "Method location")
        require_text(location.get("text"), "Method location")

        if location.get("coverage") not in {"complete", "partial"}:
            raise ValueError("Invalid location coverage")

        # Requirements: both top-level entries must be groups, because the method
        # view counts their children to size its labels.
        requirements = require_record(method.get("requirements"), "Method requirements")

        if requirements.get("coverage") not in {"complete", "partial"}:
            raise ValueError("Invalid requirement coverage")

        for group in ("access", "recommended"):
            root = requirements.get(group)
            validate_requirement(root, items)

            if root["kind"] not in {"all", "any"}:
                raise ValueError("Access and recommended requirements must be groups")

        require_text_list(requirements.get("unresolved", []), "Unresolved requirements")

        # Every method records which Wiki revision it came from.
        revision = require_record(method.get("source"), "Method source").get("revision")

        if not positive_integer(revision):
            raise ValueError("Method source revision is required")

        income = require_record(method.get("income"), "Method income")

        if income.get("period") != "hour":
            raise ValueError("Only hourly income periods are supported by this calculator")

        # The rate is the number the player can edit. Its key and unit are part of the
        # saved-rate contract; a unit change makes old saved rates invalid on purpose.
        rate_definition = require_record(income.get("rate"), "Method rate")
        rate_key = rate_definition.get("key")

        if not isinstance(rate_key, str) or not re.fullmatch(r"[a-z0-9_]+", rate_key):
            raise ValueError("Invalid method rate key")

        rate = rate_definition.get("default")

        if (not non_negative_number(rate)
                or rate_definition.get("unit") not in {"kills/hour", "logs/hour", "smelts/hour"}):
            raise ValueError("Invalid method rate")

        if income["coverage"] not in {"complete", "partial"}:
            raise ValueError("Invalid income coverage")

        require_text_list(income.get("assumptions"), "Income assumptions")
        require_text_list(income.get("unresolved"), "Unresolved income")

        # Each supply/output row: a name, a quantity, and whether that quantity is per
        # action or per hour. A "complete" model can't have rows we can't price.
        for direction in ("inputs", "outputs"):
            lines = income.get(direction)

            if not isinstance(lines, list):
                raise ValueError(f"Income {direction} must be a list")

            for line in lines:
                line = require_record(line, "Income row")
                require_text(line.get("name"), "Income item name")

                if "display_item_id" in line:
                    if not positive_integer(line["display_item_id"]) or str(line["display_item_id"]) not in items:
                        raise ValueError("Unresolved income display item")

                if line.get("basis") not in {"action", "hour"} or not non_negative_number(line.get("quantity")):
                    raise ValueError("Invalid income quantity/basis")

                if "item_id" in line:
                    if not positive_integer(line["item_id"]) or str(line["item_id"]) not in items:
                        raise ValueError("Unresolved method item reference")
                elif income["coverage"] == "complete":
                    raise ValueError("Complete income cannot have unresolved item valuations")

                # Untradeable supplies are priced by what they cost to make. The row
                # names the recipe (a Wiki page) and the doses it's counted in, so
                # e.g. a 6-dose potion made by a 6-dose recipe costs one recipe.
                if "pricing" in line:
                    if line["pricing"] != "recipe" or direction != "inputs":
                        raise ValueError("Only input rows can be priced by recipe")

                    recipe = (recipes or {}).get(line.get("recipe"))

                    if recipe is None:
                        raise ValueError(f"Unknown recipe for income row: {line.get('recipe')}")

                    if ("portion" in line) != ("portion" in recipe["output"]):
                        raise ValueError(f"Doses for {line['name']} must match its recipe's output")

                    if "portion" in line and not positive_integer(line["portion"]):
                        raise ValueError(f"Invalid dose count for {line['name']}")

                # GE tax is only paid when selling, so it only belongs on outputs.
                if "tax_denominator" in line:
                    if not positive_integer(line["tax_denominator"]):
                        raise ValueError("Invalid per-item tax denominator")

                    if direction != "outputs":
                        raise ValueError("Sale tax is only valid on output rows")

        # PvM methods point at rows in the shared monster data instead of copying them.
        # Each selector must still match exactly the expected number of drop rows; if
        # a monster re-import changes that, the build fails so someone looks at it.
        if "loot" in income:
            loot = require_record(income["loot"], "Monster loot selection")
            require_text(loot.get("monster"), "Loot monster")

            if not isinstance(loot.get("selection"), list) or not loot["selection"]:
                raise ValueError("Monster loot selection cannot be empty")

            monster = known.get(loot["monster"])

            if monster is None:
                raise ValueError("Unresolved method monster reference")

            for selected in loot["selection"]:
                selected = require_record(selected, "Loot selector")

                # Some source sections are untitled, so the section may be empty text.
                if not isinstance(selected.get("section"), str):
                    raise ValueError("Loot selector section must be text")

                require_text(selected.get("item"), "Loot selector item")

                if not positive_integer(selected.get("rows")):
                    raise ValueError("Loot selectors must select at least one row")

                matches = [
                    drop for section in monster["sections"] if section.get("title") == selected["section"]
                    for drop in section["drops"] if drop["name"] == selected["item"]
                ]

                if len(matches) != selected["rows"]:
                    raise ValueError(f"Loot selector changed: {method['id']} / {selected}")

            # The calculator doesn't value loot yet, so it can't be "complete".
            if income["coverage"] == "complete":
                raise ValueError("Unprocessed monster loot cannot be labelled complete")

        if income["coverage"] == "complete" and income.get("unresolved"):
            raise ValueError("Complete income cannot have unresolved assumptions")

    json_text(source)


def methods_text(source, monsters, recipes=None):
    validate_methods(source, monsters, recipes)

    return ("-- Generated by src/tools/catalogue.py; do not edit.\n"
            "-- RuneScape Wiki contributors, CC BY-NC-SA 3.0. See THIRD_PARTY_NOTICES.txt.\n"
            "return " + readable_lua(source) + "\n")


def load_recipes():
    """The recipe source, or None if it hasn't been imported (it's optional)."""
    if not RECIPE_SOURCE.exists():
        return None

    return json.loads(RECIPE_SOURCE.read_text(encoding="utf-8"))


def verify_methods(monsters, recipe_source):
    # Same idea as verify(): the file on disk must match a fresh build, and the
    # generated Lua must actually load.
    source = json.loads(METHOD_SOURCE.read_text(encoding="utf-8"))
    recipes = choose_recipes(recipe_source) if recipe_source else None
    expected = methods_text(source, monsters, recipes)

    if METHOD_OUTPUT.read_text(encoding="utf-8") != expected:
        raise ValueError("Generated methods are out of date; run build")

    LuaRuntime().execute(expected)

    print(f"Verified {len(source['methods'])} representative methods and their shared-data references.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("import-monsters", "build", "verify"))
    parser.add_argument("--from", dest="checkout", type=Path)
    args = parser.parse_args()

    if args.command == "import-monsters":
        if args.checkout is None:
            parser.error("import-monsters requires --from PATH")

        import_monsters(args.checkout)

    source = json.loads(SOURCE.read_text(encoding="utf-8"))
    recipe_source = load_recipes()

    if args.command in {"import-monsters", "build"}:
        # Build every output in memory first. Only once all pass validation do we
        # write any, so a bad method or recipe can't leave a mix of old and new data.
        generated = build_text(source)
        generated_methods = None
        generated_recipes = None

        if recipe_source is not None:
            generated_recipes = recipes_text(recipe_source)

        if METHOD_SOURCE.exists():
            methods = json.loads(METHOD_SOURCE.read_text(encoding="utf-8"))
            recipes = choose_recipes(recipe_source) if recipe_source else None
            generated_methods = methods_text(methods, source, recipes)

        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(generated, encoding="utf-8", newline="\n")

        if generated_methods is not None:
            METHOD_OUTPUT.write_text(generated_methods, encoding="utf-8", newline="\n")

        if generated_recipes is not None:
            RECIPE_OUTPUT.write_text(generated_recipes, encoding="utf-8", newline="\n")

    # Always finish with a full verify, even straight after a build.
    verify(source)

    if recipe_source is not None:
        verify_recipes(recipe_source)

    if METHOD_SOURCE.exists():
        verify_methods(source, recipe_source)


if __name__ == "__main__":
    main()
