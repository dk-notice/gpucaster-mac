// SceneState: everything that describes a scene apart from the pictures
// themselves - random seed, camera, lights and settings.  Plain C++ (no Metal).
//
// The random-number use deliberately follows the original Windows program
// step for step, so that a given seed produces the same scene.

#pragma once

#include <random>
#include <string>
#include <vector>

#include "../shaders/shared_types.h"

typedef simd_float3 float3;

// A position and three axes.  Used for the camera, and for each light
// (where only the z axis, the direction the light travels, matters).
struct Frame {
    float3 pos = {0, 0, 0};
    float3 x = {1, 0, 0};   // right
    float3 y = {0, 1, 0};   // up
    float3 z = {0, 0, 1};   // camera looks down this axis
    float  fov = 0;         // radians, of the longer axis of the window
    float  aspect = 1;      // width / height

    void RotateOnX(float radians);    // about its own axes
    void RotateOnY(float radians);
    void RotateOnZ(float radians);
    void RotateOnWSX(float radians);  // about the world's axes
    void RotateOnWSY(float radians);
};

// Random texture contents generated from the seed.
struct NoiseData {
    std::vector<uint8_t>  cube[4];    // 16x16x16, 4 signed bytes per texel
    std::vector<uint16_t> noise2d;    // 128x128, 4 unsigned 16-bit values per texel
};

constexpr int   kNoiseCubeEdge = 16;
constexpr float kFOVDegrees = 50.0f;
constexpr float kMaxDist = 30.0f;
constexpr float kLookAtDistance = 1.0f;
constexpr int   kAmboRaysPerPassDefault = 16;
constexpr int   kAmboSamplesPerRayDefault = 64;
constexpr int   kMaxAmboPasses = AMBO_RAY_DIRS / kAmboRaysPerPassDefault;
constexpr uint32_t kDefaultSeed = 0x713BF2CE;

class SceneState {
public:
    Uniforms  cb;                  // sent to the shaders every frame
    Frame     camera;
    Frame     lights[MAX_LIGHTS];
    NoiseData noise;

    SceneState();

    float    frand();              // [0..1]
    uint32_t nrand();              // 32 random bits

    void ApplyDefaultSettings();
    void ResetCamera();
    void OnSeed(uint32_t seed);    // regenerates seed values and noise
    uint32_t NewRandomSeed() { return nrand(); }

    void SetLightDir(int i, float3 dir);
    void RandomizeLightColor(int i);
    void RandomizeLightDir(int i);
    void RandomizeLight(int i, float strength);
    void RandomizeLights();
    void RandomizeAmboParams();
    void RandomizeSpecParams();
    void RandomizeFogColor();
    void RandomizeFog();

    // Fills in the camera-dependent values in 'cb' for an image of this size.
    void UpdateCameraUniforms(int width, int height);

    // Scene files, in the same binary format as the Windows version (.scn).
    bool Export(const std::string &path, std::string *error) const;
    bool Import(const std::string &path, bool lightsOnly, std::string *error);

private:
    std::mt19937 rng_;
    f4     rand4();                // four values in [0..1]
    float3 randDir();              // random unit vector
    void   RandomizeCommonLightParams();
    void   RebuildLightFrames();
};
