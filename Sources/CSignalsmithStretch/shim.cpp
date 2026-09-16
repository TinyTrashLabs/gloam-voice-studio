//  C++ side of the signalsmith-stretch shim. See include/ for the C surface.
//
//  signalsmith-stretch and signalsmith-linear are MIT-licensed; their headers
//  are vendored under vendor/ by scripts/fetch-signalsmith.sh.

#include "include/signalsmith_stretch_shim.h"
#include "vendor/signalsmith-stretch.h"

#include <new>
#include <vector>

namespace {
struct Wrapper {
    signalsmith::stretch::SignalsmithStretch<float> stretch;
};
}

extern "C" {

GVFXStretchRef gvfx_stretch_create(int channels, float sampleRate) {
    // Only mono is supported: process() below hands the library a single-
    // element pointer array, and VoiceFXKit's FXStage protocol is mono end
    // to end, so anything else would be unused (and unsafe) surface area.
    if (channels != 1 || sampleRate <= 0) return nullptr;
    auto *w = new (std::nothrow) Wrapper();
    if (!w) return nullptr;
    try {
        w->stretch.presetDefault(channels, sampleRate);
    } catch (...) {
        delete w;
        return nullptr;
    }
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
    try {
        w->stretch.process(inPtrs, inCount, outPtrs, outCount);
    } catch (...) {
        // Nothing may propagate across the extern "C" boundary. Best we can
        // do is leave `output` as-is (already caller-owned, possibly
        // partially written) and swallow the exception.
    }
}

void gvfx_stretch_reset(GVFXStretchRef ref) {
    if (!ref) return;
    try {
        reinterpret_cast<Wrapper *>(ref)->stretch.reset();
    } catch (...) {
        // See gvfx_stretch_process: exceptions must not cross extern "C".
    }
}

}
