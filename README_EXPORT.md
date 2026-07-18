# game-20260718-492248f9

Exported from Tesana on 2026-07-18.
Game ID: `game-20260718-492248f9`.

This zip is a clean Godot 4.x project — open it in the editor,
edit it, re-export it, version-control it however you like.

---

## What's in this zip

- `project.godot` — the Godot project descriptor (engine version, autoloads,
  input map, rendering settings, etc.). Open this file in Godot to load the project.
- **Scripts**: `.gd` files (GDScript), each with a `.gd.uid` sidecar.
  The `.uid` file stores a stable identifier (e.g. `uid://abc123`) that scenes
  use to reference the script — keeping these means moving files around
  later won't break scene-to-script links.
- **Scenes**: `.tscn` files. Plain-text scene definitions.
- **Resources**: `.tres` files. Plain-text serialized resources — UI styles,
  themes, materials, audio randomizers, custom Resource subclasses, etc.
- **Assets**: `assets/` contains images, audio, 3D models, and other media.
  Each asset has a sidecar `.import` file (e.g. `hero.png` + `hero.png.import`)
  that stores Godot's per-asset import settings (compression mode, mipmaps,
  filter mode, output path, content hash). **Keep `.import` files** —
  without them Godot re-imports with defaults on first open and your scenes
  can break.
- `addons/` — third-party Godot addons your game uses (if any).
- `export_presets.cfg` — the same preset config Tesana uses to build for
  macOS, Windows, and Web. Keep this if you want to re-export with the
  exact configuration we use.
- This `README_EXPORT.md`.

> **Quick guide:** `.gd` is your code, `.tscn` is your scenes, `.tres` is
> your resources, `.import` is "how to import this asset", `.uid` is "the
> stable name of this script/shader". Commit all of them to version control.

## What's NOT in this zip and why

- `.godot/` (the Godot import cache) — large per-asset binary cache
  (`.ctex`, `.oggvorbisstr`, etc.). Godot regenerates it on first editor
  open in 30s–2min.
- `web-export/` and `desktop-export/` — previously-built artifacts.
  Re-build yourself with the snippets below.

---

## Open in Godot 4.x

```sh
godot --editor --path .
```

…or just double-click `project.godot`. The first open will re-import
all assets — for a typical game this takes 30s to 2 minutes.

> Get Godot from <https://godotengine.org/download>.

---

## Re-export it yourself

The bundled `export_presets.cfg` includes presets for Web, macOS,
Windows, and Linux. From the project root:

```sh
# Web (HTML/WASM/PCK) — open the resulting index.html in a modern browser.
godot --headless --export-release "Web" web/index.html

# macOS (unsigned .app bundle, zipped) — see the Gatekeeper note below.
godot --headless --export-release "macOS" build/game-20260718-492248f9.app.zip

# Windows desktop (.exe + data.pck)
godot --headless --export-release "Windows Desktop" build/game-20260718-492248f9.exe

# Linux desktop
godot --headless --export-release "Linux" build/game-20260718-492248f9.x86_64
```

You'll need the matching Godot **export templates** installed
(Editor → Manage Export Templates… inside the editor, or place them
under `~/.local/share/godot/export_templates/<version>/`).

---

## Add your own version control

```sh
cd <unzipped-folder>
git init
git add .
git commit -m "Initial export from Tesana"
```

We pre-supply a sane `.gitignore` (see `.gitignore` if present, otherwise
create one with at least `.godot/`, `web-export/`, `build/`).

---

## macOS Gatekeeper

The `.app.zip` produced by the macOS preset is **unsigned**. macOS will
refuse to launch it the first time with a "cannot be opened because the
developer cannot be verified" dialog. To bypass:

- **Right-click → Open** (instead of double-click), then click *Open*
  in the confirmation dialog. macOS remembers the choice afterwards.
- **Or** strip the quarantine attribute from the terminal:
  ```sh
  xattr -dr com.apple.quarantine path/to/game-20260718-492248f9.app
  ```

To produce a signed bundle yourself you'll need an Apple Developer
account; configure the codesign identity in `export_presets.cfg`
under the macOS preset.

---

## Branding & redistribution

Games exported from Tesana are yours to modify, host, and distribute
under our Terms of Service. For commercial use, attribution requirements,
or platform store submission guidance, see <https://tesana.ai/terms>
and <https://tesana.ai/help>.

## Get help

- Help: <https://tesana.ai/help>
- Help: support@tesana.ai
- Discord: <https://discord.gg/tesana>
