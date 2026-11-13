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
- Scene files survive save and reload.

Also checked by hand-run commands: every shape renders when selected, a shape file
outside the folder loads, a broken shape reports its own file and line, and the
window layout via the app's layout snapshot. A real 4x export of the fractal
dodecahedron through the app worked (see Notes).

## Not yet verified (needs a person at the window)

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

## Known gaps

- Not packaged: the app runs from the build folder and finds its shaders beside it.
  No app icon. Needs a decision on where a packaged app keeps the user's own shapes.
- Export is limited by graphics memory (about 30 megapixels per gigabyte allowed).
- No mouse zoom lens (the original's Z key).
- Lighting history is not saved between launches.
- Unused original textures (`textures/h1.png`, packed noise cubes) are not loaded.

## Next steps

1. User tries the new controls; fix whatever doesn't feel right.
2. Packaging: icon, shaders inside the app, a home for user shapes.
3. Push to GitHub when the user says so (local commits are ahead of the remote).

## Repository

- Published at https://github.com/dk-notice/gpucaster-mac (public). It holds only the
  Mac port (`mac/`), `README.md` and this file.
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
