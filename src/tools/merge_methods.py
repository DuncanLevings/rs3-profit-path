"""Merge the Wiki guide snapshot with our hand research into full method records,
and report what still needs research."""
# Developer tool, never shipped with the plugin. Step 3 of
# outputs/profit-path-catalogue-scoping.md.
#
# Inputs:
#   catalogue-source/wiki/guides.jsonl + meta.json   every current Wiki guide
#                                                    (src/tools/wiki_methods.py)
#   catalogue-source/methods.json                    our curated methods (step 1)
#   catalogue-source/research/capabilities.json      what non-item requirements are,
#                                                    and the sprite for each
#   catalogue-source/recipes.json                    creation costs for untradeables
#
# Output: one catalogue in the same full-record shape the plugin already uses, so
# `catalogue.validate_methods` checks every imported method exactly like a curated
# one. Nothing here writes plugin data yet: step 4 switches data/methods.lua over.
#
# The rules, in order:
#   1. A curated method replaces the Wiki guide it was made from (same page, same
#      version label). Our research always wins over the raw import.
#   2. Recurring guides (daily/weekly runs) count per run, not per hour: their rate
#      is a "% of guide yield", and they keep how often they can be done.
#   3. Every other guide becomes a method:
#        - per-kill guides keep their kills per hour as the rate
#        - per-hour guides get a "% of guide pace" rate: 100 is the guide's own pace,
#          and every amount scales with it
#        - GE rows need an item ID; a row without one leaves the income "partial"
#        - the Wiki's fixed values (coins, clues) stay fixed values
#        - the Wiki's calculated values use our creation-cost recipe when we have
#          one, otherwise the Wiki's figure as a fixed value with a note
#        - requirements become skill/item checks where the plugin can check them,
#          and quest checks for quests mapped to their client config (research/
#          quests.json). Wiki advice pages ("Armoury", "Recommended equipment") become
#          "see also" notes, not checks. Everything else is a "capability" check,
#          shown as unknown: outfits, abilities, perks... A capability records its
#          kind and gets its sprite when the research file has them; unmapped quests
#          get the quest icon. An outfit whose pieces we know (research/outfits.json)
#          becomes "all of these pieces", checked like any other items.
from __future__ import annotations

import collections
import json
import re

import catalogue
import wiki_methods

PREFIX = "Money making guide/"

SUFFIX = {"required": "", "recommended": " (recommended)", "optional": " (optional)"}

# Wiki skill names that the client knows by another SkillType name.
CLIENT_SKILL_NAMES = {"CONSTITUTION": "HITPOINTS"}

# How a skill reads in requirement text, where the client's name isn't the one players use.
SKILL_LABELS = {"HITPOINTS": "Constitution"}


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")


def method_id(guide):
    return slug(guide["page"][len(PREFIX):]) + "." + (slug(guide.get("version")) or "standard")


def activity_category(source_category):
    """Our three activity groups (they colour titles and drive the filter)."""
    source_category = (source_category or "").lower()

    if source_category.startswith("combat"):
        return "pvm"

    return "production" if source_category == "processing" else "skilling"


def tidy_name(name):
    """A Wiki link target as readable text: "Armour/Magic armour#High level (61+)"
    becomes "Magic armour: High level (61+)", and "Recommended equipment for
    PvM/Magic" becomes "Recommended equipment for PvM: Magic"."""
    base, _, anchor = name.replace("_", " ").partition("#")

    if anchor:
        return f"{base.rsplit('/', 1)[-1]}: {anchor}"

    return base.replace("/", ": ")


def load_achievements():
    """{requirement name: [in-game achievement IDs]} from research/achievements.json."""
    if not wiki_methods.ACHIEVEMENTS.exists():
        return {}

    source = json.loads(wiki_methods.ACHIEVEMENTS.read_text(encoding="utf-8"))

    return {name: entry["ids"] for name, entry in source.get("achievements", {}).items()}


def load_outfits():
    """{outfit name: [[slot, piece name, item ID, (every charge level's ID)], ...]}
    for outfits whose pieces all resolved, from research/outfits.json."""
    if not wiki_methods.OUTFITS.exists():
        return {}

    source = json.loads(wiki_methods.OUTFITS.read_text(encoding="utf-8"))

    if source.get("schema") != 1 or not isinstance(source.get("outfits"), dict):
        raise ValueError("Unsupported outfits research file")

    outfits = {}

    for name, outfit in source["outfits"].items():
        pieces = outfit.get("pieces") or []

        # Half an outfit isn't the outfit: only use ones where every piece is known.
        if pieces and all(catalogue.positive_integer(piece[2]) for piece in pieces):
            outfits[name] = pieces

    return outfits


def load_snapshot():
    """(guides, meta) from catalogue-source/wiki, or ([], None) before any import."""
    if not wiki_methods.GUIDES.exists():
        return [], None

    guides = [json.loads(line) for line in wiki_methods.GUIDES.read_text(encoding="utf-8").splitlines()]

    return guides, json.loads(wiki_methods.META.read_text(encoding="utf-8"))


class Context:
    """Shared lookups while converting guides, plus the items table they fill in."""

    def __init__(self, items, meta, capabilities, recipes, quests=None, outfits=None, achievements=None):
        self.items = items
        self.meta = meta
        self.capabilities = capabilities
        self.recipes = recipes or {}
        self.quests = quests or {}
        self.outfits = outfits or {}
        self.achievements = achievements or {}

        # Wiki advice links found while converting the current method.
        self.advice = []

    def item_id(self, name):
        """The item ID for a Wiki name, adding it to the items table on first use.
        Curated item definitions are never replaced."""
        item_id = self.meta["items"].get(name)

        if item_id is None:
            return None

        if str(item_id) not in self.items:
            # The item's own name, not the guide's spelling: the plugin checks it
            # against the game before trusting the ID ("Aggroverload (6)", "Coins").
            real_name = self.meta.get("item_names", {}).get(str(item_id), name)
            definition = {"name": real_name, "source": f"RuneScape Wiki infobox_item, retrieved {self.meta['retrieved']}"}

            # A dose-less potion name stands for every dose: owning any one counts.
            if name in self.meta.get("item_families", {}):
                definition["ownership_ids"] = self.meta["item_families"][name]

            self.items[str(item_id)] = definition

        return item_id

    def define_item(self, item_id, name, ownership_ids=None):
        """Adds an item we found outside the guide snapshot (an outfit piece)."""
        if str(item_id) not in self.items:
            definition = {"name": name, "source": "RuneScape Wiki outfit page and infobox_item"}

            if ownership_ids:
                definition["ownership_ids"] = ownership_ids

            self.items[str(item_id)] = definition

    def recipe_for(self, name, note):
        """(recipe page, dose) for an untradeable row we can cost ourselves, or None."""
        dose = re.search(r"\((\d+)\)$", name)
        candidates = [note.split("|")[-1]] if note else []
        candidates.append(re.sub(r"\s*\(\d+\)$", "", name))

        for page in candidates:
            recipe = self.recipes.get(page)

            if recipe is None:
                continue

            # The row and the recipe must agree on doses, or the cost would be wrong.
            if "portion" in recipe["output"]:
                return (page, int(dose.group(1))) if dose else None

            return None if dose else (page, None)

        return None


def capability(name, ctx, quest=False):
    """A requirement the plugin can't check yet, or None for a Wiki advice page
    (those are collected into ctx.advice instead)."""
    research = ctx.capabilities.get(name, {})

    # A quest we've mapped to its client config can be checked for real.
    if name in ctx.quests:
        return {"kind": "quest", "quest": ctx.quests[name], "text": tidy_name(name), "display_icon": "quest"}

    if research.get("kind") == "guidance":
        ctx.advice.append(tidy_name(name))
        return None

    # A relic (or other unlock) with a flag verified in game is checked directly.
    if research.get("flag"):
        check = {"kind": "flag", "var": research["flag"], "text": tidy_name(name)}

        if research.get("sprite"):
            check["display_icon"] = catalogue.capability_icon(research["sprite"])

        return check

    # A spell or prayer that only needs levels (and sometimes a quest), per the
    # Wiki's spell and prayer data, is checked as all of those. "requires" uses the
    # same shorthand as guide requirements ("skill:MAGIC:67", "quest:Desert Treasure").
    if research.get("requires"):
        children = [convert_requirement(entry, ctx) for entry in research["requires"]]
        check = {"kind": "all", "children": children,
                 "text": f"{tidy_name(name)} ({', '.join(child['text'] for child in children)})"}

        if research.get("sprite"):
            check["display_icon"] = catalogue.capability_icon(research["sprite"])

        return check

    # An achievement, or a whole diary tier, by in-game IDs.
    if name in ctx.achievements:
        return {"kind": "achievement", "ids": ctx.achievements[name], "text": tidy_name(name)}

    # A known outfit is all of its pieces. The plugin checks each one like an item
    # (backpack, worn or bank) and shows them as a grid of icons.
    if name in ctx.outfits:
        children = []

        for slot, piece, item_id, *family in ctx.outfits[name]:
            ctx.define_item(item_id, piece, family[0] if family else None)
            children.append({"kind": "item", "itemId": item_id, "quantity": 1, "text": piece})

        return {"kind": "all", "text": tidy_name(name), "children": children,
                "display_items": [child["itemId"] for child in children]}

    check = {"kind": "capability", "text": tidy_name(name)}

    if quest:
        check["capability_kind"] = "quest"
        check["display_icon"] = "quest"
    else:
        if research.get("kind"):
            check["capability_kind"] = research["kind"]

        if research.get("sprite"):
            check["display_icon"] = catalogue.capability_icon(research["sprite"])

    return check


def convert_requirement(entry, ctx):
    """One parsed Wiki requirement as one full requirement record."""
    text = None

    if isinstance(entry, dict):
        if "req" not in entry:
            # Plain words with nothing structured: shown, but can't be checked.
            return {"kind": "capability", "text": entry["text"]}

        text, entry = entry["text"], entry["req"]

    if isinstance(entry, list):
        children = [convert_requirement(child, ctx) for child in entry[1:]]
        children = [child for child in children if child]

        # Every option was a Wiki advice page: there's nothing left to check.
        if not children:
            return None

        check = {"kind": "any", "children": children,
                 "text": " or ".join([", ".join(child["text"] for child in children[:-1]), children[-1]["text"]])
                 if len(children) > 1 else children[0]["text"]}

        if all(child["kind"] == "item" for child in children):
            check["display_items"] = list(dict.fromkeys(child["itemId"] for child in children))

    elif entry.startswith("skill:"):
        _, name, level = entry.split(":")

        # The client's SkillType calls Constitution HITPOINTS (developer.runescape.com
        # Player docs); the Wiki says Constitution.
        name = CLIENT_SKILL_NAMES.get(name, name)

        # Combat level: the plugin works it out from the combat skills.
        if name in ("COMBAT", "COMBAT_LEVEL"):
            check = {"kind": "combat_level", "level": int(level), "text": f"{level} Combat"}

        # "Melee" is the Wiki's shorthand for the melee skills, Attack and Strength.
        elif name == "MELEE":
            check = {"kind": "all", "text": f"{level} Melee (Attack and Strength)", "children": [
                {"kind": "skill", "skill": "ATTACK", "level": int(level), "text": f"{level} Attack"},
                {"kind": "skill", "skill": "STRENGTH", "level": int(level), "text": f"{level} Strength"},
            ]}

        # Only the client's real skills (each has an icon) can be checked. Anything
        # else stays an unknown capability.
        elif "skill_" + name.lower() in catalogue.ICON_NAMES:
            check = {"kind": "skill", "skill": name, "level": int(level),
                     "text": f"{level} {SKILL_LABELS.get(name, name.capitalize())}"}
        else:
            check = {"kind": "capability", "text": f"{level} {name.replace('_', ' ').capitalize()}"}

    elif entry.startswith("item:"):
        name = entry[len("item:"):]
        head, _, number = name.rpartition(":")
        quantity = 1

        if head and number.isdecimal():
            name, quantity = head, max(1, int(number))

        item_id = ctx.item_id(name)

        if item_id:
            check = {"kind": "item", "itemId": item_id, "quantity": quantity,
                     "text": name if quantity == 1 else f"{quantity:,} {name}"}

            # The Requirements tab draws an item's icon (with its owned / missing
            # border) from display_items. A stack keeps its text so the amount shows.
            if quantity == 1:
                check["display_items"] = [item_id]
        else:
            check = capability(name, ctx)

    elif entry.startswith("quest:"):
        # Quests need their client quest ID to be checked, which is research for
        # later. Until then they show the quest icon and stay unknown.
        check = capability(entry[len("quest:"):], ctx, quest=True)

    else:
        raise ValueError(f"Unknown requirement in the Wiki snapshot: {entry}")

    if check is None:
        # Keep the Wiki's own wording for an advice link when it has some.
        if text and ctx.advice:
            ctx.advice[-1] = text

        return None

    if text:
        check["text"] = text

    return check


def unknown_only(check):
    """True if nothing in this requirement can be checked in game yet."""
    if check["kind"] in ("all", "any"):
        return all(unknown_only(child) for child in check["children"])

    return check["kind"] == "capability"


def check_icons(check):
    """Every icon alias in a requirement, in order, without repeats."""
    icons = [check["display_icon"]] if check.get("display_icon") else []

    for child in check.get("children", []):
        icons += [icon for icon in check_icons(child) if icon not in icons]

    return icons


def convert_requirements(requirements, ctx):
    access, recommended, tips = [], [], []
    ctx.advice = []

    for importance, entries in requirements.items():
        for entry in entries:
            check = convert_requirement(entry, ctx)

            if check is None:
                continue

            # Something only recommended that the plugin can't check (a relic, an
            # ability, a diary) is a tip, not a grey "unknown" check: it never
            # decides whether you can do the method.
            # The Wiki sometimes lists a suggestion under "required" ("Tomes of the
            # Warlock recommended for Darkness"); its own wording says what it is.
            suggested = importance != "required" or re.search(r"\brecommended\b|\boptional\b", check["text"], re.I)

            if suggested and unknown_only(check):
                tip = {"text": check["text"]}
                icons = check_icons(check)

                if icons:
                    tip["icons"] = icons[:4]

                tips.append(tip)
                continue

            suffix = SUFFIX[importance]

            # Don't say "recommended" twice when the Wiki's own wording already does.
            if suffix and suffix.strip(" ()") not in check["text"].lower():
                check["text"] += suffix

            (access if importance == "required" else recommended).append(check)

    return {
        # The Wiki's list is a good start, but nobody has checked it against the
        # game for this method yet.
        "coverage": "partial",
        "access": {"kind": "all", "text": "Required", "children": access},
        "recommended": {"kind": "all", "text": "Recommended", "children": recommended},
        "unresolved": [],

        # Wiki pages worth reading for this method, in the guide's order.
        "advice": list(dict.fromkeys(ctx.advice)),

        # Recommended things the plugin can't check, shown as tips with icons.
        "tips": tips,
    }


def convert_income(guide, ctx, pvm):
    pace = "kph" not in guide
    retrieved = ctx.meta["retrieved"]
    recurring = guide.get("recurring")

    if recurring:
        # A daily/weekly run: amounts are for one run. Like a pace, 100% is the
        # guide's own yield, and every amount scales with it.
        rate = {"key": "guide_yield", "unit": "% of guide yield", "default": 100}
        every = recurring["every"].lower()
        minutes = recurring["minutes"]
        assumptions = [f"Amounts are one run of the Wiki guide at 100% yield. Set your own yield as a percentage.",
                       f"Can be done every {every}; a run takes about {minutes:g} minutes."]
    elif pace:
        rate = {"key": "guide_pace", "unit": "% of guide pace", "default": 100}
        assumptions = ["Amounts are the Wiki guide's hourly figures at 100% pace. "
                       "Set your own pace as a percentage of the guide's."]
    else:
        unit = "kills/hour" if pvm else "actions/hour"
        rate = {"key": unit.split("/")[0] + "_per_hour", "unit": unit, "default": guide["kph"]}
        assumptions = [f"Assumes the guide's {guide['kph']:,} {unit.split('/')[0]} per hour. Adjust it to your own pace."]

    assumptions.append(f"Imported from the Wiki guide on {retrieved}; not yet reviewed for Profit Path.")
    income = {"coverage": "complete", "period": "run" if recurring else "hour", "rate": rate,
              "inputs": [], "outputs": [], "assumptions": assumptions, "unresolved": []}

    if recurring:
        income["recurrence"] = {"every": recurring["every"].lower(), "minutes": recurring["minutes"]}

    for direction in ("inputs", "outputs"):
        for name, quantity, basis, pricing, value, *note in guide[direction]:
            # Per-hour and per-run guides store amounts per 1% of pace or yield.
            line = {"name": name,
                    "quantity": quantity / 100 if pace else quantity,
                    "basis": "action" if pace else basis}
            item_id = ctx.item_id(name)

            if pricing == "ge":
                if item_id:
                    line["item_id"] = item_id

                    # GE tax is paid on what you sell, 1 GP in 50.
                    if direction == "outputs":
                        line["tax_denominator"] = 50
                else:
                    income["unresolved"].append(f"No item ID found for {name}.")

            elif pricing == "calc" and direction == "inputs" and ctx.recipe_for(name, note[0] if note else None):
                page, dose = ctx.recipe_for(name, note[0] if note else None)
                line.update({"pricing": "recipe", "recipe": page})

                if dose:
                    line["portion"] = dose

                if item_id:
                    line["item_id"] = item_id

            else:
                # The Wiki's own value: fixed for coins/clues, or its calculation
                # for an untradeable we can't cost ourselves yet.
                line.update({"pricing": "fixed", "unit_value": value,
                             "valuation_note": "Fixed value set by the Wiki guide." if pricing == "value" else
                             f"The Wiki's calculated value on {retrieved}; untradeable, so not a live price."})

                if item_id:
                    line["item_id"] = item_id

            income[direction].append(line)

    if income["unresolved"]:
        income["coverage"] = "partial"

    return income


def convert_guide(guide, ctx, category):
    title = guide["page"][len(PREFIX):]
    method = {
        "id": method_id(guide),
        "schema": catalogue.METHOD_RECORD_SCHEMA,
        "origin": "bundled",
        "title": title,
        "category": category,
        "source_category": guide.get("category") or "Uncategorised",
        "members": guide["members"],
        "intensity": guide.get("intensity") or "Unknown",
        "source": {"title": guide["page"], "revision": guide["revision"],
                   "url": catalogue.wiki_url(guide["page"], guide["revision"])},
    }

    if guide.get("version"):
        method["variant"] = guide["version"]

    method["requirements"] = convert_requirements(guide.get("requirements", {}), ctx)
    method["income"] = convert_income(guide, ctx, category == "pvm")
    method["instructions"] = []
    method["location"] = {"text": "See the Wiki guide for where to go.", "coverage": "partial", "routes": []}

    return method


def count_checks(node, kinds):
    """How many requirement checks of these kinds sit anywhere under a group."""
    own = 1 if node.get("kind") in kinds else 0

    return own + sum(count_checks(child, kinds) for child in node.get("children", []))


# ---- Checking PvM drops against the monster drop tables -----------------------
#
# A Wiki guide lists each drop's expected amount per kill. Our monster snapshot
# (catalogue-source/monsters.json) has the drop tables themselves. For each per-kill
# output we work out rate x average quantity over every table row for that item and
# compare. The result is one status per method:
#
#   drops checked        every drop with a fixed rate matches within 10%
#   drops partly checked fixed-rate drops match; some rare drops have a rate that
#                        depends on conditions ("1/284-1/1,988", "1/640; 1/632"),
#                        so the guide's figure for its setup is used
#   drops differ         some fixed-rate drops don't match (listed in the report)
#   setting-specific     a guide version for a set enrage, killstreak or hard mode:
#                        its drops come from rates or a table the base drop table
#                        doesn't hold, so it can't be checked against it
#   no drop table        no monster in the snapshot matches the guide

DROP_TOLERANCE = 0.10

_monsters = None


def monster_tables(monsters=None):
    """{lower-case monster title: monster} from the snapshot, loaded once."""
    global _monsters

    if monsters is not None:
        return {monster["title"].lower(): monster for monster in monsters["monsters"]}

    if _monsters is None:
        source = json.loads(catalogue.SOURCE.read_text(encoding="utf-8"))
        _monsters = {monster["title"].lower(): monster for monster in source["monsters"]}

    return _monsters


def monster_for(page, tables):
    """The monster a guide is about, by name: "Killing abyssal demons" -> "Abyssal
    demon". Tries the name as written, then common singular forms."""
    name = re.sub(r"^(Killing|Completing|Fighting|Defeating)\s+(the\s+)?", "", page[len(PREFIX):], flags=re.IGNORECASE)
    forms = [name]

    for plural, singular in (("ies", "y"), ("es", ""), ("s", "")):
        if name.endswith(plural):
            forms.append(name[:-len(plural)] + singular)

    forms += [form.split(" and ")[0] for form in list(forms)]

    return next((tables[form.lower()] for form in forms if form.lower() in tables), None)


def drop_rate(text):
    """A fixed drop rate as a number ("1/128", "2 x 1/128", "Always"), or None for
    one that depends on conditions (a range, several rates, "Common")."""
    text = (text or "").replace(",", "").replace(" ", "").replace("\u00d7", "*")

    if text == "Always":
        return 1.0

    match = re.fullmatch(r"(?:(\d+\.?\d*)\*)?(\d+\.?\d*)/(\d+\.?\d*)", text)

    return float(match.group(1) or 1) * float(match.group(2)) / float(match.group(3)) if match else None


def drop_quantity(drop):
    if "quantity_low" in drop:
        return (drop["quantity_low"] + drop.get("quantity_high", drop["quantity_low"])) / 2

    numbers = [float(n) for n in re.findall(r"\d+(?:\.\d+)?", (drop.get("quantity") or "").replace(",", ""))][:2]

    return sum(numbers) / len(numbers) if numbers else None


def check_drops(guide, tables):
    """{"status", "agree", "conditional", "differ": [names]} for one PvM guide."""
    if re.search(r"enrage|killstreak|hard mode", guide.get("version") or "", re.IGNORECASE):
        return {"status": "setting-specific", "agree": 0, "conditional": 0, "differ": []}

    monster = monster_for(guide["page"], tables) if "kph" in guide else None

    if monster is None:
        return {"status": "no drop table", "agree": 0, "conditional": 0, "differ": []}

    agree, conditional, differ = 0, 0, []

    for name, quantity, basis, *_ in guide["outputs"]:
        if basis != "action":
            continue

        rows = [drop for section in monster["sections"] for drop in section["drops"]
                if drop["name"].lower() == name.lower()]
        rates = [drop_rate(drop.get("rate")) for drop in rows]
        amounts = [drop_quantity(drop) for drop in rows]

        if not rows or any(amount is None for amount in amounts):
            differ.append(name)
        elif any(rate is None for rate in rates):
            conditional += 1
        else:
            expected = sum(rate * amount for rate, amount in zip(rates, amounts))

            if expected > 0 and abs(quantity - expected) / expected <= DROP_TOLERANCE:
                agree += 1
            else:
                differ.append(name)

    status = "drops differ" if differ else ("drops partly checked" if conditional else "drops checked")

    return {"status": status, "agree": agree, "conditional": conditional, "differ": differ}


def research_status(method, curated, drops=None):
    """What's been researched for one method. Computed, never hand-written."""
    requirements = method["requirements"]
    unknown = sum(count_checks(requirements[group], {"capability"}) for group in ("access", "recommended"))

    if method["category"] != "pvm":
        pvm = "n/a"
    elif curated and "loot" in method["income"]:
        pvm = "loot checked"
    else:
        pvm = drops["status"] if drops else "no drop table"

    return {
        "income": "curated" if curated else "wiki",
        "unpriced": len(method["income"]["unresolved"]),
        "unknown_checks": unknown,
        "pvm": pvm,
        "drops_differ": len(drops["differ"]) if drops else 0,
        "steps": bool(method["instructions"]),
        "location": method["location"]["coverage"] == "complete",
    }


def merge(recipe_source=None, monsters=None):
    """Returns (catalogue, details). The catalogue holds every method in full; the
    details say where each came from and what was left out. `monsters` is the
    monster snapshot if the caller already has it loaded (it's 12 MB)."""
    tables = monster_tables(monsters)
    curated = catalogue.expand_methods(catalogue.load_method_source())
    guides, meta = load_snapshot()
    recipes = catalogue.choose_recipes(recipe_source) if recipe_source else {}

    items = dict(curated["items"])
    ctx = Context(items, meta or {"items": {}, "retrieved": None}, catalogue.load_capabilities(), recipes,
                  catalogue.load_quests(), load_outfits(), load_achievements())

    # Rule 1: which guides our curated methods replace.
    by_key = {(guide["page"], (guide.get("version") or "").lower()): guide for guide in guides}
    replaced, unmatched = {}, []

    for method in curated["methods"]:
        key = (method["source"]["title"], (method.get("variant") or "").lower())

        if key in by_key:
            replaced[key] = method["id"]
        else:
            unmatched.append(method["id"])

    # Versions on one page share a category (the version dropdown needs that), so
    # each page uses its most common one.
    page_categories = collections.defaultdict(collections.Counter)

    for guide in guides:
        # Recurring (daily/weekly) guides are their own activity group in Browse.
        category = "recurring" if "recurring" in guide else activity_category(guide.get("category"))
        page_categories[guide["page"]][category] += 1

    for method in curated["methods"]:
        page_categories[method["source"]["title"]][method["category"]] += 100

    methods = []
    details = {"curated": len(curated["methods"]), "recurring": [], "unmatched_curated": unmatched,
               "research": {}, "wiki_profit": {}, "retrieved": ctx.meta.get("retrieved")}

    for method in curated["methods"]:
        method["research"] = research_status(method, True)
        methods.append(method)
        details["research"][method["id"]] = method["research"]

    pages = collections.defaultdict(list)

    for guide in guides:
        key = (guide["page"], (guide.get("version") or "").lower())

        if key in replaced:
            details["wiki_profit"][replaced[key]] = guide["wiki_profit"]
            continue

        if "recurring" in guide:
            details["recurring"].append(guide)

        method = convert_guide(guide, ctx, page_categories[guide["page"]].most_common(1)[0][0])
        drops = check_drops(guide, tables) if method["category"] == "pvm" else None
        method["research"] = research_status(method, False, drops)

        if drops and drops["differ"]:
            details.setdefault("drops_differ", {})[method["id"]] = drops["differ"]
        pages[guide["page"]].append(method)
        methods.append(method)
        details["research"][method["id"]] = method["research"]
        details["wiki_profit"][method["id"]] = guide["wiki_profit"]

    # A page with several versions needs every version labelled, including one the
    # Wiki left unlabelled next to labelled ones.
    for page, versions in pages.items():
        if len(versions) > 1 or any(m["source"]["title"] == page for m in curated["methods"]):
            for method in versions:
                method.setdefault("variant", "Standard")

    ids = collections.Counter(method["id"] for method in methods)
    duplicates = [method_id for method_id, count in ids.items() if count > 1]

    if duplicates:
        raise ValueError(f"Merged method IDs collide: {duplicates[:5]}")

    # The plugin's own icon list only knows hand-picked names. Capability sprites
    # travel with the catalogue: only the ones some method actually uses.
    sprites = {catalogue.capability_icon(entry["sprite"]): entry["sprite"]
               for entry in ctx.capabilities.values() if entry.get("sprite")}
    used = {check.get("display_icon") for method in methods for group in ("access", "recommended")
            for check in walk_checks(method["requirements"][group])}

    # Tips draw their icons too.
    used |= {icon for method in methods for tip in method["requirements"].get("tips", [])
             for icon in tip.get("icons", [])}

    merged = {"schema": 1, "items": items, "methods": methods,
              "icons": {alias: sprite for alias, sprite in sorted(sprites.items()) if alias in used}}

    for key in ("equipment", "toolbelt"):
        if key in curated:
            merged[key] = curated[key]

    return merged, details


def verify_merge(monsters, recipe_source):
    """Builds the merged catalogue and checks every method with the same validator
    as the curated ones. Run by test.py. Returns the method count."""
    merged, _ = merge(recipe_source, monsters)
    recipes = catalogue.choose_recipes(recipe_source) if recipe_source else None
    catalogue.validate_methods(merged, monsters, recipes)

    return len(merged["methods"])


def walk_checks(node):
    yield node

    for child in node.get("children", []):
        yield from walk_checks(child)


def print_report(monsters, recipe_source):
    merged, details = merge(recipe_source, monsters)
    recipes = catalogue.choose_recipes(recipe_source) if recipe_source else None
    catalogue.validate_methods(merged, monsters, recipes)

    methods = merged["methods"]
    research = details["research"]
    imported = len(methods) - details["curated"]

    print(f"Catalogue coverage (Wiki snapshot {details['retrieved']})")
    print(f"  Methods: {len(methods)} = {details['curated']} curated + {imported} imported from the Wiki")
    print(f"  Recurring (per run, sorted after hourly methods): {len(details['recurring'])}")

    if details["unmatched_curated"]:
        print(f"  Curated methods with no current Wiki guide: {', '.join(details['unmatched_curated'])}")

    # Income: how much can be priced.
    complete = sum(1 for method in methods if method["income"]["coverage"] == "complete")
    unpriced = collections.Counter(line.split("found for ", 1)[-1].rstrip(".")
                                   for method in methods for line in method["income"]["unresolved"])
    print(f"\nIncome: {complete} complete, {len(methods) - complete} partial (some row has no item ID)")

    for name, count in unpriced.most_common(12):
        print(f"    {count:3} methods use unpriced {name}")

    # Requirements: what the plugin will be able to check.
    kinds, unknown_names, with_icon = collections.Counter(), collections.Counter(), 0
    capability_kinds = collections.Counter()

    for method in methods:
        for group in ("access", "recommended"):
            for check in walk_checks(method["requirements"][group]):
                if check is method["requirements"][group] or check["kind"] in ("all", "any"):
                    continue

                kinds[check["kind"]] += 1

                if check["kind"] == "capability":
                    with_icon += 1 if "display_icon" in check else 0
                    capability_kinds[check.get("capability_kind", "unclassified")] += 1

                    # Classified checks are researched; list the ones that aren't.
                    if "capability_kind" not in check:
                        unknown_names[check["text"].replace(" (recommended)", "").replace(" (optional)", "")] += 1

    print(f"\nRequirement checks: {dict(kinds)}")
    print(f"  {kinds['capability']} can't be checked yet (shown as unknown); {with_icon} of them have a sprite")
    print(f"  By kind: {dict(capability_kinds.most_common())}")
    print(f"  Wiki advice links shown as notes instead of checks: "
          f"{sum(len(method['requirements'].get('advice', [])) for method in methods)}")
    print(f"  Recommended things shown as tips instead of checks: "
          f"{sum(len(method['requirements'].get('tips', [])) for method in methods)}")
    print("  Most common checks not researched yet (add these to capabilities.json first):")

    for name, count in unknown_names.most_common(15):
        print(f"    {count:3}  {name[:90]}")

    pvm = collections.Counter(status["pvm"] for status in research.values() if status["pvm"] != "n/a")
    print(f"\nPvM drops: {dict(pvm.most_common())}")
    print("  Highest-value methods whose drops differ from the drop table:")

    differing = sorted(details.get("drops_differ", {}).items(),
                       key=lambda pair: details["wiki_profit"].get(pair[0], 0), reverse=True)

    for method_id, names in differing[:10]:
        print(f"    {method_id[:48]:48} {', '.join(names)[:80]}")
    print(f"Steps written: {sum(s['steps'] for s in research.values())}; "
          f"locations written: {sum(s['location'] for s in research.values())} of {len(methods)}")

    # Most valuable first: the Wiki's own profit figure decides what to research next.
    print("\nNeeds research first (highest Wiki profit, imported methods):")
    ranked = sorted((method for method in methods if research[method["id"]]["income"] == "wiki"),
                    key=lambda method: details["wiki_profit"].get(method["id"], 0), reverse=True)

    for method in ranked[:20]:
        status = research[method["id"]]
        gaps = []

        if status["unpriced"]:
            gaps.append(f"{status['unpriced']} unpriced")

        if status["unknown_checks"]:
            gaps.append(f"{status['unknown_checks']} unknown checks")

        if status["pvm"] not in ("n/a", "loot checked", "drops checked"):
            gaps.append(status["pvm"])

        gaps.append("no steps")
        label = method["title"] + (f" - {method['variant']}" if method.get("variant") else "")
        print(f"  {details['wiki_profit'].get(method['id'], 0):>14,.0f}/h  {label[:55]:55}  {', '.join(gaps)}")
