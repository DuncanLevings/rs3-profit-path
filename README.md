# Profit Path

An RS3 plugin for planning money making. It lists every RuneScape Wiki money making guide (674 activities), works out each one's profit from live Grand Exchange prices, checks the guide's requirements against your account, and can suggest an activity that suits you.

It is a planning tool only. It sends no game inputs, gives no live combat or movement advice, and opens no links. Status: development build (`plugin.json` version ends in `-dev`); not submitted, and no approval is implied. Contact: Tatsuya636@hotmail.com.

## What the player sees

The **Open Profit Path** button in the Plugins ribbon opens a separate, resizable window with four sidebar sections, a **Create activity** button (which opens the custom activity editor) and an **Import activity** button (which takes an activity someone shared):

- **Browse**: every activity, bundled and your own custom ones, by group (PvM, Skilling, Production, Recurring), with search, Profit or ROI sort (highest first), Show (All or Custom only), and Intensity, Requirements and Difficulty filters. Ten rows per page.
- **Recommend for me**: pick a group, get one suggestion at a time with the reasons for it. **Show another** moves on; **Don't recommend** skips that exact activity from now on (with Undo). Your custom activities are suggested too, once the game confirms every Required check; a custom PvM activity is rated 1-10 in the editor and checked against your PvM comfort like a bundled boss.
- **Favourites**: the activities you starred, with the same sorting and filters.
- **My account**: a full-width page showing which character and profile your settings belong to, Recommend for me's settings (PvM comfort 1-10, harder "learning" suggestions, solo/group), and the activities you chose not to have recommended. Back returns to the previous list or recommendation.

Opening an activity shows four tabs: **Income** (inputs, outputs, profit, ROI and an editable rate you can save or reset), **Requirements** (the guide's own wording, with what your account meets), **How to do it** and **Getting there**.

A custom activity's page also has **Edit**, **Delete** and **Export** in its header. Export shows the activity as one line of text to copy (Ctrl+A, Ctrl+C) and send to someone. Import checks a pasted line and shows what it holds before **Add as new activity** saves it. Only the recipe is shared: no profile, favourites, saved rates, account details, your own GE prices or profit figures.

## Reviewer guide

### Entry point and lifecycle

`main.lua` (required by the client at the plugin root) calls `require("src/main").start()` and hands the returned shutdown function to `PluginShutdown`. `src/main.lua` builds everything once per enable and owns the `ContentLayerReady` subscription that mounts the ribbon launcher.

Shutdown order: mark inactive, unsubscribe `ContentLayerReady`, `account:destroy()` (unsubscribes every client event, drops caches, flushes and unbinds the saved item snapshot), then `view:destroy()` (stops per-tick work, releases views, destroys the window and launcher). Each destroy is safe to call twice.

A game-state change (login, logout, world hop) destroys the window, because its native parent may have been replaced; the player reopens it from the ribbon.

### Modules

| File | Owns |
|---|---|
| `src/main.lua` | Wiring, the calculator state behind the method screen, which account evidence the catalogue needs |
| `src/game/account.lua` | All client event subscriptions and native account reads (display name, skills, quests, unlock flags, achievements, backpack/worn/bank, tool belt) |
| `src/game/toolbelt.lua` | Tool-belt hatchet/pickaxe/mattock reads through the client's own item enums |
| `src/game/requirements.lua` | Pure met / unmet / unknown evaluation of requirement trees (no client calls) |
| `src/methods/income.lua` | GEPL price reads and the profit/ROI arithmetic |
| `src/methods/loot.lua`, `recipe_cost.lua` | Expected PvM loot from shared drop tables; creation cost of untradeable supplies |
| `src/methods/browser.lua` | Browse filters, sorting, paging and the return-to-list position |
| `src/methods/recommendations.lua` | Candidate filtering, ordering and rotation for Recommend for me |
| `src/methods/custom_draft.lua` | The custom activity editor's working copy: loading drops from a monster or thieving target, the three row states, drops left out at the limit, Duplicate as custom and the preview |
| `src/ui/method_editor.lua` | The custom activity editor screen (the activity page's tabs plus Outputs and Supplies, profit band, item table, searches that wait for a pause in typing) |
| `src/methods/custom_share.lua` | Sharing custom activities: the `PP1:` share line (short field names, escaped text, an FNV-1a checksum), a strict reader that only builds known fields, and GE item names left out when they match the bundled list, the import review (the same checks as a save, plus warnings for unknown GE items and quests) |
| `src/ui/share_view.lua` | The Export screen (the line in a box that puts itself back if typed in) and the Import screen (paste box, review, Add as new activity) |
| `src/methods/custom_methods.lua` | Custom activities: record checks and size limits, conversion to the shared method shape, and storage. Saved ones show in Browse (Show: Custom only lists just them) and Favourites |
| `src/storage/preferences.lua` | Every saved setting (keys below) |
| `src/storage/account_snapshot.lua` | Saved catalogue-relevant item counts per profile (stands in for a closed bank) |
| `src/data/method_data.lua`, `monster_data.lua` | Readers for the packed generated data in `data/` |
| `src/data/thieving_data.lua`, `item_names.lua` | Readers for thieving loot (same format as the monster snapshot) and GE item names (the custom activity editor's item search) |
| `src/data/unlock_data.lua` | Reader for `data/unlocks.lua`: every current quest plus a reviewed list of unlocks (prayers, spellbooks, relics, abilities, diaries), each with the same check bundled activities use, for the custom activity editor's "Quest or unlock" search |
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
- **Native dynamic IDs**: the client has 4,096 shared by every plugin, and PrettyUI builds each tooltip up front (about 11 IDs each), so activity pages draw in steps and use tooltips sparingly. The Mega Shop Run guide is left out of the catalogue because its page alone ran out of IDs. Custom activities are capped (40 outputs, 15 supplies) so their page stays under 60% of that page's tooltips: their rows keep the item icon's tooltip but not a per-row price note, and the editor draws 8 rows at a time, with tooltips only on each row's item icon, remove button and (drops with a note) On/Off button. Each row's "About 2.4 an hour" line is plain text, with no tooltip. On a custom page, item requirements show the item's picture beside a line that names it, and item groups list their items in the line, so neither adds a tooltip; the budget test includes a full requirements list. The test fake counts parts and tooltips (src/tests/custom_editor.lua); that's a relative measure, not the client's real ID count.
- **Item IDs** are checked against the client's own item name before an icon is shown or ownership counts.
- **Sharing** (`custom_share.lua`): plugins have no clipboard or file API, so activities are shared as text in an InputField. A probe plugin (5 Nov 2026) found that a box holds at most 9,999 characters whatever `maxLength` asks for, that a line break cuts the text, and that Ctrl+C and Ctrl+V keep the text exactly. So the share line is one line of printable ASCII of at most 9,998 characters, and a 9,999-character paste is refused as possibly cut off. GE item names that match the bundled GE list are left out of the line and filled back in from the list on import (an item the list lacks comes in as "Item <id>", with a warning), so a typical monster activity is about 2,200 characters. One with long notes on every row, or every requirement a full item group, can still go over the limit. The editor's profit band shows the share size from 8,500 characters ("Share code: 8,700 of 9,998 characters", red when over), and Export then says what to shorten. The text limits weren't lowered: bundled steps and directions already run past them (up to about 1,250 characters, shortened on Duplicate), and saved activities must keep loading.

### Requirement checks and their limits

Checks the plugin can read: base skill levels, combat level, quest completion (verified non-deprecated quest config names), unlock flags (relics, codices and other game variables found in the client), achievements, item ownership across backpack, worn gear and bank, tool-belt hatchets/pickaxes/mattocks, and tiered gear groups.

The bank can only be read while it is open, so a closed bank counts as it was last seen open (this login, or the copy saved for the character). Saved backpack and worn data are only hints.

Some requirements the game doesn't expose to plugins (Invention perks, some places and machines, shop upgrades, "be skulled"). These are listed on the activity page as neutral lines to check yourself, and are left out of the overall Met / Missing verdict. That is a deliberate trade-off: otherwise most activities could never read as Met.

### Data sources

All activity data is bundled, generated by maintainer tools from a pinned snapshot; the plugin never contacts the Wiki at runtime.

- RuneScape Wiki money making guides, recipes, item, outfit and area pages, and guide warnings (CC BY-NC-SA 3.0, with revisions recorded).
- A monster drop snapshot inherited from the author's Monster Lookup plugin (Wiki-derived).
- RuneScape Wiki GE item names and thieving loot (pickpocket NPCs and stalls), for custom activities (not used by the plugin yet).
- PvM difficulty ratings (1-10) from the author's research using PvME (CC BY-NC-SA 4.0), Wiki and community sources; one evidence note per rating in `catalogue-source/research/difficulty.json`.

Attribution and licences are in `THIRD_PARTY_NOTICES.txt`.

### Persistence

Everything is stored in the client's `PersistentDB` on this computer. Keys (treat them as a contract):

| Key | Holds |
|---|---|
| `profit-path.profile.v1` | The last selected profile |
| `profit-path.characters.v1` | Which character display name uses which profile (the first character keeps the existing profile; later ones are "Character 2", "Character 3"...; builds before 0.8.30 named them after the character) |
| `profit-path.browser.v1` | Sort choice (device-wide) |
| `profit-path.rate.v1/<profile>/<method>/<unit>` | One saved personal rate per activity |
| `profit-path.favourites.v1/<profile>` | Favourites |
| `profit-path.hidden.v1/<profile>` | Activities not to recommend |
| `profit-path.recommend.v1/<profile>` | Recommend for me settings and rotation history (bounded by the catalogue) |
| `profit-path.custom.v1/index` | Custom activity list and the next unused ID (shared by every profile; IDs are never reused) |
| `profit-path.custom.v1/custom.<n>` | One custom activity per key (shared by every profile) |
| `profit-path.account.v1/<profile>` | Saved item counts for catalogue items only, per container (capped) |

Unreadable records are never overwritten; write failures are shown and can be retried.

### Submission disclosure (draft)

Written to the section headings of Jagex's submission example (developer.runescape.com/rs/submission/example.html). Not submitted yet.

- **Email:** Tatsuya636@hotmail.com (also `contactEmailAddress` in `plugin.json`).
- **Feedback and collaboration:** in the plugin's channel on the RuneScape Plugin Portal Discord (channel link to add once it exists), or by the email above.
- **EULA:** Profit Path uses software licensed by Jagex under the Jagex EULA (https://legal.jagex.com/docs/terms/eula); all development and use of the plugin is subject to it.
- **Permissions:** none requested (no HttpAccess, chatAccess or trackingAccess). `test.py` fails if one is added. trackingAccess was tried in 0.8.30-dev to key settings by tracking ID, but `Player.GetTrackingID()` crashes this client every time (see Known limitations). Prices come from the separately installed GE Prices Library, which requests its own HttpAccess; Profit Path makes no network requests itself.
- **Data Protection:** nothing is transmitted anywhere. What is read: your character's visible display name (to keep settings per character; the tracking ID is never read), skill levels, combat level, quest completion, specific unlock and achievement values, and counts of catalogue items in your backpack, worn equipment, bank and tool belt. What is stored locally between sessions: the settings in the table above, the display-name-to-profile link, and per-profile counts of catalogue items (so a closed bank can be counted). **Open question:** the example's case 1 (no transmission) says game information isn't stored between sessions, and Profit Path does keep the display name and item counts. Confirm with Jagex which case applies, or drop that storage, before submitting.

### Dependencies

| Dependency | Use | Manifest today |
|---|---|---|
| PrettyUI 1.2.0 | All UI | Plugin Hub ID 6398181 |
| GE Prices Library | Every price | Plugin Hub ID 6414886 |
| rsprite 0.1.2 | Icon sprites by name | Development folder `rsprite` (not on the Plugin Hub yet) |

rsprite must become a Plugin Hub ID before submission; `package.py build` lists this.

## Development

### Setup

Use the RS3 plugin beta. Put this folder in `dev_plugins` as `profit-path`, with rsprite in `dev_plugins/rsprite`, and PrettyUI and GE Prices Library installed from the Plugin Hub. Enable the dependencies in the client yourself, then reload Profit Path.

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
- `catalogue-source/research/` holds the hand-checked research: requirement capabilities and unlock flags, quest config names (plus `quest-list.json`, every current quest, and `custom-unlocks.json`, the unlocks the custom activity editor offers; `catalogue.py map-quests` writes both quest files), outfits, gear tiers, PvM difficulty, team sizes, price choices, and guide text overrides.
- `catalogue-source/monsters.json` is the monster snapshot, imported with `catalogue.py import-monsters --from PATH`.
- `catalogue-source/ge-items.json` and `thieving.json` hold GE item names and thieving loot, written by `src/tools/wiki_drop_sources.py items` and then `thieving` (in that order: the item list decides which drops are sellable).

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
- Window position isn't remembered across reloads.
- A display-name change looks like a new character; the old settings stay saved under the old name.
- Settings can't follow a renamed character: the documented `Player.GetTrackingID()` (trackingAccess) crashes the RuneScape client on every call (traced in 0.8.32-dev: `Plugin.HasPermission` returns true, then the client dies inside `GetTrackingID`). Profit Path never calls it; revisit once Jagex fixes it.
- Profit is an estimate from the Wiki's rates and current GE prices, not a promise.
- A very large custom activity (long notes on every row, or every requirement a full item group) can be too big to export; the box holds 9,999 characters. The editor warns from 8,500.
