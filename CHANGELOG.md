# Changelog

## v0.2.1 — Ending Audio Patch

- Removed the temporary `F10` ending shortcut and its spawn-door support code.
- Reduced the ending video's maximum volume from `-9 dB` to `-22 dB`.
- Extended the audio fade-in to five seconds and routed the video through the
  SFX bus so it respects both master and effects volume settings.

## v0.2.0 — Main Game Release

This version turns the original prototype into the main LIMINAL game build.

### Progression and ending

- Complete objective chain: collect five randomized Snus, activate randomized
  emergency button(s), then locate the exit.
- Clear objective transitions without exposing the entity's internal escalation.
- Immersive door transition into the ending video, followed by TV static and
  credits.
- Optional cassette collectible and environmental storytelling through notes,
  anomalous events and rare blood trails.

### Horror and pacing

- Rebalanced sprint, recovery, chase distance and entity speed.
- Improved entity peeking, wall checks, disappearance logic and animation speed.
- 3D footsteps for players and the entity, quieter telephones and refined light
  flicker.
- Mimic encounters, environmental anomalies and a stronger extraction climax.

### Co-op

- Randomized, separated player spawns with positional screams for regrouping.
- Downed, revive and spectator flow with switching between living teammates.
- Dead players are ignored by the entity until revived.
- Host-authoritative shared progression while scares and peeks remain local.
- Lobby difficulty presets and modifiers.
- Opening the pause menu does not stop the co-op simulation.

### Presentation and technical polish

- Redesigned main menu, loading screen, settings and pause UI in the Corporate
  Liminal Brutalism style.
- Cleaner carpet, yellow Backrooms color grade, refined wall materials and larger
  environmental blood stains.
- Consistent interactions, randomized objective placement and improved audio
  feedback.
- Standalone Windows export with the game data embedded in `LIMINAL.exe`.
