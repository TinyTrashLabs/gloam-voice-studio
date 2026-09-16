//  C API over signalsmith-stretch (MIT, Geraint Luff / Signalsmith Audio).
//
//  Swift sees only this header. The C++ lives in shim.cpp, matching the
//  CSherpaOnnx / COnnxRuntime shim-target pattern used elsewhere in this
//  package.

#ifndef GVFX_SIGNALSMITH_STRETCH_SHIM_H
#define GVFX_SIGNALSMITH_STRETCH_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GVFXStretchOpaque *GVFXStretchRef;

/// Allocates a shifter configured for `channels` at `sampleRate`.
/// Only `channels == 1` (mono) is supported; any other value returns NULL,
/// as does a non-positive `sampleRate` or an allocation/configuration
/// failure. Caller owns the result; free with destroy.
GVFXStretchRef gvfx_stretch_create(int channels, float sampleRate);
void gvfx_stretch_destroy(GVFXStretchRef ref);

/// Pitch shift, in semitones. Negative is down.
void gvfx_stretch_set_transpose_semitones(GVFXStretchRef ref, float semitones);

/// Formant shift, in semitones — INDEPENDENT of pitch. This is the parameter
/// that makes a voice read as monstrous rather than merely slowed down.
void gvfx_stretch_set_formant_semitones(GVFXStretchRef ref, float semitones);

/// Rough fundamental-frequency hint for formant analysis, normalised by
/// sample rate (f0 / sampleRate) — NOT Hz. Pass 0 to let the library detect
/// the pitch itself.
void gvfx_stretch_set_formant_base(GVFXStretchRef ref, float baseFreqHz);

int gvfx_stretch_input_latency(GVFXStretchRef ref);
int gvfx_stretch_output_latency(GVFXStretchRef ref);

/// Mono process. `inCount` and `outCount` are equal for pure pitch shifting.
void gvfx_stretch_process(GVFXStretchRef ref,
                          const float *input, int inCount,
                          float *output, int outCount);

void gvfx_stretch_reset(GVFXStretchRef ref);

#ifdef __cplusplus
}
#endif

#endif /* GVFX_SIGNALSMITH_STRETCH_SHIM_H */
