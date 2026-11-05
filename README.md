# Profit Path

An RS3 plugin for planning money making. It lists every RuneScape Wiki money making guide (674 activities), works out each one's profit from live Grand Exchange prices, checks the guide's requirements against your account, and can suggest an activity that suits you.

It is a planning tool only. It sends no game inputs, gives no live combat or movement advice, and opens no links. Status: development build (`plugin.json` version ends in `-dev`); not submitted, and no approval is implied.

## What the player sees

The **Open Profit Path** button in the Plugins ribbon opens a separate, resizable window with four sidebar sections:

- **Browse**: every activity, by group (PvM, Skilling, Production, Recurring), with search, Profit or ROI sort, and Intensity, Requirements and Difficulty filters. Ten rows per page.
- **Recommend for me**: pick a group, get one suggestion at a time with the reasons for it. **Show another** moves on; **Don't recommend** skips that exact activity from now on (with Undo).
- **Favourites**: the activities you starred, with the same sorting and filters.
- **My account**: which character and profile your settings belong to, Recommend for me's settings (PvM comfort 1-10, harder "learning" suggestions, solo/group), and the activities you chose not to have recommended.

Opening an activity shows four tabs: **Income** (inputs, outputs, profit, ROI and an editable rate you can save or reset), **Requirements** (the guide's own wording, with what your account meets), **How to do it** and **Getting there**.

## Reviewer guide

### Entry point and lifecycle

`main.lua` (required by the client at the plugin root) calls `require("src/main").start()` and hands the returned shutdown function to `PluginShutdown`. `src/main.lua` builds everything once per enable and owns the `ContentLayerReady` subscription that mounts the ribbon launcher.

Shutdown order: mark inactive, unsubscribe `ContentLayerReady`, `account:destroy()` (unsubscribes every client event, drops caches, flushes and unbinds the saved item snapshot), then `view:destroy()` (stops per-tick work, releases views, destroys the window and launcher). Each destroy is safe to call twice.

A game-state change (login, logout, world hop) destroys the window, because its native parent may have been replaced; the player reopens it from the ribbon.

### Modules

| File | Owns |
|---|---|
| `src/main.lua` | Wiring, the calculator state behind the method screen, which account evidence the catalogue needs |
| `src/game/account.lua` | All client event subscriptions and native account reads (skills, quests, unlock flags, achievements, backpack/worn/bank, tool belt) |
| `src/game/toolbelt.lua` | Tool-belt hatchet/pickaxe/mattock reads through the client's own item enums |
| `src/game/requirements.lua` | Pure met / unmet / unknown evaluation of requirement trees (no client calls) |
| `src/methods/income.lua` | GEPL price reads and the profit/ROI arithmetic |
| `src/methods/loot.lua`, `recipe_cost.lua` | Expected PvM loot from shared drop tables; creation cost of untradeable supplies |
| `src/methods/browser.lua` | Browse filters, sorting, paging and the return-to-list position |
| `src/methods/recommendations.lua` | Candidate filtering, ordering and rotation for Recommend for me |
| `src/storage/preferences.lua` | Every saved setting (keys below) |
| `src/storage/account_snapshot.lua` | Saved catalogue-relevant item counts per profile (stands in for a closed bank) |
| `src/data/method_data.lua`, `monster_data.lua` | Readers for the packed generated data in `data/` |
| `src/ui/workbench.lua` | Launcher, window, navigation and the resize watch |
| `src/ui/browse_view.lua`, `method_view.lua` | The Browse/Recommend/Favourites/My account screens and the activity tabs |
| `src/ui/dropdown.lua`, `item_icon.lua`, `view_style.lua` | Dropdown workarounds, validated item icons, shared colours and formatting |

### Event flow

`account.lua` subscribes (under one name, `profit-path-account`) to `InventoryAdded`, `InventoryUpdated`, `InventoryRemoved`, `VarTransmit`, `SkillTransmit` and `GameStateChanged`. Each event only marks its kind of evidence stale and tells `main.lua` the reason (`inventory`, `skills`, `quests`, `game_state`). While the window is visible, `main.lua` re-reads just that kind and re-evaluates requirements, and the screen updates labels in place.

Per-tick work uses `Event.Logic` and always stops itself:

| Subscription | Runs while | Stops when |
|---|---|---|
| `profit-path-resize` | the window is open and visible | hidden, closed or destroyed |
| `profit-path-method-build` | an activity page is still drawing its later rows (`ROWS_PER_STEP` per tick) | drawing ends, a row fails, or the page is left |
| `profit-path-search` | the player is typing in search (redraws after 12 quiet ticks) | it redraws, or the screen is released |
| `profit-path-recommend` | Show another's 25-tick pause | it picks, or the screen is released |
| `profit-path-dropdown-*`, `profit-path-version` | one tick after a dropdown change | after that tick, or on release |

There is no gameplay polling. Late button callbacks are ignored using a per-screen generation counter (`workbench.lua`).

### One feature end to end: opening an activity

1. A Browse row's open button calls the workbench, which swaps only the content view (the window keeps its place and size).
2. `calculator:select(method)` captures one set of GEPL quotes for that activity and loads its saved rate (`preferences:loadRate`), then `Income.calculate` produces the inputs, outputs, net profit and ROI.
3. `method_view.lua` draws the header and the visible part of the tab, then the rest over the next ticks.
4. The Requirements tab uses `Requirements.evaluateAccess` on the same evidence Browse uses. Missing evidence is "unknown", never "not met".
5. Typing a rate previews it using the captured quotes (no new price reads); **Save** writes one key; **Reset** deletes it.
6. **Back** restores the Browse section, filters, search, sort, page and scroll position.

### Client workarounds

- **Dropdowns** (`dropdown.lua`): entry IDs must count from 0, and the selection is read one tick after the change hook with `GetEntrySelected(id)`, because `selectedEntries` returned numbers that didn't match our IDs.
- **Resize** (`workbench.lua`): the native `ONRESIZE` hook didn't fire for PrettyUI window resizes, so the visible window's content size is compared once per tick, and the screen is rebuilt after it holds for 15 ticks.
- **No `utf8` global** in the client; the tests run with it removed.
- **Native dynamic IDs**: the client has 4,096 shared by every plugin, and PrettyUI builds each tooltip up front (about 11 IDs each), so activity pages draw in steps and use tooltips sparingly. The Mega Shop Run guide is left out of the catalogue because its page alone ran out of IDs.
- **Item IDs** are checked against the client's own item name before an icon is shown or ownership counts.

### Requirement checks and their limits

Checks the plugin can read: base skill levels, combat level, quest completion (verified non-deprecated quest config names), unlock flags (relics, codices and other game variables found in the client), achievements, item ownership across backpack, worn gear and bank, tool-belt hatchets/pickaxes/mattocks, and tiered gear groups.

The bank can only be read while it is open, so a closed bank counts as it was last seen open (this login, or the copy saved for the character). Saved backpack and worn data are only hints.

Some requirements the game doesn't expose to plugins (Invention perks, some places and machines, shop upgrades, "be skulled"). These are listed on the activity page as neutral lines to check yourself, and are left out of the overall Met / Missing verdict. That is a deliberate trade-off: otherwise most activities could never read as Met.

### Data sources

All activity data is bundled, generated by maintainer tools from a pinned snapshot; the plugin never contacts the Wiki at runtime.

- RuneScape Wiki money making guides, recipes, item, outfit and area pages, and guide warnings (CC BY-NC-SA 3.0, with revisions recorded).
- A monster drop snapshot inherited from the author's Monster Lookup plugin (Wiki-derived).
- PvM difficulty ratings (1-10) from the author's research using PvME (CC BY-NC-SA 4.0), Wiki and community sources; one evidence note per rating in `catalogue-source/research/difficulty.json`.

Attribution and licences are in `THIRD_PARTY_NOTICES.txt`.

### Persistence

Everything is stored in the client's `PersistentDB` on this computer. Keys (treat them as a contract):

| Key | Holds |
|---|---|
| `profit-path.profile.v1` | The last selected profile |
| `profit-path.characters.v1` | Which character display name uses which profile |
| `profit-path.browser.v1` | Sort choice (device-wide) |
| `profit-path.rate.v1/<profile>/<method>/<unit>` | One saved personal rate per activity |
| `profit-path.favourites.v1/<profile>` | Favourites |
| `profit-path.hidden.v1/<profile>` | Activities not to recommend |
| `profit-path.recommend.v1/<profile>` | Recommend for me settings and rotation history (bounded by the catalogue) |
| `profit-path.account.v1/<profile>` | Saved item counts for catalogue items only, per container (capped) |

Unreadable records are never overwritten; write failures are shown and can be retried.

### Permissions, network and data disclosure (draft)

- **Permissions requested:** none. `test.py` fails if one is added to `plugin.json`.
- **Network:** Profit Path makes no requests itself. Prices come from GE Prices Library, which owns its own HTTP access and cache.
- **Game data read:** your character's visible display name (to keep settings per character; the tracking ID is never read), skill levels, combat level, quest completion, specific unlock and achievement values, and counts of catalogue items in your backpack, worn equipment, bank and tool belt.
- **Stored:** the settings and item counts listed above, locally only. Nothing is sent anywhere.

### Dependencies

| Dependency | Use | Manifest today |
|---|---|---|
| PrettyUI 1.2.0 | All UI | Plugin Hub ID 6398181 |
| GE Prices Library 0.3.1 | Every price | Development folder `gepl` |
| rsprite 0.1.2 | Icon sprites by name | Development folder `rsprite` (not on the Plugin Hub yet) |

The two development-folder dependencies must become Plugin Hub IDs before submission; `package.py build` lists this.

## Development

### Setup

Use the RS3 plugin beta. Put this folder in `dev_plugins` as `profit-path`, with GEPL in `dev_plugins/gepl` and rsprite in `dev_plugins/rsprite`, and PrettyUI installed. Enable the dependencies in the client yourself, then reload Profit Path.

### Tests

Install `requirements-dev.txt` (lupa), then:

```text
python src/tools/test.py
```

This checks the Markdown policy (only this file and `CHANGELOG.md`), the manifest (no permissions or URLs), Lua 5.4 syntax for every file, the Lua behaviour tests (with fake client and PrettyUI objects), the generated data against its sources, and the Python tool tests. Passing tests do not replace checking in game.

### Release package

```text
python src/tools/package.py build
python src/tools/package.py check-install PATH
```

`build` writes `dist/profit-path-<version>.zip` with only the runtime files (`main.lua`, `plugin.json`, `CHANGELOG.md`, `THIRD_PARTY_NOTICES.txt`, `data/*.lua` and `src/` Lua outside `src/tests` and `src/tools`), byte-for-byte repeatable, and prints anything in the manifest that blocks submission. `check-install` compares an install folder with those files by SHA-256 and lists any that differ, are missing, or don't belong.

### Catalogue data

`data/*.lua` is generated; edit the sources in `catalogue-source/` and rebuild:

```text
python src/tools/catalogue.py build     # merge, validate and write data/*.lua
python src/tools/catalogue.py verify    # regenerate in memory and compare
python src/tools/catalogue.py report    # coverage and what to research next
```

- `catalogue-source/wiki/` is the Wiki guide snapshot (`guides.jsonl`, `meta.json`, `warnings.json`), written by `src/tools/wiki_methods.py`.
- `catalogue-source/recipes.json` holds creation-cost recipes, written by `wiki_recipes.py`.
- `catalogue-source/methods.json` holds the hand-curated activities, which replace their Wiki guide.
- `catalogue-source/research/` holds the hand-checked research: requirement capabilities and unlock flags, quest config names, outfits, gear tiers, PvM difficulty, team sizes, price choices, and guide text overrides.
- `catalogue-source/monsters.json` is the monster snapshot, imported with `catalogue.py import-monsters --from PATH`.

`src/tools/merge_methods.py` turns the snapshot and research into the shipped records and refuses anything inconsistent. Examples: a PvM activity without a difficulty rating, a rating outside 1-10, a price choice that doesn't reproduce its guide, or a warning whose page has no activity. `guide_content.py` builds the How to do it and Getting there text from a cache of pinned Wiki pages kept outside the repo.

Wiki collection is a deliberate maintainer step, never part of the plugin. It follows the Wiki's plugin-data guidance: Bucket/MediaWiki APIs only, at most one request per second, cached responses, recorded revisions, and the User-Agent `ProfitPath-development (Discord: Tatsuya)`.

### Pricing rules (summary)

- Supplies use GEPL's instant-buy price and outputs its instant-sell price, averaged over the last hour.
- A side with no trades in the hour falls back to its latest trade, unless that trade is more than 3x away from the other side's average.
- Output tax is rounded down per item.
- ROI is net profit divided by supply cost. With zero cost it is shown as not applicable.
- When most of a side's market items are priced, a missing price counts as 0 GP and is named in the status line.
- Untradeable supplies are priced by their recipe's ingredients.
- Wiki guides that choose between options from prices (shop runs, 3- vs 4-dose potions) choose again from live prices.

## Known limitations

- Gear tier checks cover the bundled tier lists; other tool-belt categories and storage outside the backpack, worn gear and bank (e.g. Diango) aren't read.
- Unlocks the game doesn't expose stay as "check yourself" lines (see Requirement checks).
- A character display-name change looks like a new character; the old settings stay saved under the old name.
- Window position isn't remembered across reloads.
- Profit is an estimate from the Wiki's rates and current GE prices, not a promise.
