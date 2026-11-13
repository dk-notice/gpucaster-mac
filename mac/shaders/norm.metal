// Normals pass: works out which way the surface faces at each pixel, for
// either the primary ray's hit point or the reflection ray's hit point.
// (This file is included inside the Scene struct in gpucaster.metal.)

#define kNormRefinementSteps 12

// Returns a vector in the plane made by the two vectors, N and T,
// that is parallel to the surface, at the point ws.
float3 GradHelper(const float3 N, const float3 T, const float3 ws, const float ws_pixel_size) {
    const float rad = ws_pixel_size*0.5f * kNormSampleRadiusMult;
    float3 intersection_pt[2];
    for (int side=0; side<2; side++)
    {
        float lo = 0;
        float hi = 3.1415926535898f;
        const float T_sign = (side==0) ? 1.0f : -1.0f;
        for (int it=0; it<kNormRefinementSteps; it++)
        {
            float mid = (lo+hi)*0.5f;
            float2 sin_cos = MySinCos(mid);
            float3 pt = ws + N*(rad*-sin_cos.y) + T*(sin_cos.x*rad*T_sign);
            float density = Eval(pt).density;
            if (density > 0)
                lo = mid;
            else
                hi = mid;
        }
        float mid = (lo+hi)*0.5f;
        float2 sin_cos = MySinCos(mid);
        intersection_pt[side] = ws + N*(rad*-sin_cos.y) + T*(sin_cos.x*rad*T_sign);
    }
    // Do normalize here, in case the vectors are getting too tiny to store in float.
    float3 v = (intersection_pt[1] - intersection_pt[0]);
    return normalize(v);
}

// Takes 512 samples out at 1/2 a pixel's radius; averages the direction
// of the samples that are 'escaped' (in air, not rock).
// Also returns the fraction escaped in .w, for debugging purposes.
float4 GetSurfaceNormalHQ(float3 ws, float ws_pixel_size) {
    float rad = ws_pixel_size*0.5f * kNormSampleRadiusMult;
    int escaped_count = 0;
    float3 average_escape_ray = float3(0,0,0);
    for (int i=0; i<NORMAL_RAY_DIRS; i++)
    {
        float3 dir = normalize( tex_normal_ray_dirs.read(uint2(i, 0)).xyz );
        float3 ws2 = ws + (dir * rad);
        float density = Eval(ws2).density;
        if (density <= 0) {
            escaped_count++;
            average_escape_ray += dir;
        }
    }
    float3 N         = normalize(average_escape_ray);
    float  ambo_frac = escaped_count/(float)(NORMAL_RAY_DIRS);
    return float4(N, ambo_frac);
}

float4 GetSurfaceNormalHQ_refined(float3 ws, float ws_pixel_size) {
    float4 mq_data = GetSurfaceNormalHQ(ws, ws_pixel_size);
    const float3 orig_grad = mq_data.xyz;
    float3 grad = orig_grad;

    // Refine.  This is pretty much essential for reflection, otherwise reflections are ultra-fuzzy.
    const float3 s = float3( grad.x > 0 ? 1 : -1,
                             grad.y > 0 ? 1 : -1,
                             grad.z > 0 ? 1 : -1 );
    const float3 M = abs(grad);
    const float fmax = max(M.x, max(M.y, M.z));
    float3 du[2];
    float3 dv[2];
    float sgn[2];
    if (M.z >= fmax) {
        // Valid except in XY plane.
        du[0] = float3(0,s.y,0);
        dv[0] = float3(0,0,1);
        du[1] = float3(0,0,s.z);
        dv[1] = float3(1,0,0);
        sgn[0] = s.y;
        sgn[1] = s.z;
    } else if (M.x >= fmax) {
        // Valid except in YZ plane.
        du[0] = float3(0,0,s.z);
        dv[0] = float3(1,0,0);
        du[1] = float3(s.x,0,0);
        dv[1] = float3(0,1,0);
        sgn[0] = s.z;
        sgn[1] = s.x;
    } else {
        // Valid except in XZ plane.
        du[0] = float3(s.x,0,0);
        dv[0] = float3(0,1,0);
        du[1] = float3(0,s.y,0);
        dv[1] = float3(0,0,1);
        sgn[0] = s.x;
        sgn[1] = s.y;
    }

    // Only run GradHelper() twice, because it's expensive:
    float3 z[2];
    for (int i=0; i<2; i++)
    {
        z[i] = GradHelper(du[i], dv[i], ws, ws_pixel_size) * sgn[i];
    }

    if (abs(length(z[0]) - 1) < 0.01 &&
        abs(length(z[1]) - 1) < 0.01 &&
        abs(dot(z[0],z[1])) < 0.99)
    {
        float3 new_grad = normalize(cross(z[0], z[1])) * sgn[1]; //[sic]
        if (abs(length(new_grad) - 1) < 0.01)
        {
            grad = new_grad;
        }
    }

    return float4(grad, mq_data.w);
}

float4 NormPS(float2 uv) {
    const RayInfo r = GetRayInfo(uv, tex_refl_depth);

    float4 surface_normal = float4(0);
    if (r.main_depth > 0 && r.prev_depth_along_ray > 0)
    {
        float3 ws = r.ray_start + r.ray_dir * r.prev_depth_along_ray;
        float  ws_pixel_size = g_ws_pixel_size_at_depth_1 * length(ws - ws_eye_pos);
        ws -= r.ray_dir * (kNormPixelsAlongEyeRayToPullBack * ws_pixel_size);
        surface_normal = GetSurfaceNormalHQ_refined(ws, ws_pixel_size);   // .w = debugging info
    }
    return surface_normal;
}
