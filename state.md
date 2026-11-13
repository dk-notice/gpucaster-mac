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
- Four new built-in shapes (new in 1.3), written for this port after looking at Ryan
  Geiss's gallery (geisswerks.com/ryan/PROG-STIL): Menger sponge, Tangled rings,
  Ribbon ring (a Moebius band with odd half-twists) and Banded terrain (noise terrain
  coloured in height bands). They are new formulas aiming for a similar look, not
  his unpublished code. All set `surface_color`, which needs the Surface colour
  slider turned up to show. A fifth, Chrome spheres, was written to match a specific
  gallery image the user picked (set4/img_9bb51309__4d73f6cd): mirror spheres of
  many sizes on brown ground, made from one random sphere per grid cell at six
  halving cell sizes, with per-point reflectivity (spheres 1, ground 0). Fifteen
  built-in shapes in total.
- Lighting > Make Lights White (W) keeps each light's brightness and direction but
  removes its colour, so shapes that set their own colours show them truly.
- Undo and redo (Edit menu) cover lighting, camera, shape values, shape changes,
  new random scenes and opened scenes. Steps that changed nothing are skipped.
- File > Export Large Image rebuilds the picture at 2 to 16 times the window size
  (limited by graphics memory) with a progress sheet, and saves a PNG.
- Scene files (`.scn`) use the Windows version's format. Saving a scene or image
  also writes the shape beside it as `name.metal`; opening a scene picks that up.
- An idle app uses no graphics card time.
- Experimental section (new in 1.2, collapsed at the bottom of the sidebar): a live
  speed reading in passes per second and five toggles, all app preferences, off by
  default, not saved in scenes: Half detail (render at half the window's resolution
  and enlarge), Sharpen Half detail with MetalFX (Apple's spatial upscaler), Skip
  empty sky (stop testing empty pixels after 16 geometry passes), Extended
  brightness (show values above white on EDR displays) and Fast math (relaxed
  shader arithmetic).
- Lights section (new in 1.1): each light is listed by where it shines from as seen
  from the camera, with a colour swatch and an on/off tick. A direction ball shows
  the lights as dots (solid = lights the front, hollow = from behind); dragging a dot
  moves the light and double-clicking flips it. Brightness is its own slider, and a
  hold-down button shows the selected light alone.
- Packaged as a self-contained, double-clickable app with an icon and the shaders
  inside it. `make dist` produces `mac/build/Gpucaster-<version>.zip`. Current
  version: 1.3 (set in `mac/Makefile` and `mac/Info.plist`).
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
- Lights: directions set in the camera's terms read back the same and get the
  expected wording; showing one light alone changes the picture but not the scene.

Also checked by hand-run commands: every shape renders when selected, a shape file
outside the folder loads, a broken shape reports its own file and line, and the
window layout via the app's layout snapshot. A real 4x export of the fractal
dodecahedron through the app worked (see Notes).

The packaged zip was unpacked in a separate folder and the whole self-test passed
there using the shaders inside the app; its signature verifies and its window opens.

## Not yet verified (needs a person at the window)

- The new suggested names as they appear in the real save dialogs, and the export
  name following the Size pop-up.
- (The user tried all five Experimental options, including how Extended brightness
  and MetalFX look, and confirmed they work as expected, 2026-11-12.)

- The light direction ball: dragging dots, double-click to flip, clicking the ball
  to move the selected light. Light rows: selecting, on/off ticks. The hold-down
  "see this light alone" button. Only their layout and the maths behind them are
  checked.

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
seconds and quits (`GPUCASTER_UISHOT_BOTTOM=1` first opens the collapsed groups and
scrolls to them); `GPUCASTER_HALF`, `GPUCASTER_SHARP`, `GPUCASTER_SKIPSKY`, `GPUCASTER_EDR` and
`GPUCASTER_FASTMATH` (each 1 or 0) set the experimental options for one run; `--render ... --fast-math` renders with fast math;
`GPUCASTER_BENCH=1` measures geometry passes per second in the
live window and quits; a diagnostic log of mouse presses and slider changes is written
to `~/Library/Logs/Gpucaster/debug.log` whenever the app runs from the source folder
(or with `GPUCASTER_LOG` set), replaced at each launch; `GPUCASTER_UICHECK=1` drives every sidebar slider through its
handler, checks nothing overlaps the visible controls, exercises the colour picker,
prints a report and quits; `GPUCASTER_EXPORT=path` with optional `GPUCASTER_EXPORT_SCALE=n`
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
- The app chooses how many 128-pixel tiles to draw at a time from measured GPU time;
  there are no tile-size launchers.
- Work is handed to the graphics card in back-to-back slices (two queued at once),
  independent of the screen refresh, so the card stays busy. Slices aim for 30 ms
  when nothing is being touched and 8 ms for half a second after any input. The
  window only copies the latest picture to the screen each refresh. Before this
  (2026-11-12) work was done once per screen refresh with a 10 ms budget and at most
  one pass per frame, which used well under half the card.
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
- Lights have a direction but no position (as in the original), so they are shown
  on a direction ball and described in words, not drawn in the 3D picture.
- A light's brightness is its strongest colour channel. The colour picker sets the
  colour exactly as picked (brightness included); the Brightness slider can then go
  beyond what a picker can show, up to 2. The scene file format is unchanged.
- The sidebar's "Mouse moves" pop-up is gone; dragging lights in the picture is still
  available from the Lighting menu and keys 0, 1-5 and 9, and the status line says
  when it is on.
- The Experimental options are remembered as app preferences (not in scene files)
  and read by the app at launch, not by the renderer, so tests and command-line
  renders are unaffected.
- Suggested file names are "<Shape> <yyyy-MM-dd> at <HH.mm.ss>" for images and
  scenes, with " (W × H)" added for large exports (following the Size pop-up until
  the name is typed over). Chosen so names are unique without inspecting folders,
  and so the companion `.scn` and `.metal` files, which are replaced without a
  warning, never collide (user, 2026-11-12). The seed is no longer in the name; it
  is stored inside the scene file.
- Exports are always accurate (user, 2026-11-12: people will design a scene with the
  fast options and export later at high resolution). They are sized from the
  window's screen pixels, so Half detail does not shrink them, and the export copy
  switches Fast math and Skip empty sky off, compiling accurate shaders first if the
  window was using fast math. MetalFX and Extended brightness only affect the window.
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

- Lights controls (reported by the user, 2026-11-12): the colour picker's sliders
  did not work, and the per-light Brightness and Wrap sliders did not work.
  Fixed: the light's colour well ignored the brightness chosen in the picker and
  wrote a changed colour back into the well while the picker was open, so the picker
  fought the app. The picker now sets the light's colour exactly, and the app never
  echoes colours back.
  Brightness and Wrap: cause never identified. The user reported them still failing
  on the build with the picker fix, but in two later sessions with the diagnostic log
  on (the only change), every drag on every light worked, before and after Solo, the
  random buttons, the ball and the picker, and the user confirmed it all worked.
  Treat as unexplained, possibly intermittent. The diagnostic log stays on in the
  development build so a recurrence is captured: ask the user to leave the app open
  and read `~/Library/Logs/Gpucaster/debug.log`.

## Known gaps

- Not notarised: there is no paid Apple developer account, so a downloaded copy has
  to be allowed once in System Settings. Apple silicon only.
- Export is limited by graphics memory (about 30 megapixels per gigabyte allowed).
- No mouse zoom lens (the original's Z key).
- Lighting history is not saved between launches.
- Unused original textures (`textures/h1.png`, packed noise cubes) are not loaded.

## Next steps

Releases so far: 1.0 (the finished port), 1.1 (lights shown by direction with a
direction ball, brightness slider and solo; colour picker fix; about twice the
rendering speed), 1.2 (the Experimental options, exports that are always
accurate, file names from shape and date) and 1.3 (five new shapes and Make
Lights White). Versioning: new features that keep old
scenes and shapes working are a minor version; fixes only would be a patch (1.2.1);
a change that breaks old files would be 2.0. Released versions are never altered.
New work continues on `main`. Ideas not yet started:

1. Ideas from the gallery not done: a sky or horizon gradient behind terrains (his
   have one; ours go to black or flat fog), and using the release's unported
   `textures/h1.png`, which is probably a height-to-colour map (an inference).
1. Possible bigger changes discussed but not started: running the stages as compute
   shaders (a replacement engine, not a toggle), and compiling the shape separately
   from the other shader code so switching shapes is faster.
1. Save the lighting history between launches.
2. A zoom lens for checking detail (the original's Z key).
3. Notarisation, if an Apple developer account is ever available.

## Repository

- Published at https://github.com/dk-notice/gpucaster-mac (public). It holds only the
  Mac port (`mac/`), `README.md` and this file.
- Tags `v1.0`, `v1.1`, `v1.2` and `v1.3`, each with a GitHub Release carrying the app zip.
- Version 1.2 is installed on this Mac at `/Applications/Gpucaster.app` (copied from
  the release zip, 2026-11-12). It is separate from the development build in
  `mac/build/`, which is what `make run` opens. The installed copy has no
  diagnostic log; that is on only when running from the source folder.
- The original Windows release stays in this folder on disk but is ignored by git, so
  it is never uploaded. The earlier local history that included it is kept on the
  local branch `local-full-history`; do not push that branch.
- Commits use the GitHub account's private "noreply" address, not a personal email.

## Notes

- Speed in the window at 1960 x 1448 on this Mac (M4 Max), geometry passes per
  second, before -> after feeding the card continuously: fractal dodecahedron 8.8 ->
  16.7 (flat-out off-screen: 20), blobs 63 -> 176 (flat-out: 178), noise-warped
  ground 4.5 after. Measure with `GPUCASTER_BENCH=1`.
- The user found the Mac version much slower than Windows in the VM. Half of that was
  the pacing above. The other possible half, not addressed at the user's choice: the
  Mac renders at full Retina resolution, four times the pixels of an unscaled window.
  A "half detail" option was offered and declined for now.
- Experimental toggles, measured in the window at 1960 x 1448 on this Mac, geometry
  passes per second (normal / fast math / half detail / both): fractal dodecahedron
  16.7 / 18.0 / 68.7 / 72.0; Mandelbox 95 / 293 / 386 / 1138. Half detail is about
  4.1x everywhere. Fast math is about 3x for the Mandelbox and Blobs and under 10%
  for the fractal dodecahedron and Mandelbulb.
- Skip empty sky gained only 3% (Mandelbulb), 8% (fractal dodecahedron) and 19%
  (sphere on plane) in the benchmark, because those views have little empty area.
  It skips a pixel only if it and its four neighbours have found nothing, so
  surfaces still spread from their edges; the test confirms the surface is unchanged.
- MetalFX: on the fractal dodecahedron the enlarged picture has visibly crisper
  edges than plain enlargement, and fine noisy detail looks somewhat harsher
  (compared by eye from the self-test's `7_half_detail_*.png`). Its cost is
  negligible (382 vs 386 passes per second on the Mandelbox at half detail).
- Extended brightness: the stored picture becomes 16-bit float and keeps values
  above white (test: 29.8 with brightness 5, against 1.0 clipped); the window
  switches to an extended-range layer and converts with a 2.2 gamma, limited to the
  display's current headroom. Saved images are identical with it on or off. How it
  LOOKS on the display has not been seen by the assistant at all; MetalFX is
  switched off while it is on.
- Colours written in a shape come out much darker than written, because the final
  picture is raised to the power 2.2 (as in the original): 0.42 becomes 0.15. Write
  surface colours lighter than intended.
- Matching the chrome-spheres reference needed scene settings as well as the shape:
  white lights, reflectivity 1, surface colour 1, pale blue fog at density 0.02 (the
  fog colour is what mirrors reflect as sky) and brightness about 1.8.
- Fast math and picture accuracy: rendering Mandelbox, fractal dodecahedron,
  Mandelbulb and Blobs both ways at 800 x 500, the mean difference was at most 0.18
  out of 255 per colour channel and at most 0.24% of pixels differed strongly. So
  it is far safer than assumed when it was first switched off, on these shapes.
- Export timing on this Mac (M4 Max): the fractal dodecahedron, the slowest example,
  at 7840 x 5792 (45 megapixels) with 40 geometry and 16 shading passes took 4 minutes
  38 seconds and produced an 89 MB PNG.

- The project folder is synced by a file provider (Documents), which adds file
  attributes that break app signing; the Makefile strips them before signing.
- If `make` fails at the signing step while the app is open, quit the app and run
  `make` again after `touch src/main.mm`.
- No licence is stated in the original release; ask the author before distributing.
