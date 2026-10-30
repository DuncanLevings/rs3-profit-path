"""Research the price-dependent choices in Wiki shop-run guides.

Writes the "shops" part of catalogue-source/research/income-choices.json. Run by
hand after a Wiki re-import changes one of these guides; the plugin never talks
to the Wiki.
"""
# Developer tool, never shipped with the plugin.
#
# Why this exists: a guide like "Buying runes" buys each item only while the
# shop price is below the GE price. The Wiki works that out on every page view,
# but the money_making_guide bucket only has the answer from the day we import,
# so a rune that wasn't worth buying then stays at 0 forever. Instead we keep
# each item's shop stock and price, and the plugin decides from live prices.
#
# How it gets the numbers without writing a wikitext interpreter: it asks the
# Wiki itself to expand each output's quantity twice (action=expandtemplates),
# once with every {{GEP}} forced very high (so every "buy it?" test passes) and
# once with it forced to 0 (so every test fails). The difference is the shop
# stock; what's left with the test failing is anything you get anyway (Mega shop
# run's free runes). {{GEValue}}, the item's value, is what the guides use as the
# shop price, so that's expanded as-is.
#
# merge_methods.py checks the result against the imported guide: every item's
# imported quantity must be its "bought" or "not bought" amount, and the guide's
# Coins must be exactly the stock times price of the items it bought.
from __future__ import annotations

import argparse
import datetime
import json
import re
import time
import urllib.parse
import urllib.request

import wiki_methods

RESEARCH = wiki_methods.ROOT / "catalogue-source" / "research" / "income-choices.json"

# Guides that buy each item from shops only while it's worth it.
SHOP_GUIDES = (
    "Money making guide/Buying runes",
    "Money making guide/Mega shop run",
    "Money making guide/Buying feathers",
    "Money making guide/Buying items from farm shops",
    "Money making guide/Buying vials of water",
    "Money making guide/Buying yak-hide",
    "Money making guide/Buying supplies from the Stonemason",
)

# Stands in for a GE price that beats any shop price.
HIGH = "1000000000"


def fetch_wikitext(pages):
    """{page: (revision, wikitext)} for the guide pages, in one request."""
    data = wiki_methods.get({"action": "query", "prop": "revisions", "rvprop": "ids|content", "rvslots": "main",
                             "formatversion": "2", "titles": "|".join(pages)})
    result = {}

    for page in data["query"]["pages"]:
        revision = page["revisions"][0]
        result[page["title"]] = (revision["revid"], revision["slots"]["main"]["content"])

    return result


def expand(page, text):
    """The Wiki's own expansion of some wikitext, as if it were on `page`. Sent as
    a POST: Mega shop run's 51 items make a URL too long for a GET.
    """
    body = urllib.parse.urlencode({"action": "expandtemplates", "title": page, "text": text,
                                   "prop": "wikitext", "format": "json"}).encode("utf-8")
    request = urllib.request.Request(wiki_methods.API, data=body, headers={"User-Agent": wiki_methods.USER_AGENT})

    with urllib.request.urlopen(request, timeout=60) as response:
        data = json.loads(response.read().decode("utf-8"))

    time.sleep(wiki_methods.REQUEST_GAP)

    if not isinstance(data, dict) or "error" in data:
        raise ValueError(f"Wiki request failed: {data.get('error') if isinstance(data, dict) else data}")

    return data["expandtemplates"]["wikitext"]


def versions(wikitext):
    """[(version, template text)]: one per tab of a tabbed guide, else one ("", text)."""
    if "<tabber>" not in wikitext:
        return [("", wikitext)]

    body = wikitext.split("<tabber>", 1)[1].split("</tabber>", 1)[0]
    result = []

    for tab in body.split("|-|"):
        version = re.search(r"\|\s*Version\s*=\s*([^\n|]+)", tab)
        result.append((version.group(1).strip() if version else tab.split("=", 1)[0].strip(), tab))

    return result


def fields(text):
    """The template's fields, {name: text}. "Output counter" numbering (Output{{+=...}})
    is replaced by the number it stands for, so every output has a plain name.
    """
    counter = 0
    lines = []

    for line in text.split("\n"):
        if "{{+=|Output counter|1|echo=1}}" in line:
            counter += 1
            line = line.replace("{{+=|Output counter|1|echo=1}}", str(counter))

        lines.append(line.replace("{{#var:Output counter}}", str(counter)))

    result, current = {}, None

    for line in lines:
        match = re.match(r"\|\s*([A-Za-z][A-Za-z0-9 ]*?)\s*=(.*)", line)

        if match:
            current = match.group(1)
            result[current] = match.group(2)
        elif current:
            result[current] += "\n" + line

    return result


def shop_items(page, text):
    """[{name, stock, free, price}] for every output whose amount depends on prices."""
    found = fields(text)
    defines = found.get("Define variables", "")

    outputs = []
    number = 1

    while f"Output{number}" in found:
        outputs.append((found[f"Output{number}"].strip(), found.get(f"Output{number}num", "0")))
        number += 1

    def amounts(price):
        # One request: every output's amount, one per line, with GE prices forced.
        forced = re.sub(r"\{\{\s*(GEP|GEVolume)\s*\|[^{}]*\}\}", price, defines + "\n" +
                        "\n".join(f"@@{index}@@{{{{#expr:{amount}}}}}" for index, (_, amount) in enumerate(outputs)))
        values = dict(re.findall(r"@@(\d+)@@\s*([-\d.eE+]+)", expand(page, forced)))

        if len(values) != len(outputs):
            raise ValueError(f"{page}: couldn't expand every output amount")

        return [float(values[str(index)]) for index in range(len(outputs))]

    bought, skipped = amounts(HIGH), amounts("0")

    # Shop prices: the guides use {{GEValue}}, the item's value.
    names = [name for (name, _), buy, skip in zip(outputs, bought, skipped) if buy != skip]
    prices = dict(re.findall(r"@@(.+?)@@\s*([\d.]+)",
                             expand(page, "\n".join(f"@@{name}@@{{{{GEValue|{name}}}}}" for name in names))))
    items = []

    for (name, _), buy, skip in zip(outputs, bought, skipped):
        if buy == skip:
            continue

        if name not in prices:
            raise ValueError(f"{page}: no shop price for {name}")

        def whole(value):
            return int(value) if value == int(value) else value

        items.append({"name": name, "stock": whole(buy - skip), "free": whole(skip), "price": whole(float(prices[name]))})

    return items


def research_shops():
    document = json.loads(RESEARCH.read_text(encoding="utf-8")) if RESEARCH.exists() else {"schema": 1, "guides": []}

    # Hand-researched choices (alternatives) are kept; shop entries are redone.
    kept = [entry for entry in document["guides"] if "shops" not in entry]
    shops = []

    for page, (revision, wikitext) in sorted(fetch_wikitext(SHOP_GUIDES).items()):
        for version, text in versions(wikitext):
            items = shop_items(page, text)
            print(f"{page} {version or '(no version)'}: {len(items)} shop items")
            shops.append({"page": page, "version": version, "revision": revision, "shops": items})

    document["guides"] = shops + kept
    document["shops_retrieved"] = datetime.date.today().isoformat()
    RESEARCH.write_text(json.dumps(document, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.parse_args()
    research_shops()


if __name__ == "__main__":
    main()
