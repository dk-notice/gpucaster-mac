// Small math helpers available to eval.metal.
// (This file is included inside the Scene struct in gpucaster.metal.)

// Input: t in [0..1].  Output: a smooth interpolation from [0..1].
float SmoothL1(float t) {
    t = saturate(t);
    return t * t * (3 - 2 * t);
}

// Input: t in [0..1].  Output: a smoother interpolation from [0..1]. (Lighting will look good.)
float SmoothL2(float t) {
    t = saturate(t);
    return t * t * t * (t * (t * 6 - 15) + 10);
}

// Rotation ONLY - skips the translation (if there is any in the matrix).
float3 RotatePointByMatrix(float3 a, float4x4 m) {
    return float3(dot(float3(m[0].x, m[1].x, m[2].x), a),
                  dot(float3(m[0].y, m[1].y, m[2].y), a),
                  dot(float3(m[0].z, m[1].z, m[2].z), a));
}

// Reflects a point about a plane with the given normal that intersects the origin.
float3 ReflectAboutPlane(float3 p, float3 N) {
    float t = dot(p, N);
    if (t < 0) {
        return p - 2 * t * N;
    } else {
        return p;
    }
}

// Ray through the pixel at 'uv' ((0,0) = upper-left of the image, (1,1) = lower-right).
float3 ComputeViewRayDirFromUV(float2 uv) {
    // A point on the virtual screen we're casting rays through, in camera space.
    float3 pt = ws_screen_corner_UL + ws_screen_across * uv.x + ws_screen_down * uv.y;
    float3 ray_dir = normalize(pt);
    // Rotate from camera space into world space.
    return normalize(ray_dir.x * ws_camera_x_axis +
                     ray_dir.y * ws_camera_y_axis +
                     ray_dir.z * ws_camera_z_axis);
}

float3 ComputeBouncedRayDir(float3 main_ray_dir, float3 main_norm) {
    float3 I = normalize(main_ray_dir);
    float3 N = normalize(main_norm);
    float3 R = normalize(I - N * (2 * dot(I, N)));
    return R;
}
