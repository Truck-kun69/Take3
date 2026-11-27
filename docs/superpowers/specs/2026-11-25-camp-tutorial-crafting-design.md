# The Camp, the tutorial and camp crafting (0.11.0-alpha)

Request (25 Nov 2026): "implement further critical fixes and tweaks, like the UI, the tutorial, weaponsmithing,
salvage benches, fusion furnace for items and weapons, other friendly NPCs". The user opted out of design
questions, so every call below is mine.

## Intent

Give the time between runs a place and a purpose. Today a run ends on the title screen, gold piles up in the
profile with nothing to spend it on (`Save.data.gold` has no sink; only the in-run merchant spends run gold),
gear crafting is one dense stash page, and a new player gets a narrated intro but no lesson in the controls.

## Goals

- A Camp hub with friendly NPCs, each running one station, reachable from the title.
- Weaponsmithing that matters although weapons only live inside a run.
- A salvage bench, and a fusion furnace for gear and for weapons.
- A first-run tutorial that teaches by doing, on a phone.
- UI tweaks found along the way (title bar, stash, end screen).

Non-goals: a walkable 3D camp (new art, new scenes and controls for a menu's job); new voice recordings
(they cost money, so NPC lines are text); changing in-run balance beyond the opt-in camp bonuses.

Anti-goals: a camp that slows the loop (every station is two taps from the title and one from the next
run); a tutorial that blocks play or nags (steps finish on their own, time out, and can be turned off).

## Approaches considered

1. **Camp as a menu hub** (chosen): one Camp page of NPC cards, each opening a station page built with the
   existing Screens/UIKit kit. Cheap, phone friendly, consistent with every other page.
2. Walkable 3D camp on the title stage: richer but needs NPC models (paid generation), pathing and a new
   input mode. Rejected for cost and time.
3. Stations folded into the existing stash page: least work, but the stash page is already dense and the
   request names NPCs. Rejected.

Weaponsmithing options: (a) **permanent Temper ranks per weapon** (chosen: a run applies them when the
weapon is picked up; gives gold a sink); (b) a persistent weapon inventory (would rework the run's weapon
offers); (c) cosmetic only (does not matter).

Weapon fusion options: (a) **Kindling a fusion pair** at the furnace (chosen: that pair may fuse in a run as
soon as both weapons reach level 5, evolved or not, and kindled fusions hit harder); (b) fusion cores used up
per run (bookkeeping for little gain).

Tutorial options: (a) **contextual coach in the first runs** (chosen); (b) a separate training arena (more
content, players skip it); (c) a static how-to page only (kept as the Drillmaster's page, not the lesson).

## Design

New profile fields (`Save.defaults`, normalised on load, forward compatible):
`materials {scrap, ore}`, `temper {weapon id: rank 0-5}`, `kindled [fusion keys]`, `locked [item uids]`,
`trader {day, rolls, stock, sold}`, `tutorial {on, done [step ids]}`, `camp_seen`.

Materials: **Scrap** comes from salvaging gear (Normal 2, Magic 4, Rare 8, Legendary 20, on top of today's
currency yield). **Rift Ore** comes from runs: 1 per Rift Champion, 3 for an act's tyrant, 1 per 400 kills,
at most 12 a run; none from the Daily Rift (everyone starts equal there).

NPCs and stations (`scripts/sim/camp.gd` holds the rules as static functions, tested; the pages live in
`scripts/ui/camp_pages.gd`):

- **Doran Ashhand, Weaponsmith**: Temper any unlocked weapon, ranks 1-5. Each rank +8% damage for that
  weapon; rank 3 also -8% cooldown; rank 5 (Masterwork) a further 10% more damage. Costs gold, ore and scrap,
  rising per rank. A run applies the ranks to a weapon's own stats when it is taken (not in the Daily Rift).
- **Nim, Salvager** (salvage bench): salvage every unlocked item of a rarity at once (Normal, Magic, Rare;
  never Legendary, never equipped or locked), with the yield shown first. Items can be locked in the stash.
- **Mother Kiln, Fusion Furnace**: Gear: three unlocked items of one slot and rarity become one new item of
  that slot a rarity higher (Rare to Legendary also takes a Divine Shard), item level the highest of the three.
  Weapons: kindle a pair (any two unlocked weapons) for gold and ore; in a run that pair may fuse at level 5
  without evolving, and a kindled fusion deals 35% more damage instead of 25%.
- **Sella Coinwright, Trader**: four items a day (seeded by the date and the profile's progress) and
  crafting shards, for gold; one paid restock a day.
- **Captain Brask, Drillmaster**: How to Play, the tutorial switch, Replay tutorial.
- **The Chronicler** and **the Cartographer** front the existing Codex & Story and Modes pages.

Tutorial coach (`scripts/ui/coach.gd`): in a campaign run while `tutorial.on` and steps remain, one prompt
at a time over the HUD, with a pulsing ring on the touch button it names. Steps: move, let the weapons fire
(5 kills), gather shards (level 2), pick a card (on the level-up page), roll, drink a flask (when hurt), jump,
ultimate (when charged), loot (first item). Each finishes when the player does it; an untriggered contextual
step waits; a prompt fades after 9 s. Options > Game: Tutorial tips on/off and Replay tutorial.

UI tweaks: the title's bar gets Camp in place of Gear (gold when the camp has something new or affordable);
stash items sort by rarity then score and show a lock; the end-of-run page lists the ore earned and offers
Camp; the stash's Salvage shows its yield.

## Left to the builder

Exact copy, colours, NPC medallion drawing, and cost numbers beyond the tables above (tuned in tests).

## After the first build (0.11.0 to 0.11.1)

- Prices were set from bot runs of Act I (`tests.tscn -- sim` with `SIM_QUICK=1` reports gold, ore, items and the
  scrap they would salvage to): a run banks 500-10,000 gold, 1-12 Rift Ore and 10-50 items, so the first gold
  prices were about four times too low. Ore paces the smith: a masterwork takes 10,100 gold, 22 ore and 118 scrap.
- A friendly NPC met in a run (my call, from "other friendly NPCs"): the **Wayside Forge**, a director event
  (not in Greater Rifts). Ash, Doran's apprentice, hones each weapon carried once a forge: one temper rank for
  the run, 80 run gold a rank (`World.hone_weapon`), stacking on the Camp's rank, never past a masterwork.
- A full stash (80) salvages the weakest unlocked find below Legendary at the bench's rates, never a locked item
  or a Legendary (a Legendary takes the stash over the cap).
