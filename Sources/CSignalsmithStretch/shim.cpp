//  C++ side of the signalsmith-stretch shim. See include/ for the C surface.
//
//  signalsmith-stretch and signalsmith-linear are MIT-licensed; their headers
//  are vendored under vendor/ by scripts/fetch-signalsmith.sh.

#include "include/signalsmith_stretch_shim.h"
#include "vendor/signalsmith-stretch.h"

#include <vector>

namespace {
struct Wrapper {
    signalsmith::stretch::SignalsmithStretch<float> stretch;
    int channels = 1;
};
}

extern "C" {

GVFXStretchRef gvfx_stretch_create(int channels, float sampleRate) {
    if (channels < 1 || sampleRate <= 0) return nullptr;
    auto *w = new (std::nothrow) Wrapper();
    if (!w) return nullptr;
    w->channels = channels;
    w->stretch.presetDefault(channels, sampleRate);
    return reinterpret_cast<GVFXStretchRef>(w);
}

void gvfx_stretch_destroy(GVFXStretchRef ref) {
    delete reinterpret_cast<Wrapper *>(ref);
}

void gvfx_stretch_set_transpose_semitones(GVFXStretchRef ref, float semitones) {
    if (!ref) return;
    reinterpret_cast<Wrapper *>(ref)->stretch.setTransposeSemitones(semitones);
}

void gvfx_stretch_set_formant_semitones(GVFXStretchRef ref, float semitones) {
    if (!ref) return;
    reinterpret_cast<Wrapper *>(ref)->stretch.setFormantSemitones(semitones);
}

void gvfx_stretch_set_formant_base(GVFXStretchRef ref, float baseFreqHz) {
    if (!ref) return;
    reinterpret_cast<Wrapper *>(ref)->stretch.setFormantBase(baseFreqHz);
}

int gvfx_stretch_input_latency(GVFXStretchRef ref) {
    return ref ? reinterpret_cast<Wrapper *>(ref)->stretch.inputLatency() : 0;
}

int gvfx_stretch_output_latency(GVFXStretchRef ref) {
    return ref ? reinterpret_cast<Wrapper *>(ref)->stretch.outputLatency() : 0;
}

void gvfx_stretch_process(GVFXStretchRef ref,
                          const float *input, int inCount,
                          float *output, int outCount) {
    if (!ref || !input || !output) return;
    auto *w = reinterpret_cast<Wrapper *>(ref);
    const float *inPtrs[1] = { input };
    float *outPtrs[1] = { output };
    w->stretch.process(inPtrs, inCount, outPtrs, outCount);
}

void gvfx_stretch_reset(GVFXStretchRef ref) {
    if (!ref) return;
    reinterpret_cast<Wrapper *>(ref)->stretch.reset();
}

}
