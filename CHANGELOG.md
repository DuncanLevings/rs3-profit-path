# Changelog

## Unreleased

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
