#include "SceneState.h"

#include <cmath>
#include <cstdio>
#include <cstring>

static inline float saturate(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }
static inline float3 lerp3(float3 a, float3 b, float t) { return a + (b - a) * t; }
static inline f4 make4(float3 v, float w) { return simd_make_float4(v.x, v.y, v.z, w); }
static inline float3 xyz(f4 v) { return simd_make_float3(v.x, v.y, v.z); }

//--------------------------------------------------------------------------------------
// Quaternion rotation (same formulas as the shaders)
//--------------------------------------------------------------------------------------
static f4 MakeQuaternion(float3 axis, float radians) {
    float s = sinf(radians * 0.5f), c = cosf(radians * 0.5f);
    return simd_make_float4(c, s * axis.x, s * axis.y, s * axis.z);
}

static float3 RotatePointByQuaternion(float3 p1, f4 q) {
    const float a = q.x, b = q.y, c = q.z, d = q.w;
    const float t2 = a * b, t3 = a * c, t4 = a * d, t5 = -b * b, t6 = b * c;
    const float t7 = b * d, t8 = -c * c, t9 = c * d, t10 = -d * d;
    float3 p2;
    p2.x = 2 * ((t8 + t10) * p1.x + (t6 - t4) * p1.y + (t3 + t7) * p1.z) + p1.x;
    p2.y = 2 * ((t4 + t6) * p1.x + (t5 + t10) * p1.y + (t9 - t2) * p1.z) + p1.y;
    p2.z = 2 * ((t7 - t3) * p1.x + (t2 + t9) * p1.y + (t5 + t8) * p1.z) + p1.z;
    return p2;
}

void Frame::RotateOnX(float radians) {
    f4 q = MakeQuaternion(x, radians);
    y = RotatePointByQuaternion(y, q);
    z = RotatePointByQuaternion(z, q);
    y = simd_normalize(simd_cross(z, x));
    z = simd_normalize(simd_cross(x, y));
}
void Frame::RotateOnY(float radians) {
    f4 q = MakeQuaternion(y, radians);
    z = RotatePointByQuaternion(z, q);
    x = RotatePointByQuaternion(x, q);
    z = simd_normalize(simd_cross(x, y));
    x = simd_normalize(simd_cross(y, z));
}
void Frame::RotateOnZ(float radians) {
    f4 q = MakeQuaternion(z, radians);
    x = RotatePointByQuaternion(x, q);
    y = RotatePointByQuaternion(y, q);
    x = simd_normalize(simd_cross(y, z));
    y = simd_normalize(simd_cross(z, x));
}
void Frame::RotateOnWSX(float radians) {
    f4 q = MakeQuaternion(simd_make_float3(1, 0, 0), radians);
    y = RotatePointByQuaternion(y, q);
    z = RotatePointByQuaternion(z, q);
    y = simd_normalize(simd_cross(z, x));
    z = simd_normalize(simd_cross(x, y));
}
void Frame::RotateOnWSY(float radians) {
    f4 q = MakeQuaternion(simd_make_float3(0, 1, 0), radians);
    z = RotatePointByQuaternion(z, q);
    x = RotatePointByQuaternion(x, q);
    z = simd_normalize(simd_cross(x, y));
    x = simd_normalize(simd_cross(y, z));
}

//--------------------------------------------------------------------------------------
// Random numbers
//--------------------------------------------------------------------------------------
// std::mt19937 is the same Mersenne Twister generator, with the same seeding,
// as the MTRand class the Windows version used.

SceneState::SceneState() {
    ApplyDefaultSettings();
    ResetCamera();
    OnSeed(kDefaultSeed);
    RandomizeLights();
}

uint32_t SceneState::nrand() { return (uint32_t)rng_(); }
float SceneState::frand() { return (float)((double)nrand() * (1.0 / 4294967295.0)); }

// The Windows compiler evaluated the arguments of float4(FRAND, FRAND, FRAND, FRAND)
// from right to left, so the last component gets the first random number.
f4 SceneState::rand4() {
    float w = frand(), z = frand(), y = frand(), x = frand();
    return simd_make_float4(x, y, z, w);
}

float3 SceneState::randDir() {
    float z = frand() * 2 - 1, y = frand() * 2 - 1, x = frand() * 2 - 1;
    return simd_normalize(simd_make_float3(x, y, z));
}

//--------------------------------------------------------------------------------------
// Settings and seed
//--------------------------------------------------------------------------------------
void SceneState::ApplyDefaultSettings() {
    memset(&cb, 0, sizeof(cb));
    cb.kGeomSamplesPerFrame = 4;
    cb.kGeomPercentNeighborDepthRand = 0.02f;
    cb.kNormSampleRadiusMult = 1.0f;   // 1 = sample over entire pixel (sphere within)
    cb.kNormPixelsAlongEyeRayToPullBack = 0;
    cb.kAmboRaysPerPass = kAmboRaysPerPassDefault;
    cb.kAmboSamplesPerRay = kAmboSamplesPerRayDefault;   // Stay above 32, otherwise edges glow.
    cb.kAmboSamplePlacementAlongRayPow = 3;   // Higher = more samples nearby.
    cb.kAmboFalloffPower = 2.5f;              // 0.5 = very short rays; 3.0 = very long rays.
    cb.kAmboPixelsAlongEyeRayToPullBack = 0.1f;
    cb.kAmboPixelsAlongNormalToJumpFwd = 0.2f;
    cb.kAmboPixelsAlongAmboRayToJumpFwd = 0.0f;
    cb.kNoiseCubeSize = kNoiseCubeEdge;
    cb.kNoiseVoxelSize = 1.0f / (float)kNoiseCubeEdge;
    cb.g_viz_mode = 0;
    cb.max_dist = kMaxDist;
    for (int i = 0; i < MAX_VECTOR_COEFFS; i++) cb.g_dialog_coeffs[i] = simd_make_float4(1, 1, 1, 1);
}

void SceneState::ResetCamera() {
    camera = Frame();
    camera.pos = simd_make_float3(0, 0, -kLookAtDistance);
    camera.fov = kFOVDegrees * (3.1415926f / 180.0f);
}

void SceneState::OnSeed(uint32_t seed) {
    rng_.seed(seed);
    cb.g_scene_seed = seed;

    for (int i = 0; i < SEED_ROT_MAT_COUNT; ++i) {
        float3 vx = randDir();
        float3 vy = randDir();
        float3 vz = randDir();
        vx = simd_normalize(simd_cross(vy, vz));
        vy = simd_normalize(simd_cross(vx, vz));
        float tz = frand(), ty = frand(), tx = frand();
        cb.seed_rot_mat[i].columns[0] = make4(vx, 0);
        cb.seed_rot_mat[i].columns[1] = make4(vy, 0);
        cb.seed_rot_mat[i].columns[2] = make4(vz, 0);
        cb.seed_rot_mat[i].columns[3] = simd_make_float4(tx, ty, tz, 1);
    }
    for (int i = 0; i < SEED_DIR_COUNT; ++i) cb.seed_dir[i] = make4(randDir(), 0);
    for (int i = 0; i < SEED_UNORM_COUNT; ++i) cb.seed_unorm[i] = rand4();
    for (int i = 0; i < SEED_SNORM_COUNT; ++i) cb.seed_snorm[i] = rand4() * 2 - 1;
    for (int i = 0; i < SEED_UINT_COUNT; ++i) {
        uint32_t w = nrand(), z = nrand(), y = nrand(), x = nrand();
        cb.seed_uint[i] = simd_make_uint4(x, y, z, w);
    }

    // Noise textures.  The Windows version made 8 pairs of noise cubes (a
    // plain one and a "packed" one) plus a 1D noise texture; the shaders only
    // ever use the first four plain cubes.  The unused ones are still drawn
    // from the generator, and thrown away, so the numbers that follow match.
    const int cubeValues = kNoiseCubeEdge * kNoiseCubeEdge * kNoiseCubeEdge * 4;
    for (int i = 0; i < 8; i++) {
        if (i < 4) {
            noise.cube[i].resize(cubeValues);
            for (int k = 0; k < cubeValues; k++) noise.cube[i][k] = (uint8_t)(nrand() & 0xFF);
        } else {
            for (int k = 0; k < cubeValues; k++) nrand();
        }
        for (int k = 0; k < cubeValues; k++) nrand();   // the "packed" cube
    }
    for (int k = 0; k < 1024 * 4; k++) nrand();         // the 1D noise texture
    noise.noise2d.resize(NOISE_2D_SIZE * NOISE_2D_SIZE * 4);
    for (auto &v : noise.noise2d) v = (uint16_t)(nrand() & 0xFFFF);
}

//--------------------------------------------------------------------------------------
// Lights
//--------------------------------------------------------------------------------------
static bool IsALight(int i) { return i >= 0 && i < MAX_LIGHTS; }

void SceneState::SetLightDir(int i, float3 dir) {
    if (!IsALight(i)) return;
    cb.g_light_dir[i] = make4(dir, 0);
}

void SceneState::RandomizeLightColor(int i) {
    if (!IsALight(i)) return;
    float b = frand(), g = frand(), r = frand();
    cb.g_light_col[i] = simd_make_float4(r, g, b, 0);
}

void SceneState::RandomizeLightDir(int i) {
    if (!IsALight(i)) return;
    Frame &L = lights[i];
    L.z = randDir();
    float lerp_to_look_dir = frand() * 0.5f + frand() * 0.3f;
    L.z = simd_normalize(lerp3(L.z, camera.z, lerp_to_look_dir));
    L.y = simd_make_float3(0, 1, 0);
    L.x = simd_normalize(simd_cross(L.y, L.z));
    L.y = simd_normalize(simd_cross(L.z, L.x));
    cb.g_light_dir[i] = make4(L.z, 0);
}

void SceneState::RandomizeLight(int i, float str) {
    if (!IsALight(i)) return;
    RandomizeLightDir(i);
    RandomizeLightColor(i);
    cb.g_light_wrap[i] = simd_make_float4(frand() * frand(), 0, 0, 0);
    cb.g_light_spec_scale[i] = simd_make_float4(frand() + frand(), 0, 0, 0);
    cb.g_light_spec_enabled[i] = simd_make_uint4(1, 0, 0, 0);
    cb.g_light_unorm[i] = rand4();
    float3 col = xyz(cb.g_light_col[i]);
    float lum = (col.x + col.y + col.z) * 0.33333f;
    float desat = frand() * frand();
    cb.g_light_col[i] = make4(lerp3(col, simd_make_float3(lum, lum, lum), desat), 1) * str;
}

void SceneState::RandomizeAmboParams() {
    cb.kLightAmboDiffuseUnLitThresh = frand() * frand() * 0.25f;
    cb.kLightAmboDiffuseFullyLitThresh = 0.45f + frand() * 0.05f + frand() * 0.05f;
    cb.kLightAmboDiffuseExponent = powf(2.0f, frand() + frand() - 1);
    cb.kLightAmboSpecLo = 0.20f;
    cb.kLightAmboSpecHi = 0.45f;
    cb.kLightAmboDirScale = 3 + 2 * frand();
    cb.kLightAmboDirBias = 0 + 0.2f * frand();
    cb.kLightUseDirectionalAmbo = 1;
}

void SceneState::RandomizeSpecParams() {
    cb.kLightSpecStr = saturate(frand() * frand() * 1.3f - 0.3f) * 1.0f;
    cb.kLightSpecPow = frand() * frand() * 8;   // Actual exponent is 2^this.
}

void SceneState::RandomizeFogColor() {
    float b = frand(), g = frand(), r = frand();
    cb.g_fog_color = simd_make_float4(r, g, b, 0);
}

void SceneState::RandomizeFog() {
    RandomizeFogColor();
    cb.g_fog_params.x = frand() * frand() * frand();
    if (frand() < 0.5f) cb.g_fog_params.x = 0;
    cb.g_fog_params.y = powf(2.0f, frand() * 4 - 2);
    cb.g_fog_params.z = 0;
    cb.g_fog_params.w = 0;
}

void SceneState::RandomizeCommonLightParams() {
    cb.g_light_unorm_all = rand4();
    RandomizeAmboParams();
    RandomizeSpecParams();
    RandomizeFog();
    cb.kLightScale = 1;
    cb.kLightSat = (frand() < 0.01f) ? 0 : 1.0f;
    cb.kReflectivity = saturate(frand() * 2 - 1);
    cb.kSurfaceColorAmount = saturate(frand() * 2 - 1);
    cb.kFinalGamma = 2.2f;
}

void SceneState::RandomizeLights() {
    int num_primary_lights = 3 + (nrand() % 3);
    float str_per_light = 3.0f / (float)num_primary_lights;
    for (int i = 0; i < MAX_LIGHTS; i++) {
        float str = (i < num_primary_lights) ? str_per_light : 0;
        RandomizeLight(i, str);
    }
    RandomizeCommonLightParams();
}

void SceneState::RebuildLightFrames() {
    for (int i = 0; i < MAX_LIGHTS; i++) {
        Frame &L = lights[i];
        L.z = xyz(cb.g_light_dir[i]);
        L.y = simd_make_float3(0, 1, 0);
        L.x = simd_normalize(simd_cross(L.y, L.z));
        L.y = simd_normalize(simd_cross(L.z, L.x));
    }
}

//--------------------------------------------------------------------------------------
// Camera
//--------------------------------------------------------------------------------------
void SceneState::UpdateCameraUniforms(int width, int height) {
    camera.aspect = width / (float)height;

    // The field of view applies to the longer side of the image.
    float dx, dy;
    if (height > width) {
        dy = tanf(camera.fov * 0.5f);
        dx = dy * camera.aspect;
    } else {
        dx = tanf(camera.fov * 0.5f);
        dy = dx / camera.aspect;
    }

    // Corners of a virtual screen one unit in front of the eye, in camera space.
    float3 UL = simd_make_float3(-dx, dy, 1);
    float3 UR = simd_make_float3(dx, dy, 1);
    float3 LL = simd_make_float3(-dx, -dy, 1);

    cb.ws_eye_pos = make4(camera.pos, 0);
    cb.ws_look_dir = make4(camera.z, 0);
    cb.ws_screen_corner_UL = make4(UL, 0);
    cb.ws_screen_across = make4(UR - UL, 0);
    cb.ws_screen_down = make4(LL - UL, 0);
    cb.ws_camera_x_axis = make4(camera.x, 0);
    cb.ws_camera_y_axis = make4(camera.y, 0);
    cb.ws_camera_z_axis = make4(camera.z, 0);
    cb.g_image_size = simd_make_float4((float)width, (float)height, 1.0f / width, 1.0f / height);
    cb.g_ws_pixel_size_at_depth_1 = (2 * dx) / (float)width;
    cb.max_dist = kMaxDist;
}

//--------------------------------------------------------------------------------------
// Scene files (.scn), compatible with the Windows version (format version 5)
//--------------------------------------------------------------------------------------
namespace {
struct Writer {
    FILE *f;
    void u32(uint32_t v) { fwrite(&v, 4, 1, f); }
    void i32(int32_t v) { fwrite(&v, 4, 1, f); }
    void flt(float v) { fwrite(&v, 4, 1, f); }
    void v3(float3 v) { flt(v.x); flt(v.y); flt(v.z); }
    void v4(f4 v) { flt(v.x); flt(v.y); flt(v.z); flt(v.w); }
    void uv4(u4 v) { u32(v.x); u32(v.y); u32(v.z); u32(v.w); }
};
struct Reader {
    FILE *f;
    bool ok = true;
    uint32_t u32() { uint32_t v = 0; if (fread(&v, 4, 1, f) != 1) ok = false; return v; }
    int32_t i32() { return (int32_t)u32(); }
    float flt() { float v = 0; if (fread(&v, 4, 1, f) != 1) ok = false; return v; }
    float3 v3() { float x = flt(), y = flt(), z = flt(); return simd_make_float3(x, y, z); }
    f4 v4() { float x = flt(), y = flt(), z = flt(), w = flt(); return simd_make_float4(x, y, z, w); }
    u4 uv4() { uint32_t x = u32(), y = u32(), z = u32(), w = u32(); return simd_make_uint4(x, y, z, w); }
};
}

bool SceneState::Export(const std::string &path, std::string *error) const {
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) {
        if (error) *error = "Unable to open the file for writing.";
        return false;
    }
    Writer w{f};
    w.u32(5);   // version
    w.u32(cb.g_scene_seed);
    w.v3(camera.pos);
    w.v3(camera.x);
    w.v3(camera.y);
    w.v3(camera.z);
    w.flt(camera.fov);
    w.flt(camera.aspect);
    w.u32(MAX_LIGHTS);
    w.v4(cb.g_light_unorm_all);
    w.i32(cb.kLightUseDirectionalAmbo);
    w.flt(cb.kLightAmboDiffuseUnLitThresh);
    w.flt(cb.kLightAmboDiffuseFullyLitThresh);
    w.flt(cb.kLightAmboDiffuseExponent);
    w.flt(cb.kLightAmboSpecLo);
    w.flt(cb.kLightAmboSpecHi);
    w.flt(cb.kLightAmboDirScale);
    w.flt(cb.kLightAmboDirBias);
    w.flt(cb.kLightSpecStr);
    w.flt(cb.kLightSpecPow);
    w.flt(cb.kLightScale);
    w.flt(cb.kLightSat);
    for (int i = 0; i < MAX_LIGHTS; i++) {
        w.v4(cb.g_light_dir[i]);
        w.v4(cb.g_light_col[i]);
        w.v4(cb.g_light_wrap[i]);
        w.v4(cb.g_light_unorm[i]);
        w.v4(cb.g_light_spec_scale[i]);
        w.uv4(cb.g_light_spec_enabled[i]);
    }
    w.v4(cb.g_fog_color);
    w.v4(cb.g_fog_params);
    w.flt(cb.kReflectivity);
    w.flt(cb.kSurfaceColorAmount);
    for (int i = 0; i < MAX_VECTOR_COEFFS; i++) w.v4(cb.g_dialog_coeffs[i]);
    w.flt(cb.kFinalGamma);
    bool ok = !ferror(f);
    fclose(f);
    if (!ok && error) *error = "Error while writing the file.";
    return ok;
}

bool SceneState::Import(const std::string &path, bool lightsOnly, std::string *error) {
    FILE *f = fopen(path.c_str(), "rb");
    if (!f) {
        if (error) *error = "Unable to open the file.";
        return false;
    }
    Reader r{f};
    uint32_t version = r.u32();
    uint32_t seed = r.u32();
    if (!r.ok || version < 1 || version > 5) {
        fclose(f);
        if (error) *error = r.ok ? "Unknown scene file version." : "The file is empty or too short to be a scene.";
        return false;
    }

    // Read into copies first, so a damaged file leaves the current scene alone.
    Uniforms c = cb;
    Frame cam;
    cam.pos = r.v3();
    cam.x = r.v3();
    cam.y = r.v3();
    cam.z = r.v3();
    cam.fov = r.flt();
    cam.aspect = r.flt();
    uint32_t num_lights = r.u32();
    c.g_light_unorm_all = r.v4();
    c.kLightUseDirectionalAmbo = r.i32();
    c.kLightAmboDiffuseUnLitThresh = r.flt();
    c.kLightAmboDiffuseFullyLitThresh = r.flt();
    c.kLightAmboDiffuseExponent = r.flt();
    c.kLightAmboSpecLo = r.flt();
    c.kLightAmboSpecHi = r.flt();
    c.kLightAmboDirScale = r.flt();
    c.kLightAmboDirBias = r.flt();
    c.kLightSpecStr = r.flt();
    c.kLightSpecPow = r.flt();
    c.kLightScale = r.flt();
    c.kLightSat = r.flt();
    if (!r.ok || num_lights > 64) {
        fclose(f);
        if (error) *error = "The scene file is damaged.";
        return false;
    }
    for (uint32_t i = 0; i < num_lights; i++) {
        f4 dir = r.v4(), col = r.v4(), wrap = r.v4(), unorm = r.v4(), spec = r.v4();
        u4 enabled = r.uv4();
        if (i >= MAX_LIGHTS) continue;
        if (lightsOnly) {
            // Keep each light in the same place relative to the camera.
            float3 d = xyz(dir);
            float3 es = simd_make_float3(simd_dot(cam.x, d), simd_dot(cam.y, d), simd_dot(cam.z, d));
            dir = make4(camera.x * es.x + camera.y * es.y + camera.z * es.z, 0);
        }
        c.g_light_dir[i] = dir;
        c.g_light_col[i] = col;
        c.g_light_wrap[i] = wrap;
        c.g_light_unorm[i] = unorm;
        c.g_light_spec_scale[i] = spec;
        c.g_light_spec_enabled[i] = enabled;
    }
    if (version >= 2) {
        c.g_fog_color = r.v4();
        c.g_fog_params = r.v4();
    } else {
        c.g_fog_color = simd_make_float4(0, 0, 0, 0);
        c.g_fog_params = simd_make_float4(0, 1, 0, 0);
    }
    if (version >= 3) {
        c.kReflectivity = r.flt();
        c.kSurfaceColorAmount = r.flt();
    } else {
        c.kReflectivity = 0;
        c.kSurfaceColorAmount = 0;
    }
    for (int i = 0; i < MAX_VECTOR_COEFFS; i++)
        c.g_dialog_coeffs[i] = (version >= 4) ? r.v4() : simd_make_float4(0, 0, 0, 0);
    c.kFinalGamma = (version >= 5) ? r.flt() : 1;
    bool ok = r.ok;
    fclose(f);
    if (!ok) {
        if (error) *error = "The scene file is damaged or incomplete.";
        return false;
    }

    cb = c;
    RebuildLightFrames();
    if (!lightsOnly) {
        OnSeed(seed);
        cam.aspect = camera.aspect;
        camera = cam;
    }
    return true;
}
