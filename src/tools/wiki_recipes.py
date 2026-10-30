"""Import untradeable Herblore/Summoning recipes from the RuneScape Wiki.

Writes catalogue-source/recipes.json. Run by hand when the recipes need refreshing;
the plugin never talks to the Wiki. `catalogue.py build` then turns the JSON into
data/recipes.lua offline, just like the monster and method data.
"""
# Developer tool, never shipped with the plugin.
#
# Why this exists: some supplies (Perfect plus potion, Overload, most summoning
# pouches) can't be traded, so GE Prices Library has no price for them. Instead we
# price them by what it costs to MAKE them: add up the ingredients at GE prices.
#
# Where the data comes from: the Wiki keeps structured "buckets" next to its pages.
#   recipe        every recipe's ingredients, outputs and doses ("production_json").
#                 Each ingredient says how the Wiki prices it:
#                   gemw     a Grand Exchange price
#                   estcost  untradeable, priced from its own recipe
#                   no       no price at all (e.g. Crystal tree blossom)
#                   smuggler only sold by the Daemonheim smuggler
#   infobox_item  item names -> item IDs, which GEPL needs to look up prices.
#
# What we keep:
#   1. every Herblore and Summoning recipe whose main output can't be traded;
#   2. the recipes for any untradeable ingredient those need (and theirs, and so on);
#   3. item IDs for every output and every GE-priced ingredient.
#
# Everything fetched is treated as untrusted data: it's parsed as JSON, checked for
# the shapes we expect, and nothing in it is ever run.
from __future__ import annotations

import argparse
import datetime
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "catalogue-source" / "recipes.json"

API = "https://runescape.wiki/api.php"

# The Wiki asks tools to identify themselves. Agreed with Duncan for this project.
USER_AGENT = "ProfitPath-development (Discord: Tatsuya)"

# Seconds between requests, so we stay a polite, low-volume client.
REQUEST_GAP = 1.0

SKILLS = ("Herblore", "Summoning")

# How many pages to ask about in one batched (OR) lookup, and rows per page.
BATCH = 40
PAGE_SIZE = 500


def ask(query):
    """Runs one bucket query and returns its rows. Raises on any API error."""
    url = API + "?" + urllib.parse.urlencode({"action": "bucket", "format": "json", "query": query})
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})

    with urllib.request.urlopen(request, timeout=60) as response:
        data = json.loads(response.read().decode("utf-8"))

    time.sleep(REQUEST_GAP)

    if not isinstance(data, dict) or "error" in data or not isinstance(data.get("bucket"), list):
        raise ValueError(f"Wiki query failed: {data.get('error') if isinstance(data, dict) else data}")

    return data["bucket"]


def lua_text(value):
    """Quotes a value for the bucket query language (a small Lua-like syntax)."""
    return "'" + str(value).replace("\\", "\\\\").replace("'", "\\'") + "'"


def ask_all(select, where):
    """Runs a query page by page until the Wiki runs out of rows."""
    rows, offset = [], 0

    while True:
        page = ask(f"bucket('recipe').select({select}).where({where}).limit({PAGE_SIZE}).offset({offset}).run()")
        rows += page

        if len(page) < PAGE_SIZE:
            return rows

        offset += PAGE_SIZE


def any_of(field, values):
    """Builds a where() argument matching any of `values` in `field`."""
    clauses = ",".join("{" + lua_text(field) + "," + lua_text(value) + "}" for value in values)

    return f"bucket.Or({clauses})"


def batches(values):
    values = sorted(values)

    for start in range(0, len(values), BATCH):
        yield values[start:start + BATCH]


RECIPE_FIELDS = "'page_name','page_name_sub','sequence','production_main_output','production_json'"


def number(value, field):
    """Wiki quantities arrive as text like "4". Anything else is a data problem."""
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        raise ValueError(f"{field} is not a number: {value!r}")

    if parsed <= 0 or parsed != parsed or parsed == float("inf"):
        raise ValueError(f"{field} must be above zero: {value!r}")

    return int(parsed) if parsed == int(parsed) else parsed


def parse_recipe(row):
    """Turns one bucket row into our recipe shape, or None if it has no outputs.

    Only the main output is kept. By-products (like the empty vials left after
    making an overload) are ignored when working out a cost.
    """
    production = json.loads(row["production_json"])
    outputs = production.get("outputs") or []

    if not outputs:
        return None

    main_pages = row.get("production_main_output") or []
    main = next((output for output in outputs if output.get("page") in main_pages), outputs[0])

    output = {
        "name": main["name"],
        "page": main.get("page") or row["page_name"],
        "quantity": number(main.get("quantity"), f"{row['page_name_sub']} output quantity"),
        "tradeable": main.get("cost_method") == "gemw",
    }

    if isinstance(main.get("portion"), int):
        output["portion"] = main["portion"]

    materials = []

    for material in production.get("materials") or []:
        entry = {
            "name": material["name"],
            "page": material.get("page") or material["name"],
            "quantity": number(material.get("quantity"), f"{row['page_name_sub']} material {material['name']}"),
            "wiki_cost": material.get("cost_method") or "none",
        }

        if isinstance(material.get("portion"), int):
            entry["portion"] = material["portion"]

        materials.append(entry)

    return {
        "page": row["page_name"],
        "sequence": row.get("sequence") or 1,
        "url": "https://runescape.wiki/w/" + urllib.parse.quote(row["page_name"].replace(" ", "_")),
        "output": output,
        "materials": materials,
    }


def collect_recipes():
    """Step 1 and 2: untradeable skill recipes, then every untradeable ingredient's."""
    recipes = []

    for skill in SKILLS:
        for row in ask_all(RECIPE_FIELDS, f"'uses_skill',{lua_text(skill)}"):
            recipe = parse_recipe(row)

            if recipe and not recipe["output"]["tradeable"]:
                recipes.append(recipe)

        print(f"{skill}: {len(recipes)} untradeable recipes so far")

    # Follow ingredients the Wiki prices from their own recipe ("estcost") until
    # there's nothing new to fetch. Pages we already have are skipped.
    known = {recipe["page"] for recipe in recipes}

    while True:
        wanted = {
            material["page"] for recipe in recipes for material in recipe["materials"]
            if material["wiki_cost"] == "estcost" and material["page"] not in known
        }

        if not wanted:
            return recipes

        for group in batches(wanted):
            for row in ask_all(RECIPE_FIELDS, any_of("production_main_output", group)):
                recipe = parse_recipe(row)

                if recipe and recipe["page"] not in known:
                    recipes.append(recipe)

        # Even if a page had no recipe, don't ask for it again.
        known |= wanted
        known |= {recipe["page"] for recipe in recipes}


def resolve_item_ids(recipes):
    """Step 3: item IDs for outputs and GE-priced ingredients, via infobox_item.

    Several versions of an item can share one name, and only one of them is on
    the Grand Exchange (the one with an exchange page). For a GE-priced
    ingredient that's the version we need, so it wins over the others."""
    pages = {recipe["output"]["page"] for recipe in recipes}
    pages |= {m["page"] for recipe in recipes for m in recipe["materials"] if m["wiki_cost"] == "gemw"}

    # item name -> ID, and page -> its only ID (for pages without dose variants).
    by_name, single = {}, {}

    # Item IDs we picked from a row with an exchange page.
    on_exchange = set()

    for group in batches(pages):
        rows = ask(
            "bucket('infobox_item').select('page_name','item_name','item_id','exchange_page')"
            f".where({any_of('page_name', group)}).limit({PAGE_SIZE}).run()"
        )
        per_page = {}

        for row in rows:
            ids = row.get("item_id") or []

            if not ids or not isinstance(ids[0], int):
                continue

            name = row.get("item_name")
            listed = bool(row.get("exchange_page"))

            # Keep the first ID for a name, unless a GE-listed version turns up later.
            if name not in by_name or (listed and by_name[name] not in on_exchange):
                by_name[name] = ids[0]

            if listed:
                on_exchange.add(ids[0])

            per_page.setdefault(row["page_name"], set()).add(ids[0])

        for page, ids in per_page.items():
            if len(ids) == 1:
                single[page] = next(iter(ids))

    def lookup(entry):
        return by_name.get(entry["name"]) or single.get(entry["page"])

    for recipe in recipes:
        item_id = lookup(recipe["output"])

        if item_id:
            recipe["output"]["item_id"] = item_id

        for material in recipe["materials"]:
            if material["wiki_cost"] == "gemw":
                item_id = lookup(material)

                if item_id:
                    material["item_id"] = item_id


def classify(recipes):
    """Decides how each ingredient gets priced in the plugin.

      ge      GE buy price (needs an item ID)
      recipe  follow that ingredient's own recipe
      free    no price: counted as 0 GP, and the plugin names it in a note
    """
    has_recipe = {recipe["page"] for recipe in recipes}

    for recipe in recipes:
        for material in recipe["materials"]:
            if material["wiki_cost"] == "gemw" and "item_id" in material:
                material["pricing"] = "ge"
            elif material["page"] in has_recipe and material["page"] != recipe["page"]:
                material["pricing"] = "recipe"
            else:
                # Includes GE items whose ID we couldn't find: free is the only
                # honest option short of dropping the recipe, and the note says so.
                material["pricing"] = "free"


def refresh_items():
    """Looks up item IDs again for the recipes already on disk, keeping the
    recipes themselves as they are. Returns the updated document and a list of
    (recipe page, ingredient or output name, old ID, new ID) changes."""
    document = json.loads(OUTPUT.read_text(encoding="utf-8"))
    recipes = document["recipes"]

    def entries():
        for recipe in recipes:
            yield recipe, recipe["output"]

            for material in recipe["materials"]:
                yield recipe, material

    old = [entry.get("item_id") for _, entry in entries()]

    # Start clean, so an ID the Wiki no longer gives doesn't linger.
    for _, entry in entries():
        entry.pop("item_id", None)
        entry.pop("pricing", None)

    resolve_item_ids(recipes)
    classify(recipes)

    changes = [(recipe["page"], entry["name"], before, entry.get("item_id"))
               for (recipe, entry), before in zip(entries(), old) if before != entry.get("item_id")]

    document["items_retrieved"] = datetime.date.today().isoformat()

    return document, changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--items", action="store_true",
                        help="look up item IDs again for the saved recipes, leaving the recipes unchanged")
    args = parser.parse_args()

    if args.items:
        document, changes = refresh_items()
        OUTPUT.write_text(json.dumps(document, indent=2, ensure_ascii=True) + "\n", encoding="utf-8", newline="\n")

        print(f"{len(changes)} item IDs changed:")

        for page, name, before, after in changes:
            print(f"  {page} / {name}: {before} -> {after}")

        return

    recipes = collect_recipes()
    resolve_item_ids(recipes)
    classify(recipes)

    recipes.sort(key=lambda recipe: (recipe["page"], recipe["sequence"]))

    document = {
        "schema": 1,
        "retrieved": datetime.date.today().isoformat(),
        "source": "RuneScape Wiki recipe and infobox_item buckets (api.php?action=bucket).",
        "licence": "RuneScape Wiki contributors, CC BY-NC-SA 3.0.",
        "skills": list(SKILLS),
        "recipes": recipes,
    }

    OUTPUT.write_text(json.dumps(document, indent=2, ensure_ascii=True) + "\n", encoding="utf-8", newline="\n")

    free = sum(1 for recipe in recipes for m in recipe["materials"] if m["pricing"] == "free")
    unpriced_ge = sum(1 for recipe in recipes for m in recipe["materials"]
                      if m["wiki_cost"] == "gemw" and m["pricing"] != "ge")

    print(f"Wrote {len(recipes)} recipes to {OUTPUT.relative_to(ROOT)}; "
          f"{free} free ingredients ({unpriced_ge} of them GE items without a known ID).")


if __name__ == "__main__":
    main()
