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
const JUMP_ARM_TIME := 300.0            # jumpscares possible from minute 5
const CHASE_ARM_TIME := 480.0           # chases possible from minute 8
const FINAL_PHASE_TIME := 600.0         # minute 10: permanent slow stalker

# ---------------------------------------------------------------------------
# Vultos — peek (the watchers)
# ---------------------------------------------------------------------------
const PEEK_FIRST_SIGHTING := 60.0       # ± random offset, first watcher ~1-1.5 min
const PEEK_DIST_MIN := 11.0             # spawn distance band (open-plan sightlines)
const PEEK_DIST_MAX := 20.0
const PEEK_VANISH_DIST := 6.0           # closer than this → gone before it's seen up close
const PEEK_MUFFLE_DIST := 10.0          # near-but-unseen → hum drops, world muffles
const PEEK_GAP_EARLY := 70.0            # seconds between watchers at run start…
const PEEK_GAP_LATE := 22.0             # …shrinking to this by minute 10

# ---------------------------------------------------------------------------
# Vultos — jumpscare
# ---------------------------------------------------------------------------
const JUMP_MAX_PER_RUN := 3
const JUMP_MIN_GAP := 180.0             # never two jumpscares within 3 min
const JUMP_DURATION := 0.55             # on screen for less than a second
const JUMP_CALM_MIN := 30.0             # forced calm after a jumpscare
const JUMP_CALM_MAX := 60.0
const PRE_JUMP_CALM_WINDOW := 25.0      # false-security silence before each scare

# ---------------------------------------------------------------------------
# Vultos — chase
# ---------------------------------------------------------------------------
const CHASE_MAX_PER_RUN := 2
const CHASE_SPEED := 2.95               # player walks at 2.4 — escapable, barely
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
const LIT_THRESHOLD := 0.52             # hash above this → cell gets a light panel
const DARK_ZONE_CHANCE := 0.14          # open cells that stay genuinely dark
const ANOMALY_CHANCE := 0.045           # wrong-chair / off-hook-phone rooms
const PANEL_ENERGY := 1.35              # hot panels burning against the dark
const LIGHT_ENERGY := 1.15              # OmniLight energy when steady
const LIGHT_RANGE := 4.4                # tight pools — the dark owns the gaps
const LIGHT_ATTENUATION := 2.2

# ---------------------------------------------------------------------------
# Atmosphere (reference: dark A24-still grade — isolated warm pools, deep
# brown-black shadows, drained colour)
# ---------------------------------------------------------------------------
const AMBIENT_ENERGY := 0.14            # barely-there ambient; shadows go black
const FOG_DENSITY := 0.06               # gloom closes in sooner
