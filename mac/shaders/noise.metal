// Quaternion rotation and 3D noise functions available to eval.metal.
// (This file is included inside the Scene struct in gpucaster.metal.)

// smooth1(): sufficient for smooth geometry.
float  smooth1(float  t) { return (3 - 2*t)*t*t; }
float3 smooth1(float3 t) { return (3 - 2*t)*t*t; }

// smooth2(): sufficient for smooth geometry AND normals (i.e. lighting).
float  smooth2(float  t) { return t * t * t * (t * (t * 6 - 15) + 10); }
float3 smooth2(float3 t) { return t * t * t * (t * (t * 6 - 15) + 10); }

// Goes from -1 to 1 and back, each time t goes from [0..1].
float PseudoSine(float t) {
    float t2 = frac(t) * 2 - 1;
    float t3 = abs(t2);
    float t4 = smooth1(t3);
    return t4 * 2 - 1;
}

// Returns sin(angle) in .x, and cos(angle) in .y.
float2 MySinCos(float angle_radians) {
    return float2(sin(angle_radians), cos(angle_radians));
}

//--------------------------------------------------------------------------------------
// Quaternions
//--------------------------------------------------------------------------------------
float4 MakeQuaternion(float3 rot_axis_normalized, float radians) {
    // A quaternion for a rotation about the origin, around 'axis', by 'radians':
    float s = sin(radians * 0.5f);
    float c = cos(radians * 0.5f);
    return float4(c, s * rot_axis_normalized.x, s * rot_axis_normalized.y, s * rot_axis_normalized.z);
}

float3 RotatePointByQuaternion(float3 p1, float4 q) {
    float3 p2;
    const float a = q.x;
    const float b = q.y;
    const float c = q.z;
    const float d = q.w;
    const float t2 =   a*b;
    const float t3 =   a*c;
    const float t4 =   a*d;
    const float t5 =  -b*b;
    const float t6 =   b*c;
    const float t7 =   b*d;
    const float t8 =  -c*c;
    const float t9 =   c*d;
    const float t10 = -d*d;
    p2.x = 2*( (t8 + t10)*p1.x + (t6 -  t4)*p1.y + (t3 + t7)*p1.z ) + p1.x;
    p2.y = 2*( (t4 +  t6)*p1.x + (t5 + t10)*p1.y + (t9 - t2)*p1.z ) + p1.y;
    p2.z = 2*( (t7 -  t3)*p1.x + (t2 +  t9)*p1.y + (t5 + t8)*p1.z ) + p1.z;
    return p2;
}

float3 RotatePointAboutAxis(float3 rot_axis_normalized, float3 pivot, float3 ws_point, const float radians) {
    const float4 q       = MakeQuaternion(rot_axis_normalized, radians);
    const float3 pt      = ws_point - pivot;
    const float3 rotated = RotatePointByQuaternion(pt, q);
    return rotated + pivot;
}

//--------------------------------------------------------------------------------------
// Noise
//--------------------------------------------------------------------------------------
// As this goes >1, higher frequencies are biased toward higher amplitudes.
#define kNoiseAmpBias 0.93f

float UHQNoise_helper(texture3d<float> tex, float3 uvw000, float3 t, float4 scales, float e_x, float f_x) {
    const float2 delta = float2(0, kNoiseVoxelSize);
    const float3 c000 = tex.sample(sam_linear_wrap, uvw000            , level(0)).xyz;  // Gradient at (i,j,k); each item in [-1..1] range.
    const float3 c001 = tex.sample(sam_linear_wrap, uvw000 + delta.xxy, level(0)).xyz;
    const float3 c010 = tex.sample(sam_linear_wrap, uvw000 + delta.xyx, level(0)).xyz;
    const float3 c011 = tex.sample(sam_linear_wrap, uvw000 + delta.xyy, level(0)).xyz;
    const float3 c100 = tex.sample(sam_linear_wrap, uvw000 + delta.yxx, level(0)).xyz;
    const float3 c101 = tex.sample(sam_linear_wrap, uvw000 + delta.yxy, level(0)).xyz;
    const float3 c110 = tex.sample(sam_linear_wrap, uvw000 + delta.yyx, level(0)).xyz;
    const float3 c111 = tex.sample(sam_linear_wrap, uvw000 + delta.yyy, level(0)).xyz;  // Gradient at (i+1,j+1,k+1)
    const float4 proj1 = float4( dot(c000, t                ),
                                 dot(c001, t - float3(0,0,1)),
                                 dot(c010, t - float3(0,1,0)),
                                 dot(c011, t - float3(0,1,1)) );
    const float4 proj2 = float4( dot(c100, t - float3(1,0,0)),
                                 dot(c101, t - float3(1,0,1)),
                                 dot(c110, t - float3(1,1,0)),
                                 dot(c111, t - 1           ) );
    const float4 proj3 = (proj1 * f_x + proj2 * e_x) * scales;
    return dot(proj3, float4(1));
}

float4 UHQNoise4(float3 uvw) {   // Returns values in [-1..1].
    const float3 t = frac(uvw);       // [0..1]
    const float3 uvw_real = uvw * kNoiseVoxelSize;    // Incoming 'uvw' is 1 unit per noise value.
    const float3 uvw000 = uvw_real - t * kNoiseVoxelSize;
    const float3 e = smooth2(t);
    const float3 f = 1 - e;
    const float4 scales = float4(f.y, f.y, e.y, e.y) * float4(f.z, e.z, f.z, e.z);

    float4 ret;
    ret.x = UHQNoise_helper(tex_noise3D_full_a, uvw000, t, scales, e.x, f.x);
    ret.y = UHQNoise_helper(tex_noise3D_full_b, uvw000, t, scales, e.x, f.x);
    ret.z = UHQNoise_helper(tex_noise3D_full_c, uvw000, t, scales, e.x, f.x);
    ret.w = UHQNoise_helper(tex_noise3D_full_d, uvw000, t, scales, e.x, f.x);
    return ret;
}

float4 HQNoise4_helper(float3 uvw000, float3 t) {
    const float2 delta = float2(0, kNoiseVoxelSize);

    const float4 c000 = tex_noise3D_full_a.sample(sam_nearest_wrap, uvw000            , level(0));  // Value at (i,j,k); each item in [-1..1] range.
    const float4 c001 = tex_noise3D_full_a.sample(sam_nearest_wrap, uvw000 + delta.xxy, level(0));
    const float4 c010 = tex_noise3D_full_a.sample(sam_nearest_wrap, uvw000 + delta.xyx, level(0));
    const float4 c011 = tex_noise3D_full_a.sample(sam_nearest_wrap, uvw000 + delta.xyy, level(0));
    const float4 c100 = tex_noise3D_full_a.sample(sam_nearest_wrap, uvw000 + delta.yxx, level(0));
    const float4 c101 = tex_noise3D_full_a.sample(sam_nearest_wrap, uvw000 + delta.yxy, level(0));
    const float4 c110 = tex_noise3D_full_a.sample(sam_nearest_wrap, uvw000 + delta.yyx, level(0));
    const float4 c111 = tex_noise3D_full_a.sample(sam_nearest_wrap, uvw000 + delta.yyy, level(0));  // Value at (i+1,j+1,k+1)
    const float3 g000 = tex_noise3D_full_b.sample(sam_nearest_wrap, uvw000            , level(0)).xyz;  // Gradient at (i,j,k)
    const float3 g001 = tex_noise3D_full_b.sample(sam_nearest_wrap, uvw000 + delta.xxy, level(0)).xyz;
    const float3 g010 = tex_noise3D_full_b.sample(sam_nearest_wrap, uvw000 + delta.xyx, level(0)).xyz;
    const float3 g011 = tex_noise3D_full_b.sample(sam_nearest_wrap, uvw000 + delta.xyy, level(0)).xyz;
    const float3 g100 = tex_noise3D_full_b.sample(sam_nearest_wrap, uvw000 + delta.yxx, level(0)).xyz;
    const float3 g101 = tex_noise3D_full_b.sample(sam_nearest_wrap, uvw000 + delta.yxy, level(0)).xyz;
    const float3 g110 = tex_noise3D_full_b.sample(sam_nearest_wrap, uvw000 + delta.yyx, level(0)).xyz;
    const float3 g111 = tex_noise3D_full_b.sample(sam_nearest_wrap, uvw000 + delta.yyy, level(0)).xyz;
    const float3 e = smooth2(t);
    const float3 f = 1 - e;

    float4 ret = (c000 + dot(g000, t                )) * f.x * f.y * f.z
               + (c001 + dot(g001, t - float3(0,0,1))) * f.x * f.y * e.z
               + (c010 + dot(g010, t - float3(0,1,0))) * f.x * e.y * f.z
               + (c011 + dot(g011, t - float3(0,1,1))) * f.x * e.y * e.z
               + (c100 + dot(g100, t - float3(1,0,0))) * e.x * f.y * f.z
               + (c101 + dot(g101, t - float3(1,0,1))) * e.x * f.y * e.z
               + (c110 + dot(g110, t - float3(1,1,0))) * e.x * e.y * f.z
               + (c111 + dot(g111, t - 1           ) ) * e.x * e.y * e.z;
    return ret;
}

// Output: values in [-1..1] range (roughly; this one has higher amplitudes).
float4 HQNoise4(float3 uvw) {
    const float3 t = frac(uvw);       // [0..1]
    const float3 uvw_real = uvw * kNoiseVoxelSize;
    const float3 uvw000 = uvw_real - t * kNoiseVoxelSize;
    return HQNoise4_helper(uvw000, t);
}

float4 RegNoise4_helper(texture3d<float> tex, float3 uvw000, float3 t) {
    const float2 delta = float2(0, kNoiseVoxelSize);

    const float4 c000 = tex.sample(sam_nearest_wrap, uvw000            , level(0));  // Value at (i,j,k); each item in [-1..1] range.
    const float4 c001 = tex.sample(sam_nearest_wrap, uvw000 + delta.xxy, level(0));
    const float4 c010 = tex.sample(sam_nearest_wrap, uvw000 + delta.xyx, level(0));
    const float4 c011 = tex.sample(sam_nearest_wrap, uvw000 + delta.xyy, level(0));
    const float4 c100 = tex.sample(sam_nearest_wrap, uvw000 + delta.yxx, level(0));
    const float4 c101 = tex.sample(sam_nearest_wrap, uvw000 + delta.yxy, level(0));
    const float4 c110 = tex.sample(sam_nearest_wrap, uvw000 + delta.yyx, level(0));
    const float4 c111 = tex.sample(sam_nearest_wrap, uvw000 + delta.yyy, level(0));  // Value at (i+1,j+1,k+1)
    const float3 e = smooth2(t);
    const float3 f = 1 - e;

    float4 ret = c000 * f.x * f.y * f.z
               + c001 * f.x * f.y * e.z
               + c010 * f.x * e.y * f.z
               + c011 * f.x * e.y * e.z
               + c100 * e.x * f.y * f.z
               + c101 * e.x * f.y * e.z
               + c110 * e.x * e.y * f.z
               + c111 * e.x * e.y * e.z;
    return ret;
}

// Output: values in [-1..1] range.
float4 RegNoise4(float3 uvw) {
    const float3 t = frac(uvw);       // [0..1]
    const float3 uvw_real = uvw * kNoiseVoxelSize;
    const float3 uvw000 = uvw_real - t * kNoiseVoxelSize;
    return RegNoise4_helper(tex_noise3D_full_a, uvw000, t);
}

// Output: values in [-1..1] range.  One lookup; blocky.
float4 SnapNoise4(float3 uvw) {
    return tex_noise3D_full_a.sample(sam_nearest_wrap, uvw * kNoiseVoxelSize, level(0));
}
float4 SnapNoise4(float3 uvw, texture3d<float> tex) {
    return tex.sample(sam_nearest_wrap, uvw * kNoiseVoxelSize, level(0));
}

#define NOISE_SNAP 0    // Ultra-fast (single lookup).
#define NOISE_REG  1    // USE THIS in most cases.  Basis shape slightly blocky, but good enough.  8 lookups.
#define NOISE_HQ   2    // Quasi-Perlin noise.  16 lookups.  **NOTE - this one has higher amplitudes.**
#define NOISE_UHQ  3    // Full Perlin noise.  Very slow.

#define MAX_OCTAVES 24

float4 OctaveNoise(const int NOISE_TYPE,
                   const float3 ws,  // <----- THIS MUST BE THE REAL WS COORD, OTHERWISE NYQUIST LIMIT WON'T BE HONORED <-----
                   const float wavelen,       // How much distance, in world-space units, 1 texel of noise should cover.
                   const float ws_pixel_size,
                   const float _min_feature_size_pixels,
                   const bool bSmoothBasedOnLowerFreqs,
                   const bool bCreased,
                   const int noiseIndex,    // allows each subsequent OctaveNoise call (within a single Eval()) to produce different noise.
                   const int nMaxOctaves,   // = MAX_OCTAVES
                   const bool bDimply = false)
{
    float3 uvw_orig = ws * (1.0/wavelen);
    const float min_feature_size_pixels = _min_feature_size_pixels * 0.67f;

    // For damping various octaves:
    float4 fMult[4] = { float4(1,1,1,1), float4(1,1,1,1), float4(1,1,1,1), float4(1,1,1,1) };

    float4 noise_sum = float4(0);
    float _amp  = 1.0f;
    float _freq = 1.0f;

    const int N = min(nMaxOctaves, MAX_OCTAVES);

    for (int i=0; i<N; i++)
    {
        int randIndex = i * (noiseIndex+1) + noiseIndex*7 + 3;

        float amp  = _amp;
        float freq = _freq * (1 + 0.15f*seed_snorm[randIndex % SEED_SNORM_COUNT].w);

        // Nyquist limit (soft): stop adding detail finer than a pixel.
        float nyquist_fade = saturate( wavelen - min_feature_size_pixels * (freq * ws_pixel_size) + 0.5f);
        if (nyquist_fade <= 0)
            break;

        // Randomly rotate (and translate) the uvw coordinates for this octave.
        const float4x4 m = seed_rot_mat[randIndex % SEED_ROT_MAT_COUNT];
        float3 uvw = (m * float4(uvw_orig, float(kNoiseCubeSize))).xyz;

        // Scale them, crunch noise, scale the result, and add it to our running sum.
        float4 noise;
        if (NOISE_TYPE == NOISE_SNAP)
            noise = SnapNoise4(uvw * freq);
        else if (NOISE_TYPE == NOISE_REG)
            noise = RegNoise4(uvw * freq);
        else if (NOISE_TYPE == NOISE_HQ)
            noise = HQNoise4(uvw * freq);
        else
            noise = UHQNoise4(uvw * freq);

        if (bSmoothBasedOnLowerFreqs)
        {
            noise *= fMult[i % 3];
            float4 fTerm = noise*0.5 + 0.5;
            fMult[i % 3] = fTerm;
        }

        if (bCreased)
            noise = (0.4f - abs(noise))*2;

        if (bDimply) {
            noise = noise*0.5f + 0.5f;
            noise *= noise;
            noise -= 0.25f;
            noise *= -1.333f;
        }

        noise_sum += noise * (amp * nyquist_fade);

        _amp  *= 0.5f * kNoiseAmpBias;
        _freq *= 2.0f;
    }
    return noise_sum;
}
