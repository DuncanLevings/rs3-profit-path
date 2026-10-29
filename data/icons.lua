-- The small set of native sprite names Profit Path draws, keyed by the short alias
-- the views use. This isn't a copy of rsprite's catalogue: names were picked from
-- its client 950-1 reference list, and rsprite resolves them against the running
-- client (and refuses sprites known to crash it).
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

    -- Same stopwatch-reset art PrettyUI uses for its UNDO sprite button.
    reset = "RS3_ICON_STOPWATCH_RESET_0",

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
}
