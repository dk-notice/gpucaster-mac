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

Working. All four rendering stages (geometry, normals, ambient occlusion,
relighting) and the reflection pass are ported, all ten example shapes from the
original render, and the output has been checked against the Windows version.
See [state.md](state.md) for current status, known gaps and next steps.

## Requirements

- An Apple silicon Mac running macOS 15 or later.

## Install

Download the latest `Gpucaster` zip from the
[Releases page](https://github.com/dk-notice/gpucaster-mac/releases), unzip it
and move Gpucaster to your Applications folder.

The app is not signed with a paid Apple developer certificate, so macOS blocks
it the first time. To allow it: try to open it once, then go to System Settings >
Privacy & Security, scroll down to the message about Gpucaster, and click
Open Anyway. This is needed only once.

## Build from source

You need Apple's Command Line Tools (`xcode-select --install`); full Xcode is
not needed. From the `mac` folder:

```bash
make run
```

Other targets: `make test` renders test scenes off-screen and checks the
results (pictures land in `mac/build/selftest/`), and `make dist` makes the
zip. When run from the source folder, the app uses the `shaders` folder beside
it, so those files can be edited directly; anywhere else it uses the copy
inside the app.

## Using it

- **Drag** to orbit the camera. **Scroll**, **pinch** or **right-drag** to move
  forwards and backwards. **Shift-drag** slides sideways; **Control-drag** or
  **Option-drag** rolls.
- **The picture builds itself**: geometry, then normals, then shading, and then
  reflections if the surface is reflective. The toolbar shows progress.
  **Pause** holds it, **Refine More** adds shading passes to a finished
  picture, and **Restart** begins again. Moving the camera restarts it.
- Press **L** for random lighting, and use the sidebar to adjust it. The last
  twelve lightings are kept as small pictures in the sidebar; click one to go
  back to it.
- **Lights** are listed by where they shine from ("Upper left, in front"), with
  a ball showing each as a dot. Drag a dot to move a light, double-click to
  flip it between front and behind, and hold **Hold to see this light alone**
  to see what one light contributes.
- **Cmd-Z** undoes any change: lighting, camera, shape settings, shape, scene.
- **File > Export Large Image** builds the picture again at up to sixteen times
  the window's size, limited by the graphics card's memory, and saves a PNG.
- Every command is in the menus with its shortcut. The single-key shortcuts of
  the Windows version (G, N, A, Esc, L, C, R, F, 0-9, F1, F2) still work, for
  running stages by hand.

## Shapes and scenes

Two kinds of file describe a picture:

- A **shape** is a `.metal` file containing the `Eval()` function that defines
  the world. Ten are included in [mac/shaders/shapes](mac/shaders/shapes).
- A **scene** is a `.scn` file holding the random seed, camera position and
  lighting. It uses the same format as the Windows version, so old scenes open
  here.

Pick a shape from the pop-up at the left of the toolbar, or from the Shape
menu. Your own shapes live in a `Gpucaster Shapes` folder in Documents (Shape >
Show My Shapes Folder) and are listed below the built-in ones. Shape > Open
Shape File opens one from anywhere.

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

Choose Shape > New Shape. It copies the current shape into your shapes folder
under a new name, switches to it and opens it in your text editor. Edit the `Eval()` function and save; the
app reloads it by itself. If there is a mistake, it shows the file and line and
keeps the last version that worked.

A comment line near the top of a shape file, such as

```
// param: twist = 0.3 (0.0 to 1.0)
```

makes a "Twist" slider in the sidebar and lets the code use `twist` as a
number. Moving the slider redraws the picture without recompiling, and the
value is saved in scene files.

[mac/shaders/eval_common.metal](mac/shaders/eval_common.metal) lists everything
a shape file can use.

## Rendering from the command line

The program inside the app can render a picture without opening a window:

```bash
Gpucaster.app/Contents/MacOS/Gpucaster --render out.png --shape mandelbox --size 3840x2160
```

Options: `--shape` (a built-in name or a `.metal` file), `--scene file.scn`,
`--size WIDTHxHEIGHT`, `--geometry passes` and `--shading passes`.

## Files

- `mac/src/` - the app (Objective-C++).
- `mac/shaders/` - the shaders (Metal Shading Language), loaded as text when
  the app runs.
- `mac/shaders/shapes/` - one file per built-in shape.
- `mac/tools/make_icon.m` and `mac/Gpucaster.icns` - the app icon, a picture of
  the fractal dodecahedron drawn by the app itself (`make icon` re-creates it).

## Credits and licence

Gpucaster was created by Ryan Geiss. The rendering method, the shaders this
port's shaders are translated from, and the ray-direction data files are his
work. The original release does not state a licence, and neither does this
repository: treat it as shared for personal, non-commercial interest, and ask
the original author before reusing his work elsewhere.

The original Windows release is not included here.
