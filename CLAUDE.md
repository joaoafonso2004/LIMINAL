# LIMINAL

First-person Backrooms horror (single-player + WebSocket co-op). The player wakes
in an infinite Level-0 office floor, collects 5 snus tins to unlock the single
real exit, and is hunted by shadowy "vultos" (watchers) that must NEVER be seen
up close outside a jumpscare.

## Vision pillars (do not violate)

1. **Dread over gore** — no blood, no monster close-ups, no death screens except
   the sanctioned endings. The player's imagination does the work.
2. **The signal is sick** — everything is watched through an old-TV/CRT filter
   (scanlines, snow, tracking tears). More dread = sicker signal.
3. **Sound carries the game** — the fluorescent hum bed NEVER stops (the only
   absolute silence allowed: ~2.4s right after a jumpscare, and after a chase
   vanishes). Distance and danger are communicated by audio, not UI.
4. **Watchers, not monsters** — vultos observe from afar, recede when looked at
   directly, and are simply gone if the player tries to reach them (vanish
   inside 6m). Chases are the exception: 1-2 per run, escapable by cornering.
5. **Static maze** — the layout is a pure function of cell coordinates
   (hash-based). Required for co-op sync; never reintroduce per-player mutation.
6. **No HUD** — except the transient snus counter that fades in for seconds.
   No map, no flashlight, no objective markers.

## Stack

- **Engine**: Godot 4 — `project.godot` declares 4.3 features; the QA/publish
  runner executes **Godot 4.6.1**. Check `docs/engine-reference/godot/` for
  4.4-4.6 API changes before using newer APIs (that folder is the source of
  truth for post-4.3 changes; includes deprecated-API replacement table).
- **Renderer**: `gl_compatibility` (WebGL 2 web export). No Forward+-only
  features (volumetric fog, SDFGI). Depth fog + glow are fine (4.3+).
- **Language**: GDScript, tabs, static typing everywhere it's practical.
- **Multiplayer**: custom WebSocket relay via `NetManager` autoload (see
  `scripts/autoloads/net_manager.gd`); position broadcast at 20 Hz.

## Layout & systems map

- `scenes/` — thin .tscn shells; almost everything is built **in code**
  (players, UI, maze cells). Keep it that way: scripts attach to bare nodes.
- `scripts/autoloads/` — `LoadingScreen`, `AudioManager` (pooled SFX + music,
  web autoplay-gated), `GameManager` (run clock, look-back counter, restart),
  `NetManager`.
- `scripts/world/game_world.gd` — world glue: environment, ambient bed,
  audio ducking, endings, co-op wiring.
- `scripts/world/maze_manager.gd` — streaming static grid: open-plan halls,
  pillars, sparse wall slabs, spaced fluorescent panels, `corridor_path()` BFS
  used by the entity. Exit at fixed cell (14,-16), unlocked by snus.
- `scripts/world/entity_director.gd` — the vultos: PEEK/JUMP/CHASE/STALK state
  machine paced off `GameManager.run_time`. Chase follows corridor waypoints
  (never phases through walls); 2s without line of sight = instant vanish.
- `scripts/world/snus_manager.gd` — 5 tins at fixed cells; co-op-shared pickup.
- `scripts/ui/overlay.gd` — CanvasLayer with the CRT post shader
  (`assets/shaders/post_crt_old_tv.gdshader`), fade rect, ending text.
- `scripts/tuning.gd` — **ALL horror pacing/difficulty knobs live here.**
  Change game feel by editing this file only; see the knob table in
  `docs/design/game-design.md`.

## Conventions

- Guard every asset load with `ResourceLoader.exists()` — assets may be missing
  in partial checkouts; the game must degrade, not crash.
- Cross-system communication by signals; UI never reached into directly from
  world code.
- Audio: use `AudioManager` (pooled, web-safe). Never create ad-hoc
  AudioStreamPlayers except positional ones parented to short-lived nodes.
- Shaders live in `assets/shaders/` as `.gdshader` files, named
  `[type]_[purpose].gdshader` — never as inline strings in scripts.
- Entity/AI state transitions are logged in debug builds
  (`Tuning.DEBUG_ENTITY_LOG`) — keep transitions observable.

## Verification

- No local Godot binary on this machine. QA runs happen through the platform's
  headless runner (writes to `.qa/<timestamp>/report.json` + `console.log`).
  After significant changes, ask the user to run the game / QA probe rather
  than claiming runtime verification.
- ripgrep has **no `gdscript` file type** — use `--glob "*.gd"` (the `gd` type
  maps to GAP language and silently matches nothing useful).
