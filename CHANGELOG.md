# Changelog

## 0.8.14-dev - 2026-10-30

- Hovering an either-or or all-of requirement line that isn't met says what each part reads as, e.g. "Either one will do. Mobile: can't be checked in game. Shadow's Grace: not unlocked yet." A line like "Mobile or Shadow's Grace" stays neutral rather than red when the relic isn't unlocked, because the Mobile perk can't be checked; the hover now says so. The label is made again only when that text changes, at most four lines in any method.

## 0.8.13-dev - 2026-10-30

- 21 Wiki guides that choose from GE prices now make those choices from live prices instead of keeping the Wiki's answer from import day. Shop runs (Buying runes, Mega shop run daily and weekly, Buying feathers, farm shops, vials of water, yak-hide and the Stonemason) buy each item only while the GE pays more after tax than the shop charges; the Coins supply now adds up the shop price of whichever items are bought, and each item's hover shows its shop price. Bones to Bananas, Casting fruitfall, the Anachronia agility codexes, Cutting willow logs and six potion guides (3-dose or 4-dose) pick whichever option pays more. Options that aren't used stay listed at 0, and hovering a row says whether it's used and why. Before, Buying runes showed air, mind, earth, death and blood runes at 0 forever.
- New `wiki_choices.py` researches the shop runs by asking the Wiki to expand each guide's own stock and price formulas. `catalogue-source/research/income-choices.json` holds that research and the hand-researched alternatives, pinned to each guide's revision. The merge checks it against the imported guides, including each shop run's Coins total.
- Item IDs were looked up for the options guides didn't pick on import day (Double Escape codex, Super antipoison (3), Super attack (4)).

## 0.8.12-dev - 2026-10-30

- An item with no price no longer hides a method's profit when most of the other items on its side have prices: K'ril Tsutsaroth's Steam battlestaff, a tiny share of the drops, made every K'ril method "Not estimated". Missing outputs now count as 0 GP, which can only understate the profit, and the status line, the Browse tooltip and each row's hover say what was left out. Coins and other fixed values don't count towards the majority. Supplies follow the same rule: Killing Araxxi's Antipoison++ (4), with no recent instant-buy trades, made the method "Not estimated". A supply counted as 0 can overstate the profit a little, and its row's hover says so. A missing price for the only row on a side, or most of them, still blocks the total. The status line under the profit is shorter and starts after its label, so a long message no longer runs into it.
- 128 Wiki-imported income items were asking GE Prices Library for the wrong version of the item, so they showed "Unavailable". Masuta's warspear (ED1) asked for the untradeable used version (43055) instead of the tradeable new one (43053); Barrows, Nex, crystal and drygore drops, the Mining ores, magic potions, ectoplasm and leather scraps had the same problem with used, Dungeoneering, minigame or event copies. The importer now prefers the version with a Grand Exchange page, and other versions on the same Wiki page still count as owned (a worn Torva piece meets a Torva requirement). `wiki_methods.py --items` and `wiki_recipes.py --items` look item IDs up again without re-importing; recipe ingredients needed no changes.
- An item with hourly GE trades but no latest-trade entry is priced from its hourly average. Before, a missing latest entry stopped the hourly data from ever being checked, and prices waited for the latest data even when the hourly data had loaded.
- Hovering an "Unavailable" value says why: GE Price Library still loading, no GE prices for the item, no recent instant-buy or instant-sell trades, a refused one-off trade, or which ingredient a creation cost is missing. The status line names the first missing item. GEPL's "Price not found" is reported as no prices for the item rather than as a library error.
- 14 more supply rows use live creation costs instead of the Wiki's fixed figure: dose-less potioncost rows (elder overload salve and potion, holy overload potion, perfect plus potion) are one whole potion, per the template's documentation, and Adrenaline renewal potion (4) matches its recipe by name. Rows priced with an improved recipe tier, and supplies without a Herblore or Summoning recipe (Divination signs, XP capacitors, the potion reservoir, the overload flask), keep the Wiki's figure.

## 0.8.11-dev - 2026-10-30

- Tool requirement ownership hints stay inline; the native label previously rendered their newline as a square character.

- Audited all 15 recommendation-only variants. Restored custom gear labels lost behind generic Wiki advice links, added sourced method/setup checks and retained manual conditions where no verified client check exists. Reviewed spinning wool as requirement-free. Added low-tier gear data; unresolved low-tier items cannot establish absence. Recommendations remain separate. Validation: 127 Lua and 113 Python tests.

- An empty Required list in incomplete source data no longer passes Met (including Telos 200 Killstreak). Required notes or unresolved entries also keep otherwise passing access unknown; an explicitly complete requirement-free method can still pass. Browse and method details share this decision. Validation: 125 Lua and 109 Python tests.

- Browse Met now follows the actual listed requirement verdicts instead of rejecting otherwise passing methods because their source research is marked partial. Missing evidence still stays unknown; recommendations do not gate access. Regression coverage includes passing, missing and unavailable levels. Validation: 123 Lua and 109 Python tests.

- Requirements explicitly described as recommended or optional now appear in Recommended even when the source groups them as required. Genuine minimum requirements with advice about better levels or tools stay Required.

- Getting there separates each area into a named section with its own directions, instead of joining names and repeating the area prefix on every line. Shared itineraries stay above the area sections; pricing commentary is excluded from travel notes.
- Text cleanup removes empty list introductions and extraction fragments, improves route wording, and preserves numeric levels from Wiki scm/scp templates. Access prerequisites and route conditions remain intact.

- All 676 method variants now have bundled How to do it summaries and Getting there text. Guide prose uses the same pinned revisions as income. Area routes retain their own revisions, quest/item conditions and source attribution; generic bank/workstation methods state their interchangeable location.
- Added a maintainer-only, cached Wiki API collection tool and targeted research inputs. Shared area text and the existing string pool avoid per-method copies of the same route wording. No runtime Wiki requests, external links, new dependencies or live navigation.
- PvM summaries keep the activity and brief notes rather than full boss strategies. The larder/egg collection steps need checking against the current housing interface; source wording and layout still require in-game review.
- Validation: 122 Lua and 109 Python tests, including recommendation classification and minimum-level preservation, plus full packed-data round trips. The content pass also passed a decoded comparison of income, requirements, method IDs, equipment and pricing references before this requirement reclassification.

## 0.8.10-dev – 2026-10-30

- A method screen that fails to draw one of its later pieces stops drawing and reports the error once. Before, a failing Income row was retried every game tick: 50 errors a second, each leaving another half-made row behind.
- Guideline pass: the README no longer describes the removed equipment and quest probe buttons and lists every requirement kind it checks (combat level, unlock flags, achievements); stale comments left by the Diagnostics removal are fixed; a quest-name error no longer asks the player to type a name; the method screen's description sits on the right function; clearer names where a loop variable hid another and where the Income tables' update was called `fill`; spacing between steps in a few places.

## 0.8.9-dev – 2026-10-30

- Opening a method no longer runs past the client's one-second limit. The screen used to draw all four tabs in one click, up to about 300 components and 90 tooltips for a boss with a long drop table (PrettyUI builds every tooltip up front). Now it draws the open tab and the first 6 rows of each Income table, then the rest a piece per game tick: more rows, then each other tab. Clicking a tab that isn't drawn yet draws it straight away, and leaving the screen stops the drawing. The biggest single click is now under 90 components and about 22 tooltips.
- Abilities and spells that only need levels (and a quest) are checked: Barge (65 Attack), Dive (30 Agility), Surge and Double Surge (5 Agility), Sunshine (The World Wakes, 76 Magic), Light Form (The Light Within, 80 Prayer) and Trollheim Teleport (Eadgar's Ruse, 61 Magic; the quest itself is still "can't tell"). Lines such as "Dive or Bladed Dive recommended" are now real checks instead of tips (tips fall from 303 to 244); Bladed Dive is a Shattered Worlds unlock and stays "can't tell", which is why the unknown count rises from 204 to 217. Mobile is an Invention perk, not an ability.
- Unlocked abilities are checked by the game's own unlock flags, found with a temporary Diagnostics scan: Greater Chain, Greater Ricochet and Magma Tempest (codices), Bladed Dive (Shattered Worlds), the Dragon Slayer and Undead Slayer abilities, and the Necromancy talents (the four Conjures, Darkness, Invoke Death, Lesser Bone Shield). The codex and talent unlocks are bits of one variable; on a test account with only Conjure Skeleton Warrior, only that bit is set, which confirms how it's read. War's Retreat Teleport reads the teleport unlock bought at War's Wares, and Corruption Shot and Blast read Liberation of Mazcab's Ranged and Magic basic-ability unlocks. The Shattered Worlds, Ulthven, War's Retreat and Mazcab flags are named outright but not yet seen switched on. Unknown checks fall to 167; flag checks rise from 138 to 208. Skeletal horror Teleport and Make Leather stay "can't tell": no unlock variable was found for them yet.
- The temporary Diagnostics page is gone: the launcher's Diagnostics button, its inventory, quest, tool-belt and price probes, and the variable scans that found the unlock flags above (`diagnostics.lua`, `toolbelt_probe.lua` and the probe readers in `account.lua`). The tool-belt reader, unlock flags and quest checks the plugin uses are unchanged.

## 0.8.8-dev – 2026-10-30

- Red "missing" borders survive a plugin reload. Saved item evidence now keeps held items one by one and every checked-and-absent item as one compact list of IDs; with the tiered gear checks it had grown to about 3,500 entries per container, mostly zeros. Saved item IDs read back as numbers are accepted too, instead of making the whole record look corrupt (which also stopped it ever being saved again). Records saved by earlier versions still load.
- One Wiki line with several links is one requirement again. The importer split such lines into one entry per link, so "Built a plank maker then a high capacity plank maker" or "Woodcutting boosts such as Sana's fyrtorch, Ring of Whispers, ..." showed the same text two or three times. They're joined back: "any one of" when the wording offers a choice ("or", "such as", "like", "/"), otherwise "all of". A link named only inside brackets is a side note ("Tier 80+ pickaxe (Augmentable pickaxe highly recommended)"), and a bare name next to its qualified one ("Undead Slayer" and "Undead Slayer (ability)") is listed once.
- Pickaxe and hatchet lines that accept any good enough tool check the tool, not the one item the Wiki linked: "Any pickaxe", "Crystal pickaxe or better", "Tier 80+ pickaxe", "Primal pickaxe + 5 at minimum", "Dragon hatchet or better", "Hatchet (highest tier hatchet that you have)". A better pickaxe counts ("+ 5 or better" needs at least the + 5). Pickaxes come from the Wiki's Pickaxes table (`wiki_methods.py --pickaxes`, saved in `research/pickaxes.json`: 61 pickaxes with augmented versions). Not finding one stays "can't tell" until the tool belt's pickaxe IDs are compared with the Wiki's in game.
- "High-level power armour" and "Any high level shield required" (Helwyr) are gear checks at the Wiki's high level (61+).
- "Recommended" is said once per line: "Salve amulet (e) recommended recommended" and "Dive or Bladed Dive recommended (highly recommended)" lose the repeat.
- Gear checks rise from 91 to 113 and "Check yourself" lines fall from 141 to 133. The unknown count (204) counts each part of a joined line separately; no line became less checked.

## 0.8.7-dev — 2026-10-30

- Required lines the Wiki writes as plain words are sorted. Ones with a real check become one: spellbook lines ("Lunar spellbook active") check the quest that unlocks the book, "Prifddinas unlocked" checks Plague's End, Divine Conversion checks its relic, Elite Ardougne and Morytania legs 2 check their diary tiers, and Eclipse of the Heart, Breaking the Seal and Everything Is Oresome check their achievements. Parsing leftovers ("83", "High", "Strategies") are dropped. The rest (gear tiers, team sizes, shop upgrades) are listed under a new "Check yourself" heading on the Requirements tab, one per line, never coloured or counted as unknown (143 lines). Unknown checks fall from 388 to 199.
- Tiered gear lines are real checks: "Tier 90+ magic weapon", "Tier 90+ weapon and Tier 80+ armour", "T90+ magic tank armour" and the Wiki's "Magic armour: High level equipment (61+)" links. Owning (carried, worn or banked) any weapon, shield or body armour of that tier, style and type meets it; armour is checked by its body piece, and perks aren't checked. The tiers come from the Wiki's equipment data (`wiki_methods.py --equipment`, saved in `research/equipment.json`: 6,295 tier 60+ pieces, about 2,900 of them weapons, shields and bodies). 91 gear checks, including tier lines the Wiki links to its Armoury page (they were shown under "See also"); a line linked to a named item ("Inquisitor staff is best in slot") accepts that item too. the catalogue grows to 1.13 MB. With that many items, ownership reads each container's slots once instead of asking for every item.
- A gear check with no owned match shows an empty slot whose border gives the verdict (red when missing) instead of the group's coverage note.
- "Any one" tiered gear (magic, melee, ranged or necromancy armour) shows one slot per option with a short label ("T61+ magic armour"), like the "Any one" item groups, instead of one long line of link text.
- The "See also on the Wiki" section is gone: bare Wiki page names (Armoury, Spear, Recommended equipment for PvM...) can't be clicked in game and were clutter. Where a guide words its own advice through such a link ("Hybrid armour recommended (suggested warpriest armour)", "Weight-reducing clothing"), that wording is kept as a tip or a "Check yourself" line.
- A gear check no longer stays "unknown" because of one Wiki item ID the client names differently (a retired or renamed version): such an ID is skipped unless you hold it. A failed name read still counts as "can't tell", never as missing.
- Validate with 127 Lua behaviour tests and 83 Python tests.

## 0.8.6-dev — 2026-10-29

- Recommended things the plugin can't check (relics, abilities, diaries, perks, and lines the Wiki words as "recommended" or "optional") are now tips: listed under "Also helps" on the Requirements tab with their icons, never coloured or counted as unknown. Unknown checks fall from 1,039 to 482 (523 tips).
- Single required items show their icon with the owned / missing border, like curated ones (a stack such as "500 Coins" keeps its text).
- Methods whose drops don't match the drop table now just say their drops use the Wiki's own figures; the mismatches stay in `catalogue.py report`.
- Relics and achievements are real checks now. 13 relics (Death Note, Berserker's Fury, Shadow's Grace and others) are read from their in-game unlock variables (`ARCH_RELIC_<NAME>_UNLOCKED`, found with the new Diagnostics unlock scan), and 30 achievements and achievement-diary tiers are read by in-game ID (`config.Achievement`; a tier is met when every task in it is complete, and retired tasks never block it). The IDs come from the Wiki's achievement data (`wiki_methods.py --achievements`, saved in `research/achievements.json`). 128 relic and 91 achievement requirements become checks; unknown checks fall from 482 to 420.
- More unlocks from a second, narrower scan: the War's Retreat adrenaline crystal, the Ranger's Workroom, the large dinosaur pen, the bonecrusher upgrade and Restocking Cannon. Lodestones and Invention machines aren't stored under names the scan can find, so they stay unknown.
- Spells and prayers with a clear unlock rule in the Wiki's spell and prayer data are checked as their level plus the quest that opens their book: Crumble Undead, Penance, Vampyrism, Animate Dead, Incite Fear, Crystal Mask, Lunar spells, Ancient curses, Soul Split, Torment and Affliction ("Vampyrism (Desert Treasure, 69 Magic)"). Abilities stay unknown: the Wiki doesn't say which need a codex or quest, and a level-only check could wrongly show green. Unknown checks are now 388.
- Diagnostics has temporary unlock-variable and achievement inspectors for this research.
- Validate with 123 Lua behaviour tests and 77 Python tests.

## 0.8.5-dev — 2026-10-29

- Research pass 5, PvM drops. The build now checks every PvM guide's per-kill drops against the monster drop tables in our snapshot (rate × average quantity over every row for the item, within 10%). Each PvM method gets a status that its "Partly researched" note explains: drops checked (16), partly checked because some rare drops depend on conditions (18), setting-specific for enrage, killstreak and hard-mode versions the base table can't check (27), drops that don't match the table yet (66, listed by value in `catalogue.py report`), or no drop table (54).
- Validate with 122 Lua behaviour tests and 74 Python tests.

## 0.8.4-dev — 2026-10-29

- Research pass 4, recurring guides. The 94 daily/weekly Wiki guides are now methods, counted per run: "Profit per run", "Per run" columns and "1.2M / RUN" in Browse, with the cycle shown on the row ("every 24 hours") and in Notes with the minutes per run. Their rate box is "Yield (% of guide)" (100 is the guide's own amounts). They have their own Recurring section in the Browse sidebar, after Production, with a subtle orange title colour; under All activities they're always listed after hourly methods, so a two-minute daily never outranks a real hourly method. The catalogue is now 676 methods (889 KB).
- Validate with 122 Lua behaviour tests and 70 Python tests.

## 0.8.3-dev — 2026-10-29

- Research pass 3, combat levels. A combat level requirement ("70 Combat", "138 Combat") is now a real check against the client's own combat level (`Player.GetCombatLevel`), so free-to-play rules are the client's. "90 Melee" is read as 90 Attack and 90 Strength. Constitution requirements are now checked too: the client's SkillType calls the skill HITPOINTS, so they had always read as unknown. 32 combat and 12 melee requirements become checks; unknown checks fall from 879 to 835. Combat level rows have no icon (the Skills tab's badge isn't a sprite the plugin can read). Diagnostics shows the combat level.
- Browse rows: the version label after a method title is smaller and muted, and the title and version share the space before the profit column without tooltips. A full page of tooltips (PrettyUI builds 11 native components per tooltip) had used up the native component IDs. Browse ROI keeps its sign colour in subtler shades so the profit figure stands out.
- Validate with 121 Lua behaviour tests and 67 Python tests.

## 0.8.2-dev — 2026-10-29

- Research pass 2, outfits. `wiki_methods.py --outfits` reads each outfit's `{{Infobox Set}}` on the Wiki (with its page revision) and resolves every piece to an item ID, retrying charged pieces like "Ghost hunter goggles (20)" by name so any charge level counts. 19 outfits, all 94 pieces resolved (`catalogue-source/research/outfits.json`).
- An outfit requirement now becomes "all of these pieces": checked against your backpack, worn items and bank like other items, and shown as a grid of piece icons. Unknown checks fall from 1,044 to 879; Dragon bane equipment and Trapper outfit have no set template on the Wiki and stay unknown.
- Validate with 120 Lua behaviour tests and 65 Python tests.

## 0.8.1-dev — 2026-10-29

- Research pass 1, requirements the plugin couldn't check. Quests now map to their in-game quest configs by exact name (`catalogue-source/research/quests.json`, built by `catalogue.py map-quests` from Skill Tips' verified in-game quest dump; deprecated configs never used). 115 Wiki quest names are mapped, so 399 quest requirements are real checks instead of unknowns, including Wiki links that are really quests (New Foundations).
- Wiki advice pages ("Armoury", "Recommended equipment for PvM", armour and weapon comparisons) are no longer shown as unknown requirements: the Requirements tab lists them under "See also on the Wiki" (244 links). Every other unknown requirement name is classified by kind in `capabilities.json` (outfit, ability, relic, achievement, place...). Unknown checks fall from 1,772 to 1,044, and an unmapped quest still sits under Quests.
- Validate with 120 Lua behaviour tests and 62 Python tests.

## 0.8.0-dev — 2026-10-29

- Ship the full catalogue: 582 methods (our 4 curated ones plus 578 current Wiki guides; recurring daily/weekly guides come later). `data/methods.lua` is 747 KB and decodes in about 30 ms on desktop Lua.
- Browse shows 25 methods a page, with Previous/Next page controls. Filters, search and sorting go back to page 1; returning from a method keeps the page.
- Opening the window prices every method once (sorting by profit needs them all), but each distinct item is looked up only once per refresh: 5,524 price-library calls for 1,381 items instead of one set per method, and Browse opened in 27 ms in the desktop test. Native item-name checks are cached for the session instead of repeated on every inventory change.
- Wiki imports say "Partly researched" in Browse. The method page's Notes list what hasn't been checked (unknown requirements, Wiki drop figures, unpriced items), and How to do it points to the Wiki guide until steps are written. Per-hour guides show "Pace (% of guide)" (100 is the guide's pace).
- Capability requirements show their sprite (relics, abilities, spells, perks; quests use the quest marker), from icons shipped with the catalogue. Item definitions use each item's own Wiki name, so dose-family potions pass the in-game name check. Rows without an item show their own name as the tooltip.
- Behaviour tests use the 4 curated methods; new full-catalogue tests check paging, per-item pricing, research labels and icons. Validate with 119 Lua behaviour tests and 59 Python tests.

## Catalogue import tools — 2026-10-29

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
