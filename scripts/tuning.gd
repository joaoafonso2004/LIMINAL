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
const JUMP_ARM_TIME := 40.0            # jumpscares possible from 40s
const CHASE_ARM_TIME := 60.0           # chases possible from 1 min
const FINAL_PHASE_TIME := 600.0         # minute 10: permanent slow stalker

# ---------------------------------------------------------------------------
# Vultos — peek (the watchers)
# ---------------------------------------------------------------------------
const PEEK_FIRST_SIGHTING := 6.0       # ± random offset, first watcher happens quickly
const PEEK_DIST_MIN := 6.5              # spawn distance band (closer so we can find clear sightlines)
const PEEK_DIST_MAX := 14.0
const PEEK_VANISH_DIST := 3.5           # closer than this → gone before it's seen up close
const PEEK_MUFFLE_DIST := 8.0           # near-but-unseen → hum drops, world muffles
const PEEK_GAP_EARLY := 12.0            # seconds between watchers at run start…
const PEEK_GAP_LATE := 6.0             # …shrinking to this by minute 10

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
const SHADOW_ARM_TIME := 50.0          # tails possible from 50s
const SHADOW_GAP_MIN := 40.0           # seconds between tail attempts
const SHADOW_GAP_MAX := 90.0
const SHADOW_REVEAL_HOLD := 0.5         # how long it lets you see it looking
const SHADOW_MAX_TIME := 45.0           # a tail never outstays this

# ---------------------------------------------------------------------------
# Vultos — chase
# ---------------------------------------------------------------------------
const CHASE_MAX_PER_RUN := 2
const CHASE_SPEED := 4.15               # player walks at 2.4 — much faster than player
const CATCH_DIST := 1.35
const LOS_LOSE_TIME := 2.0              # seconds out of sight before it vanishes
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
# Atmosphere (reference: dark A24-still grade — isolated warm pools, deep
# brown-black shadows, drained colour)
# ---------------------------------------------------------------------------
const AMBIENT_ENERGY := 1.3            # slightly darker ambient; shadows go black
const FOG_DENSITY := 0.003               # gloom closes in sooner
