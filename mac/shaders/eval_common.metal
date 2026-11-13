// What a shape file can use.
//
// A shape is one file in the "shapes" folder containing one function:
//
//     EvalResult Eval(float3 ws) { ... }
//
// It receives 'ws', a point in 3D space, and says whether there is something
// there.  Pick a shape in the app's Shape menu; saving the file reloads it.
// The quickest way to start a new one is Shape > New Shape, which copies the
// current shape under a new name.
//
// The language is Metal Shading Language, which is close to C.  Some useful
// built-in functions: abs(), frac(), ceil(), floor(), lerp(), normalize(),
// saturate(), length(), dot(), cross(), sin(), cos(), pow().
//
// From helper.metal and noise.metal:
//   RotatePointAboutAxis(), RotatePointByQuaternion(), MakeQuaternion(),
//   ReflectAboutPlane(), SmoothL2(), OctaveNoise(), RegNoise4(), SnapNoise4(),
//   and the dodec[] / icosa[] direction tables.
//
// Random values that stay fixed for a scene (they change when you pick a new
// random scene): seed_snorm[i] (-1..1), seed_unorm[i] (0..1), seed_dir[i]
// (unit vectors), each with .x .y .z .w, for i in 0..63.
//
// Adjustable values.  A comment line like this near the top of a shape file:
//
//     // param: twist = 0.3 (0.0 to 1.0)
//
// makes a "Twist" slider in the sidebar, running from 0 to 1 and starting at
// 0.3, and lets the code use 'twist' as a number.  Moving the slider redraws
// the picture without recompiling.  If all three numbers are written without
// a decimal point, as in "iterations = 8 (2 to 16)", the slider moves in whole
// numbers; use int(iterations) where a whole number is needed, such as a loop
// count.  Up to 40 per shape.  Their values are saved in scene files.
//
// Also available: ws_eye_pos (where the camera is) and
// g_ws_pixel_size_at_depth_1 (multiply by the distance from the camera to get
// the size of one pixel at that distance - handy for adding detail down to
// the size of a pixel but no finer).
//
// A common trick: warp the whole world before doing anything else, by nudging
// 'ws' with fractal noise.  For example:
//
//     float ws_pixel_size = length(ws_eye_pos - ws) * g_ws_pixel_size_at_depth_1;
//     int noiseIndex = 0;
//     float3 delta = OctaveNoise(
//         NOISE_HQ,        // NOISE_SNAP, NOISE_REG, or NOISE_HQ
//         ws,              // the real world-space position
//         0.5,             // wavelength of the largest lumps
//         ws_pixel_size,   // size of a pixel at this depth
//         4.0,             // smallest feature to add, in pixels
//         false,           // smooth based on lower frequencies
//         false,           // creased
//         noiseIndex++,    // gives each call different noise
//         MAX_OCTAVES).xyz;
//     ws += delta * 0.05;
//
// (This file is included inside the Scene struct in gpucaster.metal.)

struct EvalResult {
    float  density;         // positive = solid, negative or zero = air
    float3 surface_color;   // only shows if 'Surface colour' is turned up in the sidebar
    float  reflectivity;    // [0..1]; only shows if 'Reflectivity' is turned up in the sidebar
};
