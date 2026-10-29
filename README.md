# Profit Path

An RS3 plugin for finding money-making methods suited to your account.

Early development: version 0.3.3-dev contains an independent resizable window with a three-method browser, dedicated method tabs and the first income calculator. This is a functional slice; the full workbench styling, catalogue and recommendations are still in development. It sends no game inputs and stores only a selected manual profile and saved method rates.

## Development setup

Use the RS3 plugin beta. Put the project folder in its `dev_plugins` directory as `profit-path`. Install PrettyUI (6398181). For the optional quote check, put GE Prices Library 0.3.1 in the adjacent `gepl` development folder and enable it through the client. This build does not enable dependencies or grant permissions itself. GEPL owns its HTTP access; its quote getter may refresh its cache.

Enable or reload `profit-path` and open its ribbon panel in the Plugins window. Click **Open Profit Path** to open the separate in-game window; the ribbon page is only a launcher and does not open it automatically. Open **Smelting steel bars** for the first complete calculator. The other two methods show partial source models. **Diagnostics** retains the player, BANK/INV and quest probes. Complete bank coverage, equipment matching and general unlock detection are still unverified.

Drag and resize the window using its native frame. Navigation replaces only the content view, so moving between methods and Browse keeps the frame's position and size. Closing hides it; reopening retains the current screen, draft rate and tab. A game-state transition destroys the window because its native parent may change; reopen it explicitly afterward. Placement is not persisted across reloads or game-state transitions in this build.

This is a development manifest; release contact metadata and the published GEPL dependency mapping will be added before submission. This build requests no permissions and does not read character tracking IDs. The identity probe was removed after a reported client crash when granting tracking access; the cause is still unconfirmed.

For the equipment probe, equip or remove an item and select **Inspect last changed inventory**. Compare the displayed container name and items with your equipment. Other inventory changes can also update this target; it is not automatic equipment identification. Item previews show the first 12 occupied slots in slot order.

For the quest probe, select **Inspect quest** with `COOKS_ASSISTANT` (Cook's Assistant), or enter another verified, non-deprecated quest config name. This default comes from Skill Tips' verified config data; the official documentation's older `COOK_QUEST` example is deprecated. Compare results with your quest journal. Quest inspection is manual and clears on game-state changes; it is not yet used for method eligibility. Missing, deprecated or failed quest reads remain unknown or explicit errors.

## Requirement checks

`requirements.lua` evaluates plain account evidence and returns `met`, `unmet` or `unknown`, keeping the original requirement text and the evidence for each check. It supports base skill levels, completed quests, named-item quantities and nested all/any groups. Access requirements and recommended setups are evaluated separately. Unsupported gear or unlock checks remain unknown.

Item evidence must represent current, deduplicated ownership. Observing enough items can meet a requirement; a shortfall is only unmet when the evidence explicitly establishes complete coverage. Missing, stale and incomplete evidence cannot establish absence. The current inventory probe has not established complete coverage and is not yet aggregated into ownership evidence.

The quest probe uses the shared checker and displays its verdict. Method Requirements tabs read the relevant base skill levels and refresh on native skill updates while the workbench is visible; inventory updates do not trigger these reads. Item/gear matching is not yet connected to the catalogue. Unknown gear/capability checks stay unknown; there is no full readiness verdict or recommendation engine yet.

The entry point `main.lua` connects account reads, requirements, the calculator, saved rates and navigation. `account.lua` owns inventory/skill/game-state subscriptions; `ui.lua` separately owns the launcher, workbench frame and current content view. `method_view.lua` renders the four tabs. `income.lua` owns GE quote interpretation and pure arithmetic; `preferences.lua` owns rate persistence. Temporary probes live in `diagnostics.lua`, the marked probe section and diagnostics state of `account.lua`, and the two marked diagnostics callbacks in `main.lua`; remove all of them together with the Diagnostics button in `ui.lua` before release. Shutdown unsubscribes owned callbacks and destroys the launcher, workbench and content. This build makes no direct network requests.

## Calculator and saved rates

The steel-bar recipe uses the Wiki's base 2,000 smelts/hour model. Inputs use GEPL's instant-buy side, outputs its instant-sell side. The output tax is rounded down per item before multiplying the quantity. Net profit is revenue after tax minus supply costs; ROI is net profit divided by supply cost. A zero denominator shows not applicable. These trade quotes differ from the Wiki's GE guide prices.

Opening a method captures its direct-item quote set; **Refresh prices** reads GEPL again. The library owns HTTP/cache refreshes. Rate edits reuse captured quotes and update the estimate without reconstructing the input field. Latest trade timestamps are shown per item; old/illiquid trades are not claimed fresh. Missing prices or incomplete source costs prevent a complete profit estimate. No snapshot-price fallback or direct price polling is used.

Choose a manual profile name for the current character, then **Use profile**. A valid rate edit previews immediately. Press Enter or **Save rate** to persist it; **Reset to source rate** deletes that override. Invalid input keeps the last valid estimate. The selected profile and rates use plugin-local PersistentDB storage on this device, shared across beta clients. Character identity is not read; choose different manual profiles for different characters. Save/reset failures are displayed, and changing units invalidates an old rate with a visible warning.

For in-game verification, compare 2,000 and 1,000 smelts/hour without refreshing prices: each steel-bar subtotal and profit should halve. Save a custom rate, reload and confirm it remains under the same profile. Reset and confirm 2,000 returns. Check the separate tax line, all four tabs, Back, resizing and repeat reload/close cycles. Automated tests do not establish native rendering or persistence behavior.

## Tests

Install `requirements-dev.txt`, then run `python tools/test.py`. The tests use Lua 5.4 with mocked client/dependency interfaces. They do not replace in-game testing.

The only Markdown files permitted in this repository are README.md and CHANGELOG.md.

## Local reference data

The build includes a copied monster/drop snapshot and three representative method records. Method data now feeds the browser/calculator. PvM loot selection and income reconciliation remain incomplete, so monster data is not yet valued by the calculator. No recommendation engine uses it yet.

`catalogue-source/monsters.json` is the readable source, with original input hashes and provenance. `data/monsters.lua` is generated: repeated strings, drop rows and sections are stored once. `monster_data.lua` looks up exact Wiki titles and returns fresh plain tables, decoding only the requested record. No Monster Data Core or Monster Lookup dependency is required, and no network requests occur. The snapshot covers 1,120 monster pages from the inherited bundle built 2026-10-22; this is not full current Wiki coverage.

The import retains drop quantities, rates, rolls, ranges, modes, conditions and notes. It omits combat stats, maps, locations, search indexes and historical prices. Unknown rates/quantities remain unknown. The inherited snapshot does not provide individual article revisions. Notices are in `THIRD_PARTY_NOTICES.txt`; full inherited notices are retained with the source inputs.

`catalogue-source/methods.json` records the initial steel-bar, elder-log and abyssal-demon methods with Wiki revisions. Method quantities explicitly distinguish per-action and hourly costs. The PvM entry references selected shared drop rows instead of copying them. Its income and requirements remain partial until reconciled; the elder-log potion-cost formula also remains unresolved. Only the steel-bar base recipe is fully modelled in this sample. Item IDs sourced from Wiki data still need native mapping verification before ownership matching.

With the development Python dependencies installed:

```text
python tools/catalogue.py build
python tools/catalogue.py verify
python tools/catalogue.py import-monsters --from "PATH TO LOCAL monster-lookup"
```

`build` regenerates Lua from the checked-in source. `verify` checks deterministic output, every retained monster field through the actual Lua reader, and method identities, item/loot references and supply units. `import-monsters` is an explicit maintainer operation that reads the user's existing local Monster Lookup bundle; it does not fetch anything. Review changed source hashes and notices when importing an update. New Wiki collection must follow the Wiki's plugin-data guidance; the confirmed collection contact is Discord user Tatsuya.

Catalogue validation runs before either generated output is written. It checks the requirement trees and display labels, source revisions, referenced items/loot, supported periods and units, and output-only sale tax. The small method catalogue is emitted as readable multiline Lua; the larger monster dataset retains its verified compact layout. Runtime checks consume these validated definitions and only validate newly read account/quote evidence.
