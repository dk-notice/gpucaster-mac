# Gpucaster macOS port — state

Last updated: 2026-11-12

## Current status

- The Mac app in `mac/` renders Gpucaster scenes with all stages ported to Metal:
  geometry, normals, ambient occlusion, relighting and reflections.
- The user compared it with the Windows version (running in a Parallels VM) and
  reports the output matches (2026-11-12).
- The picture builds itself: geometry, normals, shading, then reflections when the
  surface is reflective. Toolbar: Shape pop-up, one Pause / Resume / Refine More
  button, Restart, a progress bar and a status line. Stages can still be run by hand
  from the Render menu and the original shortcut keys.
- Sidebar sections: the current shape's own sliders, View, Quality (pass counts),
  Lights (with a strip of the last twelve lightings), Ambient occlusion, Shiny
  highlights, Fog, Surface, and a collapsed Advanced section.
- Shapes: each world is one `.metal` file in `mac/shaders/shapes/` holding an `Eval()`
  function. `// param: name = default (min to max)` lines become sidebar sliders.
  Saving a shape file reloads it; errors show the file and line.
- Undo and redo (Edit menu) cover lighting, camera, shape values, shape changes,
  new random scenes and opened scenes. Steps that changed nothing are skipped.
- File > Export Large Image rebuilds the picture at 2 to 16 times the window size
  (limited by graphics memory) with a progress sheet, and saves a PNG.
- Scene files (`.scn`) use the Windows version's format. Saving a scene or image
  also writes the shape beside it as `name.metal`; opening a scene picks that up.
- An idle app uses no graphics card time.
- Packaged as version 1.0: a self-contained, double-clickable app with an icon and
  the shaders inside it. `make dist` produces `mac/build/Gpucaster-1.0.zip`.
- Your own shapes live in `~/Documents/Gpucaster Shapes`, listed below the built-in
  ones. Built-in shapes inside a packaged app are read-only; Edit offers a copy.
- A command-line mode renders a picture without a window (`--render`, see README).

## Verified automatically (`make test`)

- Default scene rendered through every stage: pass counts, a surface, a unit-length
  normal and a plausible ambient value at the centre pixel.
- Automatic runs: with reflectivity (goes on to reflections, then stops) and without
  (stops after 12 + 1 + 4 passes in the test), and Refine More.
- Shape parameters: the Mandelbox's five are read, start at their defaults, and
  changing one changes the picture.
- Undo snapshots restore lighting, camera and seed exactly.
- Lighting thumbnails differ for different lightings and leave the scene untouched.
- Large export: a copy renders at twice the size and saves a PNG of the right size.
- Every file in the shapes folder compiles.
- Shape switching with background compiling: each shape loads with its own
  parameters at their defaults, including when two are picked in quick succession.
- Scene files survive save and reload.
- A shape in the user shapes folder is listed and loads; shapes inside the app are
  treated as read-only.

Also checked by hand-run commands: every shape renders when selected, a shape file
outside the folder loads, a broken shape reports its own file and line, and the
window layout via the app's layout snapshot. A real 4x export of the fractal
dodecahedron through the app worked (see Notes).

The packaged zip was unpacked in a separate folder and the whole self-test passed
there using the shaders inside the app; its signature verifies and its window opens.

## Not yet verified (needs a person at the window)

- The downloaded app's first launch: macOS will block it until allowed in System
  Settings > Privacy & Security (it is not notarised). Not tried on another Mac.
- New Shape and Show My Shapes Folder with the real Documents folder, including the
  one-time macOS prompt for access to Documents.
- "Make a Copy" when editing a built-in shape in the packaged app.

- Pause / Resume / Refine More button and the progress bar while rendering.
- Shape sliders, Reset to defaults, the Advanced disclosure.
- Undo and redo from the Edit menu and Cmd-Z, including after slider drags.
- Lighting history strip: clicking a picture, Keep current.
- Export Large Image: the size chooser, the progress sheet and Cancel.
- Reflections starting by themselves when Reflectivity is raised.

## How to build and run

From the `mac/` folder:

- `make run` builds and opens the app.
- `make test` runs the off-screen self-test; pictures land in `mac/build/selftest/`.

Only Apple's Command Line Tools are needed (no Xcode). Requires macOS 15 or later
and an Apple silicon Mac.

Testing aids (environment variables): `GPUCASTER_SHAPE=name` or a full path chooses
the shape; `GPUCASTER_UISHOT=path` saves a picture of the window's controls after 4
seconds and quits; `GPUCASTER_EXPORT=path` with optional `GPUCASTER_EXPORT_SCALE=n`
runs a large export through the app and quits. Screen capture is not permitted for
the assistant on this Mac, which is why the layout snapshot exists.

## Decisions

- Not aiming for an exact copy. Design changes are welcome where they make the Mac
  version better, including the interface (user, 2026-11-12).
- Native Metal + AppKit app in `mac/`, written in Objective-C++. Original files are
  left untouched.
- "Shape" means the `Eval()` geometry file (`.metal`); "scene" means seed, camera and
  lighting (`.scn`). The two-file pairing was chosen over a single Mac-only bundle so
  that old Windows scenes still open (user, 2026-11-12).
- Shape parameter values live in the scene file's ten four-part "tunable value" slots
  (`g_c0`..`g_c9` in the original), so they save with scenes; up to 40 per shape.
- Reflections are a stage of the automatic run, triggered by reflectivity above
  zero, not a separate mode.
- Quality pass counts take effect at the next restart, and are used by exports.
- Shader code lives inside a `Scene` struct (Metal has no global variables), with
  macros in `compat.metal` so shape files read almost like the original.
- Risky floating-point optimisations are off (Metal "safe" math mode).
- The app chooses how many 128-pixel tiles to draw per frame from measured GPU time;
  there are no tile-size launchers.
- Camera moves restart rendering immediately (the original waited for the pass to end).
- Random numbers follow the original step for step (same generator, same order).
  Because the scene seed also seeds the lighting generator, restoring a seed (undo,
  or opening a scene) makes the next random lightings repeat from the start.
- Per-tile random numbers use their own generator.
- A packaged app prefers a `shaders` folder found beside or above it (the source
  checkout) over the copy inside it, so running from `mac/build` edits the originals.
- The user shapes folder is only read once it has been used (New Shape, Show My
  Shapes Folder, or opening a shape from it), so the app does not ask for access to
  Documents at first launch.
- The icon is generated, not hand-drawn: `make icon` renders the fractal
  dodecahedron with the app and masks it to the standard rounded square.
- Shader compiles start immediately and run side by side; only the newest request's
  result is used. Whether a shape's slider values are kept or reset is decided from
  the file the shaders were actually compiled from.
- The tiles-per-frame budget is learned separately for geometry, normals and ambient
  occlusion, and starts again from one tile whenever new shaders are adopted.

## Fixed problems worth remembering

- Shape switching (reported by the user, 2026-11-12): picking a second shape while
  the first was still compiling gave the second shape the first one's slider values
  (matched by name and clamped), so it drew wrongly or looked empty. Separately, the
  tile budget learned on a cheap shape could make an expensive one draw a whole pass
  in a single frame, stalling the app. Both fixed; the first has a test. The user
  confirmed shape switching works afterwards.

## Known gaps

- Not notarised: there is no paid Apple developer account, so a downloaded copy has
  to be allowed once in System Settings. Apple silicon only.
- Export is limited by graphics memory (about 30 megapixels per gigabyte allowed).
- No mouse zoom lens (the original's Z key).
- Lighting history is not saved between launches.
- Unused original textures (`textures/h1.png`, packed noise cubes) are not loaded.

## Next steps

Version 1.0 is the finished baseline. New work continues on `main`; later
milestones get their own tags (v1.1, v2.0 and so on). Ideas not yet started:

1. Save the lighting history between launches.
2. A zoom lens for checking detail (the original's Z key).
3. Notarisation, if an Apple developer account is ever available.

## Repository

- Published at https://github.com/dk-notice/gpucaster-mac (public). It holds only the
  Mac port (`mac/`), `README.md` and this file.
- Version 1.0 is tagged `v1.0`, with a GitHub Release carrying `Gpucaster-1.0.zip`.
- Version 1.0 is installed on this Mac at `/Applications/Gpucaster.app` (copied from
  the release zip, 2026-11-12). It is separate from the development build in
  `mac/build/`, which is what `make run` opens.
- The original Windows release stays in this folder on disk but is ignored by git, so
  it is never uploaded. The earlier local history that included it is kept on the
  local branch `local-full-history`; do not push that branch.
- Commits use the GitHub account's private "noreply" address, not a personal email.

## Notes

- Export timing on this Mac (M4 Max): the fractal dodecahedron, the slowest example,
  at 7840 x 5792 (45 megapixels) with 40 geometry and 16 shading passes took 4 minutes
  38 seconds and produced an 89 MB PNG.

- The project folder is synced by a file provider (Documents), which adds file
  attributes that break app signing; the Makefile strips them before signing.
- If `make` fails at the signing step while the app is open, quit the app and run
  `make` again after `touch src/main.mm`.
- No licence is stated in the original release; ask the author before distributing.
