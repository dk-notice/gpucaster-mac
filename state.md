# Gpucaster macOS port — state

Last updated: 2026-11-12

## Current status

- The Mac app in `mac/` now renders real Gpucaster scenes. All four stages are ported
  to Metal: geometry, normals, ambient occlusion and relighting, plus the reflection
  pass. All ten example scenes from the original `eval.hlsl` render.
- Interface: one window with a stage toolbar (Geometry / Normals / Ambient / Stop,
  Auto, Reflections, Restart, status line), a sidebar of lighting controls, and a full
  menu bar. The original single-key shortcuts still work.
- Auto mode (on by default) runs 40 geometry passes, normals, then 16 ambient passes
  and stops. Moving the camera restarts it.
- Shaders are text files in `mac/shaders/`. Saving one reloads it automatically;
  compile errors show in a sheet with the file and line.
- Shapes: each world is one `.metal` file in `mac/shaders/shapes/` holding an `Eval()`
  function. A toolbar pop-up and a Shape menu list the folder; Open Shape File loads
  one from anywhere; New Shape copies the current one and opens it in a text editor.
  The last shape used is remembered between launches.
- Scene files (`.scn`) load and save in the Windows version's format (version 5).
- Save Scene and Save Image also write a copy of the shape beside the file as
  `name.metal`; Open Scene loads a same-named `.metal` beside the `.scn` if present.

## Verified automatically

- `make test`: renders the default scene off-screen through every stage, checks pass
  counts, that a surface, unit-length normal and plausible ambient value exist at the
  centre pixel, and that a scene file survives save and reload. Pictures land in
  `mac/build/selftest/`.
- `make test` also compiles every file in the shapes folder.
- All ten shapes render when selected (`GPUCASTER_SHAPE=name`), as does a shape file
  outside the folder; a broken shape reports its own file name and line.
- Shader error messages name the right file and line.
- Window layout (toolbar and sidebar), from the app's own layout snapshot.

## Not yet verified (needs a person at the window)

- Mouse camera control, scroll/pinch zoom, dragging lights.
- Shape pop-up and Shape menu (Open Shape File, New Shape, Edit, Show in Finder).
- Shape copy on Save Scene / Save Image, and shape pickup on Open Scene.
- Open/Save Scene and Save Image panels.
- Reflection pass in the live app (shader path compiles; not exercised by the test).
- Whether output matches the Windows version: no reference captures yet.

## How to build and run

From the `mac/` folder:

- `make run` builds and opens the app.
- `make test` runs the off-screen self-test.

Only Apple's Command Line Tools are needed (no Xcode). Requires macOS 15 or later
and an Apple silicon Mac.

Testing aids: `GPUCASTER_SHAPE=name` (or a full path) overrides the shape; `GPUCASTER_UISHOT=path`
saves a picture of the window's controls after 4 seconds and quits (screen capture is
not permitted for the assistant on this Mac, so this is how layout gets checked).

## Decisions

- Not aiming for an exact copy. Design changes are welcome where they make the Mac
  version better, including the interface (user, 2026-11-12).
- Get the app working first; matching the original's render quality comes later.
- Native Metal + AppKit app in `mac/`, written in Objective-C++. Original files are
  left untouched.
- "Shape" means the `Eval()` geometry file (`.metal`); "scene" means seed, camera and
  lighting (`.scn`). The two-file pairing was chosen over a single Mac-only bundle so
  that old Windows scenes still open (user, 2026-11-12).
- Shader code lives inside a `Scene` struct (Metal has no global variables), with
  macros in `compat.metal` so shape files read almost like the original.
- Risky floating-point optimisations are off (Metal "safe" math mode).
- The app chooses how many 128-pixel tiles to draw per frame from measured GPU time;
  there are no tile-size launchers.
- Camera moves restart rendering immediately (the original waited for the pass to end).
- Random numbers follow the original step for step (same generator, same order,
  assuming the Windows compiler evaluated constructor arguments right to left), so a
  seed should give the same scene. Unconfirmed until compared with reference captures.
- Per-tile random numbers use their own generator, so pressing L gives the same
  lighting sequence regardless of how long the app has been rendering.
- Reference captures are all taken with tile size 256 (`gpucaster_tile_size_256.bat`)
  and the unmodified `shaders/eval.hlsl`; they go in a `reference/` folder.

## Known gaps

- No undo yet (L still randomises lighting with no way back; save the scene first).
- No editor for the tunable values `g_c0`..`g_c9` (they default to 1; the
  noise-warped-ground shape uses them).
- No high-resolution export: the picture is the size of the window in pixels.
- No mouse zoom lens (the original's Z key).
- No app icon; not packaged for distribution.
- Unused original textures (`textures/h1.png`, packed noise cubes) are not loaded.

## Reference captures requested (from the Windows VM)

- Set A: one scene, all seven F1/F2 views saved with Ctrl+S, plus exported scene file.
- Set B (optional): same scene with reflections, exported scene file, final color view.
- Set C: Windows screenshots of the lighting dialog, help screen, and title bar.
- Also: window size from the title bar, and `bin\_screenshot_.scn` if present.

## Next steps

1. User tries the live app; fix whatever doesn't feel right.
2. Compare against the Windows reference captures (open the exported `.scn` on the Mac).
3. Undo, tunable-value editor, high-resolution export.
4. Icon and packaging.

## Repository

- Published at https://github.com/dk-notice/gpucaster-mac (public). It holds only the
  Mac port (`mac/`), `README.md` and this file.
- The original Windows release stays in this folder on disk but is ignored by git, so
  it is never uploaded. The earlier local history that included it is kept on the
  local branch `local-full-history`; do not push that branch.
- Commits use the GitHub account's private "noreply" address, not a personal email.

## Notes

- The project folder is synced by a file provider (Documents), which adds file
  attributes that break app signing; the Makefile strips them before signing.
- If `make` fails at the signing step while the app is open, quit the app and run
  `make` again after `touch src/main.mm`.
- No licence is stated in the original release; ask the author before distributing.
