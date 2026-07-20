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
const NOISE_RANGE_CROUCH := 2.5
const NOISE_RANGE_WALK := 8.0
const NOISE_RANGE_SPRINT := 22.0

# ---------------------------------------------------------------------------
# Telephone risk/reward
# ---------------------------------------------------------------------------
const PHONE_TRAP_PERCENT := 0.30
const PHONE_TRAP_COOLDOWN := 60.0
const PHONE_COUNT := 6
const PHONE_RADAR_PINGS := 4
const PHONE_RADAR_PING_MIN_GAP := 2.4
const PHONE_RADAR_PING_MAX_GAP := 3.8

# ---------------------------------------------------------------------------
# Co-op reunion and communication
# ---------------------------------------------------------------------------
const COOP_CALLOUT_COOLDOWN := 10.0
const COOP_CALLOUT_HEARING_RANGE := 32.0
const COOP_DOWNED_CALLOUT_HEARING_RANGE := 56.0
const COOP_CALLOUT_ENTITY_RANGE := 20.0
const COOP_CALLOUT_VOLUME_DB := -11.0
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
const ENTITY_HEARS_FOOTSTEPS_FROM_SNUS := 3
const MIMIC_UNLOCK_SNUS := 4

# ---------------------------------------------------------------------------
# Vultos — peek (the watchers)
# ---------------------------------------------------------------------------
const PEEK_FIRST_SIGHTING := 35.0      # first unease after the initial orientation window
const PEEK_DIST_MIN := 6.5              # spawn distance band (closer so we can find clear sightlines)
const PEEK_DIST_MAX := 14.0
const PEEK_VANISH_DIST := 3.5           # closer than this → gone before it's seen up close
const PEEK_MUFFLE_DIST := 8.0           # near-but-unseen → hum drops, world muffles
const PEEK_GAP_EARLY := 32.0            # watchers stay unsettling, not repetitive
const PEEK_GAP_LATE := 26.0             # late-game pressure rises without peek spam

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
const CHASE_SPEED := 5.6                # faster than the player's short 4.75 m/s sprint
const CHASE_SPAWN_MIN := 17.0           # heard at range before the charge enters view
const CHASE_SPAWN_MAX := 25.0
const CATCH_DIST := 1.35
const LOS_LOSE_TIME := 3.0              # corners buy time, but do not cancel it instantly
const CHASE_PATH_REFRESH := 0.4         # BFS repath interval
const CHASE_NO_ROUTE_TIMEOUT := 4.0     # sealed off this long → dissolves

# ---------------------------------------------------------------------------
# Vultos — stalk (final phase)
# ---------------------------------------------------------------------------
const STALK_SPEED := 1.4
const STALK_KEEP_DISTANCE := 4.0
const STALK_LINGER_KILL := 6.0          # stand still this long and it takes you

# ---------------------------------------------------------------------------
# Ambient sound events
# ---------------------------------------------------------------------------
const SOUND_GAP_MIN := 18.0             # unexplained distant events cadence
const SOUND_GAP_MAX := 40.0

# ---------------------------------------------------------------------------
# Maze look & layout (STATIC — same for every client and every revisit)
# ---------------------------------------------------------------------------
const WALL_DENSITY := 0.22              # fraction of cell edges with wall slabs
const PILLAR_DENSITY := 0.3             # fraction of cell corners with columns
const LIT_THRESHOLD := 0.20             # lower threshold → more light panels
const DARK_ZONE_CHANCE := 0.24          # open cells that stay genuinely dark
const ANOMALY_CHANCE := 0.015           # wrong-chair / off-hook-phone rooms
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
