// Master shader file.  The app loads this one file; it pulls in the others.
// To make new worlds you only need to add or edit a file in the "shapes" folder.

#include <metal_stdlib>
using namespace metal;

#include "shared_types.h"
#include "compat.metal"

// Everything the shader code can see: settings, random values, textures.
// The original Windows shaders used global variables for these; Metal has no
// global variables, so all the shader code lives inside this struct instead.
struct Scene {
    constant Uniforms&     u;
    constant TileUniforms& tu;

    texture3d<float> tex_noise3D_full_a;
    texture3d<float> tex_noise3D_full_b;
    texture3d<float> tex_noise3D_full_c;
    texture3d<float> tex_noise3D_full_d;
    texture2d<float> tex_noise_unorm_2d;   // per-pixel random values
    texture2d<float> tex_ray_dirs;         // ambient occlusion ray directions (one row)
    texture2d<float> tex_normal_ray_dirs;  // sample directions for normals (one row)
    texture2d<float> tex_main_depth;       // primary ray: distance to the surface
    texture2d<float> tex_main_norm;        // primary ray: surface normal
    texture2d<float> tex_main_ambo;        // primary ray: ambient occlusion
    texture2d<float> tex_refl_depth;       // reflection ray: distance to the surface
    texture2d<float> tex_refl_norm;        // reflection ray: surface normal
    texture2d<float> tex_refl_ambo;        // reflection ray: ambient occlusion
    texture2d<float> tex_prev_depth;       // depth from the previous geometry pass

    sampler sam_linear_wrap;
    sampler sam_nearest_wrap;
    sampler sam_nearest_clamp;

#include "helper.metal"
#include "noise.metal"
#include "eval_common.metal"
#include "@shape"   // replaced by the app with the chosen file from the shapes folder
#include "geom.metal"
#include "norm.metal"
#include "ambo.metal"
#include "relight.metal"
};

//--------------------------------------------------------------------------------------
// Entry points
//--------------------------------------------------------------------------------------

struct VSOut {
    float4 pos [[position]];
};

// One big triangle that covers the whole image.  The app limits drawing to
// one tile at a time with a scissor rectangle.
vertex VSOut vs_fullscreen(uint vid [[vertex_id]]) {
    VSOut o;
    float2 p = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

#define SCENE_PARAMS \
    constant Uniforms&     u  [[buffer(0)]], \
    constant TileUniforms& tu [[buffer(1)]], \
    texture3d<float> t_noise_a     [[texture(0)]], \
    texture3d<float> t_noise_b     [[texture(1)]], \
    texture3d<float> t_noise_c     [[texture(2)]], \
    texture3d<float> t_noise_d     [[texture(3)]], \
    texture2d<float> t_noise_2d    [[texture(4)]], \
    texture2d<float> t_ray_dirs    [[texture(5)]], \
    texture2d<float> t_normal_dirs [[texture(6)]], \
    texture2d<float> t_main_depth  [[texture(7)]], \
    texture2d<float> t_main_norm   [[texture(8)]], \
    texture2d<float> t_main_ambo   [[texture(9)]], \
    texture2d<float> t_refl_depth  [[texture(10)]], \
    texture2d<float> t_refl_norm   [[texture(11)]], \
    texture2d<float> t_refl_ambo   [[texture(12)]], \
    texture2d<float> t_prev_depth  [[texture(13)]], \
    sampler s_linear_wrap   [[sampler(0)]], \
    sampler s_nearest_wrap  [[sampler(1)]], \
    sampler s_nearest_clamp [[sampler(2)]]

#define MAKE_SCENE \
    Scene scene { u, tu, t_noise_a, t_noise_b, t_noise_c, t_noise_d, t_noise_2d, t_ray_dirs, \
                  t_normal_dirs, t_main_depth, t_main_norm, t_main_ambo, t_refl_depth, \
                  t_refl_norm, t_refl_ambo, t_prev_depth, s_linear_wrap, s_nearest_wrap, \
                  s_nearest_clamp }; \
    float2 uv = in.pos.xy * g_image_size.zw   /* (0,0) = upper-left corner of the image */

fragment float4 fs_geom(VSOut in [[stage_in]], SCENE_PARAMS) {
    MAKE_SCENE;
    return float4(scene.GeomPS(uv), 0, 0, 0);
}

fragment float4 fs_norm(VSOut in [[stage_in]], SCENE_PARAMS) {
    MAKE_SCENE;
    return scene.NormPS(uv);
}

fragment float4 fs_ambo(VSOut in [[stage_in]], SCENE_PARAMS) {
    MAKE_SCENE;
    return scene.AmboPS(uv);
}

fragment float4 fs_relight(VSOut in [[stage_in]], SCENE_PARAMS) {
    MAKE_SCENE;
    return scene.RelightPS(uv);
}

// Copies the finished picture to the window, scaling it to fit.
fragment float4 fs_display(VSOut in [[stage_in]],
                           texture2d<float> image [[texture(0)]],
                           sampler s [[sampler(0)]],
                           constant float4& view_size [[buffer(0)]]) {
    return image.sample(s, in.pos.xy * view_size.zw);
}

// The same, for a window showing extended brightness.  The stored picture is
// encoded for an ordinary display; this converts it to linear light, which is
// what an extended-range window expects, and limits it to what the display
// can show right now (hdr.x, where 1 is ordinary white).
fragment float4 fs_display_hdr(VSOut in [[stage_in]],
                               texture2d<float> image [[texture(0)]],
                               sampler s [[sampler(0)]],
                               constant float4& view_size [[buffer(0)]],
                               constant float4& hdr [[buffer(1)]]) {
    float3 v = max(image.sample(s, in.pos.xy * view_size.zw).rgb, float3(0));
    float3 linear_light = pow(v, float3(2.2));
    return float4(min(linear_light, float3(hdr.x)), 1);
}
