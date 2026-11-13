// Data layout shared between the app (C++) and the shaders (Metal).
// Both sides include this file, so the two can never drift apart.
//
// Only 16-byte vector types and 4-byte scalars are used, and scalars come in
// groups of four, so the layout is identical on both sides.

#ifndef GPUCASTER_SHARED_TYPES_H
#define GPUCASTER_SHARED_TYPES_H

#ifdef __METAL_VERSION__
typedef float4   f4;
typedef uint4    u4;
typedef float4x4 m4;
typedef uint     u32;
typedef int      i32;
#else
#include <simd/simd.h>
#include <stdint.h>
typedef simd_float4   f4;
typedef simd_uint4    u4;
typedef simd_float4x4 m4;
typedef uint32_t      u32;
typedef int32_t       i32;
#endif

// Sets of random values, generated from the scene's random number seed.
#define SEED_ROT_MAT_COUNT 40   // random rotation matrices
#define SEED_DIR_COUNT     64   // random unit-length vectors
#define SEED_UNORM_COUNT   64   // [0..1]
#define SEED_SNORM_COUNT   64   // [-1..1]
#define SEED_UINT_COUNT    64   // [0..2^32-1]
#define TIME_UNORM_COUNT   64   // fresh random values for every tile drawn

#define NOISE_2D_SIZE      128
#define AMBO_RAY_DIRS      8192 // must not exceed the count in ambo_ray_dirs.txt
#define NORMAL_RAY_DIRS    512  // must match normal_dirs_512.txt

#define MAX_LIGHTS         8    // do not change: scene files depend on it
#define MAX_VECTOR_COEFFS  10   // do not change: scene files depend on it

// Everything that stays the same for a whole frame.
struct Uniforms {
    m4 seed_rot_mat[SEED_ROT_MAT_COUNT];
    f4 seed_dir[SEED_DIR_COUNT];
    f4 seed_unorm[SEED_UNORM_COUNT];
    f4 seed_snorm[SEED_SNORM_COUNT];
    u4 seed_uint[SEED_UINT_COUNT];

    // Lighting
    f4 g_light_dir[MAX_LIGHTS];          // unit vectors (xyz)
    f4 g_light_col[MAX_LIGHTS];          // [0..1] in xyz
    f4 g_light_wrap[MAX_LIGHTS];         // only .x used
    f4 g_light_unorm[MAX_LIGHTS];
    f4 g_light_spec_scale[MAX_LIGHTS];   // only .x used
    u4 g_light_spec_enabled[MAX_LIGHTS]; // only .x used
    f4 g_light_unorm_all;
    f4 g_fog_color;
    f4 g_fog_params;                     // .x = thickness, .y = exponent

    // Camera (xyz used)
    f4 ws_eye_pos;
    f4 ws_look_dir;
    f4 ws_screen_corner_UL;
    f4 ws_screen_across;
    f4 ws_screen_down;
    f4 ws_camera_x_axis;
    f4 ws_camera_y_axis;
    f4 ws_camera_z_axis;
    f4 g_image_size;                     // .xy = w, h; .zw = 1/w, 1/h
    f4 g_tile_info;                      // .xy = tile width, height in pixels; .zw = tiles across, down

    // Values the user can adjust without recompiling (g_c0 .. g_c9)
    f4 g_dialog_coeffs[MAX_VECTOR_COEFFS];

    float g_ws_pixel_size_at_depth_1;
    float max_dist;
    u32   g_scene_seed;
    u32   g_cur_ambo_pass;

    u32   g_main_ambo_pass;
    u32   g_refl_ambo_pass;
    u32   g_intersection_set;            // 0 = working on main rays, 1 = reflection rays
    u32   g_geom_frames_since_geom_clear;

    u32   g_viz_mode;
    i32   kGeomSamplesPerFrame;
    float kGeomPercentNeighborDepthRand;
    float kNormSampleRadiusMult;

    float kNormPixelsAlongEyeRayToPullBack;
    i32   kAmboRaysPerPass;
    i32   kAmboSamplesPerRay;
    float kAmboSamplePlacementAlongRayPow;

    float kAmboFalloffPower;
    float kAmboPixelsAlongEyeRayToPullBack;
    float kAmboPixelsAlongNormalToJumpFwd;
    float kAmboPixelsAlongAmboRayToJumpFwd;

    i32   kNoiseCubeSize;
    float kNoiseVoxelSize;
    i32   kLightUseDirectionalAmbo;
    float kLightAmboDiffuseUnLitThresh;

    float kLightAmboDiffuseFullyLitThresh;
    float kLightAmboDiffuseExponent;
    float kLightAmboSpecLo;
    float kLightAmboSpecHi;

    float kLightAmboDirScale;
    float kLightAmboDirBias;
    float kLightSpecStr;
    float kLightSpecPow;

    float kLightScale;
    float kLightSat;
    float kReflectivity;
    float kSurfaceColorAmount;

    float kFinalGamma;
    // How many tiles of the ambient occlusion pass in progress are done
    // (a huge number when no pass is part-way through).
    u32   g_main_ambo_tiles_done;
    u32   g_refl_ambo_tiles_done;
    // Experimental: after this many geometry passes, stop testing pixels where
    // nothing has been found (0 = never stop).
    u32   g_skip_empty_after;

    // Experimental: 1 = keep colours brighter than white instead of clipping
    // them, for displays that can show extended brightness.
    u32   g_hdr_output;
    u32   pad1, pad2, pad3;
};

// Everything that changes for each tile drawn.
struct TileUniforms {
    f4  time_unorm[TIME_UNORM_COUNT];    // [0..1]
    u32 g_cur_frame;
    u32 tpad0, tpad1, tpad2;
};

#endif
