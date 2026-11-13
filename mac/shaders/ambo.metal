// Ambient occlusion pass: casts rays out from each surface point in many
// directions and records what fraction escape without hitting anything.
// Results are added to the previous passes' results (additive blending), so
// the picture gets smoother with every pass.
// (This file is included inside the Scene struct in gpucaster.metal.)

float CastAmboRay(float3 start_pt, float3 ambo_ray_dir, float ws_pixel_size, float frand) {
    float escaped = 1;
    for (int i=0; i<kAmboSamplesPerRay; i++)
    {
        // Note: using i-1 and clamping it to 0 makes sure that all rays get tested at the very start,
        // as well as at staggered points thereafter.  This prevents ugly low-freq glowing creases.
        float  t = max(0.0f, (i - 1 + frand) * (1.0f/(kAmboSamplesPerRay)));    // [0..1]
        float  dist_along_ray = pow(t, kAmboSamplePlacementAlongRayPow) * max_dist + (kAmboPixelsAlongAmboRayToJumpFwd * ws_pixel_size);
        float3 ws = start_pt + (ambo_ray_dir * dist_along_ray);
        float  density = Eval(ws).density;
        // The value we return is based solely on the distance to the *nearest* blockage.
        if (density > 0 && escaped >= 1) {
            escaped = pow( t * (1.0f/max_dist), kAmboFalloffPower );
            return escaped;
        }
    }
    return escaped;
}

// Returns .xyz = sum of escaped ray directions, .w = fraction escaped.
float4 AmboPS(float2 uv) {
    const RayInfo r = GetRayInfo(uv, tex_refl_depth);

    float3 norm_at_ws;
    if (g_intersection_set == 0)
        norm_at_ws = normalize( tex_main_norm.sample(sam_nearest_clamp, uv, level(0)).xyz );
    else
        norm_at_ws = normalize( tex_refl_norm.sample(sam_nearest_clamp, uv, level(0)).xyz );

    float4 ambo_data = float4(0);
    if (r.main_depth > 0 && r.prev_depth_along_ray > 0)
    {
        float3 ws = r.ray_start + r.ray_dir * r.prev_depth_along_ray;
        float  ws_pixel_size = g_ws_pixel_size_at_depth_1 * length(ws - ws_eye_pos);
        ws +=   norm_at_ws * kAmboPixelsAlongNormalToJumpFwd * ws_pixel_size
              - r.ray_dir * (kAmboPixelsAlongEyeRayToPullBack*ws_pixel_size);

        float4 ambo_sum = float4(0);
        int rays_cast = 0;
        for (int i=0; i<kAmboRaysPerPass; i++)
        {
            // Choose a random value [0..1] that gives each ray a random starting point.
            // The value is frac(a + b), where a varies from tile to tile,
            // and b varies from pixel to pixel.
            const float rand_ray = time_unorm[i % (TIME_UNORM_COUNT)].y;
            const float2 uv_for_noise = uv * g_image_size.xy * (1.0/(float)(NOISE_2D_SIZE));  // exactly 1:1
            const float rand_pixel = tex_noise_unorm_2d.sample(sam_nearest_wrap, uv_for_noise, level(0)).x;
            const float frand = frac(rand_ray + rand_pixel);

            // Fetch a ray direction.
            uint j = uint(i + kAmboRaysPerPass*int(g_cur_ambo_pass)) % uint(AMBO_RAY_DIRS);
            float3 ambo_ray_dir = normalize( tex_ray_dirs.read(uint2(j, 0)).xyz );

            // Cast the ray.
            float pure_ambo = CastAmboRay(ws, ambo_ray_dir, ws_pixel_size, frand);

            // Accumulate the results.
            ambo_sum += float4(ambo_ray_dir, 1) * pure_ambo;
            rays_cast++;
        }

        float4 ambo_avg = ambo_sum / (float)rays_cast;
        ambo_avg.w = max(0.001f, ambo_avg.w);
        ambo_data = ambo_avg;
    }
    return ambo_data;
}
