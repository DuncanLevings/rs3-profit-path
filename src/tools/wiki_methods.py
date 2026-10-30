"""Import every RuneScape Wiki money making guide into a reviewable snapshot.

Writes catalogue-source/wiki/guides.jsonl (one guide per line) and
catalogue-source/wiki/meta.json (retrieval details and item IDs). Run by hand when
the catalogue needs refreshing; the plugin never talks to the Wiki.
"""
# Developer tool, never shipped with the plugin.
#
# This is step 2 of outputs/profit-path-catalogue-scoping.md. It only takes a
# snapshot: nothing here changes what the plugin shows. A later step merges this
# snapshot with our hand research (catalogue-source/methods.json and friends).
#
# Where the data comes from (all through api.php, one request per second):
#   money_making_guide bucket   every guide: income rows, kills per hour, recurring
#                               runs, and requirements as HTML with data-mmg-* tags
#   prop=revisions              each guide page's current revision number, so every
#                               line says exactly which page version it came from
#   infobox_item bucket         item names -> item IDs, which GEPL needs for prices
#
# Everything fetched is treated as untrusted data: it's parsed as JSON or HTML,
# checked for the shapes we expect, and nothing in it is ever run.
#
# What one line of guides.jsonl looks like (wrapped here to fit):
#
#   {"page": "Money making guide/Killing abyssal demons", "version": "Melee",
#    "revision": 37017140, "activity": "Killing abyssal demons", "category": "Combat/Mid",
#    "intensity": "Low", "members": true, "kph": 900, "wiki_profit": 1278642.22,
#    "inputs": [["Spring", 0.21875, "action", "ge", 4835], ...],
#    "outputs": [["Abyssal whip", 0.0009765625, "action", "ge", 69578], ...],
#    "requirements": {"required": ["skill:SLAYER:85", ["any", "item:Gem bag (upgraded)",
#                     "item:Artificer's measure"], ...], "recommended": [...]}}
#
# Income rows are [name, quantity, basis, pricing, Wiki value] and sometimes a sixth
# entry, the Wiki's own note on how it worked a calculated value out.
#   basis    action  per kill/action (multiply by kph)
#            hour    a fixed amount each hour
#            run     per run of a recurring guide (a daily or weekly task)
#   pricing  ge      a Grand Exchange price
#            value   a fixed value the Wiki sets (coins, clue scrolls, ...)
#            calc    worked out by the Wiki, e.g. an untradeable potion's creation cost
# The Wiki value is the unit price the Wiki showed when we took the snapshot. It's
# a reference for sanity checks, never a live price.
from __future__ import annotations

import argparse
import datetime
import html.parser
import json
import re
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "catalogue-source" / "wiki"
GUIDES = OUTPUT / "guides.jsonl"
META = OUTPUT / "meta.json"

# Research inputs and outputs for the outfit pass (see import_outfits below).
CAPABILITIES = ROOT / "catalogue-source" / "research" / "capabilities.json"
OUTFITS = ROOT / "catalogue-source" / "research" / "outfits.json"
ACHIEVEMENTS = ROOT / "catalogue-source" / "research" / "achievements.json"
EQUIPMENT = ROOT / "catalogue-source" / "research" / "equipment.json"

API = "https://runescape.wiki/api.php"

# The Wiki asks tools to identify themselves. Agreed with Duncan for this project.
USER_AGENT = "ProfitPath-development (Discord: Tatsuya)"

# Seconds between requests, so we stay a polite, low-volume client.
REQUEST_GAP = 1.0

# Rows per bucket page, names per batched (OR) lookup, and titles per revision query
# (50 is the API's limit for ordinary accounts).
PAGE_SIZE = 500
BATCH = 40
TITLES_PER_QUERY = 50

PRICING = {"gemw": "ge", "value": "value", "calcvalue": "calc"}
IMPORTANCE = {"": "required", "required": "required", "recommended": "recommended", "optional": "optional"}

# The four guide fields that hold requirements, as HTML/wikitext.
REQUIREMENT_FIELDS = ("skill", "item", "quest", "other")


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


def bucket(query):
    data = get({"action": "bucket", "query": query})

    if not isinstance(data.get("bucket"), list):
        raise ValueError("Wiki bucket query returned no rows list")

    return data["bucket"]


def lua_text(value):
    """Quotes a value for the bucket query language (a small Lua-like syntax)."""
    return "'" + str(value).replace("\\", "\\\\").replace("'", "\\'") + "'"


def any_of(field, values):
    clauses = ",".join("{" + lua_text(field) + "," + lua_text(value) + "}" for value in values)

    return f"bucket.Or({clauses})"


def batches(values, size):
    values = sorted(values)

    for start in range(0, len(values), size):
        yield values[start:start + size]


def fetch_guides():
    """Every money making guide row, page by page."""
    rows, offset = [], 0

    while True:
        page = bucket("bucket('money_making_guide')"
                      ".select('page_name','page_name_sub','value','json','obsolete','recurring')"
                      f".limit({PAGE_SIZE}).offset({offset}).run()")
        rows += page

        if len(page) < PAGE_SIZE:
            return rows

        offset += PAGE_SIZE


def fetch_revisions(pages):
    """{page title: current revision ID}. Every title must come back with one."""
    revisions = {}

    for group in batches(pages, TITLES_PER_QUERY):
        data = get({"action": "query", "prop": "revisions", "rvprop": "ids", "titles": "|".join(group)})

        for page in data.get("query", {}).get("pages", {}).values():
            if page.get("revisions"):
                revisions[page["title"]] = page["revisions"][0]["revid"]

    missing = sorted(set(pages) - set(revisions))

    if missing:
        raise ValueError(f"No revision for {len(missing)} guide pages, e.g. {missing[:3]}")

    return revisions


def lookup_items(forms):
    """One round of item lookups for a set of spellings.

    Returns ({spelling: item ID}, {spelling: [every dose's item ID]}, {item ID: the
    item's own name}). Two lookups,
    like the recipe importer: an exact item_name match first, then the item page.
    A page whose infobox describes one item gives that item. A page whose items are
    all doses of one thing ("Aggroverload (1)" ... "(6)") is a dose family: its ID
    is the biggest dose, and the family lists every dose so owning any of them
    counts. Any other page with several items is too ambiguous to guess from."""
    found, families, real_names = {}, {}, {}

    for field in ("item_name", "page_name"):
        for group in batches(forms - set(found), BATCH):
            rows = bucket("bucket('infobox_item').select('page_name','item_name','item_id')"
                          f".where({any_of(field, group)}).limit({PAGE_SIZE}).run()")
            per_page = {}

            for row in rows:
                ids = row.get("item_id") or []

                if not ids or not isinstance(ids[0], int) or ids[0] <= 0:
                    continue

                # The game checks an item's name before showing its icon, so keep
                # the Wiki's exact item name ("Aggroverload (6)", not "Aggroverload").
                if row.get("item_name"):
                    real_names.setdefault(ids[0], row["item_name"])

                if field == "item_name" and row.get("item_name") in group:
                    found.setdefault(row["item_name"], ids[0])

                per_page.setdefault(row.get("page_name"), {})[row.get("item_name") or ""] = ids[0]

            if field != "page_name":
                continue

            for page, items in per_page.items():
                if page not in group or page in found:
                    continue

                if len(set(items.values())) == 1:
                    found[page] = next(iter(items.values()))
                    continue

                doses = {}

                for name, item_id in items.items():
                    match = re.fullmatch(re.escape(page) + r" \((\d+)\)", name)

                    if not match:
                        doses = None
                        break

                    doses[int(match.group(1))] = item_id

                if doses:
                    found[page] = doses[max(doses)]
                    families[page] = [doses[dose] for dose in sorted(doses)]

    return found, families, real_names


def fetch_item_ids(names):
    """({item name: item ID}, {item name: dose family IDs}, {item ID: its own name})
    for every name the Wiki can resolve.

    Guides don't always use the Wiki's capitals. We try the name with a capital
    first letter ("coins" -> "Coins"), then in sentence case ("Adamant Pickaxe" ->
    "Adamant pickaxe"), and map each answer back to the guide's own spelling."""
    found, families, real_names = {}, {}, {}

    for spell in (lambda name: name[:1].upper() + name[1:],
                  lambda name: name[:1].upper() + name[1:].lower()):
        forms = {name: spell(name) for name in names if name not in found}
        ids, doses, names_by_id = lookup_items(set(forms.values()))
        real_names.update(names_by_id)

        for name, form in forms.items():
            if form in ids:
                found[name] = ids[form]

                if form in doses:
                    families[name] = doses[form]

    used = set(found.values()) | {item_id for ids in families.values() for item_id in ids}

    return found, families, {item_id: real_names[item_id] for item_id in used if item_id in real_names}


# ---- Turning wikitext and HTML into plain data -------------------------------

def plain(text):
    """Wikitext to readable text: drop file icons, keep link labels, tidy spaces."""
    text = re.sub(r"\[\[File:[^\]]*\]\]", "", text or "")
    text = re.sub(r"\[\[[^\]|]*\|([^\]]*)\]\]", r"\1", text)
    text = re.sub(r"\[\[([^\]]*)\]\]", r"\1", text)
    text = re.sub(r"'{2,}", "", text)
    text = re.sub(r"\{\{[^}]*\}\}", "", text)
    # Leftover image sizes like "20px" from icons inside other markup.
    text = re.sub(r"\b\d+(x\d+)?px\b", "", text)
    text = text.replace(" ", " ")

    return re.sub(r"\s+", " ", text).strip(" *")


class RequirementLine(html.parser.HTMLParser):
    """Reads one line of a requirement field.

    Each requirement is a <span class="mmg-req ..."> with data-mmg-* attributes;
    an "or" group is a span wrapping other spans. We keep the spans as a small
    tree, plus the line's text so we can tell when it says more than the spans
    (like "Spring cleaner 2000 or above")."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = {"attrs": {}, "children": []}
        self.stack = [self.root]
        self.text = []
        self.loose = []

    def handle_starttag(self, tag, attrs):
        if tag == "span":
            node = {"attrs": dict(attrs), "children": []}
            self.stack[-1]["children"].append(node)
            self.stack.append(node)

    def handle_endtag(self, tag):
        if tag == "span" and len(self.stack) > 1:
            self.stack.pop()

    def handle_data(self, data):
        self.text.append(data)

        # Text sitting outside every requirement span: wording the spans don't cover.
        if len(self.stack) == 1:
            self.loose.append(data)


def leaf(node):
    """One requirement span as a short string, or None if it isn't one we know."""
    attrs = node["attrs"]
    classes = (attrs.get("class") or "").split()

    if "mmg-skill" in classes:
        skill = re.sub(r"[^A-Z0-9]+", "_", (attrs.get("data-mmg-skill") or "").upper()).strip("_")
        level = attrs.get("data-mmg-level") or ""

        if skill and level.isdecimal():
            return f"skill:{skill}:{int(level)}"

    if "mmg-item" in classes and attrs.get("data-mmg-item"):
        number = attrs.get("data-mmg-num") or "1"
        name = attrs["data-mmg-item"].strip()

        return f"item:{name}" if number in ("", "1") else f"item:{name}:{number}"

    if "mmg-quest" in classes and attrs.get("data-mmg-quest"):
        return "quest:" + attrs["data-mmg-quest"].strip()

    return None


def requirement(node):
    """A span (leaf or "or" group) as (requirement, importance), or None."""
    classes = (node["attrs"].get("class") or "").split()

    if "mmg-req-or" in classes:
        children = [requirement(child) for child in node["children"]]
        children = [child for child in children if child]

        if not children:
            return None

        # The group's own importance wins; otherwise its first member's.
        importance = node["attrs"].get("data-mmg-imp")
        importance = IMPORTANCE.get(importance) if importance is not None else children[0][1]

        return ["any"] + [child[0] for child in children], importance or "required"

    value = leaf(node)

    if value is None:
        return None

    return value, IMPORTANCE.get(node["attrs"].get("data-mmg-imp") or "", "required")


# Words that only join or label requirements; anything else on the line is wording
# the spans don't capture, so we keep the line's text next to the requirement.
FILLER = re.compile(r"\b(or|and|recommended|optional|required)\b|[\s,;:()*.+/&-]+", re.IGNORECASE)

# Free-text lines that just mean "nothing here".
EMPTY_WORDS = {"none", "n/a", "na", "nothing", "-", "no requirements"}


def parse_requirements(fields):
    """All four requirement fields as {"required": [...], "recommended": [...], ...}."""
    groups = {"required": [], "recommended": [], "optional": []}

    for field in fields:
        for line in (field or "").splitlines():
            parser = RequirementLine()
            parser.feed(line)
            parser.close()

            text = plain("".join(parser.text))
            found = [requirement(node) for node in parser.root["children"]]
            found = [entry for entry in found if entry]
            extra = FILLER.sub("", plain("".join(parser.loose)))

            if not found:
                # Plain words with no structured requirement at all. Skip "None",
                # "N/A" and headings like "Recommended:" (the spans under them
                # carry their own importance).
                if text and text.lower().strip(".") not in EMPTY_WORDS and not text.endswith(":"):
                    lowered = text.lower()
                    importance = "optional" if "optional" in lowered else (
                        "recommended" if "recommended" in lowered else "required")
                    groups[importance].append({"text": text})

                continue

            for value, importance in found:
                groups[importance].append({"req": value, "text": text} if extra else value)

    return {key: value for key, value in groups.items() if value}


def number(value, field):
    if type(value) not in (int, float) or value != value or value in (float("inf"), float("-inf")):
        raise ValueError(f"{field} is not a finite number: {value!r}")

    return value


def income_rows(rows, basis_for, guide):
    result = []

    for row in rows:
        name = (row.get("name") or "").strip()
        pricing = PRICING.get(row.get("pricetype"))

        if not name or not pricing:
            raise ValueError(f"{guide}: income row has no name or an unknown price type: {row}")

        entry = [name, number(row.get("qty"), f"{guide} {name} quantity"), basis_for(row), pricing,
                 number(row.get("value"), f"{guide} {name} value")]

        # The Wiki's note on how it calculated a value, e.g. "potioncost|Aggroverload".
        # The separator between its parts is an odd control character; use "|".
        if pricing == "calc" and row.get("raw_value"):
            entry.append(re.sub(r"[^\x20-\x7e]+", "|", row["raw_value"]).strip("{} "))

        result.append(entry)

    return result


def parse_guide(row, revisions):
    """One bucket row as one guides.jsonl record."""
    page = row["page_name"]
    data = json.loads(row["json"])

    if not isinstance(data, dict):
        raise ValueError(f"{page}: guide JSON isn't a record")

    recurring = "recurring" in row
    per_kill = bool(data.get("isperkill"))

    def basis_for(income):
        # Recurring guides list amounts for one run; per-kill guides mark which rows
        # are per kill (isph false) and which are a fixed amount each hour.
        if recurring:
            return "run"

        return "hour" if income.get("isph", True) else "action"

    guide = {"page": page}

    if data.get("version"):
        guide["version"] = plain(data["version"])

    guide["revision"] = revisions[page]
    guide["activity"] = plain(data.get("activity"))

    for field in ("category", "intensity"):
        if data.get(field):
            guide[field] = data[field]

    guide["members"] = data.get("members") is True

    if per_kill and not recurring:
        guide["kph"] = number(data.get("prices", {}).get("default_kph"), f"{page} kills per hour")

    if recurring:
        guide["recurring"] = {"every": plain(data.get("recurrence")),
                              "minutes": number(data.get("time"), f"{page} minutes per run")}

    # The Wiki's own profit figure when the snapshot was taken (per hour, or per
    # run for recurring guides). Kept to check our sums against later.
    guide["wiki_profit"] = round(float(row.get("value") or 0), 2)

    guide["inputs"] = income_rows(data.get("inputs") or [], basis_for, page)
    guide["outputs"] = income_rows(data.get("outputs") or [], basis_for, page)

    requirements = parse_requirements(data.get(field) for field in REQUIREMENT_FIELDS)

    if requirements:
        guide["requirements"] = requirements

    return guide


def validate_guide(guide):
    """Shape checks before anything is written. Raises ValueError."""
    if not isinstance(guide.get("page"), str) or not guide["page"].startswith("Money making guide/"):
        raise ValueError(f"Not a money making guide page: {guide.get('page')}")

    if not isinstance(guide.get("revision"), int) or guide["revision"] <= 0:
        raise ValueError(f"{guide['page']} has no revision")

    if not guide.get("activity"):
        raise ValueError(f"{guide['page']} has no activity")

    if "kph" in guide and "recurring" in guide:
        raise ValueError(f"{guide['page']} can't be both per kill and recurring")

    for direction in ("inputs", "outputs"):
        for row in guide[direction]:
            if row[1] < 0 or row[2] not in ("action", "hour", "run") or row[3] not in PRICING.values():
                raise ValueError(f"{guide['page']}: bad {direction} row {row}")

            if row[2] == "action" and "kph" not in guide:
                raise ValueError(f"{guide['page']}: a per-action row needs kills per hour")


def guide_key(guide):
    return guide["page"], guide.get("version") or ""


def requirement_items(requirement):
    """Item names inside one parsed requirement (a string, an "any" list, or a
    {"req": ..., "text": ...} record)."""
    if isinstance(requirement, dict):
        return requirement_items(requirement.get("req"))

    if isinstance(requirement, list):
        return {name for child in requirement[1:] for name in requirement_items(child)}

    if isinstance(requirement, str) and requirement.startswith("item:"):
        name = requirement[len("item:"):]
        head, _, number = name.rpartition(":")

        # "item:Coins:500" is 500 coins; the name is everything before the count.
        return {head if head and number.isdecimal() else name}

    return set()


def requirement_quests(requirement):
    """Quest names inside one parsed requirement."""
    if isinstance(requirement, dict):
        return requirement_quests(requirement.get("req"))

    if isinstance(requirement, list):
        return {name for child in requirement[1:] for name in requirement_quests(child)}

    if isinstance(requirement, str) and requirement.startswith("quest:"):
        return {requirement[len("quest:"):]}

    return set()


def requirement_names(guides):
    """Every item name any guide lists as a requirement."""
    return {name for guide in guides for group in guide.get("requirements", {}).values()
            for requirement in group for name in requirement_items(requirement)}


def is_obsolete(row):
    """The bucket only includes an "obsolete" field on guides the Wiki has put in
    Category:Obsolete money making guides (checked by hand, 29 October 2026)."""
    return "obsolete" in row


def build(rows, revisions, item_ids, retrieved, families=None, item_names=None):
    """Parses and checks everything, returning (guides.jsonl text, meta record).

    `families` maps a dose-less potion name to every dose's item ID (see lookup_items).

    Obsolete guides are left out entirely: they describe methods that no longer
    work, so they'd only be noise in Browse. meta.json still counts them."""
    obsolete = [row for row in rows if is_obsolete(row)]
    guides = [parse_guide(row, revisions) for row in rows if not is_obsolete(row)]

    # A page can have two guides with the same (or no) version label; Cutting acadia
    # logs did in October 2026. Number them in the Wiki's order so each one still
    # has its own label, and list the page in meta.json so someone can check it.
    by_key = {}

    for guide in guides:
        by_key.setdefault(guide_key(guide), []).append(guide)

    unlabelled = []

    for (page, version), group in by_key.items():
        if len(group) > 1:
            unlabelled.append(page)

            for index, guide in enumerate(group, 1):
                guide["version"] = f"{version} {index}".strip() if version else f"Variant {index}"

    guides.sort(key=guide_key)
    keys = [guide_key(guide) for guide in guides]

    if len(set(keys)) != len(keys):
        raise ValueError("Two guide rows still share a page and version after numbering")

    for guide in guides:
        validate_guide(guide)

    names = sorted({row[0] for guide in guides for row in guide["inputs"] + guide["outputs"]})
    unresolved = [name for name in names if name not in item_ids]

    # Requirement "items" are often not items at all (outfits, perks, abilities),
    # so not resolving one is normal; the merge treats those as capabilities.
    required = sorted(requirement_names(guides))

    meta = {
        "schema": 1,
        "retrieved": retrieved,
        "source": "RuneScape Wiki money_making_guide and infobox_item buckets, and page revisions (api.php).",
        "licence": "RuneScape Wiki contributors, CC BY-NC-SA 3.0.",
        "counts": {
            "guides": len(guides),
            "pages": len({guide["page"] for guide in guides}),
            "obsolete_skipped": len(obsolete),
            "recurring": sum(1 for guide in guides if "recurring" in guide),
            "per_kill": sum(1 for guide in guides if "kph" in guide),
            "income_names": len(names),
            "unresolved_names": len(unresolved),
            "requirement_item_names": len(required),
            "unresolved_requirement_items": sum(1 for name in required if name not in item_ids),
        },
        "items": {name: item_ids[name] for name in sorted(set(names) | set(required)) if name in item_ids},
        "unresolved": unresolved,
        "unresolved_requirement_items": [name for name in required if name not in item_ids],
        "item_families": {name: ids for name, ids in sorted((families or {}).items())
                          if name in names or name in required},
        # Each item's own name, for the plugin's in-game name check.
        "item_names": {str(item_id): name for item_id, name in sorted((item_names or {}).items())},
        "unlabelled_versions": sorted(unlabelled),
    }

    text = "".join(json.dumps(guide, ensure_ascii=False, separators=(",", ":")) + "\n" for guide in guides)

    return text, meta


# ---- Outfits: which items make up each one -----------------------------------
#
# Requirements like "Master camouflage outfit" name a whole set. The Wiki has no
# bucket for sets, but every set page starts with an {{Infobox Set}} template that
# names one piece per equipment slot:
#
#   {{Infobox Set
#   |name = Master camouflage outfit
#   |head = Master camouflage head
#   |body = Master camouflage body
#   ...
#
# import_outfits reads that template for every outfit in research/capabilities.json,
# resolves each piece to an item ID like any other item, and writes
# research/outfits.json. The merge then turns an outfit requirement into "all of
# these pieces", which the plugin can check against the bank like other items.

SET_SLOTS = ("head", "neck", "cape", "back", "body", "legs", "hands", "feet", "ring", "weapon", "2h",
             "shield", "offhand", "ammo", "pocket", "aura")


def set_pieces(wikitext):
    """[(slot, piece name)] from a page's {{Infobox Set}}, or [] if it has none.

    Sets with several versions number their fields (head1, head2...); we keep the
    unnumbered or first version, so each slot has one piece."""
    match = re.search(r"\{\{\s*Infobox Set(.*?)\n\}\}", wikitext or "", re.DOTALL | re.IGNORECASE)

    if not match:
        return []

    pieces = {}

    for line in match.group(1).splitlines():
        field = re.match(r"\s*\|\s*([a-z0-9]+?)(1?)\s*=\s*(.*?)\s*$", line)

        if not field or field.group(1) not in SET_SLOTS:
            continue

        name = plain(field.group(3))

        if name and field.group(1) not in pieces:
            pieces[field.group(1)] = name

    return [(slot, pieces[slot]) for slot in SET_SLOTS if slot in pieces]


def import_outfits():
    """Writes research/outfits.json for every outfit research names. Returns
    (outfits found, names with no set template)."""
    capabilities = json.loads(CAPABILITIES.read_text(encoding="utf-8"))["capabilities"]
    names = sorted(name for name, entry in capabilities.items() if entry.get("kind") == "outfit")
    outfits, missing = {}, []

    for name in names:
        data = get({"action": "parse", "page": name, "prop": "wikitext|revid", "redirects": 1})
        parsed = data.get("parse", {})
        pieces = set_pieces(parsed.get("wikitext", {}).get("*"))

        if not pieces:
            missing.append(name)
            continue

        outfits[name] = {"page": parsed["title"], "revision": parsed["revid"], "pieces": pieces}

    # A piece with charges is named with its count ("Ghost hunter goggles (20)").
    # If that exact name isn't an item, the uncharged name finds every charge level.
    names = {piece for outfit in outfits.values() for _, piece in outfit["pieces"]}
    uncharged = {re.sub(r"\s*\(\d+\)$", "", piece) for piece in names}
    ids, families, real_names = fetch_item_ids(names | uncharged)

    for outfit in outfits.values():
        resolved = []

        for slot, piece in outfit["pieces"]:
            lookup = piece if piece in ids else re.sub(r"\s*\(\d+\)$", "", piece)
            item_id = ids.get(lookup)
            entry = [slot, real_names.get(item_id, piece), item_id]

            # Owning any charge level (or dose) of the piece counts.
            if lookup in families:
                entry.append(families[lookup])

            resolved.append(entry)

        outfit["pieces"] = resolved

    document = {
        "schema": 1,
        "retrieved": datetime.date.today().isoformat(),
        "source": "{{Infobox Set}} on each outfit's RuneScape Wiki page (action=parse), pieces resolved through "
                  "the infobox_item bucket. RuneScape Wiki contributors, CC BY-NC-SA 3.0.",
        "note": "Each piece is [slot, item name, item ID or null], plus every charge level's ID when the piece "
                "has several. Outfits whose page has no set template are listed in missing.",
        "outfits": outfits,
        "missing": missing,
    }
    OUTFITS.write_text(json.dumps(document, indent=1, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")

    return outfits, missing


# ---- Achievements: in-game IDs for achievement requirements ----------------------
#
# Requirements name single achievements ("It Should Have Been Called Aetherium") or
# whole achievement diary tiers ("Hard Ardougne achievements"). The Wiki's
# `achievement` bucket gives every achievement's in-game ID, and diary tiers are
# its Area Tasks subcategories ("Hard Ardougne"). The plugin then reads completion
# in game: an achievement is complete when config.Achievement.FromID(id).progress
# is COMPLETE (-2), and a tier when every achievement in it is.

def fetch_achievements():
    """Every achievement row: name, in-game ID and categories."""
    rows, offset = [], 0

    while True:
        page = bucket("bucket('achievement').select('name','id','maincategory','subcategory')"
                      f".limit({PAGE_SIZE}).offset({offset}).run()")
        rows += page

        if len(page) < PAGE_SIZE:
            return rows

        offset += PAGE_SIZE


def import_achievements():
    """Writes research/achievements.json for every achievement research names.
    Returns (mapped names, names that matched nothing)."""
    capabilities = json.loads(CAPABILITIES.read_text(encoding="utf-8"))["capabilities"]
    names = sorted(name for name, entry in capabilities.items() if entry.get("kind") == "achievement")
    rows = [row for row in fetch_achievements() if isinstance(row.get("id"), int) and row["id"] >= 0]

    by_name = {}
    tiers = {}

    for row in rows:
        by_name.setdefault((row.get("name") or "").lower(), set()).add(row["id"])

        if row.get("maincategory") == "Area Tasks" and row.get("subcategory"):
            tiers.setdefault(row["subcategory"].lower(), set()).add(row["id"])

    mapped, missing = {}, []

    for name in names:
        tier = re.fullmatch(r"(.+) achievements", name, re.IGNORECASE)
        ids = by_name.get(name.lower())

        if tier and tier.group(1).lower() in tiers:
            mapped[name] = {"tier": tier.group(1), "ids": sorted(tiers[tier.group(1).lower()])}
        elif ids and len(ids) == 1:
            mapped[name] = {"ids": sorted(ids)}
        else:
            missing.append(name)

    document = {
        "schema": 1,
        "retrieved": datetime.date.today().isoformat(),
        "source": "RuneScape Wiki achievement bucket (in-game achievement IDs; Area Tasks subcategories for diary "
                  "tiers). RuneScape Wiki contributors, CC BY-NC-SA 3.0.",
        "note": "A requirement is met when every listed achievement is complete in game (progress COMPLETE).",
        "achievements": mapped,
        "missing": missing,
    }
    ACHIEVEMENTS.write_text(json.dumps(document, indent=1, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")

    return mapped, missing


# ---- Equipment tiers: for "Tier 90+ magic weapon" style requirements -------------
#
# The Wiki's `infobox_bonuses` bucket gives every equipment version's tier, slot,
# combat class and type (power / tank armour). `infobox_item` on the same page
# version gives its item IDs (degraded and charged versions have their own). The
# plugin then counts any owned item of a high enough tier, style and slot.

# Lowest tier any guide asks for ("High level equipment (61+)").
EQUIPMENT_MIN_TIER = 60


def fetch_equipment():
    """Every non-cosmetic equipment version of EQUIPMENT_MIN_TIER or above."""
    rows, offset = [], 0

    while True:
        page = bucket("bucket('infobox_bonuses').select('page_name','page_name_sub','equipment_tier','equipment_slot',"
                      "'combat_class','equipment_type','is_cosmetic_recolour')"
                      f".where({{'equipment_tier','>=',{EQUIPMENT_MIN_TIER}}})"
                      f".limit({PAGE_SIZE}).offset({offset}).run()")
        rows += page

        if len(page) < PAGE_SIZE:
            return [row for row in rows if not row.get("is_cosmetic_recolour")]

        offset += PAGE_SIZE


def import_equipment():
    """Writes research/equipment.json. Returns (pieces written, pages with no item ID)."""
    rows = fetch_equipment()
    pages = sorted({row["page_name"] for row in rows})
    item_rows = {}

    # Every item on each page: the "new" version has the bonuses, but "used",
    # "charged" and similar versions are the same equipment with their own IDs.
    for batch in batches(pages, 50):
        for item in bucket(f"bucket('infobox_item').select('page_name','page_name_sub','item_name','item_id')"
                           f".where({any_of('page_name', batch)}).limit({PAGE_SIZE}).run()"):
            item_rows.setdefault(item["page_name"], []).append(item)

    by_page = {}

    for row in rows:
        by_page.setdefault(row["page_name"], []).append(row)

    pieces, missing = [], []

    for page, bonuses in by_page.items():
        items = [item for item in item_rows.get(page, []) if "(broken)" not in (item.get("item_name") or "")]

        if not items:
            missing.append(page)
            continue

        # An item version with its own bonuses row takes that row. Any other
        # version on the page takes the page's lowest-tier row, so a tier is never
        # overstated.
        own = {row["page_name_sub"]: row for row in bonuses}
        lowest = min(bonuses, key=lambda row: row["equipment_tier"])

        for item in items:
            row = own.get(item["page_name_sub"], lowest)
            ids = sorted({item_id for item_id in (item.get("item_id") or []) if item_id > 0})

            if not ids:
                continue

            piece = {"name": item.get("item_name") or page, "item_ids": ids, "tier": row["equipment_tier"],
                     "slot": row.get("equipment_slot") or "", "style": row.get("combat_class") or ""}

            if row.get("equipment_type"):
                piece["type"] = row["equipment_type"]

            pieces.append(piece)

    pieces.sort(key=lambda piece: (piece["tier"], piece["name"]))
    document = {
        "schema": 1,
        "retrieved": datetime.date.today().isoformat(),
        "source": "RuneScape Wiki infobox_bonuses (tier, slot, class, type) and infobox_item (item IDs) buckets. "
                  "RuneScape Wiki contributors, CC BY-NC-SA 3.0.",
        "note": f"Every non-cosmetic equipment version of tier {EQUIPMENT_MIN_TIER}+, for tiered gear requirements.",
        "pieces": pieces,
        "missing": sorted(set(missing)),
    }
    EQUIPMENT.write_text(json.dumps(document, indent=1, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")

    return pieces, missing


def verify_snapshot():
    """Checks the files on disk: every line a valid guide, sorted, no duplicates,
    and meta.json's counts and item table agreeing with them. Run by test.py, so a
    hand edit or a half-written import can't slip through. Returns the guide count."""
    if not GUIDES.exists():
        return 0

    meta = json.loads(META.read_text(encoding="utf-8"))
    guides = [json.loads(line) for line in GUIDES.read_text(encoding="utf-8").splitlines()]

    for guide in guides:
        validate_guide(guide)

    keys = [guide_key(guide) for guide in guides]

    if keys != sorted(set(keys)):
        raise ValueError("guides.jsonl must be sorted by page and version, with no duplicates")

    if meta.get("schema") != 1 or meta["counts"]["guides"] != len(guides):
        raise ValueError("meta.json doesn't match guides.jsonl; re-run wiki_methods.py")

    names = {row[0] for guide in guides for row in guide["inputs"] + guide["outputs"]}
    names |= requirement_names(guides)
    listed = set(meta["items"]) | set(meta["unresolved"]) | set(meta["unresolved_requirement_items"])

    if names != listed:
        raise ValueError("meta.json's item names don't match guides.jsonl's income rows and requirements")

    return len(guides)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bucket-file", type=Path,
                        help="reuse a saved money_making_guide download ({'retrieved', 'rows'}) instead of fetching it")
    parser.add_argument("--equipment", action="store_true",
                        help="instead of the guides, import every tier 60+ equipment piece for tiered gear requirements")
    parser.add_argument("--achievements", action="store_true",
                        help="instead of the guides, import the in-game IDs of every achievement requirement")
    parser.add_argument("--outfits", action="store_true",
                        help="instead of the guides, import the pieces of every outfit in research/capabilities.json")
    args = parser.parse_args()

    if args.equipment:
        pieces, missing = import_equipment()
        print(f"Wrote {len(pieces)} equipment pieces to {EQUIPMENT.relative_to(ROOT)}; "
              f"{len(set(missing))} versions have no item ID.")
        return

    if args.achievements:
        mapped, missing = import_achievements()
        print(f"Wrote {len(mapped)} achievement requirements to {ACHIEVEMENTS.relative_to(ROOT)}. "
              f"No match: {', '.join(missing) or 'none'}.")
        return

    if args.outfits:
        outfits, missing = import_outfits()
        pieces = [piece for outfit in outfits.values() for piece in outfit["pieces"]]
        print(f"Wrote {len(outfits)} outfits ({len(pieces)} pieces, {sum(1 for p in pieces if p[2])} with item IDs) "
              f"to {OUTFITS.relative_to(ROOT)}. No set template: {', '.join(missing) or 'none'}.")
        return

    if args.bucket_file:
        saved = json.loads(args.bucket_file.read_text(encoding="utf-8"))
        rows, retrieved = saved["rows"], saved["retrieved"]
    else:
        rows, retrieved = fetch_guides(), datetime.date.today().isoformat()

    print(f"{len(rows)} guide rows; fetching page revisions and item IDs...")

    # Only current guides need revisions and item IDs. Parse them once (before IDs
    # are known) just to collect every income and requirement item name.
    current = [row for row in rows if not is_obsolete(row)]
    revisions = fetch_revisions({row["page_name"] for row in current})
    parsed = [parse_guide(row, revisions) for row in current]
    names = {income[0] for guide in parsed for income in guide["inputs"] + guide["outputs"]}
    item_ids, families, item_names = fetch_item_ids((names | requirement_names(parsed)) - {""})

    # Build and check everything before writing anything.
    text, meta = build(rows, revisions, item_ids, retrieved, families, item_names)

    OUTPUT.mkdir(parents=True, exist_ok=True)
    GUIDES.write_text(text, encoding="utf-8", newline="\n")
    META.write_text(json.dumps(meta, indent=1, ensure_ascii=False, sort_keys=False) + "\n", encoding="utf-8", newline="\n")

    counts = meta["counts"]
    print(f"Wrote {counts['guides']} guides ({counts['pages']} pages; {counts['obsolete_skipped']} obsolete skipped, "
          f"{counts['recurring']} recurring, {counts['per_kill']} per kill) to {GUIDES.relative_to(ROOT)}: "
          f"{len(text.encode('utf-8')):,} bytes. {counts['income_names'] - counts['unresolved_names']} of "
          f"{counts['income_names']} income names and {counts['requirement_item_names'] - counts['unresolved_requirement_items']} "
          f"of {counts['requirement_item_names']} requirement item names resolved to item IDs.")


if __name__ == "__main__":
    main()
