// eval.metal - THIS IS THE FILE TO EDIT TO MAKE NEW WORLDS.
//
// Eval() receives a point in 3D space and says whether there is something
// there.  Save the file and the app reloads it automatically.
//
// The language is Metal Shading Language, which is close to C.  Some useful
// built-in functions: abs(), frac(), ceil(), floor(), lerp(), normalize(),
// saturate(), length(), dot(), cross(), sin(), cos(), pow().
//
// Also see helper.metal and noise.metal for:
//   RotatePointAboutAxis(), RotatePointByQuaternion(), MakeQuaternion(),
//   ReflectAboutPlane(), SmoothL2(), OctaveNoise(), RegNoise4(), SnapNoise4(),
//   and the dodec[] / icosa[] direction tables.
//
// Random values that stay fixed for a scene (they change when you pick a new
// random seed): seed_snorm[i] (-1..1), seed_unorm[i] (0..1), seed_dir[i]
// (unit vectors), each with .x .y .z .w, for i in 0..63.
//
// Values you can tune from the app without recompiling: g_c0 .. g_c9, each
// with .x .y .z .w.
//
// (This file is included inside the Scene struct in gpucaster.metal.)

// Pick which example below to render:
//   1 = sphere on a plane        5 = ropey planet surface
//   2 = blobs                    6 = honeycomb floor
//   3 = reflective spheres       7 = Mandelbox
//   4 = dodecahedra/icosahedra   8 = Mandelbulb
//                                9 = noise-warped ground (uses g_c0, g_c1)
//                               10 = fractal dodecahedron (slow)
#ifndef SCENE
#define SCENE 2
#endif

struct EvalResult {
    float  density;         // positive = solid, negative or zero = air
    float3 surface_color;   // only shows if 'Surface colour' is turned up in the sidebar
    float  reflectivity;    // [0..1]; only shows if 'Reflectivity' is turned up in the sidebar
};

//--------------------------------------------------------------------------------------
// Eval - evaluates our implicit surface at a point in space.
//--------------------------------------------------------------------------------------
EvalResult Eval(
    // There is only one input to our world-defining function:
    // 'ws', the 3D world-space coordinate of the point we're evaluating.
    float3 ws
) {
    // The surface is formed along the boundary where density crosses from positive to negative.
    EvalResult ret;
    ret.density = 0;
    ret.surface_color = float3(1, 1, 1);
    ret.reflectivity = 1;

    // How large (in world-space) a pixel is, at the depth of this point.  Handy for
    // adding detail down to the size of a pixel but not beyond (to avoid aliasing).
    float ws_pixel_size = length(ws_eye_pos - ws) * g_ws_pixel_size_at_depth_1;

    // Each time we call OctaveNoise(), we pass in a new (incremented) noiseIndex value,
    // which keeps successive calls from returning the same value over and over.
    int noiseIndex = 0;

    // The original world-space point, which you can always refer back to.
    const float3 ws_orig = ws;

#if 0
    // OPTIONAL: Pre-warp the entire world by perturbing the coordinate (ws) by some 3D fractal noise.
    {
        float wavelen = 0.5;
        float strength = 0.05;
        float3 delta = OctaveNoise(
            NOISE_HQ,                   // NOISE_SNAP, NOISE_REG, or NOISE_HQ.
            ws_orig,                    // *real* world-space pos (...otherwise nyquist gets botched)
            wavelen,                    // world-space wavelength of lowest frequency (ws size of 1 texel)
            ws_pixel_size,              // the ws size of a pixel (at this depth)
            4.0,                        // the min feature size to loop until, in pixels.
            false,                      // bSmoothBasedOnLowerFreqs
            false,                      // bCreased
            noiseIndex++,               // put 'noiseIndex++' here.
            MAX_OCTAVES                 // max # of octaves.
        ).xyz;
        ws += delta * strength;
    }
#endif

#if SCENE == 1
    // A simple sphere at the origin, sitting on a plane:
    float sphere_radius = 0.3;
    float sphere = sphere_radius - length(ws);
    float plane  = -sphere_radius - ws.y;
    ret.density = max(sphere, plane);

#elif SCENE == 2
    // Blobs.
    ret.density = 0;
    for (int i = 0; i < 8; i++) {
        float3 blob_pos = seed_snorm[i].xyz * 0.4;
        float blob_field_rad = 0.4 + seed_unorm[i].w * 0.2;
        float t = length(ws - blob_pos) / blob_field_rad;
        // Pick one of the following:
        // (1) Cheap polynomial blobs:
        //ret.density += SmoothL2(1 - saturate(t)) - 0.25;
        // (2) High-quality blobs:
        ret.density += 0.1 / (t * t + 0.01) - 0.25;
    }

    // Force everything below y == -0.2 to solid earth.
    if (ws.y < -0.2) ret.density = 1;

#elif SCENE == 3
    // Some reflective spheres:
    if (length(ws) < 0.9) {
        float3 ws2 = (ws + seed_snorm[7].xyz) * 10;

        float4 sn = SnapNoise4(ws2);
        float  sph_rad = 0.2 + 0.1*sn.w;
        float3 sph_ctr = floor(ws2) + 0.5 + sn.xyz*(0.5 - sph_rad);
        if (length(ws2 - sph_ctr) < sph_rad)
        {
            ret.density = 10;
            ret.surface_color = float3(0);
            ret.reflectivity = frac(sn.w * 17.31);
        }
    }

#elif SCENE == 4
    // An infinite plane of dodecahedra and icosahedra.
    float  size = 0.2;
    float3 icosa_center = float3(0.25, -0.5, 0.25);
    float3 dodec_center = float3(-0.25, -0.5, -0.25);
    icosa_center.xz += floor(ws.xz) + 0.5;
    dodec_center.xz += floor(ws.xz) + 0.5;

    int i1 = 0;
    float closest_distance1 = 9999;
    float3 ws_dodec = (ws - dodec_center) / size;
    for (int i = 0; i < 12; i++) {
        float dist = length(dodec[i] - ws_dodec);
        if (dist < closest_distance1) {
            closest_distance1 = dist;
            i1 = i;
        }
    }

    int i2 = 0;
    float closest_distance2 = 9999;
    float3 ws_icosa = (ws - icosa_center) / size;
    for (int i = 0; i < 20; i++) {
        float dist = length(icosa[i] - ws_icosa);
        if (dist < closest_distance2 && i != i2) {
            closest_distance2 = dist;
            i2 = i;
        }
    }

    float proj1 = dot(dodec[i1], ws_dodec);
    float proj2 = dot(icosa[i2], ws_icosa);
    ret.density = (proj1 < 1 || proj2 < 1) ? 1 : -1;

#elif SCENE == 5
    // A very cool, ropey-looking planet surface:
    float bump_wavelen = 0.7f;
    float3 pivot_delta = float3( RegNoise4(ws * 0.25f/bump_wavelen + seed_snorm[0].xyz*8).x,
                                 RegNoise4(ws * 0.25f/bump_wavelen + seed_snorm[1].xyz*8).y,
                                 RegNoise4(ws * 0.25f/bump_wavelen + seed_snorm[2].xyz*8).z ) * 12 * bump_wavelen;
    float wavelen = 4;
    float amp = 0.1;
    for (int i=0; i<8; i++)
    {
        float3 axis   = seed_dir[i].xyz;
        float  amount = RegNoise4( ws * (1.0/wavelen)*3 ).w * wavelen * amp;

        float3 pivot = ws + pivot_delta;
        ws = RotatePointAboutAxis(axis, pivot, ws, amount);

        wavelen = wavelen * 0.5;
        amp = amp * 0.9;
    }
    ret.density = -1 - ws.y;

#elif SCENE == 6
    // Honeycomb floor.
    float2 st;
    float2 xy_base = float2(floor(ws.x*0.5)*2, floor(ws.z));
    float x = frac(ws.x*0.5)*2;
    float y = frac(ws.z);
    if (abs(y-0.5)*2 < (abs(x-1.3333)-0.3333)*3)
    {
        if (x < 1.333)
            st = float2(0,0);
        else
            st = float2(2,0);
    }
    else if (y < 0.5)
        st = float2(1,0);
    else
        st = float2(1,1);
    float floor_height = tex_noise3D_full_a.sample(sam_nearest_wrap, float3(xy_base + st, 0) * (1.0/16.0), level(0)).x;
    ret.density = floor_height*0.2 - ws.y - 1;
    ret.reflectivity = 1;

#elif SCENE == 7
    // Standard Mandelbox.
    const float3 c = ws * 20;
    const float scale = 2;     // TRY: -1.5, 1.5, 2
    const float r = 0.5f;
    const float f = 1;
    const int its = 8;
    float3 v = float3(0);    // c or 0?

    ret.density = -1;

    for (int i=0; i<its; i++) {

        // Box fold:
        if (v.x > 1)
            v.x = 2 - v.x;
        else if (v.x < -1)
            v.x = -2 - v.x;

        if (v.y > 1)
            v.y = 2 - v.y;
        else if (v.y < -1)
            v.y = -2 - v.y;

        if (v.z > 1)
            v.z = 2 - v.z;
        else if (v.z < -1)
            v.z = -2 - v.z;

        v = v*f;

        // Ball fold:
        float mag = length(v);
        if (mag < r)
            v *= 1.0/(r*r);
        else if (mag < 1)
            v /= mag*mag;

        v = v*scale + c;
    }

    float max_dim = max(abs(v.x), max(abs(v.y), abs(v.z)));

    ret.density = (max_dim > 4) ? -1 : 1;      // thresh determines the fullness of the volume.
    ret.reflectivity = 1;

#elif SCENE == 8
    // Standard mandelbulb.
    float n = 8;
    ws = ws.yzx * 2.5;    // Scale it down (by scaling space UP), and rotate it (by rotating space).
    const float3 ws_start = ws;

    for (int i = 0; i < 6; i++) {
        float r = length(ws);
        float theta = atan2(ws.y, ws.x);
        float phi = atan2(ws.z, length(ws.xy));

        float3 ws2;
        ws2.x = pow(r, n) * sin(theta*n) * cos(phi*n);
        ws2.y = pow(r, n) * sin(theta*n) * sin(phi*n);
        ws2.z = pow(r, n) * cos(theta*n);
        ws = ws2 + ws_start * seed_unorm[0].x;
    }

    if (length(ws) < 1) {
        ret.surface_color = 0.9 + 0.3*g_light_unorm[0].xyz;
        ret.density = 1;
    }

#elif SCENE == 9
    float str = 0.1;

    // Double pre-warp, ** driven by values you can adjust from the app (g_c0, g_c1). **

    // Pre-warp 'ws'.
    float3 delta = OctaveNoise(
        NOISE_HQ,                   // NOISE_SNAP, NOISE_REG, or NOISE_HQ.
        ws,                         // *real* world-space pos (...otherwise nyquist gets botched)
        g_c1.x,                     // wavelen (ws size of 1 texel)
        ws_pixel_size,              // the ws size of a pixel (at this depth)
        g_c0.z,                     // the min feature size to loop until, in pixels.
        false,                      // bSmoothBasedOnLowerFreqs
        false,                      // bCreased
        noiseIndex++,               // put 'noiseIndex++' here.
        MAX_OCTAVES                 // max # of octaves.
    ).xyz;
    ws += delta * str * g_c1.y;

    // Do it again.
    delta = OctaveNoise(
        NOISE_HQ,                   // NOISE_SNAP, NOISE_REG, or NOISE_HQ.
        ws,                         // *real* world-space pos (...otherwise nyquist gets botched)
        g_c1.z,                     // wavelen (ws size of 1 texel)
        ws_pixel_size,              // the ws size of a pixel (at this depth)
        1,                          // the min feature size to loop until, in pixels.
        false,                      // bSmoothBasedOnLowerFreqs
        false,                      // bCreased
        noiseIndex++,               // put 'noiseIndex++' here.
        MAX_OCTAVES                 // max # of octaves.
    ).xyz;
    ws += delta * str * g_c1.w;

    // ...plus a simple ground plane, to show it.
    ret.density = -0.5 - ws.y;

#elif SCENE == 10
    // Fractal perturbations on the surface of a dodecahedron.  (Slow)
    ws *= 3.0f;
    int iters = 10;
    for (int loop = 0; loop < iters; loop++) {
        // To which face center on the dodecahedron are we closest?
        int i1 = 0;
        float closest_distance1 = 9999;
        for (int i = 0; i < 12; i++) {
            float dist = length(dodec[i] - ws);
            if (dist < closest_distance1) {
                closest_distance1 = dist;
                i1 = i;
            }
        }
        float3 nearest_dodec_face_center = dodec[i1];

        // To which vertex on the dodecahedron (or face center on the icosahedron) are we closest?
        int i2 = 0;
        float closest_distance2 = 9999;
        for (int i = 0; i < 20; i++) {
            float dist = length(icosa[i] - ws);
            if (dist < closest_distance2 && i != i2) {
                closest_distance2 = dist;
                i2 = i;
            }
        }
        float3 nearest_dodec_vertex = icosa[i2];

        float proj1 = dot(dodec[i1], ws);
        if (proj1 < 1 && loop == iters - 1) {
            ret.density = 1;
        }

        float3 pivot = nearest_dodec_face_center;
        float3 axis0 = normalize(nearest_dodec_face_center);
        float3 axis1 = normalize(nearest_dodec_face_center - nearest_dodec_vertex);
        float3 axis2 = cross(axis0, axis1);
        ws = RotatePointAboutAxis(axis2, pivot, ws, seed_snorm[0].y * 0.5);

        float st = length(ws - axis0 * dot(ws, axis0)) * 0.3f;
        ws = RotatePointAboutAxis(axis0, nearest_dodec_face_center, ws, st);

        ws = (ws - nearest_dodec_vertex) * 2.3 + nearest_dodec_vertex;

        // Avoid +INF's causing issues at high # of iters.
        if (length(ws) > 10) {
            ws = normalize(ws) * 10;
        }
    }

    ret.density = (length(ws) < 1.0) ? 1 : -1;
#endif

    return ret;
}
