---
paths:
  - "assets/shaders/**"
---

# LIMINAL Shader Rules

Adapted from claude-code-game-studios shader standards.

- File naming: `[type]_[purpose].gdshader` (`post_crt_old_tv.gdshader`,
  `spatial_wall_wet.gdshader`). Never inline shader strings in scripts.
- Header comment on every file: purpose, what drives its uniforms and from
  where, target pipeline, and per-pixel budget.
- No magic numbers — name look constants (`const float CURVATURE = ...`) or
  expose them as hinted uniforms.
- **Compatibility pipeline only** (WebGL 2 export): no Forward+-only features,
  no compute, no stencil. `hint_screen_texture` is fine.
- No dynamic branching in fragment shaders — use `step()`/`mix()`/
  `smoothstep()`. No texture reads inside loops.
- Keep screen-texture samples per pixel documented and minimal (CRT filter
  budget: 3).
