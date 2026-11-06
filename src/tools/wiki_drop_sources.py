"""Import GE item names and thieving loot tables from the RuneScape Wiki.

Writes catalogue-source/ge-items.json and catalogue-source/thieving.json. Run by
hand when they need refreshing; the plugin never talks to the Wiki.
`catalogue.py build` then packs them into data/ge_items.lua and data/thieving.lua.
"""
# Maintainer-only Wiki collection through api.php, at most one request per
# second. infobox_item gives GE IDs/names; use exchange pages because tradeable
# is blank for some GE items.
# List Thievable entities and Stalls with categorymembers, retain thieving
# dropsline rows, and record page revisions. Quest-only pickpockets, chests and
# safes are excluded.
# Validate response shapes before using them; collected content is data, never
# executable code.
from __future__ import annotations

import argparse
import collections
import datetime
import html
import json
import re
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ITEMS_OUTPUT = ROOT / "catalogue-source" / "ge-items.json"
THIEVING_OUTPUT = ROOT / "catalogue-source" / "thieving.json"

API = "https://runescape.wiki/api.php"

# The Wiki asks tools to identify themselves. Agreed with Duncan for this project.
USER_AGENT = "ProfitPath-development (Discord: Tatsuya)"

# Seconds between requests, so we stay a polite, low-volume client.
REQUEST_GAP = 1.0

# Rows per bucket page, names per batched (OR) lookup, titles per revision query.
PAGE_SIZE = 500
BATCH = 40
TITLES_PER_QUERY = 50

TARGET_CATEGORIES = ("Thievable entities", "Stalls")

# Coins are shown under many stack-picture IDs on the Wiki. 995 is the coins item
# ID the monster snapshot and the rest of Profit Path already use.
COINS_ID = 995

# The Wiki section anchor that just means "this NPC's pickpocket table". Any other
# anchor (a dig site, a clan district...) is a separate version of the target.
SHARED_ANCHOR = "Pickpocketing"


# ---- Talking to the Wiki ----------------------------------------------------

def get(params):
    """One api.php request. Returns the parsed JSON; raises on an API error."""
    url = API + "?" + urllib.parse.urlencode({**params, "format": "json"})
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})

    with urllib.request.urlopen(request, timeout=60) as response:
        data = json.loads(response.read().decode("utf-8"))

    time.sleep(REQUEST_GAP)

    if not isinstance(data, dict) or "error" in data:
        raise ValueError(f"Wiki request failed: {data.get('error') if isinstance(data, dict) else data}")

    return data


def bucket_text(value):
    """Quotes a value for the bucket query language.

    The bucket parser doesn't understand backslash escapes (a probe of
    "Baker\\'s stall" failed with "'}' expected"), so a name with an apostrophe is
    wrapped in double quotes instead. A name with both kinds can't be written safely.
    """
    value = str(value)

    if "'" in value and '"' in value:
        raise ValueError(f"Can't quote a name with both quote marks: {value}")

    if "'" in value:
        return '"' + value + '"'

    return "'" + value + "'"


def bucket_rows(select, where):
    """Runs one bucket query page by page until the Wiki runs out of rows."""
    rows, offset = [], 0

    while True:
        query = (f"bucket({select[0]}).select({','.join(select[1:])})"
                 f".where({where}).limit({PAGE_SIZE}).offset({offset}).run()")
        page = get({"action": "bucket", "query": query}).get("bucket")

        if not isinstance(page, list):
            raise ValueError("Wiki bucket query returned no rows list")

        rows += page

        if len(page) < PAGE_SIZE:
            return rows

        offset += PAGE_SIZE


def any_page(field, names):
    """A bucket OR clause matching any of `names` in `field`."""
    return "bucket.Or(" + ",".join("{" + bucket_text(field) + "," + bucket_text(name) + "}" for name in names) + ")"


def batches(values, size):
    values = sorted(values)

    for start in range(0, len(values), size):
        yield values[start:start + size]


def category_members(category):
    """Every page title in one Wiki category, following continuation."""
    titles, cont = [], {}

    while True:
        data = get({"action": "query", "list": "categorymembers", "cmtitle": "Category:" + category,
                    "cmlimit": "500", **cont})
        titles += [member["title"] for member in data["query"]["categorymembers"]]

        if "continue" not in data:
            return titles

        cont = data["continue"]


def page_revisions(pages):
    """{page title: current revision ID}. Every title must come back with one."""
    revisions = {}

    for group in batches(pages, TITLES_PER_QUERY):
        data = get({"action": "query", "prop": "revisions", "rvprop": "ids", "titles": "|".join(group)})

        # The API normalises titles (e.g. first letter capitalised); map back.
        renamed = {entry["to"]: entry["from"] for entry in data["query"].get("normalized", [])}

        for page in data["query"]["pages"].values():
            if page.get("revisions"):
                revisions[renamed.get(page["title"], page["title"])] = page["revisions"][0]["revid"]

    missing = sorted(set(pages) - set(revisions))

    if missing:
        raise ValueError(f"No revision for: {', '.join(missing[:5])}")

    return revisions


def retrieved_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---- GE item names ----------------------------------------------------------

def convert_items(rows):
    """Turns infobox_item rows (GE items only) into a sorted, unambiguous list.

    Each entry is {"id", "label", "name", "page"}. `label` is what the search shows:
    the item's name, or its Wiki page name when several GE items share one name
    (two "Monk's robe" items become "Monk's robe (top)" and "(bottom)"). If even the
    page name repeats, the item version is added in brackets.
    """
    entries = []

    for row in rows:
        ids = row.get("item_id") or []

        # A couple of GE pages have no item ID; we can't price those, so skip them.
        if not ids:
            continue

        name, page = row.get("item_name"), row.get("page_name")

        # The Bucket API can hand back HTML-escaped text ("Armadyl&#39;s").
        name = html.unescape(name) if isinstance(name, str) else name
        page = html.unescape(page) if isinstance(page, str) else page

        if not isinstance(name, str) or not name.strip() or not isinstance(page, str) or not page.strip():
            raise ValueError(f"GE item row without a name or page: {row}")

        version = row.get("version_anchor")
        version = version if isinstance(version, str) and version not in ("", "DEFAULT") else None

        for item_id in ids:
            if type(item_id) is not int or item_id <= 0:
                raise ValueError(f"Invalid item ID for {name}: {item_id}")

            entries.append({"id": item_id, "name": name, "page": page, "version": version})

    # One entry per item ID. A repeated ID with the same name is a harmless duplicate
    # row. A repeated ID with a different name means the Wiki is confused about it
    # (e.g. 60374 is both "Apex hide armour set" and "... + 1"), so we leave that ID
    # out entirely rather than guess which name is right. They're listed in the output.
    by_id, conflicts = {}, set()

    for entry in entries:
        previous = by_id.get(entry["id"])

        if previous and previous["name"] != entry["name"]:
            conflicts.add(entry["id"])

        by_id.setdefault(entry["id"], entry)

    unique = [entry for item_id, entry in by_id.items() if item_id not in conflicts]

    # Labels: name first, then page name, then page name plus version.
    names = collections.Counter(entry["name"] for entry in unique)
    pages = collections.Counter(entry["page"] for entry in unique)

    for entry in unique:
        if names[entry["name"]] == 1:
            entry["label"] = entry["name"]
        elif pages[entry["page"]] == 1 or not entry["version"]:
            entry["label"] = entry["page"]
        else:
            entry["label"] = f"{entry['page']} ({entry['version']})"

    # Anything still ambiguous (one page listing two IDs with no version, like
    # Blurberry Special) is left out and reported, not guessed at: a player picking
    # it couldn't know which ID they were getting.
    labels = collections.Counter(entry["label"] for entry in unique)

    for entry in unique:
        if labels[entry["label"]] > 1:
            conflicts.add(entry["id"])

    result = [{"id": entry["id"], "label": entry["label"], "name": entry["name"], "page": entry["page"]}
              for entry in unique if entry["id"] not in conflicts]

    return sorted(result, key=lambda entry: (entry["label"].casefold(), entry["id"])), sorted(conflicts)


def import_items():
    rows = bucket_rows(("'infobox_item'", "'page_name'", "'item_name'", "'item_id'", "'version_anchor'"),
                       "'exchange_page','!=',bucket.Null()")
    items, conflicts = convert_items(rows)

    document = {
        "schema": 1,
        "source": {
            "wiki": "https://runescape.wiki/",
            "license": "CC BY-NC-SA 3.0",
            "query": "infobox_item rows that have an exchange_page (a Grand Exchange page)",
            "retrieved": retrieved_now(),
            "revisions": "Not recorded per item page (one revision query per 50 pages would be ~150 extra requests).",
            "left_out_conflicting_ids": conflicts,
        },
        "items": items,
    }

    validate_items(document)
    ITEMS_OUTPUT.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")
    print(f"Imported {len(items)} GE items from {len(rows)} Wiki rows; "
          f"left out {len(conflicts)} IDs the Wiki gives two names: {conflicts}.")


def validate_items(document):
    """Checks ge-items.json is the shape catalogue.py packs."""
    if document.get("schema") != 1 or not document.get("items"):
        raise ValueError("Unsupported or empty GE item source")

    ids, labels = set(), set()

    for entry in document["items"]:
        if set(entry) != {"id", "label", "name", "page"}:
            raise ValueError(f"Unexpected GE item fields: {entry}")

        if type(entry["id"]) is not int or entry["id"] <= 0 or entry["id"] in ids:
            raise ValueError(f"Invalid or repeated GE item ID: {entry['id']}")

        for field in ("label", "name", "page"):
            if not isinstance(entry[field], str) or not entry[field].strip():
                raise ValueError(f"GE item {entry['id']} has no {field}")

        if entry["label"] in labels:
            raise ValueError(f"Repeated GE item label: {entry['label']}")

        ids.add(entry["id"])
        labels.add(entry["label"])


# ---- Thieving loot ----------------------------------------------------------

# [[Page|shown text]] -> shown text, [[Page]] -> Page. Notes are shown as plain text.
WIKI_LINK = re.compile(r"\[\[(?:[^|\]]*\|)?([^\]]*)\]\]")


def clean_note(text):
    """Wiki note text without link markup or bold/italic quotes, on one line."""
    text = WIKI_LINK.sub(r"\1", html.unescape(text))
    text = text.replace("'''", "").replace("''", "")

    return " ".join(text.split())


def split_source(dropped_from):
    """'Archaeologist#Kharid-et' -> ('Archaeologist', 'Kharid-et'). No anchor -> None."""
    page, _, anchor = dropped_from.partition("#")

    return page, anchor or None


def drop_row(row, details, ge_ids, other_ids):
    """One dropsline row in the monster snapshot's drop shape (see DROP_FIELDS)."""
    name = row["item_name"]
    rarity, rolls = details["Rarity"], details["Rolls"]
    low, high = details["Quantity Low"], details["Quantity High"]

    if not isinstance(rarity, str) or not rarity.strip():
        raise ValueError(f"Drop without a rarity: {name}")

    if type(rolls) is not int or rolls < 1:
        raise ValueError(f"Invalid roll count for {name}: {rolls}")

    if type(low) not in (int, float) or type(high) not in (int, float) or low < 0 or high < low:
        raise ValueError(f"Invalid quantity range for {name}: {low}-{high}")

    # The monster snapshot writes extra rolls into the rate ("2 × 8/260"), and
    # loot.lua reads it that way. Do the same so one parser serves both.
    rate = rarity if rolls == 1 else f"{rolls} × {rarity}"

    notes = [clean_note(note["content"]) for note in details.get("Rarity Notes") or []
             if isinstance(note, dict) and isinstance(note.get("content"), str)]
    notes += [clean_note(note) for note in details.get("Quantity Notes") or [] if isinstance(note, str)]

    # The Wiki marks some rates as approximate; say so rather than look exact.
    if details.get("Approx"):
        notes.append("The Wiki marks this rate as approximate.")

    # A second rate (often with luck, sometimes something else): keep it as a note.
    # The editor uses the main rate; it never picks the better one for you.
    alternative = details.get("Alt Rarity")

    if isinstance(alternative, str) and alternative.strip():
        notes.append(f"The Wiki also lists a rate of {alternative}.")

    drop = {"name": name, "quantity": details["Drop Quantity"], "rate": rate, "rolls": rolls}

    # Whole numbers stay ints so the packed data reads back exactly.
    drop["quantity_low"] = int(low) if float(low).is_integer() else low
    drop["quantity_high"] = int(high) if float(high).is_integer() else high

    if type(drop["quantity_low"]) is not int or type(drop["quantity_high"]) is not int:
        raise ValueError(f"Fractional quantity for {name}; the drop format stores whole numbers")

    if notes:
        drop["notes"] = "\n".join(notes)

    # Item IDs: GE items from the GE list, everything else from its own infobox.
    # GE items are the only ones GEPL can price; the rest are marked untradeable,
    # like the monster snapshot's "Not sold" rows.
    #
    # A GE page with several item versions (ge_ids maps it to None) gets no ID and
    # no "untradeable" mark either: it IS sold, we just can't tell which version
    # drops, so the player has to pick the item.
    if name == "Coins":
        drop["item_id"] = COINS_ID
    elif name in ge_ids:
        if ge_ids[name] is not None:
            drop["item_id"] = ge_ids[name]
        else:
            drop["notes"] = "\n".join(notes + ["This item has several versions on the GE; choose the one that drops."])
    else:
        if name in other_ids:
            drop["item_id"] = other_ids[name]

        drop["untradeable"] = True

    return drop


def thieving_level(rows):
    """The one Thieving level every row of a target agrees on, or None."""
    levels = set()

    for details in rows:
        level = details.get("Drop level")

        # Shape is [[level]]; anything else isn't a single, clear level.
        if (isinstance(level, list) and len(level) == 1 and isinstance(level[0], list)
                and len(level[0]) == 1 and type(level[0][0]) is int):
            levels.add(level[0][0])
        else:
            return None

    return levels.pop() if len(levels) == 1 else None


def convert_thieving(rows, ge_ids, other_ids):
    """Groups thieving drop rows into targets shaped like snapshot monsters.

    A Wiki page can list its loot in several places:
      - rows with no anchor, or the "Pickpocketing" anchor: the page's own table,
        shared by every version of the target;
      - rows with any other anchor (a dig site, a clan district): one version.
    A page with versions becomes one target per version (shared rows + its own
    rows, as separate sections). Otherwise the page is a single target.

    Returns (targets, report). Each target is {"title", "npc_ids", "sections",
    "level"}; a section is {"title", "drops", "notes", "note_ids"}.
    """
    pages = collections.defaultdict(lambda: collections.defaultdict(list))

    for row in rows:
        details = json.loads(row["drop_json"])

        if "thieving" not in (details.get("Drop type") or []):
            continue

        page, anchor = split_source(details["Dropped from"])
        pages[page][anchor].append((row, details))

    targets, report = [], {"unclear_level": [], "untradeable_rows": 0, "rows": 0}

    for page in sorted(pages):
        tables = pages[page]
        shared = [anchor for anchor in (None, SHARED_ANCHOR) if anchor in tables]
        versions = sorted(anchor for anchor in tables if anchor not in (None, SHARED_ANCHOR))

        for version in versions or [None]:
            title = f"{page} ({version})" if version else page
            sections, used = [], []

            # Shared tables first, then this version's own table.
            for anchor in shared + ([version] if version else []):
                drops = [drop_row(row, details, ge_ids, other_ids) for row, details in tables[anchor]]
                used += [details for _, details in tables[anchor]]

                # Section titles name where on the page the rows came from.
                label = {None: "Loot", SHARED_ANCHOR: "Pickpocketing"}.get(anchor, anchor)
                sections.append({"title": label, "drops": drops, "notes": [], "note_ids": {}})

            target = {"title": title, "npc_ids": [], "sections": sections, "page": page}
            level = thieving_level(used)

            if level is None:
                report["unclear_level"].append(title)
            else:
                target["level"] = level

            for section in sections:
                report["rows"] += len(section["drops"])
                report["untradeable_rows"] += sum(1 for drop in section["drops"] if drop.get("untradeable"))

            targets.append(target)

    return targets, report


def ge_lookup(items):
    """{drop name: GE item ID, or None when ambiguous}.

    A drop row names an item by its Wiki page ("Cake") or, for dose and version
    items, by the item's own name ("Super attack (1)", whose page is "Super
    attack"). So a name can match as a page, as an item name, or both. We use the
    one unique item it points to. A name that fits several GE items (a page with
    versions, say "Cake" if it's both a page with versions and an item), or whose
    page and item-name matches disagree, maps to None; see drop_row.
    """
    by_page, by_name = collections.defaultdict(set), collections.defaultdict(set)

    for entry in items:
        by_page[entry["page"]].add(entry["id"])
        by_name[entry["name"]].add(entry["id"])

    lookup = {}

    for name in set(by_page) | set(by_name):
        # Each match counts only if it names exactly one item.
        unique = {min(ids) for ids in (by_page.get(name), by_name.get(name)) if ids and len(ids) == 1}

        lookup[name] = unique.pop() if len(unique) == 1 else None

    return lookup


def resolve_other_ids(names):
    """Item IDs for non-GE drop names, from each item's own infobox.

    Only a page with exactly one item ID counts; anything with several versions
    stays unresolved rather than us guessing which one drops.
    """
    resolved = {}

    for group in batches(names, BATCH):
        rows = bucket_rows(("'infobox_item'", "'page_name'", "'item_id'"), any_page("page_name", group))
        found = collections.defaultdict(set)

        for row in rows:
            for item_id in row.get("item_id") or []:
                found[row["page_name"]].add(item_id)

        for name, ids in found.items():
            if len(ids) == 1:
                resolved[name] = ids.pop()

    return resolved


def import_thieving():
    # The GE list must be current first: it decides which drops are priceable.
    items = json.loads(ITEMS_OUTPUT.read_text(encoding="utf-8"))
    validate_items(items)

    ge_ids = ge_lookup(items["items"])

    candidates = set()

    for category in TARGET_CATEGORIES:
        candidates |= {title for title in category_members(category)
                       if not title.startswith(("User:", "Category:")) and title != category}

    rows = []

    for group in batches(candidates, BATCH):
        rows += bucket_rows(("'dropsline'", "'page_name'", "'item_name'", "'drop_json'"), any_page("page_name", group))

    # Non-GE item names that appear in thieving rows, for their own ID lookup.
    others = set()

    for row in rows:
        details = json.loads(row["drop_json"])

        if "thieving" in (details.get("Drop type") or []) and row["item_name"] not in ge_ids and row["item_name"] != "Coins":
            others.add(row["item_name"])

    other_ids = resolve_other_ids(others)
    targets, report = convert_thieving(rows, ge_ids, other_ids)
    revisions = page_revisions({target["page"] for target in targets})

    for target in targets:
        target["revision"] = revisions[target["page"]]

    document = {
        "schema": 1,
        "source": {
            "wiki": "https://runescape.wiki/",
            "license": "CC BY-NC-SA 3.0",
            "query": "dropsline rows with Drop type 'thieving' on pages in "
                     + " and ".join(f"Category:{name}" for name in TARGET_CATEGORIES),
            "retrieved": retrieved_now(),
            "left_out": "Category:Thievable quest entities (quest-only), thieving chests and safes (no category).",
        },
        "targets": targets,
    }

    validate_thieving(document)
    THIEVING_OUTPUT.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")

    print(f"Imported {len(targets)} thieving targets from {len(candidates)} candidate pages: "
          f"{report['rows']} drop rows, {report['untradeable_rows']} not on the GE, "
          f"{len(report['unclear_level'])} without one clear Thieving level.")


# Fields a thieving target may have, on top of the monster drop format.
TARGET_FIELDS = {"title", "npc_ids", "sections", "page", "level", "revision"}


def validate_thieving(document):
    """Checks thieving.json; the drop rows themselves go through catalogue.validate."""
    if document.get("schema") != 1 or not document.get("targets"):
        raise ValueError("Unsupported or empty thieving source")

    titles = set()

    for target in document["targets"]:
        if set(target) - TARGET_FIELDS or target["title"] in titles:
            raise ValueError(f"Invalid or repeated thieving target: {target.get('title')}")

        if "level" in target and (type(target["level"]) is not int or not 1 <= target["level"] <= 120):
            raise ValueError(f"Invalid Thieving level: {target['title']}")

        if "revision" in target and (type(target["revision"]) is not int or target["revision"] <= 0):
            raise ValueError(f"Invalid revision: {target['title']}")

        titles.add(target["title"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("items", "thieving"))
    args = parser.parse_args()

    if args.command == "items":
        import_items()
    else:
        import_thieving()


if __name__ == "__main__":
    main()
