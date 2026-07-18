---
paths:
  - "scripts/**"
---

# LIMINAL GDScript Rules

Adapted from claude-code-game-studios rules for this project's actual layout.

- **Tuning knobs**: any pacing, difficulty, or look value a designer might tune
  goes in `scripts/tuning.gd` (documented in `docs/design/game-design.md`) —
  never hardcoded at the usage site.
- **Static typing** everywhere it's practical (`var x: float`, `Array[Type]`,
  typed function signatures). Untyped `Variant` only where dynamic dispatch on
  `_maze`-style loose references requires it.
- **Delta time** for all time-dependent motion and timers.
- **Signals for cross-system communication** — world code never reaches into
  UI nodes directly; UI listens.
- **Guard every asset load** with `ResourceLoader.exists()`; the game must
  degrade gracefully, never crash on a missing asset.
- **Audio through `AudioManager`** (pooled, web-safe). Positional one-shots via
  `play_sfx_3d`; looping positional layers parented to the emitting node so
  they die with it.
- **AI/entity state machines log transitions** in debug builds
  (`Tuning.DEBUG_ENTITY_LOG`).
- **Static maze invariant**: the layout must remain a pure function of cell
  coordinates. Nothing may mutate layout state per-player (co-op sync).
- Check `docs/engine-reference/godot/deprecated-apis.md` before using APIs
  that changed after Godot 4.3 (runtime is 4.6.1).
