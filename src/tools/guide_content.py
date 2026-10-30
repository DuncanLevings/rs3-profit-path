"""Collect the Wiki guide prose used by How to do it and Getting there.

Maintainer-only tool. Raw responses stay in the supplied cache directory; reviewed
summaries and routes live in catalogue-source/research/guide-content.json. Runtime
never contacts the Wiki. Fetches use the existing identified, paced API client.
"""
from __future__ import annotations

import argparse
import datetime
import json
import re
import html
from pathlib import Path

import wiki_methods

ROOT = Path(__file__).resolve().parents[2]
GUIDES = ROOT / "catalogue-source/wiki/guides.jsonl"


def guide_pages():
    """Every distinct guide page and its pinned catalogue revision."""
    pages = {}

    for line in GUIDES.read_text(encoding="utf-8").splitlines():
        guide = json.loads(line)
        previous = pages.setdefault(guide["page"], guide["revision"])

        if previous != guide["revision"]:
            raise ValueError("Guide variants disagree about their source revision")

    return pages


def fetch_guides(cache):
    """Reuse immutable revision responses; batch only missing page revisions.

    Each batch is saved immediately, so an interrupted collection resumes without
    asking for the same Wiki content again. Nothing runs in the game client.
    """
    cache.mkdir(parents=True, exist_ok=True)
    output = cache / "guide-pages.json"
    records = json.loads(output.read_text(encoding="utf-8")) if output.exists() else {}
    pages = guide_pages()
    missing = {title: revision for title, revision in pages.items()
               if records.get(title, {}).get("revision") != revision}

    for group in wiki_methods.batches(missing, 50):
        response = wiki_methods.get({"action": "query", "prop": "revisions",
                                    "revids": "|".join(str(pages[title]) for title in group),
                                    "rvprop": "ids|content", "rvslots": "main", "maxlag": 5})
        found = set()

        for page in response.get("query", {}).get("pages", {}).values():
            revisions = page.get("revisions", [])

            if not revisions:
                continue

            revision = revisions[0]
            title = page["title"]
            text = revision.get("slots", {}).get("main", {}).get("*", "")

            if title not in pages or revision["revid"] != pages[title] or not text:
                raise ValueError("Unexpected guide revision or empty source: " + title)

            records[title] = {"revision": revision["revid"], "text": text}
            found.add(title)

        if found != set(group):
            raise ValueError("Incomplete guide response: " + str(sorted(set(group) - found)))

        output.write_text(json.dumps(records, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"Cached {len(records)}/{len(pages)} guide pages", flush=True)

    return records


def split_fields(text):
    """Split template arguments, ignoring pipes inside nested templates/links."""
    fields, start, braces, links = [], 0, 0, 0
    index = 0

    while index < len(text):
        token = text[index:index + 2]

        if token in ("{{", "}}", "[[", "]]"):
            braces += (token == "{{") - (token == "}}")
            links += (token == "[[") - (token == "]]")
            index += 2
            continue

        if text[index] == "|" and braces == 0 and links == 0:
            fields.append(text[start:index].strip())
            start = index + 1

        index += 1

    fields.append(text[start:].strip())
    return fields


def templates(text):
    """Yield balanced template spans, with their nested content left intact."""
    stack = []

    for match in re.finditer(r"\{\{|\}\}", text):
        if match.group() == "{{":
            stack.append(match.start())
        elif stack:
            start = stack.pop()
            yield start, match.end(), split_fields(text[start + 2:match.start()])


def guide_tables(text):
    """Only MMG tables carry variant-specific prose and destinations."""
    result = []

    for start, end, fields in templates(text):
        if fields[0].strip().lower() not in {"mmgtable", "mmgtable recurring"}:
            continue

        values = {}

        for field in fields[1:]:
            if "=" in field:
                key, value = field.split("=", 1)
                values[key.strip().lower()] = value.strip()

        result.append((start, end, values))

    return result


def readable(text, variables=None):
    """Render safe prose, not executable Wiki markup. Unknown templates return
    an explicit marker so their paragraph can be held for manual review instead
    of silently dropping words that might change the instruction.
    """
    variables = variables or {}
    text = re.sub(r"<!--.*?-->|<ref\b[^>]*>.*?</ref>|<ref\b[^>]*/>", "", text, flags=re.S | re.I)

    # Innermost templates first. Known formatting/link templates keep their label;
    # calculations and unknown constructs need a maintainer's attention.
    for _ in range(30):
        found = list(re.finditer(r"\{\{([^{}]*)\}\}", text))

        if not found:
            break

        for match in reversed(found):
            args = split_fields(match[1])
            name = args[0].strip().lower()
            positional = [part for part in args[1:] if "=" not in part]
            named = dict(part.split("=", 1) for part in args[1:] if "=" in part)
            replacement = "[unresolved template]"

            if name in {"plink", "ilink", "il", "item", "item link", "npc", "monster link", "l"} and positional:
                replacement = named.get("txt", positional[0])
            elif name in {"scm", "scp"} and len(positional) > 1:
                # Verified through expandtemplates: these print the level plus an
                # icon, not the skill's name. The surrounding prose names it.
                replacement = positional[1]
            elif name.startswith("#var:"):
                replacement = str(variables.get(name[5:].strip(), "[unresolved template]"))
            elif name == "fairycode" and positional:
                replacement = positional[0].upper()
            elif name == "checklist" and positional:
                replacement = positional[0]
            elif name == "maplink":
                # A decorative map link has no route condition or action to keep.
                replacement = ""
            elif name == "nbsp":
                replacement = " "
            elif name in {"clear", "reflist", "references", "notelist"}:
                replacement = ""
            elif name == "floornumber" and positional:
                # Verified with action=expandtemplates: Wiki input 1 is ground,
                # input 2 is one above ground (US second / UK first floor).
                floor = int(positional[0]) if positional[0].isdigit() else None
                replacement = ("ground floor" if floor == 1 else
                               f"floor {floor - 1} above ground" if floor is not None and floor > 1 else
                               "[unresolved template]")
            elif name in {"sic", "!"}:
                replacement = "|" if name == "!" else ""
            elif name in {"nowrap", "small", "nobr", "colour", "color"} and positional:
                replacement = positional[-1]

            text = text[:match.start()] + replacement + text[match.end():]

    text = re.sub(r"\[\[(?:File|Image|Category|[a-z]{2,3}):.*?\]\]", "", text, flags=re.I)
    text = re.sub(r"\[\[([^]|]+)(?:\|([^]]+))?\]\]", lambda m: m[2] or m[1].split("#")[0], text)
    text = re.sub(r"\[https?://\S+\s+([^]]+)\]", r"\1", text)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"'{2,}|__\w+__", "", text)
    return html.unescape(text).replace("\u00a0", " ")


def paragraphs(text, variables=None, strict=False):
    """Keep readable paragraphs/list entries; refuse tables and template remnants."""
    text = readable(text, variables)
    text = re.sub(r"^=+.*?=+\s*$", "\n", text, flags=re.M)
    result = []

    for part in re.split(r"\n\s*\n|\n(?=[*#])", text):
        part = re.sub(r"\s+", " ", part).strip(" *#\n")

        if strict and "[unresolved template]" in part:
            continue

        if "[unresolved template]" in part:
            # Keep only whole sentences independent of the unresolved expression.
            # Price calculators often share a paragraph with useful instructions.
            part = " ".join(sentence for sentence in re.split(r"(?<=[.!?])\s+", part)
                            if "[unresolved template]" not in sentence)

        if not part or any(token in part for token in ("{{", "}}", "[[", "]]", "{|", "|}", "|-")):
            continue

        if part.startswith(("=", "|", "!")):
            continue

        result.append(part)

    return result


def inspect_guides(cache):
    """Produce a research draft with each variant kept separate and provenance
    pinned to the income snapshot. This draft is never consumed by runtime.
    """
    pages = json.loads((cache / "guide-pages.json").read_text(encoding="utf-8"))
    records, missing = [], []

    for line in GUIDES.read_text(encoding="utf-8").splitlines():
        guide = json.loads(line)
        text = pages[guide["page"]]["text"]
        tables = guide_tables(text)
        version = (guide.get("version") or "").strip().casefold()
        matches = [table for table in tables if table[2].get("version", "").strip().casefold() == version]

        if not matches and version in {"variant 1", "variant 2"} and len(tables) == 2:
            # The Bucket snapshot labels these unnamed versions in table order.
            # Preserve that same explicit order rather than mixing their prose.
            matches = [tables[int(version[-1]) - 1]]

        if not matches and len(tables) == 1:
            matches = tables

        if len(matches) > 1 and len({(t[2].get("location"), t[2].get("details")) for t in matches}) == 1:
            matches = matches[:1]

        if len(matches) != 1:
            missing.append([guide["page"], guide.get("version"), [t[2].get("version") for t in tables]])
            continue

        start, end, fields = matches[0]
        common = text

        for left, right, _ in reversed(tables):
            common = common[:left] + "\n\n" + common[right:]

        # Text between tabber versions may only apply to one variant. Only append
        # shared prose after the tabber, unless the page has no tabber at all.
        if "</tabber>" in common.lower():
            common = re.split(r"</tabber>", common, flags=re.I)[-1]

        variables = {}

        for _, _, parts in templates(text):
            if parts[0].lower().startswith(("#vardefine:", "#vardefineecho:")) and len(parts) > 1:
                variables[parts[0].split(":", 1)[1].strip()] = parts[1]

        variables["kph"] = guide.get("kph", "the guide's rate")
        records.append({"page": guide["page"], "version": guide.get("version", ""),
                        "revision": guide["revision"], "activity": guide["activity"],
                        "location": fields.get("location", ""),
                        "details": paragraphs(fields.get("details", ""), variables),
                        "shared": paragraphs(common, variables)})

    (cache / "guide-draft.json").write_text(json.dumps({"records": records, "missing": missing}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"Drafted {len(records)} variants; {len(missing)} unmatched tables; "
          f"{sum(bool(r['details'] or r['shared']) for r in records)} have prose")
    return records


def fetch_locations(cache, records):
    """Cache the area articles explicitly linked by each guide's Location field.
    Redirects are retained so several guides can share one canonical area page.
    """
    output = cache / "location-pages.json"
    saved = json.loads(output.read_text(encoding="utf-8")) if output.exists() else {}
    titles = set()

    for record in records:
        location = record["location"]
        titles.update(link.split("#")[0].strip() for link in re.findall(r"\[\[([^]|]+)", location)
                      if not link.lower().startswith(("file:", "image:")))

        for _, _, fields in templates(location):
            if fields[0].casefold() in {"ilink", "il"} and len(fields) > 1:
                titles.add(fields[1])

        # A plain article title is common too ("Fort Forinthry", "Slayer Tower").
        plain = readable(location).strip()

        if plain and len(plain) < 65 and not re.search(r"[.\n,]|unresolved|\b(any|bank|portable|recommended|north|south|east|west|rotating|various|none|patch|altar)\b", plain, re.I):
            titles.add(plain)

    overrides_path = ROOT / "catalogue-source/research/guide-content-overrides.json"

    if overrides_path.exists():
        overrides = json.loads(overrides_path.read_text(encoding="utf-8"))
        titles.update(overrides.get("articles", []))

    missing = titles - set(saved)

    for group in wiki_methods.batches(missing, 40):
        response = wiki_methods.get({"action": "query", "prop": "revisions", "titles": "|".join(group),
                                    "redirects": 1, "rvprop": "ids|content", "rvslots": "main", "maxlag": 5})
        query = response.get("query", {})
        aliases = {r["from"]: r["to"] for r in query.get("normalized", []) + query.get("redirects", [])}
        pages = {p["title"]: p for p in query.get("pages", {}).values()}

        for title in group:
            resolved, seen = title, set()

            while resolved in aliases and resolved not in seen:
                seen.add(resolved)
                resolved = aliases[resolved]

            page = pages.get(resolved, {})
            revisions = page.get("revisions", [])

            if not revisions:
                saved[title] = {"title": resolved, "missing": True}
                continue

            revision = revisions[0]
            saved[title] = {"title": resolved, "revision": revision["revid"],
                            "text": revision["slots"]["main"]["*"]}

        output.write_text(json.dumps(saved, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"Cached {len(set(saved) & titles)}/{len(titles)} location articles", flush=True)

    return saved


def polish_paragraph(text, travel=False):
    """Clean editorial leftovers without rewriting game facts. Keep complete
    descriptive sentences, but turn obvious route-list fragments into directions.
    """
    text = re.sub(r"\s+", " ", text).strip()

    # These introduce a list on a web page; they aren't useful list entries.
    if text.endswith(":"):
        parts = re.split(r"(?<=[.!?])\s+", text)
        last = parts[-1]

        if re.search(r"(?:methods|options) (?:include|are)|following|ways (?:of|to)|(?:can|may) use:$|to reach .+ use:$", last, re.I):
            text = " ".join(parts[:-1])
        else:
            text = text[:-1] + "."

    if not text or re.fullmatch(r"[-=; ]+|Item Cost|Smelting Speed|Preparation", text, re.I):
        return ""

    if re.fullmatch(r"[a-z]+\)\.?", text) or re.match(r"Any travelling methods getting to", text, re.I):
        return ""

    if re.match(r"There are (?:several|multiple|\w+) (?:ways|methods)\b", text, re.I) and not re.search(r"\b(?:via|by|requires?|must|use|teleport)\b", text, re.I):
        return ""

    text = text.replace("Start in at ", "Start at ")
    text = text.replace("The outputs is ", "The outputs are ")

    if travel:
        # The shared Front articles all use this same wordy sentence. Its
        # destination and nearby landmark are preserved in the shorter wording.
        glider = re.fullmatch(r"Using a gnome glider to fly to (.+?) leaves the player very close to (.+?)\.?", text)

        if glider:
            text = "Take a gnome glider to " + glider[1] + ", then walk to " + glider[2].rstrip(".") + "."
        elif text.startswith("Via "):
            text = "Use " + text[4:]
        else:
            starts = {"Using": "Use", "Teleporting": "Teleport", "Walking": "Walk",
                      "Travelling": "Travel", "Traveling": "Travel", "Taking": "Take",
                      "Activating": "Activate", "Riding": "Ride", "Breaking": "Break"}
            match = re.match(r"^(?:By )?(" + "|".join(starts) + r") (.+)", text)

            # Don't break a complete gerund sentence ("Using X is fastest").
            if match and not re.search(r"\b(?:is|will|leaves|takes|brings|allows|puts|gets|gives)\b", match[2]):
                text = starts[match[1]] + " " + match[2]

        # A named teleport by itself is a valid route option, but reads more
        # naturally as an instruction. Descriptions with a finite verb stay as-is.
        is_instruction = re.match(r"(?:Use|Take|Teleport|Walk|Run|Head|Go|Travel|Ride|Cast|Break|Enter|Complete)\b", text, re.I)
        has_verb = re.search(r"\b(?:requires?|is|are|can|may|must|will|leads?|provides?|has|have|teleports)\b", text, re.I)

        if re.search(r"teleport|lodestone", text, re.I) and not is_instruction and not has_verb:
            first = text[0].lower() + text[1:] if text.startswith(("A ", "An ", "The ")) else text
            text = "Use " + first

    if text and text[-1] not in ".!?":
        text += "."

    return text


def travel_paragraphs(text):
    """Read an area's travel/access section, including its subheadings. Do not
    mistake a list of things found at a location for directions to that location.
    """
    headings = list(re.finditer(r"^(={2,})\s*(.*?)\s*\1\s*$", text, re.M))

    for index, heading in enumerate(headings):
        if not re.search(r"getting (?:there|here|to)|\btravell?ing\b|\btravel\b|transportation|^access$|^entrances?$|^locations?$", heading[2], re.I):
            continue

        end = len(text)

        for following in headings[index + 1:]:
            if len(following[1]) <= len(heading[1]):
                end = following.start()
                break

        candidates = paragraphs(text[heading.end():end], strict=True)

        if heading[2].casefold() in {"location", "locations"}:
            candidates = [p for p in candidates if re.search(r"teleport|lodestone|fairy ring|\b(?:north|south|east|west|entrance|access|reached)\b", p, re.I)]

        # Prefer actual access/travel text over isolated equipment names from an
        # altar's entry-items list. Introductory "methods include:" rows are not
        # routes and must not consume the four-option display budget.
        routes = []

        for candidate in candidates:
            if not re.search(r"teleport|lodestone|fairy ring|\b(?:walk|run|head|travel|travelling|entrance|access|reached|enter|equip|wear|bring|carry|use|take|climb|follow|requires?|required|needed|must|complete|completion|north|south|east|west)\b", candidate, re.I):
                continue

            wording = polish_paragraph(candidate, travel=True)

            if wording:
                routes.append(wording)

        if routes:
            return routes

    return []


def source_steps(record):
    """A concise source excerpt: complete useful paragraphs, with price and rate
    commentary left to Income. It is a summary, not a full strategy guide.
    """
    steps = []
    words = 0

    prose = record["details"] + record["shared"]

    if record["details"] and re.match(r"Then\b|Afterwards\b", record["details"][0]):
        # Some MMG tables put the final step in Details, with the full procedure
        # immediately after the table. Keep that procedure's order intact.
        prose = record["shared"] + record["details"]

    for paragraph in prose:
        # Keep summaries manageable. A long paragraph can be shortened at a whole
        # sentence boundary, never halfway through a condition or button name.
        sentences = re.split(r"(?<=[.!?])\s+(?=[A-Z])", paragraph)
        selected = []

        for sentence in sentences:
            if re.search(r"https?://|table below|!!|guide updates itself|high level variant of this guide", sentence, re.I):
                continue

            if re.match(r"(?:This|The) (?:profit|guide|method).*?(?:assumes|profit rate)|Beware of.*trade volume", sentence, re.I):
                continue

            if words + len(sentence.split()) > 230:
                break

            selected.append(sentence)
            words += len(sentence.split())

        if selected:
            step = polish_paragraph(" ".join(selected))

            if step and step not in steps:
                steps.append(step)

        if len(steps) >= 5 or words >= 200:
            break

    return steps


def write_content(cache):
    """Write the compact, inspectable maintainer input. Location articles are
    shared by name here; the existing runtime string pool shares their wording.
    Any unresolved destination stays partial instead of inventing a route.
    """
    records = inspect_guides(cache)
    pages = json.loads((cache / "location-pages.json").read_text(encoding="utf-8"))
    overrides_path = ROOT / "catalogue-source/research/guide-content-overrides.json"
    overrides = json.loads(overrides_path.read_text(encoding="utf-8")) if overrides_path.exists() else {}
    locations = {}
    route_overrides = {title.casefold(): routes for title, routes in overrides.get("locations", {}).items()}

    for alias, page in pages.items():
        if page.get("missing"):
            continue

        title = page["title"]
        routes = travel_paragraphs(page["text"])

        if title.casefold() in route_overrides:
            routes = [polish_paragraph(route, travel=True) for route in route_overrides[title.casefold()]]

        if routes:
            # Retain complete alternatives and their conditions, not just a
            # teleport's name with its quest/item requirement stripped away.
            locations[title] = {"revision": page["revision"], "routes": routes[:4]}

            if title in overrides.get("location_sources", {}):
                locations[title]["sources"] = [{"title": name, "revision": pages[name]["revision"]}
                                               for name in overrides["location_sources"][title]]

    aliases = {alias.casefold(): page["title"] for alias, page in pages.items() if not page.get("missing")}
    guides = []

    for record in records:
        override = overrides.get("guides", {}).get(record["page"], {})
        variant_override = override.get("versions", {}).get(record["version"], {})
        override = {**override, **variant_override}
        raw_location = override.get("location", record["location"])
        # Adjacent Wiki links otherwise render as "Herblore HabitatAnachronia".
        labelled_location = re.sub(r"(\]\]|\}\})\s*(?=\[\[|\{\{)", r"\1 / ", raw_location)
        location = re.sub(r"\s+", " ", readable(labelled_location)).strip()
        candidates = re.findall(r"\[\[([^]|#]+)", raw_location)
        candidates += [fields[1] for _, _, fields in templates(raw_location)
                       if fields[0].casefold() in {"ilink", "il"} and len(fields) > 1]
        candidates.append(location)
        candidates.extend(override.get("places", []))
        places = []

        for candidate in candidates:
            candidate = overrides.get("aliases", {}).get(candidate, candidate)
            title = aliases.get(candidate.strip().casefold())

            if title in locations and title not in places:
                places.append(title)

        steps = override.get("instructions", source_steps(record))

        if record["page"].startswith(("Money making guide/Killing ", "Money making guide/Completing ")):
            # PvM needs a concise activity reminder, not a copied boss strategy.
            # The selected variant, equipment and income tables supply the setup.
            activity = re.sub(r"\s+", " ", readable(record["activity"])).strip()
            activity = re.sub(r"^Killing\b", "Kill", activity)
            activity = re.sub(r"^Completing\b", "Complete", activity)
            notes = [step for step in steps if not re.search(r"mechanic|\btiles?\b|\battacks?\b|\babilities\b|revolution|prayer|soul split|animate dead|cannon position", step, re.I)]
            steps = [activity.rstrip(".") + ". Collect the drops listed in Outputs and restock supplies between trips."] + notes[:2]
        # A source Location field can be empty while its prose gives the route.
        # Keep those complete source sentences as travel text; don't infer a city
        # from an item, a monster name or a suggested piece of equipment.
        guide_routes = []

        for paragraph in record["details"] + record["shared"]:
            # A production bonus may mention a portable well without describing
            # any travel. Keep price/profit commentary out of this tab.
            sentences = [sentence for sentence in re.split(r"(?<=[.!?])\s+(?=[A-Z])", paragraph)
                         if not re.search(r"\b(?:profit|income|value is estimated|trade volume|scroll of cleansing|procs)\b", sentence, re.I)]
            note = " ".join(sentences)

            if re.search(r"\b(?:teleport(?:s|ing)?|lodestone|fairy ring|travel(?:ling|ing) (?:to|south|north|east|west)|travel to|located|can be found|can be killed at|situated|portable (?:well|crafter|fletcher|range))\b|\b(?:walk|run|head)\s+(?:north|south|east|west|to|towards|up|down|back)\b|\b(?:any|nearby|next to|at a)\s+(?:bank|anvil|furnace)\b", note, re.I):
                wording = polish_paragraph(note, travel=True)

                if wording:
                    guide_routes.append(wording)

        generic = bool(re.fullmatch(r"(?:any )?bank(?: or bank chest)?|bank or bank chest|anywhere(?: \(no banking necessary\))?|any", location, re.I))

        if "unresolved template" in location:
            location = ""

        entry = {"page": record["page"], "version": record["version"], "revision": record["revision"],
                 "instructions": steps, "location": location, "places": places}

        stationary = bool(re.search(r"\bany (?:location|anvil)|portable|bankstanding", location, re.I))

        if stationary:
            entry["stationary"] = True

        if override.get("travel"):
            entry["travel"] = override["travel"]
        elif generic:
            entry["travel"] = ["Use a convenient bank to withdraw the listed supplies and deposit the results." if "bank" in location.lower()
                               else "No fixed destination is specified for this method. Choose a convenient place for the activity."]
        elif guide_routes:
            entry["travel"] = guide_routes[:2]

        if override.get("sources"):
            entry["sources"] = override["sources"]

        guides.append(entry)

    document = {"schema": 1, "built": datetime.datetime.now(datetime.timezone.utc).date().isoformat(),
                "licence": "RuneScape Wiki contributors, CC BY-NC-SA 3.0.",
                "source": "Guide prose pinned to the income snapshot; area travel/access sections collected via api.php. "
                          "Complete sentences selected and markup removed; not full boss strategies.",
                "locations": locations, "guides": guides}
    output = ROOT / "catalogue-source/research/guide-content.json"
    output.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")
    print(f"Wrote {len(guides)} guide versions: {sum(bool(g['instructions']) for g in guides)} summaries; "
          f"{sum(bool(g['places'] or g.get('travel')) for g in guides)} with travel text; {len(locations)} shared areas")
    return document


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--build", action="store_true", help="build from the local cache without network requests")
    args = parser.parse_args()

    if args.build:
        write_content(args.cache)
    else:
        fetch_guides(args.cache)
        records = inspect_guides(args.cache)
        fetch_locations(args.cache, records)


if __name__ == "__main__":
    main()
