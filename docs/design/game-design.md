# LIMINAL — Game Design Document

Format follows the claude-code-game-studios GDD template (trimmed to this
project's scale). The vision pillars live in `CLAUDE.md`; this doc covers the
systems, the player journey, and every tuning knob.

## Overview

First-person Backrooms horror. Level-0 open-plan office floor: sickly yellow
wallpaper, moist carpet, spaced fluorescent panels, pillar halls sinking into
gloom — all watched through an old-TV/CRT filter that degrades as dread rises.
Single-player or WebSocket co-op. Collect 5 snus tins → the single real exit
unlocks at a fixed deep cell. Shadowy watchers escalate from distant sightings
to jumpscares to chases; from minute 10 a permanent slow stalker follows.

## Player Fantasy

"I am alone in a place that shouldn't exist, and something is watching me.
If I look for it, it's gone. If I run well, I can live. The TV signal I'm
seeing this through is as sick as I am scared."

## Player Journey (target pacing)

| Time | Beat |
|---|---|
| 0–1 min | Calm. Hum + HVAC bed. Learn movement. Open starting room. |
| ~1–5 min | First distant watcher (~60–90s). Unexplained sounds every 18–40s. Snus hunting. |
| 5–8 min | Jumpscares armed (max 3/run, ≥3 min apart, each preceded by ~25s of false-security calm). |
| 8–10 min | Chases armed (max 2/run). Corridor pursuit, escapable by cornering (2s LOS break = vanish). |
| 10+ min | Final phase: permanent slow stalker; standing still >6s is death. Exit music rises. |
| Exit | All 5 snus → exit spawns at cell (14,−16); reaching it ends the run. |

## Systems (implementation map)

- **World glue** — `scripts/world/game_world.gd`: environment, ambient bed +
  ducking (post-jumpscare silence, post-chase dead air), endings, co-op wiring.
- **Maze** — `scripts/world/maze_manager.gd`: static hash-derived streaming
  grid; pillars + sparse slabs; spaced panels with real dark pockets;
  `corridor_path()` BFS for entity pursuit; anomaly rooms; fixed exit.
- **Entity** — `scripts/world/entity_director.gd`: PEEK/JUMP/CHASE/STALK state
  machine; all spawns raycast-validated; watchers track the player, recede when
  looked at, vanish inside 6m or when hunted.
- **Snus** — `scripts/world/snus_manager.gd`: 5 fixed-cell tins, co-op-shared.
- **CRT filter** — `assets/shaders/post_crt_old_tv.gdshader` via
  `scripts/ui/overlay.gd` (`dread`/`pulse` uniforms).

## Tuning Knobs

All in `scripts/tuning.gd`. The intent column is the contract — retune freely
within it.

| Knob | Value | Intent |
|---|---|---|
| `JUMP_ARM_TIME` | 300 | No jumpscares in the first 5 minutes, ever. |
| `CHASE_ARM_TIME` | 480 | Chases belong to the late-middle game. |
| `FINAL_PHASE_TIME` | 600 | Stalker pressure begins near exit availability. |
| `PEEK_DIST_MIN/MAX` | 11/20 | Watchers live at the edge of legibility. |
| `PEEK_VANISH_DIST` | 6 | A vulto is NEVER seen up close outside a jumpscare. |
| `PEEK_MUFFLE_DIST` | 10 | Near-but-unseen = hum pitch drop + low-pass. |
| `PEEK_GAP_EARLY/LATE` | 70/22 | Sightings escalate in frequency over 10 min. |
| `JUMP_MAX_PER_RUN` | 3 | 2–3 per run is the ceiling; scarcity keeps power. |
| `JUMP_MIN_GAP` | 180 | Never two scares within 3 minutes. |
| `JUMP_DURATION` | 0.55 | On screen under a second; no death, no lingering. |
| `PRE_JUMP_CALM_WINDOW` | 25 | False security precedes every scare. |
| `JUMP_CALM_MIN/MAX` | 30/60 | Total calm after a scare. |
| `CHASE_SPEED` | 7.2 | Faster than the 4.75 sprint on purpose: you cannot outrun it. |
| `CHASE_SIGHT_RANGE` | 26.0 | Without a cap it re-acquired down any straight corridor forever. |
| `CHASE_BLIND_GIVE_UP` | 12.0 | Cornering buys a hunt to your last known spot, not an instant escape. |
| `CONFUSED_DURATION` | 3.0 | It stands and looks before wandering off; stay in cover. |
| `CONFUSED_REACQUIRE_RANGE` | 16.0 | Stepping out during that window puts it straight back on you. |
| `CHASE_NO_ROUTE_TIMEOUT` | 4.0 | A walled-off chaser dissolves; no wall-humping. |
| `STALK_LINGER_KILL` | 6.0 | Final phase punishes stopping, not moving. |
| `SOUND_GAP_MIN/MAX` | 18/40 | Unexplained events stay rare enough to unsettle. |
| `WALL_DENSITY` | 0.22 | Open-plan halls, long sightlines (reference image). |
| `PILLAR_DENSITY` | 0.3 | Loose column grid holds up the halls. |
| `LIT_THRESHOLD` | 0.52 | Sparse hot panels; the dark owns the gaps. |
| `DARK_ZONE_CHANCE` | 0.14 | Genuinely dark pockets must always exist. |
| `ANOMALY_CHANCE` | 0.045 | Wrong rooms stay rare and unexplained. |
| `LIGHT_RANGE`/`ATTENUATION` | 4.4/2.2 | Tight isolated pools (reference still). |
| `AMBIENT_ENERGY` | 0.14 | Near-black brown shadows between the pools. |
| `FOG_DENSITY` | 0.06 | Gloom closes in early; no visible corridor ends. |

### Grade & ambience references

- **Visual**: dark A24-still grade — crushed brown-black shadows, isolated warm
  panels with bloom, heavy vignette, strong red/cyan aberration, sepia drain.
  Shader look constants in `assets/shaders/post_crt_old_tv.gdshader`.
- **Ambience**: A24 "1 Hour of Backrooms Ambience" vibe — deep room-tone drone
  (menu theme at 0.72x pitch, `DRONE_VOL` −16 dB) + dark mains hum (0.92x) +
  distant HVAC. Mix constants at the top of `scripts/world/game_world.gd`.

## Acceptance Criteria

- [ ] Genuinely dark screen zones exist at any moment of the run
- [ ] Never absolute silence outside the sanctioned post-jumpscare beat
- [ ] Impossible to see a vulto up close outside a jumpscare
- [ ] Chase entity vanishes after 2s of broken line of sight, with a hard sound cut
- [ ] A false-security calm precedes every jumpscare
- [ ] No HUD (transient snus counter excepted), no map, no flashlight, no gore
- [ ] Maze layout identical across clients and revisits (static invariant)

## Endings

1. **Exit** ("You left…") — reach the unlocked exit. Whole team escapes in co-op.
2. **Caught** ("Ele encontrou-te primeiro.") — chase touch or stalk kill; black
   screen, dead silence, restart. In co-op: personal down + spectate.
3. **Secret** ("Now you are the one waiting at the corner.") — stand still 60s
   inside an anomaly room.
