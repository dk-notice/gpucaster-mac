// Relight pass: turns the stored depth, normals and ambient occlusion into
// the final coloured picture.  It is cheap, so lighting changes show instantly.
// (This file is included inside the Scene struct in gpucaster.metal.)

float3 DoFog(float3 pre_fog_surface_color, float depth) {
    float fog_depth = ((depth<=0) ? max_dist : depth) * g_fog_params.x;
    float fog_str = saturate(pow(fog_depth, g_fog_params.y));
    return lerp(pre_fog_surface_color, g_fog_color.xyz, fog_str);
}

float3 DoLighting(float3 ws,
                  float3 incoming_refl_light,
                  EvalResult evalResult,
                  float depth,
                  float3 N,
                  float3 ambo_dir,   // direction (might be 0)
                  float  ambo_frac,  // fraction escaped (~0.5 = bright)
                  float  spec_scale)
{
    float3 lit_color = float3(0);
    if (depth > 0)
    {
        const int num_lights = min(5, MAX_LIGHTS);    // DO NOT EXCEED 'MAX_LIGHTS'.

        float ambo_diffuse = saturate( (ambo_frac - kLightAmboDiffuseUnLitThresh) * (1.0f/(kLightAmboDiffuseFullyLitThresh - kLightAmboDiffuseUnLitThresh)) );
        ambo_diffuse = ambo_diffuse*ambo_diffuse*(3 - 2*ambo_diffuse);
        ambo_diffuse = pow(ambo_diffuse, kLightAmboDiffuseExponent) * 0.8f;

        float ambo_spec = saturate( (ambo_frac - kLightAmboSpecLo) * (1.0f/(kLightAmboSpecHi - kLightAmboSpecLo)) );
        ambo_spec = ambo_spec*ambo_spec*(3 - 2*ambo_spec);

        // Diffuse light:
        for (int i=0; i<num_lights; i++)
        {
            const float3 L = -g_light_dir[i].xyz;
            float orig_str = dot(N, L);
            if (length(ambo_dir) > 0.01 && kLightUseDirectionalAmbo > 0)
            {
                float cone_str = dot(ambo_dir, L) + (ambo_frac*2 - 1);
                orig_str *= saturate(cone_str * kLightAmboDirScale + kLightAmboDirBias);
            }
            float wrap = g_light_wrap[i].x;
            const float wrap_str = lerp(orig_str, orig_str*0.5f + 0.5f, wrap);   // light wrap
            lit_color += g_light_col[i].xyz * max(0.0f, wrap_str) * ambo_diffuse;
        }

        // Apply surface color.
        float3 surface_color = lerp(float3(1), evalResult.surface_color, kSurfaceColorAmount);
        lit_color *= surface_color;

        // Add spec light.
        for (int i=0; i<num_lights; i++)
        {
            if (g_light_spec_enabled[i].x > 0)
            {
                const float light_lum = (g_light_col[i].x + g_light_col[i].y + g_light_col[i].z) * 0.33333 * g_light_spec_scale[i].x;
                const float3 V = normalize(ws_eye_pos - ws);
                float d = dot(N, V);
                if (d > 0)
                {
                    float3 R = normalize( N*d*2 - V );
                    float d2 = -dot(R, g_light_dir[i].xyz);
                    if (d2 > 0)
                    {
                        float spec_pow = pow(2.0f, kLightSpecPow);
                        float this_spec_str = pow( d2, spec_pow );
                        lit_color += kLightSpecStr * this_spec_str * light_lum * ambo_spec * spec_scale;
                    }
                }
            }
        }

        // Add reflected light (pre-fog).
        lit_color += incoming_refl_light;
    }

    // Apply fog.
    lit_color = DoFog(lit_color, depth);

    return lit_color;
}

float4 RelightPS(float2 uv) {
    float3 final_color = float3(0);

    const float3 main_ray_dir = ComputeViewRayDirFromUV(uv);
    const float  orig_main_depth = tex_main_depth.sample(sam_nearest_clamp, uv, level(0)).x;
    const float4 orig_main_norm  = tex_main_norm.sample(sam_nearest_clamp, uv, level(0));
    const float4 orig_main_ambo  = tex_main_ambo.sample(sam_nearest_clamp, uv, level(0));
    const float  orig_refl_depth = tex_refl_depth.sample(sam_nearest_clamp, uv, level(0)).x;
    const float4 orig_refl_norm  = tex_refl_norm.sample(sam_nearest_clamp, uv, level(0));
    const float4 orig_refl_ambo  = tex_refl_ambo.sample(sam_nearest_clamp, uv, level(0));

    bool apply_final_brightness_and_sat = true;

    // Which tile this pixel is in.  While an ambient occlusion pass is part-way
    // through, tiles it hasn't reached yet have one pass fewer than the rest.
    const float2 px = uv * g_image_size.xy;
    const uint tile_index = uint(floor(px.y / g_tile_info.y)) * uint(g_tile_info.z) + uint(floor(px.x / g_tile_info.x));

    // p==0: 2nd ray intersection pt (...where the reflection ray landed).
    // p==1: primary ray intersection pt (...where the primary ray landed).
    for (int p=0; p<2; p++)
    {
        float orig_depth;
        float4 orig_norm;
        float4 orig_ambo;
        int ambo_pass;
        if (p == 0) {
            // Reflected ray.
            orig_depth = orig_refl_depth;
            orig_norm  = orig_refl_norm ;
            orig_ambo  = orig_refl_ambo ;
            ambo_pass  = int(g_refl_ambo_pass);
            if (tile_index >= g_refl_ambo_tiles_done) ambo_pass -= 1;
        } else {
            // Main ray.
            orig_depth = orig_main_depth;
            orig_norm  = orig_main_norm ;
            orig_ambo  = orig_main_ambo ;
            ambo_pass  = int(g_main_ambo_pass);
            if (tile_index >= g_main_ambo_tiles_done) ambo_pass -= 1;
        }

        const float3 surface_normal = normalize(orig_norm.xyz);
        float  spec_and_refl_scale = 1;
        const float3 ambo_dir  = normalize(orig_ambo.xyz);
        const float  ambo_frac = orig_ambo.w * (1.0f/(float)(max(ambo_pass, 1)));

        // Fetch previously-found surface depth.
        float3 ray_start;
        float3 ray_dir;
        float  prev_depth_along_ray;
        if (p == 0)
        {
            // Use reflected ray (from first surface intersection, bounced around normal):
            ray_start = ws_eye_pos + main_ray_dir * orig_main_depth;
            ray_dir   = ComputeBouncedRayDir(main_ray_dir, orig_main_norm.xyz);
            // Nudge reflected ray starting point back by about a pixel, along the original ray:
            float dist_from_eye = length(ray_start - ws_eye_pos);
            float ws_pixel_size_main = g_ws_pixel_size_at_depth_1 * dist_from_eye;
            ray_start -= main_ray_dir * ws_pixel_size_main * kReflectionPullbackAlongIncomingRay;
            prev_depth_along_ray = orig_refl_depth;
        }
        else
        {
            // Use primary ray (from eye):
            ray_start = ws_eye_pos;
            ray_dir = main_ray_dir;
            prev_depth_along_ray = orig_main_depth;
        }
        float3 ws = ray_start + ray_dir * prev_depth_along_ray;

        // Apply ambo - IF it's there.
        float temp_ambo = (orig_ambo.w > 0) ? ambo_frac : 0.5;

        // Evaluate various properties at this ws location.
        const float ws_pixel_size = length(ws_eye_pos - ws) * g_ws_pixel_size_at_depth_1;
        EvalResult evalResult = Eval(ws - surface_normal*ws_pixel_size*0.02);

        if (p==1)
        {
            // Tone down prev. reflection by reflectivity @ this ws point.
            // (Have to do this pre-fog).
            final_color *= evalResult.reflectivity * kReflectivity * spec_and_refl_scale;
        }

        final_color = DoLighting(ws, final_color, evalResult, orig_depth, surface_normal, ambo_dir, temp_ambo, spec_and_refl_scale);

        // p==0, g_intersection_set==1 : reflected ray color.
        // p==1, g_intersection_set==0 : main ray color.
        if (int(g_intersection_set) == 1-p)
        {
            // View modes:
            // 0 = regular (final lit color)
            // 1 = pink depth
            // 2 = striped depth
            // 3 = normals
            // 4 = striped normals
            // 5 = normal.w (fraction escaped; should never be white or black)
            // 6 = reflectivity
            const int remap_no_N[16] = { 1, 1, 2, 1, 1, 1, 6, 7, 1, 9, 10, 11, 12, 13, 14, 15 };

            // Until normals exist for this pixel, fall back to showing depth.
            int viz_mode = int(g_viz_mode);
            if (orig_depth > 0 && abs(length(orig_norm.xyz)-1) > 0.1)
                viz_mode = remap_no_N[viz_mode];

            if (g_viz_mode > 0 || viz_mode != int(g_viz_mode))
            {
                if (viz_mode == 1)  // pink depth
                {
                    float t = orig_depth * (1.0f/max_dist);
                    final_color.x = pow(t, 0.25);
                    final_color.y = t;
                    final_color.z = sqrt(t);
                }
                else if (viz_mode == 2)  // striped depth
                    final_color = frac(orig_depth * float3(8, 0.5, 2) * 50);
                else if (viz_mode == 3)  // normals
                    final_color = 0.5 + 0.5*orig_norm.xyz;
                else if (viz_mode == 4)  // striped normals
                    final_color = frac(orig_norm.xyz * 20);
                else if (viz_mode == 5)  // surface normal % escaped
                    final_color = float3(orig_norm.w);
                else if (viz_mode == 6)  // reflectivity
                    final_color = float3(evalResult.reflectivity);
                apply_final_brightness_and_sat = false;
            }
        }
    }

    if (apply_final_brightness_and_sat)
    {
        // apply final brightness & saturation:
        float lum = (final_color.x + final_color.y + final_color.z) * 0.33333;
        final_color = lerp(float3(lum), final_color, kLightSat);
        final_color *= kLightScale;
    }

    // Gamma correction:
    final_color = pow(max(final_color, float3(0)), float3(kFinalGamma));

    return float4(saturate(final_color), 1);
}
