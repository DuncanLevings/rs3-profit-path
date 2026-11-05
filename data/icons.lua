-- The small set of native sprite names Profit Path draws, keyed by the short alias
-- the views use. This isn't a copy of rsprite's catalogue: names were picked from
-- its client 950-1 reference list. view_style.lua resolves them against the
-- running client and keeps the known unsafe-sprite exclusion.
--
-- Skill icons use the HITMARK_ICON_SKILL_* set: the small flat icons from XP drops,
-- which match the skills tab. The SKILL_* set is the round level-up medallion art,
-- which looked wrong next to the in-game stats. Necromancy has no hitmark icon in
-- that client build, so it keeps the mission-board icon.
--
-- `coins` is only a fallback. The views prefer the real Coins item icon; see
-- Style.coins in src/ui/view_style.lua.
return {
    coins = "COINS",
    save = "WARDROBE_ICON_PRESET_SAVE_24PX_0",

    -- rsprite's curated "edit" icon (client 950-1 reference list), for Edit and
    -- Duplicate as custom. Not yet seen in game; the buttons fall back to text.
    edit = "RS3_ICON_EDIT_23PX_0",

    -- A rubbish bin, for removing rows and deleting custom activities. Not yet
    -- seen in game; the buttons fall back to text.
    trash = "AIF_COMBAR_TRASHCAN_0",

    -- The client's own menu "share" button art, for Export on a custom
    -- activity. Not yet seen in game; the button falls back to text.
    share = "RS3_MENU_BTN_SHARE_NORMAL",

    -- The activity page's boxed favourite button: gold once it's a favourite,
    -- silver when it isn't. These are the stars PrettyUI's own STAR sprite
    -- button draws (seen in game before the button was boxed). rsprite's
    -- ICON_STAR_EMPTY drew as a black star in game, so it isn't used.
    star_filled = "RAND_SPEEDRUN_STAR_GOLD_0",
    star_empty = "RAND_SPEEDRUN_STAR_SILVER_0",

    -- Same stopwatch-reset art PrettyUI uses for its UNDO sprite button.
    reset = "RS3_ICON_STOPWATCH_RESET_0",

    -- The world map's quest-start marker, for any quest requirement.
    quest = "RS3_ICON_WORLDMAP_QUEST_START",

    perk_honed = "INVENTION_ICON_PERKS_TOOLS_HONED",
    perk_fortune = "INVENTION_ICON_PERKS_TOOLS_FORTUNE",

    skill_smithing = "HITMARK_ICON_SKILL_SMITHING",
    skill_woodcutting = "HITMARK_ICON_SKILL_WOODCUTTING",
    skill_invention = "HITMARK_ICON_SKILL_INVENTION",
    skill_summoning = "HITMARK_ICON_SKILL_SUMMONING",
    skill_slayer = "HITMARK_ICON_SKILL_SLAYER",
    skill_prayer = "HITMARK_ICON_SKILL_PRAYER",
    skill_attack = "HITMARK_ICON_SKILL_ATTACK",
    skill_ranged = "HITMARK_ICON_SKILL_RANGED",
    skill_magic = "HITMARK_ICON_SKILL_MAGIC",
    skill_necromancy = "BP3_MISSION_ICON_SKILL_NECROMANCY",

    -- The rest of the skills, from the same reference list (added for the Wiki
    -- catalogue import; not yet seen in game). Hunter's sprite is named HUNTING.
    skill_agility = "HITMARK_ICON_SKILL_AGILITY",
    skill_archaeology = "HITMARK_ICON_SKILL_ARCHAEOLOGY",
    skill_constitution = "HITMARK_ICON_SKILL_CONSTITUTION",

    -- The client's SkillType for Constitution is HITPOINTS; same icon.
    skill_hitpoints = "HITMARK_ICON_SKILL_CONSTITUTION",
    skill_construction = "HITMARK_ICON_SKILL_CONSTRUCTION",
    skill_cooking = "HITMARK_ICON_SKILL_COOKING",
    skill_crafting = "HITMARK_ICON_SKILL_CRAFTING",
    skill_defence = "HITMARK_ICON_SKILL_DEFENCE",
    skill_divination = "HITMARK_ICON_SKILL_DIVINATION",
    skill_dungeoneering = "HITMARK_ICON_SKILL_DUNGEONEERING",
    skill_farming = "HITMARK_ICON_SKILL_FARMING",
    skill_firemaking = "HITMARK_ICON_SKILL_FIREMAKING",
    skill_fishing = "HITMARK_ICON_SKILL_FISHING",
    skill_fletching = "HITMARK_ICON_SKILL_FLETCHING",
    skill_herblore = "HITMARK_ICON_SKILL_HERBLORE",
    skill_mining = "HITMARK_ICON_SKILL_MINING",
    skill_runecrafting = "HITMARK_ICON_SKILL_RUNECRAFTING",
    skill_strength = "HITMARK_ICON_SKILL_STRENGTH",
    skill_thieving = "HITMARK_ICON_SKILL_THIEVING",
    skill_hunter = "HITMARK_ICON_SKILL_HUNTING",
}
