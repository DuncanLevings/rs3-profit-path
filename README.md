# Profit Path

An RS3 plugin for finding money-making methods suited to your account.

Early development: version 0.4.12-dev contains an independent resizable workbench with a sidebar, searchable three-method browser, favourites, dedicated method tabs and the first income calculator. Method rows now separate titles, compact profit figures and actions; sidebar highlights show the selected section and activity. Income has a compact results band and side-by-side input/output tables; Requirements groups Skills, Required items, Recommended items, Quests and Other, colouring confirmed text checks green or red. Item lists use native icons with name-only tooltips; missing ROI text is omitted. The full catalogue and recommendations are still in development. It sends no game inputs and stores character bindings, personal method rates, character-specific favourites and a device-wide sort choice.

## Project layout

Runtime Lua, tests and build tools live under `src/`. The root `main.lua` only starts the app and exposes its shutdown hook because the client requires that entry point. `data/` stays at the top level, alongside the manifest, readable JSON sources and notices. Install the runtime files (`main.lua`, Lua modules within `src/`, `data/*.lua`, manifest and notices), excluding `src/tests/` and `src/tools/`. UI code is in `src/ui/`; native account reads and requirement checks in `src/game/`; browsing/calculations in `src/methods/`; preferences in `src/storage/`; the monster reader in `src/data/`.

## Development setup

Use the RS3 plugin beta. Put the project folder in its `dev_plugins` directory as `profit-path`. Install PrettyUI (6398181) and rsprite 0.1.2 in the adjacent `rsprite` development folder. After installing or changing dependency manifests, manually rescan plugins (`prf`), load/reload rsprite (`prl rsprite`), then reload Profit Path (`prl profit-path`). rsprite is not yet on the Plugin Hub; the manifest currently uses its development-folder dependency. For the optional quote check, put GE Prices Library 0.3.1 in the adjacent `gepl` development folder and enable it through the client. This build does not enable dependencies or grant permissions itself. GEPL owns its HTTP access; its quote getter may refresh its cache.

Enable or reload `profit-path` and open its ribbon panel in the Plugins window. Click **Open Profit Path** to open the separate in-game window; the ribbon page is only a launcher and does not open it automatically. Open **Smelting steel bars** for the first complete calculator. The other two methods show partial source models. **Diagnostics** in the ribbon launcher retains the temporary player, BANK/INV and quest probes; these are separate from the browse sidebar. Complete bank coverage, equipment matching and general unlock detection are still unverified.

Use **Browse** or **Favourites**, then an activity category and the search field. Sort by **Profit**, **ROI**, **Difficulty** or **Intensity**, highest or lowest first. Dropdown changes read the native selected-entry collection on one deferred Logic callback, then unsubscribe; there is no recurring sort polling. Unknown values stay last in either direction, with title/ID ties kept consistent. Difficulty is not yet researched for these samples; it is shown as unclassified rather than guessed. Search matches titles, variants and source categories as plain text. Back from a method keeps the list section, category, search, sort and scroll position while the plugin remains enabled.

Opening or reopening Browse captures prices for complete method models; opening/reopening a method refreshes its own quote set without resetting a draft. Search and sorting reuse captured estimates, with no polling or manual refresh button. Back uses captured method quotes with its saved/source rate rather than an unsaved draft. Incomplete models show unavailable estimates. Browse category colours match the sidebar: PvM red, skilling green and production blue. Star and arrow icons provide favourite/open actions with tooltips.

Drag and resize the window using its native frame. Navigation replaces only the content view, so moving between methods and Browse keeps the frame's position and size. Closing hides it; reopening retains the current screen, draft rate and tab. A game-state transition destroys the window because its native parent may change; reopen it explicitly afterward. Placement is not persisted across reloads or game-state transitions in this build.

This is a development manifest; release contact metadata and the published GEPL dependency mapping will be added before submission. This build requests no permissions and does not read character tracking IDs; the account context uses only the local visible display name. The identity probe was removed after a reported client crash when granting tracking access; the cause is still unconfirmed.

For the equipment probe, equip or remove an item and select **Inspect last changed inventory**. Compare the displayed container name and items with your equipment. Other inventory changes can also update this target; it is not automatic equipment identification. Item previews show the first 12 occupied slots in slot order.

For the quest probe, select **Inspect quest** with `COOKS_ASSISTANT` (Cook's Assistant), or enter another verified, non-deprecated quest config name. This default comes from Skill Tips' verified config data; the official documentation's older `COOK_QUEST` example is deprecated. Compare results with your quest journal. Quest inspection is manual and clears on game-state changes; it is not yet used for method eligibility. Missing, deprecated or failed quest reads remain unknown or explicit errors.

## Requirement checks

`src/game/requirements.lua` evaluates plain account evidence and returns `met`, `unmet` or `unknown`, keeping the original requirement text and the evidence for each check. It supports base skill levels, completed quests, named-item quantities and nested all/any groups. Access requirements and recommended setups are evaluated separately. Unsupported gear or unlock checks remain unknown.

Item evidence must represent current, deduplicated ownership. Observing enough items can meet a requirement; a shortfall is only unmet when the evidence explicitly establishes complete coverage. Missing, stale and incomplete evidence cannot establish absence. Requirement item borders read requested totals from backpack (INV), worn gear (WORN) and bank (BANK), with inventory-event cache invalidation. Green means a listed item or curated worn/charged variant was found; red means absent from all three readable containers; grey means absence cannot be established or the icon could not be verified. Other storage is not checked, and presence does not prove usable gear or satisfy a full equipment setup. Native bank availability and rendering still need developer verification.

The quest probe uses the shared checker and displays its verdict. Method Requirements tabs read the relevant base skill levels and refresh on native skill updates while the workbench is visible; inventory updates do not trigger these reads. Item/gear matching is not yet connected to the catalogue. Unknown gear/capability checks stay unknown; there is no full readiness verdict or recommendation engine yet.

The entry point `main.lua` is the required client entry point; it starts `src/main.lua`, which connects account reads, requirements, the calculator, preferences and navigation. `src/game/account.lua` owns inventory/skill/game-state subscriptions; `src/ui/workbench.lua` separately owns the launcher, workbench frame and current content view. `src/methods/browser.lua` owns filtering, ordering and list state; `src/ui/browse_view.lua` owns the sidebar, header and scrollable result views. `src/ui/method_view.lua` renders the four detail tabs. `src/methods/income.lua` owns GE quote interpretation and pure arithmetic; `src/storage/preferences.lua` owns persistence. Temporary probes live in `src/ui/diagnostics.lua`, the marked probe section and diagnostics state of `src/game/account.lua`, and the two marked diagnostics callbacks in `src/main.lua`; remove these together with the Diagnostics navigation entries in `src/ui/workbench.lua`/`src/ui/browse_view.lua` before release. `src/ui/item_icon.lua` validates native icon lookups; `src/ui/view_style.lua` shares colours and number formatting between Browse and details. Shutdown unsubscribes owned callbacks, invalidates screen/row callbacks, then destroys child views, content, frame and launcher. This build makes no direct network requests.

## Calculator and saved rates

The steel-bar recipe uses the Wiki's base 2,000 smelts/hour model. Inputs use GEPL's instant-buy side, outputs its instant-sell side. The output tax is rounded down per item before multiplying the quantity. The UI labels revenue/profit after tax without listing tax amounts; calculations keep their full precision while money displays round to whole GP. Net profit is revenue after tax minus supply costs; ROI is net profit divided by supply cost. A zero denominator shows not applicable. These trade quotes differ from the Wiki's GE guide prices.

Opening or reopening a method captures its direct-item quote set. The library owns HTTP/cache refreshes. Rate edits reuse captured quotes and update the estimate without reconstructing the input field. Prices can be stale or illiquid; raw timestamps stay in calculator evidence rather than the player-facing table. Missing prices or incomplete source costs prevent a complete profit estimate. No snapshot-price fallback or direct price polling is used. GEPL 0.3.1's getLatest applies its own cache-expiry and in-flight guards, so rapid reopening does not force repeated HTTP refreshes; Profit Path never calls updateDatabase directly.

The window uses your own character's visible display name (`Player.GetEntity().displayName`) without tracking permission. Settings are local to this device. On first use, the current character keeps the previously selected profile's rates/favourites; later characters get separate bindings. Existing saved records and keys are preserved. Name reads and storage failures stop opening rather than writing under another character. Display-name changes are not a stable identity signal: old bindings remain stored and may need an explicit reassignment after a rename.

Method details place Back, title and favourite on one header row. Shaded input/output tables align hourly quantities and totals. The centered method title shares a row with Back and favourite. Hourly input/output totals share the section heading row; hover Inputs or Outputs for pricing assumptions. A single Rate per hour label accompanies the input, a floppy-disk save icon and an undo/reset icon. Notes describe pricing assumptions and gameplay caveats rather than refresh mechanics. A valid rate edit previews immediately. Press Enter or **Save** to persist it; **Reset to source rate** deletes that override. Invalid input keeps the last valid estimate. Save/reset failures remain visible, and changing units invalidates an old saved rate with a warning.

For in-game verification, compare 2,000 and 1,000 smelts/hour without closing/reopening: each steel-bar subtotal and profit should halve. Save a custom rate, reload and confirm it remains under the same profile. Reset and confirm 2,000 returns. Check the after-tax labels, all four tabs, Back, resizing and repeat reload/close cycles. Automated tests do not establish native rendering or persistence behavior.

For the browser milestone, type a search while watching keyboard focus, combine it with a category, try all four sorts in both directions, and return from a scrolled method list. Add a favourite in Browse and remove it in its method header; check that Favourites follows the change and survives reload. Switch characters and confirm favourites/rates remain separate, including after reload. Resize to the minimum window size and check that the sidebar, selectors and list do not overlap; this native rendering check is still outstanding for 0.4.12-dev. All in-game input and reload checks must be performed by the developer; assistant inspection is limited to screenshots, without activating or controlling the client.

## Tests

Install `requirements-dev.txt`, then run `python src/tools/test.py`. The tests use Lua 5.4 with mocked client/dependency interfaces. They do not replace in-game testing.

The only Markdown files permitted in this repository are README.md and CHANGELOG.md.

## Local reference data

The build includes a copied monster/drop snapshot and three representative method records. Method data now feeds the browser/calculator. PvM loot selection and income reconciliation remain incomplete, so monster data is not yet valued by the calculator. No recommendation engine uses it yet.

`catalogue-source/monsters.json` is the readable source, with original input hashes and provenance. `data/monsters.lua` is generated: repeated strings, drop rows and sections are stored once. `src/data/monster_data.lua` looks up exact Wiki titles and returns fresh plain tables, decoding only the requested record. No Monster Data Core or Monster Lookup dependency is required, and no network requests occur. The snapshot covers 1,120 monster pages from the inherited bundle built 2026-10-22; this is not full current Wiki coverage.

The import retains drop quantities, rates, rolls, ranges, modes, conditions and notes. It omits combat stats, maps, locations, search indexes and historical prices. Unknown rates/quantities remain unknown. The inherited snapshot does not provide individual article revisions. Notices are in `THIRD_PARTY_NOTICES.txt`; full inherited notices are retained with the source inputs.

`catalogue-source/methods.json` records the initial steel-bar, elder-log and abyssal-demon methods with Wiki revisions. Method quantities explicitly distinguish per-action and hourly costs. The PvM entry references selected shared drop rows instead of copying them. Its income and requirements remain partial until reconciled; the elder-log potion-cost formula also remains unresolved. Only the steel-bar base recipe is fully modelled in this sample. Item references are resolved to native Obj configs and checked against their expected names for icons; that visual check does not establish ownership or usability. Display-only potion references do not make their unresolved income costs priceable.

With the development Python dependencies installed:

```text
python src/tools/catalogue.py build
python src/tools/catalogue.py verify
python src/tools/catalogue.py import-monsters --from "PATH TO LOCAL monster-lookup"
```

`build` regenerates Lua from the checked-in source. `verify` checks deterministic output, every retained monster field through the actual Lua reader, and method identities, item/loot references and supply units. `import-monsters` is an explicit maintainer operation that reads the user's existing local Monster Lookup bundle; it does not fetch anything. Review changed source hashes and notices when importing an update. New Wiki collection must follow the Wiki's plugin-data guidance; the confirmed collection contact is Discord user Tatsuya.

Catalogue validation runs before either generated output is written. It checks the requirement trees and display labels, source revisions, referenced items/loot, supported periods and units, and output-only sale tax. The small method catalogue is emitted as readable multiline Lua; the larger monster dataset retains its verified compact layout. Runtime checks consume these validated definitions and only validate newly read account/quote evidence.

Equipment requirements explicitly distinguish `specific` named items from `flexible` tool or tier requirements. Flexible entries retain their source wording and cannot have a fixed icon list; the catalogue build rejects that combination. This avoids presenting a Wiki example as mandatory. Tool/tier matching remains unknown until implemented.

Required and recommended item sections share a row when both have entries; if one is empty it is omitted and the other uses the full width. The rate-control row is below the income tables; preview/save/error feedback shares that row.

The browser has a full-height shaded sidebar and divider. Unclassified difficulty is omitted from cards. `data/icons.lua` maps the small set of UI icon aliases to verified native sprite names; rsprite's public `Get` resolves those names against the running client, caches lookups and rejects known unsafe sprites. PrettyUI owns sprite rendering, buttons, tooltips and cleanup. No full search index is built. The save glyph uses a standard PrettyUI icon button; if it is absent, a text Save button remains available. Missing decorations leave the method usable. Item icons continue using validated native Obj lookups and existing ownership checks. No downloaded icon resources or runtime icon requests are needed.
