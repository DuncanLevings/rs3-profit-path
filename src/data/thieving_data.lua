-- Reads pickpocket NPCs and stalls from data/thieving.lua using the shared
-- drop-table reader. find(title) includes the target's Thieving level.
-- catalogue.py packs the Wiki snapshot collected by wiki_drop_sources.py. Rates
-- are per successful steal.
return require("src/data/monster_data").open("data/thieving")
