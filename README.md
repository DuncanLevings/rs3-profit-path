# Profit Path

An RS3 plugin for planning money making. It lists every RuneScape Wiki money making guide (674 activities), works out each one's profit from live Grand Exchange prices, checks the requirements against your account, and can suggest an activity that suits you.

It's a planning tool only: it never plays for you, gives no live combat or movement advice, and opens no links.

## Getting started

Install **PrettyUI** and **GE Prices Library** from the Plugin Hub; Profit Path needs both. Then press **Open Profit Path** in the Plugins ribbon. It opens its own window, which you can move and resize.

Open your bank once after logging in. The game only lets plugins see the bank while it's open, so until then item requirements can't be fully checked. After that, a closed bank counts as it was when you last saw it.

## Finding an activity

The sidebar has four sections:

- **Browse**: every activity, grouped into PvM, Skilling, Production and Recurring (daily and weekly runs). Search by name, sort by profit or ROI, and filter by intensity, difficulty and whether you meet the requirements.
- **Recommend for me**: pick a group and get one suggestion at a time, with the reasons it fits. **Show another** moves on, and **Don't recommend** stops suggesting that activity (with Undo). PvM suggestions follow your PvM comfort level.
- **Favourites**: the activities you starred.
- **My account**: your recommendation settings (PvM comfort from 1 to 10, harder "learning" suggestions, solo or group), and the activities you've chosen not to have recommended.

## An activity's page

- **Income**: what you spend and earn each hour (or each run), with profit and ROI at current GE prices. Change the rate to match your own pace and **Save** it; **Reset** goes back to the guide's rate.
- **Requirements**: the guide's requirements, marked as met, missing or unknown for your account. Hover a line for more detail.
- **How to do it** and **Getting there**: a short summary of the guide and how to reach the area.

Activities the Wiki marks as risky show its warning.

### What's checked

Skill levels, combat level, quests, relics and other unlocks, achievements, and items in your backpack, worn gear, bank and tool belt, including "any tier 90+ weapon" style gear checks.

Some things can't be seen by plugins (Invention perks, some unlocks and shop upgrades). Those are listed for you to check yourself and don't count against an activity.

## Custom activities

**Create activity** opens an editor for your own activities. Start from a monster's drops, a thieving target's loot or nothing at all, or use **Duplicate as custom** on any activity page to edit a copy. Set the outputs, supplies, rate, requirements and your own steps; PvM activities also get a difficulty from 1 to 10.

Custom activities show in Browse (use **Show: Custom only** to list just them), Favourites and Recommend for me.

To share one, press **Export** on its page and copy the line of text (Ctrl+A, Ctrl+C). Someone else pastes it into **Import activity**, checks what it holds and adds it. Only the activity itself is shared, never your prices, rates or account.

## Good to know

- Profit is an estimate from the guide's rates and current GE prices, not a promise.
- Settings, favourites and saved rates are kept per character, on this computer only. Changing your display name starts fresh settings; the old ones stay saved.
- Nothing is sent anywhere. Profit Path reads your account to check requirements and keeps item counts locally so a closed bank can still be counted.
- The window's position isn't remembered after a reload.

## Contact

Tatsuya636@hotmail.com

## How it was built

- Written in Lua for the RuneScape plugin client, using PrettyUI for the interface and GE Prices Library for prices.
- Activity data is a bundled snapshot from the RuneScape Wiki (CC BY-NC-SA 3.0), with PvM difficulty ratings researched with help from PvME. The plugin never contacts the Wiki while you play. Attribution is in `THIRD_PARTY_NOTICES.txt`.
