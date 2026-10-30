# Changelog

## Unreleased — 2026-10-29

- Add `src/tools/wiki_methods.py`, which snapshots every current RuneScape Wiki money making guide into `catalogue-source/wiki/guides.jsonl` (676 guides on 466 pages; the 200 the Wiki marks obsolete are skipped) and `meta.json` (1,667 of 1,695 income item names resolved to IDs). Each guide records its page revision, version, kills per hour or recurring cycle, income rows and parsed requirements. No plugin change yet: a later step merges the snapshot with our research.
- `test.py` now checks the snapshot is consistent.
- Merge the snapshot with our research (`src/tools/merge_methods.py`): curated methods replace their Wiki guide, and every other current guide becomes a full method record that passes the same validator (582 methods: 4 curated + 578 imported; 94 recurring guides wait for a per-run model). Per-hour guides get a "% of guide pace" rate. The Wiki's fixed and calculated values stay fixed values unless one of our recipes can cost them. Requirements become skill/item checks where the plugin can check them, and unknown capability checks otherwise.
- Requirement icons: every skill now has its rsprite icon, and quests show the world-map quest marker. Abilities, spells, prayers, relics and perks get their sprite from `catalogue-source/research/capabilities.json`, drafted by `catalogue.py match-sprites` from rsprite's reference list (47 matched so far). Dose-less potions resolve to their dose family, so owning any dose counts.
- New `catalogue.py report`: catalogue coverage and the methods to research first, ranked by the Wiki's profit figure. Plugin still shows only the 4 curated methods.
- Validate with 116 Lua behaviour tests and 59 Python tests.

## 0.7.4-dev — 2026-10-29

- Show a negative ROI in the same red as losses and the Inputs values, on the method page and in Browse. A positive Browse ROI stays grey; on the method page it stays green.
- Validate with 116 Lua behaviour tests and 39 Python catalogue tests.

## 0.7.3-dev — 2026-10-29

- Price items at the last hour's average trades instead of the single latest trade, the same fix Monster Lookup uses. A player dumping steel bars at 15 GP had made 2,000 bars an hour look worth 30,000 GP; the hour's average sell price was about 1,051. Supplies use the average instant-buy price and outputs the average instant-sell price, and creation costs follow automatically.
- A side with no trades in the last hour falls back to its latest trade. That trade is refused if it's more than 3× away from the other side's hourly average, so a one-off dump or misclick shows "price unavailable" rather than a fake loss.
- Move the rate controls to the top of the Income tab: a small framed panel left of the profit panel, with "Rate per hour" and Reset above the rate box and Save. The unsaved/error status line moves into the profit panel's top right. The profit per hour now uses the client's 19pt bold font with a larger coin, and ROI uses 17pt bold; both are green for a profit and red for a loss, like the Outputs values. Browse profit tooltips now show only the assumed rate, with thousands commas (e.g. 2,000 smelts/hour); the row already shows profit and ROI.
- Diagnostics show whether each side came from the hourly average or the latest trade. The Inputs/Outputs tooltips describe the new pricing.
- Validate with 115 Lua behaviour tests and 39 Python catalogue tests.

## 0.7.2-dev — 2026-10-29

- Store methods compactly, ahead of importing the full Wiki catalogue. `catalogue-source/methods.json` (schema 2) has one entry per Wiki page, and each version lists only what differs. Requirements can be short strings such as `skill:SMITHING:20` or `item:31455`; the build fills in their text, group wording, item icons, "(recommended)" endings, income row names and Wiki links. The source is 445 lines instead of 1,204. `catalogue.py format` tidies it into a one-row-per-line layout, which `build` and `verify` require.
- Pack `data/methods.lua` with shared text and record shapes (17 KB instead of 50 KB). The plugin reads it through the new `src/data/method_data.lua`, which returns the same fields as before plus `find(id)`. Every method record now carries `schema` and `origin` ("bundled"): the shape players' own copies will use later.
- No visible change: the 4 methods decode to exactly the same records as 0.7.1, checked field by field against the previous generated file, apart from an empty unresolved-requirements list now present on steel bars. `verify` round-trips every method through the plugin's own reader.
- Validate with 111 Lua behaviour tests and 39 Python catalogue tests, plus deterministic data, syntax, manifest and repository file-policy checks.

## 0.7.1-dev — 2026-10-29

- Connect quest, item and equipment-alternative requirements to shared account evidence. Add a Requirements dropdown beside Intensity, keep cards free of readiness labels and wrap filters together on narrow windows.
- Save catalogue-relevant inventory counts per character at meaningful checkpoints. Keep historical evidence separate from live ownership; retain last-checked missing-item borders after bank close and protect invalid stored data.
- Resolve tool-belt hatchets, pickaxes and mattocks through native enums and verified indexing. Cache plain results, invalidate on relevant variable events and show the actual owned item with On your tool belt. Other belt categories remain unverified.
- Complete the normal hatchet candidate list and rank it by cutting power separately from use/combat levels. Tool-belt evidence never inflates tradeable quantities or enters saved bank records.
- Show a named minimum such as Spring cleaner 2000+ when no owned match exists, with a missing/unknown border. Replace it with an owned upgrade when found; broad highest-tool requirements retain their flexible wording.
- Keep item tooltips name-only, verify native names before displaying icons and update equipment slots without rebuilding the rate input. Temporary native discovery probes are bounded, report errors/limits and cancel on screen/session teardown.
- Validate with 111 Lua behaviour tests and 32 Python catalogue tests, plus deterministic data, syntax, manifest and repository file-policy checks.

## Earlier development

- Value selected shared PvM drops and render expected hourly outputs. Abyssal demons now includes all 16 Wiki-listed outputs, actual spring-cleaner alchemy proceeds and untaxed coin drops; missing live quotes still prevent total profit. Validate ambiguous rates/quantities with the runtime loot expansion during builds.

- Make the method version picker compact: fit its labels, reduce its height and arrow, and soften the frame beside the title. Browse dropdown styling is unchanged.

- Add the elder logs "With wood spirits" version and a version dropdown after the method title for methods with several versions; Browse still lists each version. Move the native dropdown workarounds into a shared src/ui/dropdown.lua.
- Keep panel padding correct when a page shows a scrollbar: Browse rows and Income/Requirements panels are sized to the page's final width after the screen is built (fixes clipped ROI text). Side-by-side item sections now use the same symmetric padding as the Income tables.
- Detect window resizes with a per-tick size comparison while the window is visible (the ONRESIZE hook never fired for PrettyUI window resizes in game); the screen still rebuilds once after the size has held for 0.3 s.
- Rebuild the current screen once after the window is resized (documented ONRESIZE hook, settles after 0.3 s), keeping filters, list scroll, the method tab and the draft rate; fix the method page's uneven side padding (tabs no longer pick up PrettyUI's default left padding); style Browse rows as cards with a lighter fill and an activity-coloured left bar.
- Price the abyssal demon potions: Aggroverload (6) by creation cost and Super prayer renewal potion (6) at its GE price (item IDs confirmed on the Wiki). Profit stays unavailable until the loot is valued.
- Price untradeable supplies by creation cost: a new Wiki recipe sweep (src/tools/wiki_recipes.py) imports 466 Herblore/Summoning recipes with untradeable outputs and their untradeable ingredients; the build validates them and generates data/recipes.lua (339 chosen recipes). Ingredients use GE instant-buy prices, follow nested recipes with dose scaling, and unpriceable ingredients count as free with a note. Elder logs' Perfect plus potion now uses this, so the method has a complete profit estimate.
- Keep Browse method titles in their activity colour (PvM red, skilling green, production blue) under every activity filter, not only "All activities".
- Title the window just "Profit Path"; the character name is no longer shown (settings still follow the character, and a future account page will show the binding).
- Stop the "coin icon: item with quantity failed" message: the client has no two-argument SetAssociatedObject, so the coin now attaches the Coins item and sets its quantity as a property directly (the combination confirmed in game).
- Colour Browse profit figures with the same money colours as the method page: subtle green for a profit, subtle red for a loss; "Not estimated" stays gold.
- Number dropdown entries from 0, matching how the client counts them, so Profit + Highest first and both "Any" filters show as the defaults; colour Inputs money values subtle red and Outputs subtle green.
- Read dropdown selections with GetEntrySelected(id) instead of selectedEntries, fixing "Any" applying the next option; label the dropdown row with SORT BY / DIFFICULTY / INTENSITY captions, separate the sort pair from the filters with a divider, and shorten filter options to "Any".
- Make the coin pile robust: try each native step separately (item with quantity, else item plus quantity property), keep the Coins item art instead of the old COINS sprite when the quantity form is rejected, and print the first failure of each step once.
- Fix the Browse dropdown crash (the client reports selected entries as plain IDs), so sorting works again; sort by Profit or ROI only and add separate Difficulty and Intensity filter dropdowns. Old saved difficulty/intensity sorts fall back to Profit.
- Draw the Coins item at a large quantity so the client shows the full coin pile; Browse profit reads "[coin] 1.2M / H"; centre icons vertically on their text; even out Income page and table padding on both sides and right-align the summary ROI.

- Use the skills-tab style (hitmark) skill icons and the Coins item's big-stack graphic; show a coin only beside income totals, placed right next to the number; box the Reset button like Save.
- Guideline cleanup: comment and space out the view, storage and account code; name the character/favourites storage keys; remove the unused manual profile selector (tests now use character binding).

- Integrate rsprite 0.1.2 as a development dependency for native coin, skill, perk and save sprite lookup; retain PrettyUI rendering and a standard save icon button. Remove temporary downloaded/custom icon assets and custom native save-click control.

- Keep the window/calculator usable when image resources are not registered; omit missing decorations, retain a text Save button and report bounded missing-resource diagnostics.

- Anchor Browse navigation with a full-height sidebar background/divider and omit unknown difficulty from method cards.
- Add offline skill/perk/coin icons and a floppy-disk save glyph; move rate controls below income tables, avoid repeated hourly column labels and inset right-aligned values.

- Put hourly totals inline with Inputs/Outputs, move pricing explanations to heading tooltips and tighten rate-to-table spacing.
- Split required/recommended item sections into conditional side-by-side columns; a lone non-empty section uses full width.

- Remove membership labels from Browse; the interface assumes a members audience.

- Distinguish specific equipment from flexible tool/tier requirements in catalogue validation; show broad requirements as text rather than a misleading fixed-item icon. Apply to highest-tier hatchets and Spring cleaner 2000 or above.

- Center method titles, replace the pin with a Save button, move totals above item rows, combine rate labelling and simplify player-facing notes.

- Align Back, method title and favourite on one detail header row; use a compact rate editor and shaded, aligned input/output tables.
- Reconcile sort selection once after native event delivery; coalesce repeated hooks and remove pending callbacks on navigation/shutdown.
- Restrict item tooltips to names, colour confirmed text requirements, and show item-presence borders from backpack/worn/bank reads with unknown data kept neutral.

- Remove the unavailable client `utf8` library dependency from character-name validation; run behavior tests without that global to reproduce the client boundary.

- Accept native UTF-8 character display names and non-breaking spaces without applying legacy manual-profile restrictions; preserve existing character bindings and settings.

- Follow the Wiki method layout with compact results, side-by-side item tables and grouped requirement sections; use native item icons and omit unavailable ROI.
- Put favourites beside browse titles and at the detail top right; ignore stale sort events and stop resetting successful dropdown selections.
- Replace manual method profiles with local display-name bindings while preserving legacy saved rates/favourites; no tracking permission.

- Replace editable sort comboboxes with native dropdown lists; colour activity types and use star/arrow actions.
- Remove manual price refresh controls and refresh on opening/reopening instead; retain draft rates.
- Simplify Income to whole-GP, after-tax revenue/cost tables; remove tax amounts, raw timestamps and developer diagnostics from the main browsing flow.
- Group Lua modules under ui, game, methods, storage and data folders within src.

- Polish the workbench with selected sidebar states, compact method panels, profit/ROI headers, aligned income rows and separate requirement evidence.
- Move implementation, tests and tools under `src/`; retain the required root entry point and top-level data, manifest and notices.

- Add the workbench sidebar, category/plain-text search filters, Profit/ROI/Difficulty/Intensity sorting in both directions, and persistent profile-specific favourites from Browse and method details.
- Keep unknown values last, preserve list filters/scroll on Back, retain the search field while rebuilding results, and discard callbacks belonging to replaced rows.
- Refresh list estimates on request using saved/source rates, keep incomplete models explicit, invalidate estimates on profile changes, and preserve existing saved-rate formats.
- Readability pass: spread functions into blank-line-separated steps and add plain-language comments throughout the runtime modules, catalogue/test tools and the test suites. No behavior change.
- Stop inventory updates from re-reading method skill levels; mark every temporary diagnostics probe for removal; expand dense calculator, view, storage and catalogue-validation branches for readability.
- Review the lasting code against the development guidelines: validate requirement/view contracts before generation, preserve both generated outputs on validation failure, and make method Lua readable.
- Correct saved-rate preview labels, refresh displayed skill evidence on skill updates, and reject unknown navigation states with cleanup.
- Move the browser/calculator into one independent resizable window; keep the ribbon page as a launcher, preserve the frame across navigation and isolate temporary diagnostics.
- Add the first three-method browser and dedicated Income, Requirements, How to do it and Getting there tabs.
- Calculate steel-bar revenue, per-item output tax, supply costs, net profit and ROI with GEPL trade quotes.
- Add live rate previews, explicit save/reset and local manual profiles; incomplete models and missing quotes remain unavailable.
- Copy a compact local monster/drop snapshot with provenance and notices; add offline import/build/verification tooling and three initial method records with explicit incomplete-data states.
- Add shared three-state requirement checks for levels, quests, item quantities and grouped alternatives; connect the quest probe to this checker.
- Replace the deprecated COOK_QUEST default with COOKS_ASSISTANT, verified in Skill Tips' config data.
- Add manual quest completion checks and inspection of the last changed inventory, with item name/ID previews for equipment investigation.
- Remove the tracking permission request and identity probe after a reported client crash when granting access; the cause remains unconfirmed.
- Start account/inventory availability probes and a manual GEPL quote check.
- Add explicit inventory invalidation and view/subscription cleanup.
- Keep unavailable account/price data distinct from empty or zero-valued data.
