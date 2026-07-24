class_name Tuning
## Central tuning knobs for LIMINAL's horror pacing, difficulty, and look.
## Edit THIS file to retune the game — never chase magic numbers through the
## world scripts. Every knob is documented in docs/design/game-design.md.

# ---------------------------------------------------------------------------
# Debug
# ---------------------------------------------------------------------------
const DEBUG_ENTITY_LOG := true          # print vulto state transitions (debug builds only)

# ---------------------------------------------------------------------------
# Run phases (seconds since run start)
# ---------------------------------------------------------------------------
const JUMP_ARM_TIME := 100.0           # natural jumpscares only after the player has learned the space
const CHASE_ARM_TIME := 150.0          # natural chases start after the co-op reunion window
const FINAL_PHASE_TIME := 600.0         # minute 10: permanent slow stalker

# ---------------------------------------------------------------------------
# Player movement and sound
# ---------------------------------------------------------------------------
const WALK_SPEED := 2.4
const CROUCH_SPEED := 1.15
const SPRINT_SPEED := 4.75
const SPRINT_MAX_SECONDS := 6.0
const SPRINT_REGEN_SECONDS := 7.0       # empty to full
const SPRINT_REGEN_DELAY := 0.0
const SPRINT_EXHAUST_RECOVERY := 1.0    # emptying it forces the full 7-second recovery
const NOISE_RANGE_CROUCH := 0.0       # controlled crouch footsteps do not alert it
const NOISE_RANGE_WALK := 2.5         # audible only when extremely close
const NOISE_RANGE_SPRINT := 12.0      # heavy impacts carry down the corridor leg

# ---------------------------------------------------------------------------
# Telephone risk/reward
# ---------------------------------------------------------------------------
const PHONE_TRAP_PERCENT := 0.22
const PHONE_TRAP_COOLDOWN := 60.0
const PHONE_COUNT := 4
const PHONE_RADAR_PINGS := 4
const PHONE_RADAR_PING_MIN_GAP := 2.4
const PHONE_RADAR_PING_MAX_GAP := 3.8

# ---------------------------------------------------------------------------
# Co-op reunion and communication
# ---------------------------------------------------------------------------
const COOP_CALLOUT_COOLDOWN := 10.0
const COOP_CALLOUT_HEARING_RANGE := 75.0
const COOP_DOWNED_CALLOUT_HEARING_RANGE := 85.0
const COOP_CALLOUT_ENTITY_RANGE := 28.0
const COOP_CALLOUT_VOLUME_DB := 2.0
const SOLO_SPAWN_MIN_CELLS := 2
const SOLO_SPAWN_MAX_CELLS := 5
const COOP_SPAWN_MIN_CELLS := 6
const COOP_SPAWN_MAX_CELLS := 11
const COOP_SPAWN_MIN_SEPARATION := 8.0

# ---------------------------------------------------------------------------
# Survivor mimic (personal hallucination)
# ---------------------------------------------------------------------------
const MIMIC_ARM_TIME := 120.0
const MIMIC_MIN_GAP := 110.0
const MIMIC_MAX_GAP := 190.0
const MIMIC_MAX_PER_RUN := 2
const MIMIC_MIN_DISTANCE := 10.0
const MIMIC_MAX_DISTANCE := 17.0
const MIMIC_WITNESS_TIME := 0.7

# ---------------------------------------------------------------------------
# Objective pacing
# ---------------------------------------------------------------------------
const OBJECTIVE_EVENT_HOLD := 7.0      # no fresh scare is scheduled on top of a pickup
const MIMIC_UNLOCK_SNUS := 4
const ENTITY_INITIAL_SPAWN_DELAY := 15.0

# ---------------------------------------------------------------------------
# Entity perception — what the roaming Entity actually notices
# ---------------------------------------------------------------------------
# Line of sight is the real gate: walls stop the ray long before these numbers
# matter. Standing inside its cone down a clear corridor means it sees you.
const ENTITY_SIGHT_RANGE := 34.0
# Crouching lowers your silhouette; it never turns you invisible.
const ENTITY_SIGHT_RANGE_CROUCHED := 19.0
# Closer than this, crouching buys nothing at all — it is looking right at you.
const ENTITY_CROUCH_NO_HELP_DIST := 7.0

# ---------------------------------------------------------------------------
# Confused — it lost you mid-chase and has not given up yet
# ---------------------------------------------------------------------------
# How long it stands there looking for you before losing interest and roaming.
const CONFUSED_DURATION := 3.0
# Spotting you inside this window drops it straight back into the chase, so the
# only safe play is real cover until it walks away.
const CONFUSED_REACQUIRE_RANGE := 16.0
# The howl dies away instead of being cut, which is the audible tell that the
# chase is breaking.
const CHASE_AUDIO_FADE := 0.9
# CX35 — THE escape mechanic, not a safety valve. The Entity runs at 7.2 m/s and
# the player sprints at 4.75 m/s for six seconds, so outrunning it is impossible
# by design: breaking its line of sight is the only way out. It still hunts your
# last known position during these seconds (it does not stop dead), but if it
# has not re-acquired you by then, it gives up. At 12.0 this was 86 m of blind
# pursuit and the game became unescapable.
const CHASE_BLIND_GIVE_UP := 3.5
# Progress towards escaping BLEEDS OFF instead of snapping back to zero. Running
# to your last known position turns the Entity to face you, so a 110-degree cone
# re-acquires you for a fraction of a second at every corner. With a hard reset
# that made corner-cutting worthless: four corners accumulated nothing. Only
# sustained open-corridor visibility should undo an escape.
const CHASE_REACQUIRE_DECAY := 1.0
# A chase must not re-acquire you across the whole map down a straight corridor;
# that reset the blind timer forever. Walls still do the real work.
const CHASE_SIGHT_RANGE := 26.0

# ---------------------------------------------------------------------------
# Apparitions (peek / shadow / jumpscare)
# ---------------------------------------------------------------------------
# CX34 — apparitions now have their own body and never disturb the one shared
# Entity, so the old "vacate the roam" knobs (APPARITION_ROAM_MIN_DISTANCE and
# APPARITION_ROAM_HOLD) are gone. The only rule left is that a hallucination and
# the real Entity must never be on the same screen at once, which is a live
# visibility test rather than a tunable distance.

# CX36 — an apparition is a silhouette 7-14 m away, usually at an unlit corner.
# At the shared Entity's 0.42x albedo it rendered as a featureless black blob.
# This lifts it so the watcher is readable without turning it into a lit prop.
const APPARITION_BRIGHTNESS := 2.1

# ---------------------------------------------------------------------------
# Entity turning (radians/second)
# ---------------------------------------------------------------------------
# CX36 — locomotion used to rewrite the yaw with look_at() every frame, so
# rounding a corner was an instant 180-degree snap. Chase stays quick enough to
# corner convincingly; roaming is heavier because nothing is urgent.
const ENTITY_TURN_RATE_CHASE := 5.0
const ENTITY_TURN_RATE_ROAM := 2.2

# ---------------------------------------------------------------------------
# Vultos — peek (the watchers)
# ---------------------------------------------------------------------------
const PEEK_FIRST_SIGHTING := 18.0      # initial sighting delay (halved)
const PEEK_DIST_MIN := 3.5             # distance band to find cover sightlines
const PEEK_DIST_MAX := 22.0
const PEEK_VANISH_DIST := 2.0          # closer than this -> gone
const PEEK_MUFFLE_DIST := 8.0          # near-but-unseen -> hum drops
const PEEK_GAP_EARLY := 33.0            # early run gap between peeks (halved from 65s)
const PEEK_GAP_LATE := 16.0            # late run gap between peeks (halved from 32s)
const PEEK_HOLD_MIN := 2.0
const PEEK_HOLD_MAX := 4.0
const PEEK_HARD_TIMEOUT := 15.0

# ---------------------------------------------------------------------------
# Vultos — jumpscare
# ---------------------------------------------------------------------------
const JUMP_MAX_PER_RUN := 3
const JUMP_MIN_GAP := 90.0             # never two jumpscares within 1.5 min
const JUMP_DURATION := 0.5              # half a second, face filling the screen
const JUMP_CALM_MIN := 15.0             # forced calm after a jumpscare
const JUMP_CALM_MAX := 30.0
const PRE_JUMP_CALM_WINDOW := 15.0      # false-security silence before each scare

# ---------------------------------------------------------------------------
# Vultos — shadow (the silent tail: follows wall cover, only ever seen
# mid-peek when the player turns around, hides half a second later)
# ---------------------------------------------------------------------------
const SHADOW_ARM_TIME := 70.0          # tails arrive after the first distant sightings
const SHADOW_GAP_MIN := 40.0           # seconds between tail attempts
const SHADOW_GAP_MAX := 90.0
const SHADOW_REVEAL_HOLD := 0.5         # how long it lets you see it looking
const SHADOW_MAX_TIME := 45.0           # a tail never outstays this

# ---------------------------------------------------------------------------
# Vultos — chase
# ---------------------------------------------------------------------------
const CHASE_MAX_PER_RUN := 2
const CHASE_SPEED := 7.2                # High-speed terrifying scuttle (Player sprint is 4.75 m/s)
const CHASE_SPAWN_MIN := 17.0           # heard at range before the charge enters view
const CHASE_SPAWN_MAX := 25.0
const CATCH_DIST := 1.85
# CX33b — retired. This governed the apparition-era rule "the player stopped
# looking at it, so it was never there". A persistent Entity must instead walk
# to your last known position; see CHASE_BLIND_GIVE_UP.
const CHASE_PATH_REFRESH := 0.4         # BFS repath interval
const CHASE_NO_ROUTE_TIMEOUT := 4.0     # sealed off this long → dissolves

# ---------------------------------------------------------------------------
# Vultos — stalk (final phase)
# ---------------------------------------------------------------------------
const STALK_SPEED := 1.4
const STALK_KEEP_DISTANCE := 2.2        # stops just outside contact; lingering close is the threat
const STALK_LINGER_KILL := 10.0         # only counts while close, still, and completely unobserved
const STALK_DANGER_DISTANCE := 2.7
const STALK_PATH_REFRESH := 0.3
const STALK_GAZE_TIMEOUT := 0.45        # tolerate relay jitter without statue flicker
const STALK_SPAWN_DISTANCE := 12.0
const STALK_START_GRACE := 5.0
const STALK_EXIT_GRACE := 8.0           # readable head start when "Locate the door" begins
const FLEE_SPEED := 6.2                 # fast retreat after a down; visibly runs away
const FLEE_MIN_DISTANCE := 12.0         # enough to break body-camping
const FLEE_MAX_DISTANCE := 22.0         # but never grants a map-wide safe revive
const REVIVE_PRESSURE_DELAY := 4.5      # short rescue window before pressure returns
const REVIVE_PRESSURE_MIN_DISTANCE := 10.0
const REVIVE_PRESSURE_MAX_DISTANCE := 18.0

# ---------------------------------------------------------------------------
# Ambient sound events
# ---------------------------------------------------------------------------
const SOUND_GAP_MIN := 18.0             # unexplained distant events cadence
const SOUND_GAP_MAX := 40.0

# ---------------------------------------------------------------------------
# Maze look & layout (STATIC — same for every client and every revisit)
# ---------------------------------------------------------------------------
# Level 0 is "randomly segmented": clusters of enclosed rooms joined by open,
# pillared halls — not a uniform openness, not a tight maze. A low-frequency
# region field varies wall density between HALL (open) and ROOM (enclosed) so
# the map reads segmented. Still a pure function of coords → co-op stays synced.
const WALL_DENSITY := 0.22              # legacy uniform value (kept for reference)
const WALL_DENSITY_HALL := 0.2         # open pillared halls — few walls
const WALL_DENSITY_ROOM := 0.52        # enclosed room clusters — many walls
const REGION_SIZE := 5                 # cells per region (~20 m zones)
const ROOM_ZONE_BIAS := 0.52           # fraction of the map that is room clusters
const PILLAR_DENSITY := 0.3            # base column chance (concentrated in halls)
const LIT_THRESHOLD := 0.20             # lower threshold → more light panels
const DARK_ZONE_CHANCE := 0.24          # open cells that stay genuinely dark
const ANOMALY_CHANCE := 0.015           # wrong-chair / off-hook-phone rooms
const DARK_ALCOVE_CHANCE := 0.30        # rare dead ends dressed as black recesses
const ROOM_THRESHOLD_CHANCE := 0.035    # occasional chunky room portals
const MAP_DRESSING_CHANCE := 0.055      # restrained furniture/maintenance traces
const PANEL_ENERGY := 4.0              # hot panels burning against the dark
# GL Compatibility renderer HARD LIMITS: too many overlapping OmniLights get
# dropped per-mesh ARBITRARILY → neighbouring floor/wall slabs light up
# differently (the harsh black/bright patchwork). Keep range modest so each
# mesh sees <16 lights; project.godot raises the GL limits to 64 total / 16
# per object. Brightness between pools comes from AMBIENT_ENERGY, not range.
const LIGHT_ENERGY := 2.3              # OmniLight energy when steady (slightly darker)
const LIGHT_RANGE := 5.5               # pool radius — must stay ~< 1.5 cells
const LIGHT_ATTENUATION := 1.1         # soft edge, no hard cutoff

# ---------------------------------------------------------------------------
# Atmosphere (reference: sickly Level 0 fluorescents, deep neutral shadows,
# restrained yellow-green colour)
# ---------------------------------------------------------------------------
const AMBIENT_ENERGY := 1.3            # slightly darker ambient; shadows go black
const FOG_DENSITY := 0.003               # gloom closes in sooner
