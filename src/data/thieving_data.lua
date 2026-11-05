-- Reads thieving targets (pickpocket NPCs and stalls) from data/thieving.lua.
--
-- The file is built by src/tools/catalogue.py from catalogue-source/thieving.json,
-- which src/tools/wiki_drop_sources.py imports from the RuneScape Wiki. It's packed
-- exactly like the monster snapshot, so we reuse that reader rather than copy it.
-- find(title) gives the target's drop tables plus `level`, its Thieving level.
--
-- Drop rates are per successful steal. Nothing here has been checked in game.
return require("src/data/monster_data").open("data/thieving")
