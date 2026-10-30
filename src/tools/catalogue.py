"""Import local Monster Lookup data and build/verify Profit Path's static drop bundle.

No network access. Source JSON stays readable; generated Lua interns repeated strings,
drop rows and sections. Only import needs an existing Monster Lookup checkout.
"""
# Developer tool, never shipped with the plugin. The flow is:
#
#   import-monsters  copy monster/drop data out of a local Monster Lookup checkout
#                    into catalogue-source/monsters.json (readable, reviewable)
#   format           tidy a hand-edited catalogue-source/methods.json into its standard
#                    one-row-per-line layout (build and verify refuse any other layout)
#   build            turn the JSON sources into data/monsters.lua, data/methods.lua and
#                    data/recipes.lua (recipes come from src/tools/wiki_recipes.py)
#   verify           rebuild in memory and check the files on disk still match, then
#                    load every monster back through the real Lua reader
#
# The idea: humans edit and review the JSON, the plugin loads the generated Lua, and
# this script makes sure those two never drift apart.
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import re
from pathlib import Path

import lupa.lua54 as lupa
from lupa.lua54 import LuaRuntime, LuaError


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

# Reviewed research: what each non-item requirement (an ability, spell, prayer,
# relic, perk...) is, and the rsprite sprite that shows it. Drafted by
# `catalogue.py match-sprites`, then checked by hand.
CAPABILITIES = ROOT / "catalogue-source" / "research" / "capabilities.json"


def capability_icon(sprite):
    """The icon alias a capability's sprite is known by, e.g. sprite_arch_icon_..."""
    return "sprite_" + sprite.lower()


def load_capabilities():
    """{requirement name: {"kind", "sprite"}}, or {} before any research exists."""
    if not CAPABILITIES.exists():
        return {}

    source = json.loads(CAPABILITIES.read_text(encoding="utf-8"))

    if source.get("schema") != 1 or not isinstance(source.get("capabilities"), dict):
        raise ValueError("Unsupported capabilities research file")

    return source["capabilities"]


# Capability sprites are valid icons too.
ICON_NAMES |= {capability_icon(entry["sprite"]) for entry in load_capabilities().values() if entry.get("sprite")}

# What each kind of capability is. "guidance" isn't a requirement at all: it's a
# Wiki advice page ("Armoury", "Recommended equipment for PvM"), shown as a note.
CAPABILITY_KINDS = {
    "ability", "spell", "prayer", "relic", "perk", "outfit", "achievement", "place",
    "unlock", "familiar", "item", "quest", "guidance", "other",
}

# Reviewed research: Wiki quest names -> the client's quest config names, so quest
# requirements can be checked in game. Built by `catalogue.py map-quests` from a
# verified in-game quest dump.
QUESTS = ROOT / "catalogue-source" / "research" / "quests.json"


def load_quests():
    """{Wiki quest name: client quest config name}, or {} before any mapping."""
    if not QUESTS.exists():
        return {}

    source = json.loads(QUESTS.read_text(encoding="utf-8"))

    if source.get("schema") != 1 or not isinstance(source.get("quests"), dict):
        raise ValueError("Unsupported quest research file")

    for name, config in source["quests"].items():
        if not isinstance(name, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", config or ""):
            raise ValueError(f"Invalid quest mapping: {name}")

    return source["quests"]


def map_quests(dump_path):
    """Writes research/quests.json: every quest name the Wiki snapshot mentions,
    mapped to its client config name by exact display name (ignoring case).

    The dump is a verified in-game read of every quest config (Skill Tips'
    tools/verified_configs.json). A deprecated config is never used, and a name
    with two current configs is left out rather than guessed. Returns the mapping."""
    import merge_methods
    import wiki_methods

    dump = json.loads(Path(dump_path).read_text(encoding="utf-8"))
    by_name = {}

    for config, quest in dump["quests"].items():
        if not quest.get("deprecated"):
            by_name.setdefault(quest["name"].lower(), []).append(config)

    guides, _ = merge_methods.load_snapshot()
    names = set()

    for guide in guides:
        for group in guide.get("requirements", {}).values():
            for entry in group:
                names |= wiki_methods.requirement_quests(entry) | wiki_methods.requirement_items(entry)

    mapped = {}

    for name in sorted(names):
        # "Raksha, the Shadow Colossus (quest)" is the quest "Raksha, the Shadow Colossus".
        plain_name = re.sub(r"\s*\(quest\)$", "", name, flags=re.IGNORECASE)
        configs = by_name.get(plain_name.lower(), [])

        if len(configs) == 1:
            mapped[name] = configs[0]

    QUESTS.parent.mkdir(parents=True, exist_ok=True)
    document = {
        "schema": 1,
        "source": f"{Path(dump_path).name}, an in-game config dump. Its notes: " + dump.get("source", "none"),
        "note": "Wiki quest names (and Wiki links that are really quests) mapped to client quest config names by "
                "exact display name. Generated by catalogue.py map-quests; deprecated configs are never used.",
        "quests": mapped,
    }
    QUESTS.write_text(source_text(document) + "\n", encoding="utf-8", newline="\n")

    return mapped

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


def validate_requirement(check, items, equipment=None):
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

        if "equipment_group" in check:
            group_name = check["equipment_group"]

            if not isinstance(group_name, str) or group_name not in (equipment or {}):
                raise ValueError("Unresolved equipment group")

        for field in ("style", "slot"):
            if field in check:
                require_text(check[field], "Equipment " + field)

        if "minimum_tier" in check and not positive_integer(check["minimum_tier"]):
            raise ValueError("Minimum equipment tier must be positive")

        # A stated minimum is a real requirement, not a top-end example. Reject
        # any display candidate above the lowest qualifying tier.
        if "minimum_item_id" in check:
            item_id = check["minimum_item_id"]

            if not positive_integer(item_id) or str(item_id) not in items or not check.get("equipment_group"):
                raise ValueError("A minimum item must reference a known equipment candidate")

            if not positive_integer(check.get("minimum_tier")):
                raise ValueError("A minimum item needs an explicit minimum tier")

            candidates = (equipment or {})[check["equipment_group"]]["candidates"]
            eligible = [candidate for candidate in candidates
                        if candidate["tier"] >= check["minimum_tier"]
                        and ("style" not in check or candidate.get("style") == check["style"])
                        and ("slot" not in check or candidate.get("slot") == check["slot"])]

            lowest_tier = min((candidate["tier"] for candidate in eligible), default=None)

            if not any(candidate["item_id"] == item_id and candidate["tier"] == lowest_tier for candidate in eligible):
                raise ValueError("The displayed minimum item must be a lowest qualifying candidate")

        if not isinstance(scope, str) or scope not in {"specific", "flexible"}:
            raise ValueError("Gear requires an explicit equipment scope")

        if scope == "flexible" and "display_items" in check:
            raise ValueError("Flexible equipment must use text, not fixed item icons")

    elif "minimum_item_id" in check:
        raise ValueError("Minimum items only apply to equipment requirements")

    elif "equipment_scope" in check:
        raise ValueError("Equipment scope only applies to gear requirements")

    if kind in {"all", "any"}:
        children = check.get("children")

        # An empty ANY can never pass, so it's almost certainly a data mistake.
        if not isinstance(children, list) or (kind == "any" and not children):
            raise ValueError("Requirement alternatives must be a list; ANY cannot be empty")

        for child in children:
            validate_requirement(child, items, equipment)

    elif kind == "skill":
        # Must look like a client SkillType name, e.g. SMITHING.
        name = check.get("skill")

        if not isinstance(name, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", name):
            raise ValueError("Invalid skill config name")

        if not positive_integer(check.get("level")):
            raise ValueError("Requirement level must be a positive integer")

        if "skill_" + name.lower() not in ICON_NAMES:
            raise ValueError("Unresolved skill icon name")

    elif kind == "combat_level":
        # Worked out in game from nine combat skills; 152 is the highest possible.
        if not positive_integer(check.get("level")) or check["level"] > 152:
            raise ValueError("Combat level requirement must be 1 to 152")

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
        # always shows them as "unknown". A capability may say what kind it is.
        if "capability_kind" in check and check["capability_kind"] not in CAPABILITY_KINDS - {"guidance"}:
            raise ValueError(f"Unknown capability kind: {check['capability_kind']}")

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


# Rate units the calculator and saved rates understand. "actions/hour" is for
# non-combat Wiki guides counted per action; "% of guide pace" for guides given only
# per hour (100 is the guide's own pace).
RATE_UNITS = {"kills/hour", "logs/hour", "smelts/hour", "actions/hour", "% of guide pace", "% of guide yield"}


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


    # Native binding names come from developer metadata, not inferred from Wiki
    # tool names. Runtime applies one shared lookup to every supported family.
    toolbelt = source.get("toolbelt", {})

    if not isinstance(toolbelt, dict):
        raise ValueError("Tool-belt bindings must be a mapping")

    for family, binding in toolbelt.items():
        require_text(family, "Tool-belt family")
        require_record(binding, "Tool-belt binding")
        require_text(binding.get("source"), "Tool-belt source")

        for field in ("value_variable", "items_enum", "presence_variable"):
            if field == "presence_variable" and field not in binding:
                continue

            value = binding.get(field)

            if not isinstance(value, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", value):
                raise ValueError("Tool-belt native config name is invalid")

        if type(binding.get("value_offset")) is not int or binding["value_offset"] not in (0, -1):
            raise ValueError("Tool-belt index offset must be verified as 0 or -1")

    equipment = source.get("equipment", {})

    if not isinstance(equipment, dict):
        raise ValueError("Equipment groups must be a mapping")

    for name, group in equipment.items():
        require_text(name, "Equipment group name")
        require_record(group, "Equipment group")

        if type(group.get("complete")) is not bool or not isinstance(group.get("candidates"), list) or not group["candidates"]:
            raise ValueError("Equipment groups need candidates and a coverage flag")

        require_text(group.get("note"), "Equipment coverage note")
        seen = set()

        for candidate in group["candidates"]:
            require_record(candidate, "Equipment candidate")
            item_id = candidate.get("item_id")

            if not positive_integer(item_id) or str(item_id) not in items or item_id in seen:
                raise ValueError("Invalid/duplicate equipment candidate")

            seen.add(item_id)

            if not positive_integer(candidate.get("tier")) or not isinstance(candidate.get("skills"), dict):
                raise ValueError("Equipment candidates need a tier and use levels")

            for field in ("style", "slot"):
                if field in candidate:
                    require_text(candidate[field], "Equipment " + field)

            for skill, level in candidate["skills"].items():
                if not isinstance(skill, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", skill) or not positive_integer(level):
                    raise ValueError("Invalid equipment use level")

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

        # Bundled methods are always "bundled". Players' copies will use the same
        # record shape with their own origin, so the record says which one it is.
        if method.get("schema") != METHOD_RECORD_SCHEMA or method.get("origin") != "bundled":
            raise ValueError(f"{method_id} needs record schema {METHOD_RECORD_SCHEMA} and origin bundled")

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
            validate_requirement(root, items, equipment)

            if root["kind"] not in {"all", "any"}:
                raise ValueError("Access and recommended requirements must be groups")

        require_text_list(requirements.get("unresolved", []), "Unresolved requirements")

        # Wiki advice pages for the method: shown as notes, never checked.
        require_text_list(requirements.get("advice", []), "Requirement advice")

        # Every method records which Wiki revision it came from.
        revision = require_record(method.get("source"), "Method source").get("revision")

        if not positive_integer(revision):
            raise ValueError("Method source revision is required")

        income = require_record(method.get("income"), "Method income")

        # Income is per hour, or per run for a recurring (daily/weekly) method, which
        # also says how often it can be done.
        if income.get("period") not in ("hour", "run"):
            raise ValueError("Income period must be hour or run")

        if income["period"] == "run":
            recurrence = require_record(income.get("recurrence"), "Recurring income")
            require_text(recurrence.get("every"), "Recurring cycle")

            if not non_negative_number(recurrence.get("minutes")):
                raise ValueError("A recurring run needs its minutes per run")
        elif "recurrence" in income:
            raise ValueError("Only per-run income has a recurrence")

        # The rate is the number the player can edit. Its key and unit are part of the
        # saved-rate contract; a unit change makes old saved rates invalid on purpose.
        rate_definition = require_record(income.get("rate"), "Method rate")
        rate_key = rate_definition.get("key")

        if not isinstance(rate_key, str) or not re.fullmatch(r"[a-z0-9_]+", rate_key):
            raise ValueError("Invalid method rate key")

        rate = rate_definition.get("default")

        # "% of guide pace" is for Wiki guides given only per hour: 100 is the
        # guide's own pace, and every amount scales with it.
        if (not non_negative_number(rate)
                or rate_definition.get("unit") not in RATE_UNITS):
            raise ValueError(f"Invalid method rate for {method_id}")

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
                elif income["coverage"] == "complete" and line.get("pricing") != "fixed":
                    # A fixed-value row (coins, a clue scroll) needs no item to price it.
                    raise ValueError("Complete income cannot have unresolved item valuations")

                # Untradeable supplies are priced by what they cost to make. The row
                # names the recipe (a Wiki page) and the doses it's counted in, so
                # e.g. a 6-dose potion made by a 6-dose recipe costs one recipe.
                # A fixed value is a set GP amount per item (the Wiki's value for coins,
                # clue scrolls and the like). It never pays GE tax.
                if line.get("pricing") == "fixed":
                    if not non_negative_number(line.get("unit_value")) or "tax_denominator" in line:
                        raise ValueError(f"Fixed-value row {line['name']} needs a unit value and no sale tax")

                elif "pricing" in line:
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

            # Use the actual runtime expansion against source data. This checks
            # rates/ranges once, without a second Python parser or stale Lua bundle.
            lua = LuaRuntime(unpack_returned_tuples=True)
            resolver = lua.execute((ROOT / "src" / "methods" / "loot.lua").read_text(encoding="utf-8"))

            try:
                rows = resolver.expand(lua.execute("return " + lua_literal(loot["selection"])),
                                       lua.execute("return " + lua_literal(monster)))
            except LuaError as error:
                raise ValueError(f"Invalid loot model for {method_id}: {error}") from error

            for row in rows.values():
                item = items.get(str(row["item_id"]))

                if not item or item["name"] != row["name"]:
                    raise ValueError("Unresolved loot item metadata")

        if income["coverage"] == "complete" and income.get("unresolved"):
            raise ValueError("Complete income cannot have unresolved assumptions")

    # Methods sharing a title are versions of one method (like elder logs with and
    # without wood spirits); the method page has a dropdown to switch between them.
    # The dropdown shows each version's label, so every version needs its own one,
    # and they must be the same kind of activity.
    versions_by_title = {}

    for method in source["methods"]:
        versions_by_title.setdefault(method["title"], []).append(method)

    for title, versions in versions_by_title.items():
        if len(versions) < 2:
            continue

        labels = [version.get("variant") for version in versions]

        if any(not isinstance(label, str) or not label.strip() for label in labels) or len(set(labels)) != len(labels):
            raise ValueError(f"Versions of {title} need distinct variant labels")

        if len({version["category"] for version in versions}) != 1:
            raise ValueError(f"Versions of {title} must share an activity category")

    json_text(source)


# ---------------------------------------------------------------------------
# Methods: short hand-written source -> full method records -> packed runtime file
# ---------------------------------------------------------------------------
#
# catalogue-source/methods.json is written to be short (schema 2). The build
# "expands" it into full method records, which is the one shape the plugin uses for
# every method (and later for players' own copies), checks those, then packs them.
#
# What the short source is allowed to leave out, and how the build fills it in:
#
#   - One entry per Wiki page. Each item in its "versions" list gives only what's
#     different (its ID, its label, usually its income); the rest comes from the page.
#   - Requirements can be short strings: "skill:SMITHING:20" or "item:31455". Their
#     text ("20 Smithing", or the item's name) is worked out for you.
#   - A group with no text gets one from its children: "A or B" for ANY, "A; B" for
#     ALL. A group whose children are all items gets those items' icons.
#   - Everything directly under "recommended" gets " (recommended)" on the end.
#   - Income rows take their name from the items table unless they give their own.
#   - Wiki links are built from the page name and revision number.
#   - Empty lists, and the usual "hour" income period, can be left out.

METHOD_SOURCE_SCHEMA = 2

# Version of a single full method record. Bundled methods carry it now so a
# player's saved copy can be checked against the same shape later.
METHOD_RECORD_SCHEMA = 1

WIKI_PAGE = "https://runescape.wiki/w/"


def wiki_url(page, revision):
    return WIKI_PAGE + page.replace(" ", "_") + "?oldid=" + str(revision)


def merge(base, changes):
    """Deep-merges a version's changes over its page. Records merge key by key;
    anything else (text, numbers, lists) is replaced whole."""
    result = copy.deepcopy(base)

    for key, value in changes.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)

    return result


def expand_item(item):
    item = dict(require_record(item, "Item definition"))

    # A revision means "this came from the Wiki page with the item's name", unless
    # "page" names a different one (e.g. the item "Aggroverload (6)" lives on the
    # "Aggroverload" page).
    if "revision" in item:
        revision = item.pop("revision")
        page = item.pop("page", item.get("name"))

        if not positive_integer(revision) or not isinstance(page, str):
            raise ValueError(f"Invalid Wiki revision for item {item.get('name')}")

        item["source"] = wiki_url(page, revision)

    return item


def expand_requirement(check, items, suffix=""):
    # Short strings first: "skill:NAME:LEVEL" or "item:ID".
    if isinstance(check, str):
        parts = check.split(":")

        if len(parts) == 3 and parts[0] == "skill" and parts[2].isdecimal():
            check = {"kind": "skill", "skill": parts[1], "level": int(parts[2])}
        elif len(parts) == 2 and parts[0] == "item" and parts[1].isdecimal():
            check = {"kind": "item", "itemId": int(parts[1]), "quantity": 1}
        else:
            raise ValueError(f"Unknown requirement shorthand: {check}")
    else:
        check = dict(require_record(check, "Requirement"))

    kind = check.get("kind")

    if kind in {"all", "any"} and isinstance(check.get("children"), list):
        # Children never get the "(recommended)" ending; only the group itself does.
        children = [expand_requirement(child, items) for child in check["children"]]
        check["children"] = children

        if children and "display_items" not in check and all(child.get("kind") == "item" for child in children):
            check["display_items"] = [child["itemId"] for child in children]

        texts = [child.get("text") for child in children]

        if "text" not in check and texts and all(isinstance(text, str) for text in texts):
            if kind == "all":
                check["text"] = "; ".join(texts)
            else:
                check["text"] = " or ".join([", ".join(texts[:-1]), texts[-1]]) if len(texts) > 1 else texts[0]

    elif "text" not in check:
        if kind == "skill" and isinstance(check.get("skill"), str):
            check["text"] = f"{check.get('level')} {check['skill'].capitalize()}"
        elif kind == "item" and str(check.get("itemId")) in items:
            check["text"] = items[str(check["itemId"])]["name"]

    # Anything still missing text is left for validate_requirement to report.
    if suffix and isinstance(check.get("text"), str):
        check["text"] += suffix

    return check


def expand_requirements(requirements, items):
    requirements = dict(require_record(requirements, "Method requirements"))

    # The two top-level groups are always ALL groups with fixed names, so the
    # source just lists their children.
    for group, text, suffix in (("access", "Required", ""), ("recommended", "Recommended", " (recommended)")):
        children = requirements.get(group, [])

        if not isinstance(children, list):
            raise ValueError(f"Requirement {group} must be a list in the method source")

        requirements[group] = {"kind": "all", "text": text,
                               "children": [expand_requirement(child, items, suffix) for child in children]}

    requirements.setdefault("unresolved", [])

    return requirements


def expand_income(income, items):
    income = dict(require_record(income, "Method income"))
    income.setdefault("period", "hour")
    income.setdefault("assumptions", [])
    income.setdefault("unresolved", [])

    for direction in ("inputs", "outputs"):
        rows = income.get(direction, [])

        if not isinstance(rows, list):
            raise ValueError(f"Income {direction} must be a list")

        income[direction] = []

        for row in rows:
            row = dict(require_record(row, "Income row"))
            item = items.get(str(row.get("item_id")))

            # Unknown items keep no name here; validate_methods reports them.
            if "name" not in row and item:
                row["name"] = item["name"]

            income[direction].append(row)

    return income


def expand_methods(source):
    """Turns the short source into the full catalogue the plugin and validator use."""
    source = require_record(source, "Method source")

    if source.get("schema") != METHOD_SOURCE_SCHEMA or not isinstance(source.get("pages"), list):
        raise ValueError("Unsupported method source; expected schema 2 with pages")

    items = {key: expand_item(item) for key, item in require_record(source.get("items"), "Method items").items()}
    methods = []

    for page in source["pages"]:
        page = dict(require_record(page, "Method page"))
        name = page.pop("page", None)
        revision = page.pop("revision", None)
        versions = page.pop("versions", None)

        require_text(name, "Method page name")

        if not positive_integer(revision):
            raise ValueError(f"{name} needs a Wiki revision")

        if not isinstance(versions, list) or not versions:
            raise ValueError(f"{name} needs at least one version")

        for version in versions:
            method = merge(page, require_record(version, "Method version"))

            # Every method records exactly which Wiki revision it came from.
            method["source"] = {"title": name, "revision": revision, "url": wiki_url(name, revision)}
            method["schema"] = METHOD_RECORD_SCHEMA
            method["origin"] = "bundled"

            method["requirements"] = expand_requirements(method.get("requirements"), items)
            method["income"] = expand_income(method.get("income"), items)

            location = dict(require_record(method.get("location"), "Method location"))
            location.setdefault("routes", [])
            method["location"] = location

            methods.append(method)

    catalogue = {"schema": 1, "items": items, "methods": methods}

    for key in ("equipment", "toolbelt"):
        if key in source:
            catalogue[key] = source[key]

    return catalogue


def source_text(value, indent=0, lead=0, width=110):
    """The one accepted layout for method source: anything that fits on a line stays
    on one line, so a requirement or income row is one line. `verify` insists on it,
    and `format` rewrites a hand-edited file into it.

    `indent` is where this value's own lines start; `lead` is how much is already
    written before it on its first line (a record key, for example)."""
    flat = json.dumps(value, ensure_ascii=False, allow_nan=False)

    if not isinstance(value, (dict, list)) or not value or indent + lead + len(flat) <= width:
        return flat

    pad = " " * (indent + 2)
    entries = []

    if isinstance(value, dict):
        for key, item in value.items():
            prefix = json.dumps(key, ensure_ascii=False) + ": "
            entries.append(pad + prefix + source_text(item, indent + 2, len(prefix), width))
    else:
        entries = [pad + source_text(item, indent + 2, 0, width) for item in value]

    opener, closer = ("{", "}") if isinstance(value, dict) else ("[", "]")

    return opener + "\n" + ",\n".join(entries) + "\n" + " " * indent + closer


# ---- Packing the runtime file ----------------------------------------------
#
# data/methods.lua is packed so it stays small with hundreds of methods:
#
#   - every distinct piece of text is stored once in `strings`, and used by number
#   - every distinct set of record keys (a "shape") is stored once in `shapes`
#   - a record is then {shape number, value, value, ...} in the shape's key order
#   - a list is {0, value, value, ...}, or {-1, text number, ...} for a list of text
#
# A key starting with "$" in a shape means "this value is a text number". That's
# how the reader (src/data/method_data.lua) tells text apart from real numbers.

def pack_methods(catalogue):
    strings, string_ids = [], {}
    shapes, shape_ids = [], {}

    def text(value):
        if value not in string_ids:
            string_ids[value] = len(strings) + 1
            strings.append(value)

        return string_ids[value]

    def pack(value):
        if isinstance(value, dict):
            # nil fields simply don't exist in Lua, so leave them out of the shape.
            fields = [(key, value[key]) for key in sorted(value) if value[key] is not None]

            if any(not isinstance(key, str) or key.startswith("$") for key, _ in fields):
                raise ValueError("Method record keys must be text and cannot start with $")

            shape = tuple("$" + key if isinstance(item, str) else key for key, item in fields)

            if shape not in shape_ids:
                shape_ids[shape] = len(shapes) + 1
                shapes.append(list(shape))

            return [shape_ids[shape]] + [text(item) if isinstance(item, str) else pack(item) for _, item in fields]

        if isinstance(value, list):
            if value and all(isinstance(item, str) for item in value):
                return [-1] + [text(item) for item in value]

            if any(isinstance(item, str) or item is None for item in value):
                raise ValueError("A method list cannot mix text with other values or hold nil")

            return [0] + [pack(item) for item in value]

        if isinstance(value, (bool, int, float)):
            return value

        raise TypeError(f"Cannot pack method value: {type(value).__name__}")

    # Pack the parts in a fixed order so the output is the same on every build.
    items = pack(catalogue["items"])
    equipment = pack(catalogue.get("equipment", {}))
    toolbelt = pack(catalogue.get("toolbelt", {}))
    icons = pack(catalogue.get("icons", {}))
    methods = [pack(method) for method in catalogue["methods"]]

    lines = [
        "-- Generated by src/tools/catalogue.py from catalogue-source/methods.json; do not edit.",
        "-- RuneScape Wiki contributors, CC BY-NC-SA 3.0. See THIRD_PARTY_NOTICES.txt.",
        "-- Packed: read it through src/data/method_data.lua, never directly.",
        "return {", "schema=1,", "packing=1,",
        "items=" + lua_literal(items) + ",",
        "equipment=" + lua_literal(equipment) + ",",
        "toolbelt=" + lua_literal(toolbelt) + ",",
        "icons=" + lua_literal(icons) + ",",
    ]

    # One line per string, shape and method keeps diffs readable.
    for name, values in (("strings", strings), ("shapes", shapes), ("methods", methods)):
        lines.append(name + "={")
        lines.extend(lua_literal(value) + "," for value in values)
        lines.append("},")

    lines.append("}")

    return "\n".join(lines) + "\n"


def methods_text(catalogue, monsters, recipes=None):
    """Checks full method records, then packs them for the plugin."""
    validate_methods(catalogue, monsters, recipes)

    # Sprite names for capability icons (e.g. a relic's), keyed by their alias.
    for alias, sprite in catalogue.get("icons", {}).items():
        if alias != capability_icon(sprite) or not re.fullmatch(r"[A-Z0-9_]+", sprite):
            raise ValueError(f"Invalid capability icon: {alias}")

    return pack_methods(catalogue)


def load_recipes():
    """The recipe source, or None if it hasn't been imported (it's optional)."""
    if not RECIPE_SOURCE.exists():
        return None

    return json.loads(RECIPE_SOURCE.read_text(encoding="utf-8"))


def load_method_source():
    """Reads the method source and refuses one not in the accepted layout."""
    text = METHOD_SOURCE.read_text(encoding="utf-8")
    source = json.loads(text)

    if text != source_text(source) + "\n":
        raise ValueError("catalogue-source/methods.json isn't in the standard layout; run format")

    return source


# A Lua table with nothing in it can't say whether it was a list or a record, so
# both sides of the round-trip comparison turn "empty" into this marker.
EMPTY = "<empty>"


def plain(value):
    """Python data as the plugin will see it: no nil fields, empty means EMPTY."""
    if isinstance(value, dict):
        value = {key: plain(item) for key, item in value.items() if item is not None}
    elif isinstance(value, list):
        value = [plain(item) for item in value]

    return EMPTY if value in ({}, []) else value


def from_lua(value):
    if lupa.lua_type(value) != "table":
        return value

    keys = list(value.keys())

    if not keys:
        return EMPTY

    if all(type(key) is int for key in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
        return [from_lua(value[key]) for key in range(1, len(keys) + 1)]

    return {key: from_lua(value[key]) for key in keys}


def build_catalogue(recipe_source):
    """The full catalogue the plugin ships: our curated methods merged with every
    current Wiki guide (see src/tools/merge_methods.py)."""
    import merge_methods

    return merge_methods.merge(recipe_source)[0]


def verify_methods(monsters, recipe_source):
    # Same idea as verify(): the file on disk must match a fresh build, and every
    # method read back through the plugin's own reader must equal its full record.
    catalogue = build_catalogue(recipe_source)
    recipes = choose_recipes(recipe_source) if recipe_source else None
    expected = methods_text(catalogue, monsters, recipes)

    if METHOD_OUTPUT.read_text(encoding="utf-8") != expected:
        raise ValueError("Generated methods are out of date; run build")

    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = ROOT.as_posix() + "/?.lua"
    loaded = lua.eval('require("src/data/method_data")')
    decoded = loaded[0] if isinstance(loaded, tuple) else loaded

    for key in ("schema", "items", "equipment", "toolbelt", "icons"):
        if from_lua(decoded[key]) != plain(catalogue.get(key, {})):
            raise ValueError(f"Method data round-trip mismatch: {key}")

    for method in catalogue["methods"]:
        if from_lua(decoded.find(method["id"])) != plain(method):
            raise ValueError(f"Method data round-trip mismatch: {method['id']}")

    if len(decoded.methods) != len(catalogue["methods"]):
        raise ValueError("Method data round-trip mismatch: method count")

    print(f"Verified {len(catalogue['methods'])} methods round-trip through the packed reader "
          f"({len(expected.encode('utf-8')):,} runtime bytes) with their shared-data references.")


# ---------------------------------------------------------------------------
# Capability sprites: drafting research/capabilities.json from rsprite's list
# ---------------------------------------------------------------------------
#
# Many Wiki requirements aren't items: abilities, spells, prayers, relics and
# Invention perks. Each of those has a native sprite, named in a regular way:
#
#   ability  COMBAT_ABILITY_ICON_<STYLE>_<NAME>      e.g. ..._ATTACK_BLADED_DIVE
#   spell    SPELL_ICON_<BOOK>_<NAME> and similar    e.g. SPELL_ICON_NECROMANCY_DARKNESS
#   prayer   PRAYER_ICON_<NAME> / CURSE_ICON_<NAME>
#   relic    ARCH_ICON_RELIC_64PX_<NAME>             e.g. ..._DEATH_NOTE
#   perk     INVENTION_ICON_PERKS_<GROUP>_<NAME>     e.g. ..._TOOLS_HONED
#
# match-sprites reads rsprite's reference list (a maintainer's local copy; we don't
# copy it) and drafts an entry for every requirement name whose sprite matches
# exactly. Only the matches we use are saved, like data/icons.lua. Existing
# entries are never overwritten, so hand fixes stay. Locked, mobile and disabled
# variants of a sprite are skipped: they're greyed or resized copies.

SPRITE_FAMILIES = (
    ("ability", r"COMBAT_ABILITY_ICON_(?:ATTACK|STRENGTH|DEFENCE|CONSTITUTION|MELEE|RANGED|MAGIC|NECROMANCY)_"),
    ("spell", r"(?:SPELL_ANCIENT_MAGICKS_ICON_|SPELL_ICON_NECROMANCY_|SPELL_ICON_ANCIENT_|SPELL_ICON_ZAROS_"
              r"|SPELL_ICON_(?:STANDARD|LUNAR|TELEPORT)_[A-Z]+_|SPELL_SKILLING_ICON_)"),
    ("prayer", r"(?:PRAYER_ICON_|CURSE_ICON_)"),
    ("relic", r"ARCH_ICON_RELIC_64PX_"),
    ("perk", r"INVENTION_ICON_PERKS_[A-Z]+_"),
)

SPRITE_VARIANTS = re.compile(r"_(?:LOCKED|MOBILE|DISABLED|TOGGLED)(?:_|$)")


def sprite_forms(name):
    """The sprite-name spellings to try for a requirement name, best first."""
    name = re.sub(r"#.*", "", name)
    name = re.sub(r"\s*\((?:perk|ability|relic power|relic|prayer|spell)\)\s*$", "", name, flags=re.IGNORECASE)
    words = re.sub(r"[^A-Z0-9]+", "_", name.replace("'", "").upper()).strip("_")
    forms = [words]

    # Perk ranks ("Biting 3") share one icon.
    unranked = re.sub(r"_\d+$", "", words)

    if unranked != words:
        forms.append(unranked)

    # Necromancy writes "Lesser Bone Shield" as BONE_SHIELD_LESSER.
    for rank in ("GREATER", "LESSER"):
        if words.startswith(rank + "_"):
            forms.append(words[len(rank) + 1:] + "_" + rank)

    return forms


def match_sprite(name, sprites):
    """(kind, sprite name) for a requirement name, or None."""
    for form in sprite_forms(name):
        for kind, prefix in SPRITE_FAMILIES:
            pattern = re.compile(prefix + re.escape(form))
            hits = sorted(sprite for sprite in sprites
                          if pattern.fullmatch(sprite) and not SPRITE_VARIANTS.search(sprite))

            if hits:
                return kind, hits[0]

    return None


def match_sprites(sprite_list):
    """Adds drafted entries to research/capabilities.json. Returns (added, missed)."""
    sprites = set()

    for line in sprite_list.read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")

        if len(parts) >= 2 and re.fullmatch(r"[A-Z0-9_]+", parts[1]):
            sprites.add(parts[1])

    import wiki_methods

    meta = json.loads(wiki_methods.META.read_text(encoding="utf-8"))
    names = sorted(set(meta["unresolved_requirement_items"]) | set(meta["unresolved"]))
    capabilities = load_capabilities()
    added, missed = 0, []

    for name in names:
        if name in capabilities:
            continue

        match = match_sprite(name, sprites)

        if match:
            capabilities[name] = {"kind": match[0], "sprite": match[1]}
            added += 1
        else:
            missed.append(name)

    CAPABILITIES.parent.mkdir(parents=True, exist_ok=True)
    document = {
        "schema": 1,
        "note": "What non-item requirements are, and the native sprite (from rsprite's reference list) that shows "
                "each one. Drafted by catalogue.py match-sprites; reviewed by hand. Can't be checked in game yet, "
                "so the plugin shows these as unknown.",
        "capabilities": dict(sorted(capabilities.items())),
    }
    CAPABILITIES.write_text(source_text(document) + "\n", encoding="utf-8", newline="\n")

    return added, missed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("import-monsters", "format", "match-sprites", "map-quests", "report",
                                            "build", "verify"))
    parser.add_argument("--from", dest="checkout", type=Path)
    args = parser.parse_args()

    # Drafts sprite matches for non-item requirements from rsprite's reference list
    # (--from PATH to its sprites.tsv). Review the file afterwards.
    # Maps Wiki quest names to client quest configs from a verified in-game dump
    # (--from PATH to Skill Tips' tools/verified_configs.json).
    if args.command == "map-quests":
        if args.checkout is None:
            parser.error("map-quests requires --from PATH to a verified quest config dump")

        mapped = map_quests(args.checkout)
        print(f"Mapped {len(mapped)} Wiki quest names to client quest configs in {QUESTS.relative_to(ROOT)}.")
        return

    if args.command == "match-sprites":
        if args.checkout is None:
            parser.error("match-sprites requires --from PATH to rsprite's sprites.tsv")

        added, missed = match_sprites(args.checkout)
        print(f"Added {added} capability sprites to {CAPABILITIES.relative_to(ROOT)}; "
              f"{len(missed)} names have no exact sprite match.")
        return

    # Coverage of the full catalogue: what's imported, what's researched, and what
    # still needs work, most valuable first.
    if args.command == "report":
        import merge_methods

        merge_methods.print_report(json.loads(SOURCE.read_text(encoding="utf-8")), load_recipes())
        return

    # Tidies a hand-edited methods.json into the standard layout. It only changes
    # line breaks and spacing; expanding it must give exactly the same methods.
    if args.command == "format":
        source = json.loads(METHOD_SOURCE.read_text(encoding="utf-8"))
        before = expand_methods(source)
        text = source_text(source) + "\n"

        if expand_methods(json.loads(text)) != before:
            raise ValueError("Formatting changed the methods; nothing was written")

        METHOD_SOURCE.write_text(text, encoding="utf-8", newline="\n")
        print(f"Formatted {METHOD_SOURCE.relative_to(ROOT)}.")
        return

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
            methods = build_catalogue(recipe_source)
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
