class_name Story
extends RefCounted
## "The Shattering of the Veil": the campaign's story, one entry per act (Content.STAGES order), plus the four
## exiles' bios and the one mechanic each is built around. Read by the act banner and the boss nameplate (Hud),
## the Rift Echoes (World: two shards per act, each one fragment of the act's story), the Codex's Story and
## Exiles pages and the Heroes screen. Spoken lines live in data/voice_manifest.json, never here: this is the
## written half of the story (tools/gate_check.py checks that no voice line's text is copied into a script).

const TITLE := "The Shattering of the Veil"
const ECHO_SURGE_S := 10.0            # a Rift Echo's surge (Content.BUFFS.rift_surge)

const ACTS := [
	{"title": "Mossglen Hollow", "subtitle": "Act I · Where the first shard fell",
		"intro_lines": ["The Veil was the sky's skin, and for a thousand years nothing pierced it.",
			"Then it split above the Hollow, and a shard the size of a chapel came down among the oaks.",
			"The roots drank its light. They have been thirsty ever since."],
		"boss_name": "Elder Thornback", "boss_taunt": "Root and ruin. The Hollow is hungry, little exile.",
		"victory_note": "The Elder's roots go still. Under them the shard still hums, a little quieter.",
		"echoes": [
			{"title": "The Woodward's Ledger", "text": "Day nine. The wisps no longer lead travellers home. They lead them to the stump that drinks."},
			{"title": "A Child's Charm", "text": "Twine and a robin's feather, knotted to keep the sky shut. It did not."}]},
	{"title": "Cinder Wastes", "subtitle": "Act II · The burn that never cooled",
		"intro_lines": ["Where the largest shards struck, the ground caught fire and forgot how to stop.",
			"The ash still falls on the slag rivers, grey as old snow and twice as patient.",
			"Something under the crust has been growing fat on the heat."],
		"boss_name": "Cindermaw", "boss_taunt": "Feed the furnace. I will start with your bones.",
		"victory_note": "Cindermaw cools to black glass. For one breath the wind tastes of rain.",
		"echoes": [
			{"title": "The Foundry Bell", "text": "We rang it for the shardfall. We rang it until the bronze ran down the tower like honey."},
			{"title": "Smith's Last Order", "text": "Forge me a blade that does not melt. Forge it quickly. The ground is singing again."}]},
	{"title": "Gravebound Crypt", "subtitle": "Act III · The dead who would not stay",
		"intro_lines": ["The old kings were buried with shards in their hands, to light the road beneath.",
			"The light found its way back up instead, and carried the kings with it.",
			"Their halls are cold, and their courtiers still bow to a throne of bone."],
		"boss_name": "The Pale Regent", "boss_taunt": "Kneel. The court is in session, and you are the accused.",
		"victory_note": "The Regent's crown rolls into the dark. The courtiers finally lie down.",
		"echoes": [
			{"title": "Funeral Writ", "text": "Let the shard be closed in her fist, that she may find her way through the dark. And back."},
			{"title": "Gravedigger's Note", "text": "Dug the same grave three times this week. It keeps being empty."}]},
	{"title": "Neon Rift", "subtitle": "Act IV · The seam beneath the world",
		"intro_lines": ["Here the Veil did not crack. It tore, and the lattice beneath the world shows through.",
			"Light runs along it like water in a gutter, cold and humming and wrong.",
			"Whatever built the lattice is still running it."],
		"boss_name": "Overclock Prime", "boss_taunt": "Process: exile. Result: deletion. Proceed.",
		"victory_note": "Overclock Prime stutters, loops, and stops. The hum drops half a tone.",
		"echoes": [
			{"title": "Surveyor's Sketch", "text": "Lines beneath the stone, perfect and square. The world was drawn before it was made."},
			{"title": "Fragment of a Hymn", "text": "Sing the grid and the grid will hold. Stop singing, and it remembers it was never real."}]},
	{"title": "Drowned Cathedral", "subtitle": "Act V · The bells beneath the tide",
		"intro_lines": ["The last of the faithful rang the bells as the sea came in through the rift.",
			"The water has not stopped rising since, and the bells have not stopped ringing.",
			"At the bottom of the nave, the first shard waits, and it is listening."],
		"boss_name": "The Tide Bishop", "boss_taunt": "The sea has taken confession. Now it takes you.",
		"victory_note": "The bells fall silent. In the hush, the Veil above begins, slowly, to knit.",
		"echoes": [
			{"title": "Choir Ledger", "text": "Forty voices on the feast of shards. Thirty by the second hymn. By vespers, only the water sang."},
			{"title": "The Bishop's Vow", "text": "I will hold the doors until the tide turns. I will hold them after."}]},
]

## The exiles (Content.HEROES order by id): who they are, and the one mechanic each is built around (Heroes
## screen and the Codex's Exiles page).
const HEROES := {
	"warden": {"title": "The Last Shieldwall",
		"bio": "Once captain of a shieldwall that held a pass for nine days, the Warden walked out of the rift with three shard-forged blades orbiting him like loyal hounds. He does not talk about the other ninety-nine.",
		"mechanic": "Vault Slam", "mechanic_d": "Jump over a boulder or a low wall and come down in a crater: a 110-wide slam for 1.5x your blades' damage that hurls the pack back."},
	"spark": {"title": "Frost in the Veins",
		"bio": "A court mage's apprentice who touched a cold shard on a dare. The frost never left her hands; neither did the habit of firing first.",
		"mechanic": "Ricochet", "mechanic_d": "Rime Bolts glance off stone (rocks, walls and pillars) up to twice, 25% harder with every bounce, in a burst of sparks."},
	"ember": {"title": "Keeper of the Last Flame",
		"bio": "The Emberwitch tended the foundry bell's fire until the bell itself melted. She carries what was left of that fire in her ribs, and it is always hungry.",
		"mechanic": "Contagion", "mechanic_d": "Incineration lands on the densest pack and leaves the ground burning. Burn stacks to five and ramps; burning foes pass the fire on, the dying go up in conflagrations, and trees catch like beacons."},
	"storm": {"title": "The Weather's Debt",
		"bio": "Forty years the Stormwright measured the sky from his tower, until a shard fell through its roof. Now the tempest takes his dictation, and he has never once let it forget who is speaking.",
		"mechanic": "Conduction", "mechanic_d": "Skyfall striking shallow water or near a rift crystal spreads: twice the radius, and arcs branch to the foes just outside the blast."},
}

## What an exile mutters on touching a Rift Echo, before the narrator reads the fragment (two each, alternating).
const ECHO_REPLIES := {
	"warden": ["Another voice the rift kept. I'll carry it.", "Old words. Still sharper than most blades."],
	"spark": ["Cold. Like someone's still holding it.", "Huh. The rift remembers more than I do."],
	"ember": ["Still warm. Someone loved this place.", "Ash and memory. I know the taste."],
	"storm": ["Fascinating. The rift keeps records.", "Another specimen for the archive. Note it."],
}

static func act(i: int) -> Dictionary:
	return ACTS[clampi(i, 0, ACTS.size() - 1)]

## The act's Rift Echo fragment k (0 or 1).
static func echo(i: int, k: int) -> Dictionary:
	return act(i).echoes[clampi(k, 0, 1)]

static func hero(id: String) -> Dictionary:
	return HEROES.get(id, HEROES.warden)

## The Save key of an act's echo fragment (Save.data.rift_echoes holds the ones found).
static func echo_key(i: int, k: int) -> String:
	return "a%d_%d" % [i, k]
