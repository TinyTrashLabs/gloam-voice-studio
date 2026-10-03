import Foundation

let sampleRate = 24000
let samplesPerFrame = 1920

/// Port of qonnx.trailing_silence_cut: frames to keep after simulating the streaming tracker.
func trailingSilenceCut(_ wav: [Float], frames total: Int, chunk: Int = 12, floorDb: Float = -35, stopS: Float = 1.5) -> Int {
    let win = sampleRate / 50
    var heard = false
    var trailing: Float = 0
    var done = 0
    while done + chunk <= total {
        let a = done * samplesPerFrame, b = (done + chunk) * samplesPerFrame
        let nw = (b - a) / win
        var lastLoud = -1
        for w in 0..<nw {
            var ss: Float = 0
            for i in 0..<win { let v = wav[a + w * win + i]; ss += v * v }
            let db = 20 * log10f(sqrtf(ss / Float(win)) + 1e-9)
            if db > floorDb { lastLoud = w }
        }
        if lastLoud >= 0 { heard = true; trailing = Float((nw - 1 - lastLoud) * win) / Float(sampleRate) }
        else { trailing += Float(nw * win) / Float(sampleRate) }
        done += chunk
        if heard && trailing >= stopS { return done }
    }
    return total
}
