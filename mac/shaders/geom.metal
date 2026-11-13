// Geometry pass: finds how far along each ray the surface is, either for the
// primary ray (from the camera) or for the reflection ray.  Each pass tests
// more points along the ray and keeps the nearest one found so far.
// (This file is included inside the Scene struct in gpucaster.metal.)

// Describes the ray being worked on for one pixel.
struct RayInfo {
    float3 ray_start;
    float3 ray_dir;
    float3 main_ray_dir;
    float  main_depth;
    float  prev_depth_along_ray;   // depth found so far along this ray (0 = nothing yet)
};

// 'prev_refl_depth' is the reflection-ray depth texture to continue from.
RayInfo GetRayInfo(float2 uv, texture2d<float> prev_refl_depth) {
    RayInfo r;
    r.main_ray_dir = ComputeViewRayDirFromUV(uv);
    r.main_depth   = tex_main_depth.sample(sam_nearest_clamp, uv, level(0)).x;

    if (g_intersection_set == 0)
    {
        // Use primary ray (from eye):
        r.ray_start = ws_eye_pos;
        r.ray_dir = r.main_ray_dir;
        r.prev_depth_along_ray = r.main_depth;
    }
    else
    {
        // Use reflected ray (from first surface intersection, bounced around normal):
        float3 main_norm = normalize( tex_main_norm.sample(sam_nearest_clamp, uv, level(0)).xyz );
        r.ray_start = ws_eye_pos + r.main_ray_dir * r.main_depth;
        r.ray_dir   = ComputeBouncedRayDir(r.main_ray_dir, main_norm);

        // Nudge reflected ray starting point back by about a pixel, along the original ray:
        float dist_from_eye = length(r.ray_start - ws_eye_pos);
        float ws_pixel_size_main = g_ws_pixel_size_at_depth_1 * dist_from_eye;
        r.ray_start -= r.main_ray_dir * ws_pixel_size_main * kReflectionPullbackAlongIncomingRay;

        r.prev_depth_along_ray = prev_refl_depth.sample(sam_nearest_clamp, uv, level(0)).x;
    }
    return r;
}

float TryDepth(float3 start_pos, float3 ray_dir, float t, float best_t) {
    float3 ws = start_pos + (ray_dir * t);
    float  density = Eval(ws).density;
    if (density > 0 && t < best_t)
        return t;
    return best_t;
}

float GeomPS(float2 uv) {
    // Vary the types of samples we take over time.
    // This results in the geometry being pretty much solved, to within a single pixel, after 16 passes.
    const int kFrameShift = 2;
    const int kWorkMult = 8;
    const int _kBigDistSamplesPerFrame  [8] = { 16, 12,  8,  6,   4,  2, 2, 2  };
    const int _kNeighborSamplesPerFrame [8] = {  0,  4,  8, 10,  10, 10, 7, 4  };
    const int _kSmallDistSamplesPerFrame[8] = {  0,  0,  0,  0,   2,  4, 7, 10 };

    const RayInfo r = GetRayInfo(uv, tex_prev_depth);
    const float3 ray_start = r.ray_start;
    const float3 ray_dir = r.ray_dir;

    // Experimental "skip empty sky": once enough passes have gone by, stop
    // testing a pixel where nothing has been found - provided none of its four
    // neighbours has found anything either, so a surface can still spread
    // outwards from its edges.  Reflection rays from pixels with no surface
    // at all are skipped too; nothing ever reads them.
    if (g_skip_empty_after > 0) {
        if (g_intersection_set == 1 && r.main_depth <= 0) return 0;
        if (g_geom_frames_since_geom_clear >= g_skip_empty_after && r.prev_depth_along_ray <= 0) {
            float near = 0;
            near = max(near, tex_prev_depth.sample(sam_nearest_clamp, uv + g_image_size.zw * float2( 1, 0), level(0)).x);
            near = max(near, tex_prev_depth.sample(sam_nearest_clamp, uv + g_image_size.zw * float2(-1, 0), level(0)).x);
            near = max(near, tex_prev_depth.sample(sam_nearest_clamp, uv + g_image_size.zw * float2(0,  1), level(0)).x);
            near = max(near, tex_prev_depth.sample(sam_nearest_clamp, uv + g_image_size.zw * float2(0, -1), level(0)).x);
            if (near <= 0) return 0;
        }
    }

    // Test more points along the ray, but don't bother testing anything beyond
    // the nearest known surface depth.
    float best_t = (r.prev_depth_along_ray <= 0) ? max_dist : r.prev_depth_along_ray;

    int samples = 0;

    const int fr = min(int(g_geom_frames_since_geom_clear >> kFrameShift), 7);
    const int kNeighborSamplesPerFrame  = _kNeighborSamplesPerFrame[fr]  * kGeomSamplesPerFrame * kWorkMult / 16;
    const int kBigDistSamplesPerFrame   = _kBigDistSamplesPerFrame[fr]   * kGeomSamplesPerFrame * kWorkMult / 16;
    const int kSmallDistSamplesPerFrame = _kSmallDistSamplesPerFrame[fr] * kGeomSamplesPerFrame * kWorkMult / 16;

    const float2 uv_for_noise = uv * g_image_size.xy * (1.0/(float)(NOISE_2D_SIZE));  // exactly 1:1
    const float4 rand_pixel   = tex_noise_unorm_2d.sample(sam_nearest_wrap, uv_for_noise, level(0));

    // Check near a neighbor's depth values, if they're nonzero.
    // (For those that are zero, we'll just try a random depth.)
    const float2 delta[4] = { float2(1,0), float2(-1,0), float2(0,1), float2(0,-1) };
    for (int i=0; i<kNeighborSamplesPerFrame; i++)
    {
        const float rand_sample = time_unorm[samples % (TIME_UNORM_COUNT)].z;
        const float frand = frac(rand_sample + rand_pixel.z);

        int k = (i + int(g_cur_frame)) & 3;
        float neighbor_t = tex_prev_depth.sample(sam_nearest_clamp, uv + g_image_size.zw * delta[k], level(0)).x;
        float t;
        if (neighbor_t <= 0)
            t = frand * best_t;
        else
            t = neighbor_t * ((1-kGeomPercentNeighborDepthRand*0.5) + kGeomPercentNeighborDepthRand*frand);

        best_t = TryDepth(ray_start, ray_dir, t, best_t);
        samples++;
    }

    // Try some more random depths, as well as some small refinements.
    for (int i=0; i<kBigDistSamplesPerFrame + kSmallDistSamplesPerFrame; i++)
    {
        const float rand_sample = time_unorm[samples % (TIME_UNORM_COUNT)].z;
        const float frand = frac(rand_sample + rand_pixel.z);

        float t;
        if (i < kBigDistSamplesPerFrame)
        {
            // Try some big darts.
            t = frand;
            if (best_t < max_dist)
                t = 1 - t*t;
            t *= best_t;
        }
        else
        {
            // Try some little darts.
            if (best_t < max_dist) {
                float dist_from_eye = length(ray_start + ray_dir * best_t - ws_eye_pos);
                const float ws_pixel_size = g_ws_pixel_size_at_depth_1 * dist_from_eye;
                t = best_t - ws_pixel_size * frand;
            } else {
                t = frand * best_t;
            }
        }

        best_t = TryDepth(ray_start, ray_dir, t, best_t);
        samples++;
    }

    // Did we find the surface?
    if (best_t > 0 && best_t < max_dist)
        return best_t;
    return 0;
}
