// Lets shader code written in the style of the original Windows version
// (HLSL) compile as Metal with few changes.

// HLSL names for built-in functions.
#define frac fract
#define lerp mix
#define cosf cos
#define sinf sin
#define tanf tan
#define powf pow
#define LOOP_HINT

// The original shaders read these as global variables. Metal has no global
// variables, so everything lives in the Scene struct (see gpucaster.metal),
// and these names reach into it. Do not write "u." or "tu." in shader code.
#define seed_rot_mat u.seed_rot_mat
#define seed_dir     u.seed_dir
#define seed_unorm   u.seed_unorm
#define seed_snorm   u.seed_snorm
#define seed_uint    u.seed_uint
#define time_unorm   tu.time_unorm
#define g_cur_frame  tu.g_cur_frame

#define g_light_dir          u.g_light_dir
#define g_light_col          u.g_light_col
#define g_light_wrap         u.g_light_wrap
#define g_light_unorm        u.g_light_unorm
#define g_light_spec_scale   u.g_light_spec_scale
#define g_light_spec_enabled u.g_light_spec_enabled
#define g_light_unorm_all    u.g_light_unorm_all
#define g_fog_color          u.g_fog_color
#define g_fog_params         u.g_fog_params

#define ws_eye_pos          u.ws_eye_pos.xyz
#define ws_look_dir         u.ws_look_dir.xyz
#define ws_screen_corner_UL u.ws_screen_corner_UL.xyz
#define ws_screen_across    u.ws_screen_across.xyz
#define ws_screen_down      u.ws_screen_down.xyz
#define ws_camera_x_axis    u.ws_camera_x_axis.xyz
#define ws_camera_y_axis    u.ws_camera_y_axis.xyz
#define ws_camera_z_axis    u.ws_camera_z_axis.xyz
#define g_image_size        u.g_image_size
#define g_tile_info         u.g_tile_info
#define g_main_ambo_tiles_done u.g_main_ambo_tiles_done
#define g_refl_ambo_tiles_done u.g_refl_ambo_tiles_done

#define g_dialog_coeffs u.g_dialog_coeffs
#define g_c0 g_dialog_coeffs[0]
#define g_c1 g_dialog_coeffs[1]
#define g_c2 g_dialog_coeffs[2]
#define g_c3 g_dialog_coeffs[3]
#define g_c4 g_dialog_coeffs[4]
#define g_c5 g_dialog_coeffs[5]
#define g_c6 g_dialog_coeffs[6]
#define g_c7 g_dialog_coeffs[7]
#define g_c8 g_dialog_coeffs[8]
#define g_c9 g_dialog_coeffs[9]

#define g_ws_pixel_size_at_depth_1     u.g_ws_pixel_size_at_depth_1
#define max_dist                       u.max_dist
#define g_scene_seed                   u.g_scene_seed
#define g_cur_ambo_pass                u.g_cur_ambo_pass
#define g_main_ambo_pass               u.g_main_ambo_pass
#define g_refl_ambo_pass               u.g_refl_ambo_pass
#define g_intersection_set             u.g_intersection_set
#define g_geom_frames_since_geom_clear u.g_geom_frames_since_geom_clear
#define g_viz_mode                     u.g_viz_mode

#define kGeomSamplesPerFrame             u.kGeomSamplesPerFrame
#define kGeomPercentNeighborDepthRand    u.kGeomPercentNeighborDepthRand
#define kNormSampleRadiusMult            u.kNormSampleRadiusMult
#define kNormPixelsAlongEyeRayToPullBack u.kNormPixelsAlongEyeRayToPullBack
#define kAmboRaysPerPass                 u.kAmboRaysPerPass
#define kAmboSamplesPerRay               u.kAmboSamplesPerRay
#define kAmboSamplePlacementAlongRayPow  u.kAmboSamplePlacementAlongRayPow
#define kAmboFalloffPower                u.kAmboFalloffPower
#define kAmboPixelsAlongEyeRayToPullBack u.kAmboPixelsAlongEyeRayToPullBack
#define kAmboPixelsAlongNormalToJumpFwd  u.kAmboPixelsAlongNormalToJumpFwd
#define kAmboPixelsAlongAmboRayToJumpFwd u.kAmboPixelsAlongAmboRayToJumpFwd
#define kNoiseCubeSize                   u.kNoiseCubeSize
#define kNoiseVoxelSize                  u.kNoiseVoxelSize
#define kLightUseDirectionalAmbo         u.kLightUseDirectionalAmbo
#define kLightAmboDiffuseUnLitThresh     u.kLightAmboDiffuseUnLitThresh
#define kLightAmboDiffuseFullyLitThresh  u.kLightAmboDiffuseFullyLitThresh
#define kLightAmboDiffuseExponent        u.kLightAmboDiffuseExponent
#define kLightAmboSpecLo                 u.kLightAmboSpecLo
#define kLightAmboSpecHi                 u.kLightAmboSpecHi
#define kLightAmboDirScale               u.kLightAmboDirScale
#define kLightAmboDirBias                u.kLightAmboDirBias
#define kLightSpecStr                    u.kLightSpecStr
#define kLightSpecPow                    u.kLightSpecPow
#define kLightScale                      u.kLightScale
#define kLightSat                        u.kLightSat
#define kReflectivity                    u.kReflectivity
#define kSurfaceColorAmount              u.kSurfaceColorAmount
#define kFinalGamma                      u.kFinalGamma

// The center points of the 12 pentagon-shaped faces of a dodecahedron
// (also the vertices of an icosahedron), unit length.
constant float3 dodec[12] = {
    float3( 0.0,           0.5257311121,  0.8506508084),
    float3( 0.0,          -0.5257311121,  0.8506508084),
    float3( 0.0,           0.5257311121, -0.8506508084),
    float3( 0.0,          -0.5257311121, -0.8506508084),
    float3( 0.5257311121,  0.8506508084,  0.0),
    float3(-0.5257311121,  0.8506508084,  0.0),
    float3( 0.5257311121, -0.8506508084,  0.0),
    float3(-0.5257311121, -0.8506508084,  0.0),
    float3( 0.8506508084,  0.0,           0.5257311121),
    float3( 0.8506508084,  0.0,          -0.5257311121),
    float3(-0.8506508084,  0.0,           0.5257311121),
    float3(-0.8506508084,  0.0,          -0.5257311121),
};

// The center points of the 20 triangle-shaped faces of an icosahedron, unit length.
constant float3 icosa[20] = {
    float3( 0.5773502692,  0.5773502692,  0.5773502692),
    float3( 0.5773502692,  0.5773502692, -0.5773502692),
    float3( 0.5773502692, -0.5773502692,  0.5773502692),
    float3( 0.5773502692, -0.5773502692, -0.5773502692),
    float3(-0.5773502692,  0.5773502692,  0.5773502692),
    float3(-0.5773502692,  0.5773502692, -0.5773502692),
    float3(-0.5773502692, -0.5773502692,  0.5773502692),
    float3(-0.5773502692, -0.5773502692, -0.5773502692),
    float3( 0.0,           0.9341723590,  0.3568220898),
    float3( 0.0,          -0.9341723590,  0.3568220898),
    float3( 0.0,           0.9341723590, -0.3568220898),
    float3( 0.0,          -0.9341723590, -0.3568220898),
    float3( 0.9341723590,  0.3568220898,  0.0),
    float3(-0.9341723590,  0.3568220898,  0.0),
    float3( 0.9341723590, -0.3568220898,  0.0),
    float3(-0.9341723590, -0.3568220898,  0.0),
    float3( 0.3568220898,  0.0,           0.9341723590),
    float3( 0.3568220898,  0.0,          -0.9341723590),
    float3(-0.3568220898,  0.0,           0.9341723590),
    float3(-0.3568220898,  0.0,          -0.9341723590),
};

// Reflection rays start slightly back along the incoming ray.
constant float kReflectionPullbackAlongIncomingRay = 1.05;
