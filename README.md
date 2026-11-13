# Gpucaster for macOS

A native macOS port of **Gpucaster**, Ryan Geiss's program for rendering 3D
fractals and other "isosurfaces" on the graphics card.

You describe a world with one small function, `Eval()`, which receives a point
in 3D space and returns a positive number where there is something solid and a
negative number where there is open air. The program finds the surface, works
out its shape and shading, and lights it.

The original is a Windows program built on Direct3D 11 (v1.35, 25 May 2015),
from <http://www.geisswerks.com/>. This port is rewritten for Apple's Metal
graphics system and the native Mac interface.

## Status

Working, but young. All four rendering stages (geometry, normals, ambient
occlusion, relighting) and the reflection pass are ported, and all ten example
scenes from the original render. It has not yet been compared side by side
with the Windows version. See [state.md](state.md) for current status, known
gaps and next steps.

## Requirements

- An Apple silicon Mac running macOS 15 or later.
- Apple's Command Line Tools (`xcode-select --install`). Full Xcode is not needed.

## Build and run

From the `mac` folder:

```bash
make run
```

To run the off-screen self-test, which renders the default scene through every
stage and saves pictures into `mac/build/selftest/`:

```bash
make test
```

## Using it

- **Drag** to orbit the camera. **Scroll**, **pinch** or **right-drag** to move
  forwards and backwards. **Shift-drag** slides sideways; **Control-drag** or
  **Option-drag** rolls.
- With **Auto** ticked, the picture builds itself: geometry, then normals, then
  ambient occlusion. Moving the camera starts it again.
- Press **L** for random lighting, and use the sidebar to adjust it.
- Every command is in the menus with its shortcut. The single-key shortcuts of
  the Windows version (G, N, A, Esc, L, C, R, F, 0-9, F1, F2) still work.

## Shapes and scenes

Two kinds of file describe a picture:

- A **shape** is a `.metal` file containing the `Eval()` function that defines
  the world. Ten are included in [mac/shaders/shapes](mac/shaders/shapes).
- A **scene** is a `.scn` file holding the random seed, camera position and
  lighting. It uses the same format as the Windows version, so old scenes open
  here.

Pick a shape from the pop-up at the left of the toolbar, or from the Shape
menu. Any `.metal` file placed in the shapes folder appears in the list, and
Shape > Open Shape File opens one from anywhere.

| Shape | Shape |
|---|---|
| Blobs | Noise warped ground |
| Fractal dodecahedron (slow) | Polyhedra plane |
| Honeycomb floor | Reflective spheres |
| Mandelbox | Ropey planet |
| Mandelbulb | Sphere on plane |

Saving a scene or an image also saves a copy of the shape beside it with the
same name (`name.scn` and `name.metal`), and opening a scene loads the shape
beside it if there is one. A scene from the Windows version has no shape file,
so pick the matching shape yourself.

## Making new worlds

Choose Shape > New Shape. It copies the current shape under a new name, switches
to it and opens it in your text editor. Edit the `Eval()` function and save; the
app reloads it by itself. If there is a mistake, it shows the file and line and
keeps the last version that worked.

[mac/shaders/eval_common.metal](mac/shaders/eval_common.metal) lists what a
shape file can use.

## Files

- `mac/src/` - the app (Objective-C++).
- `mac/shaders/` - the shaders (Metal Shading Language), loaded as text when
  the app runs.
- `mac/shaders/shapes/` - one file per shape.

## Credits and licence

Gpucaster was created by Ryan Geiss. The rendering method, the shaders this
port's shaders are translated from, and the ray-direction data files are his
work. The original release does not state a licence, and neither does this
repository: treat it as shared for personal, non-commercial interest, and ask
the original author before reusing his work elsewhere.

The original Windows release is not included here.
