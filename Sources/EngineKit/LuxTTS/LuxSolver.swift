// LuxTTS flow-matching sampling solvers, ported from the torch reference
// zipvoice/models/modules/solver.py (DiffusionModel, DistillDiffusionModel,
// EulerSolver, DistillEulerSolver, get_time_steps).

import Foundation
import MLX

/// Velocity-field provider for the solvers; implemented by the ZipVoice
/// model's `forward_fm_decoder`.
public protocol LuxFlowMatchingModel: AnyObject {
    func forwardFMDecoder(
        t: MLXArray,
        xt: MLXArray,
        textCondition: MLXArray,
        speechCondition: MLXArray,
        paddingMask: MLXArray?,
        guidanceScale: MLXArray?
    ) -> MLXArray
}

/// solver.py `get_time_steps`: linear schedule on [tStart, tEnd] warped by
/// t_shift toward the low-SNR region. Computed on CPU as Float, matching the
/// float32 torch schedule.
public func luxTimeSteps(
    tStart: Float = 0.0,
    tEnd: Float = 1.0,
    numSteps: Int,
    tShift: Float = 1.0
) -> [Float] {
    precondition(numSteps >= 1)
    return (0 ... numSteps).map { i in
        let t = tStart + (tEnd - tStart) * Float(i) / Float(numSteps)
        return tShift * t / (1 + (tShift - 1) * t)
    }
}

/// solver.py `DiffusionModel`: classifier-free-guidance wrapper for the
/// non-distilled model. Duplicates the batch (unconditional + conditional)
/// when guidanceScale != 0; below t = 0.5 the speech condition is kept for
/// both halves and the scale is doubled instead.
public class LuxDiffusionModel {
    // unowned: the model owns its solver, which owns this wrapper.
    unowned let model: any LuxFlowMatchingModel

    public init(model: any LuxFlowMatchingModel) {
        self.model = model
    }

    public func callAsFunction(
        t: Float,
        x: MLXArray,
        textCondition: MLXArray,
        speechCondition: MLXArray,
        paddingMask: MLXArray?,
        guidanceScale: Float
    ) -> MLXArray {
        if guidanceScale == 0 {
            return model.forwardFMDecoder(
                t: MLXArray(t),
                xt: x,
                textCondition: textCondition,
                speechCondition: speechCondition,
                paddingMask: paddingMask,
                guidanceScale: nil
            )
        }

        var scale = guidanceScale
        let x2 = concatenated([x, x], axis: 0)
        let paddingMask2 = paddingMask.map { concatenated([$0, $0], axis: 0) }
        let textCondition2 = concatenated([zeros(like: textCondition), textCondition], axis: 0)

        let speechCondition2: MLXArray
        if t > 0.5 {
            speechCondition2 = concatenated(
                [zeros(like: speechCondition), speechCondition], axis: 0)
        } else {
            scale *= 2
            speechCondition2 = concatenated([speechCondition, speechCondition], axis: 0)
        }

        let output = model.forwardFMDecoder(
            t: MLXArray(t),
            xt: x2,
            textCondition: textCondition2,
            speechCondition: speechCondition2,
            paddingMask: paddingMask2,
            guidanceScale: nil
        )
        let halves = output.split(parts: 2, axis: 0)
        let dataUncond = halves[0]
        let dataCond = halves[1]
        return dataCond * (1 + scale) - dataUncond * scale
    }
}

/// solver.py `DistillDiffusionModel`: the distilled model consumes the
/// guidance scale as an embedding input instead of CFG batch duplication.
public final class LuxDistillDiffusionModel: LuxDiffusionModel {
    public override func callAsFunction(
        t: Float,
        x: MLXArray,
        textCondition: MLXArray,
        speechCondition: MLXArray,
        paddingMask: MLXArray?,
        guidanceScale: Float
    ) -> MLXArray {
        model.forwardFMDecoder(
            t: MLXArray(t),
            xt: x,
            textCondition: textCondition,
            speechCondition: speechCondition,
            paddingMask: paddingMask,
            guidanceScale: MLXArray(guidanceScale)
        )
    }
}

/// solver.py `EulerSolver`. The update is the "anchor-based" form
/// x <- (1 - t_next) * x0_pred + t_next * x1_pred, algebraically identical to
/// plain Euler x + (t_next - t_cur) * v; kept in the anchor form for
/// traceability with the reference.
public class EulerSolver {
    let model: LuxDiffusionModel

    public init(model: any LuxFlowMatchingModel) {
        self.model = LuxDiffusionModel(model: model)
    }

    init(wrapping model: LuxDiffusionModel) {
        self.model = model
    }

    public func sample(
        x: MLXArray,
        textCondition: MLXArray,
        speechCondition: MLXArray,
        paddingMask: MLXArray?,
        numSteps: Int = 10,
        guidanceScale: Float = 0.0,
        tStart: Float = 0.0,
        tEnd: Float = 1.0,
        tShift: Float = 1.0
    ) -> MLXArray {
        let timesteps = luxTimeSteps(
            tStart: tStart, tEnd: tEnd, numSteps: numSteps, tShift: tShift)

        var x = x
        for step in 0 ..< numSteps {
            let tCur = timesteps[step]
            let tNext = timesteps[step + 1]

            let v = model(
                t: tCur,
                x: x,
                textCondition: textCondition,
                speechCondition: speechCondition,
                paddingMask: paddingMask,
                guidanceScale: guidanceScale
            )
            if ProcessInfo.processInfo.environment["LUXTTS_DUMP_DEBUG"] != nil {
                eval(v)
                if step == 0 {
                    let flat = v.reshaped([-1]).asType(.float32).asArray(Float.self)
                    var data = Foundation.Data()
                    for f in flat { withUnsafeBytes(of: f) { data.append(contentsOf: $0) } }
                    try? data.write(to: URL(fileURLWithPath: "/tmp/lux_dbg_v0.f32"))
                }
                let vArr = v.asArray(Float.self)
                let mean = vArr.reduce(0, +) / Float(vArr.count)
                let variance = vArr.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(vArr.count)
                FileHandle.standardError.write(Data(
                    "DEBUG step=\(step) tCur=\(tCur) v.shape=\(v.shape) v.mean=\(mean) v.std=\(sqrt(variance)) v.absmax=\(vArr.map { abs($0) }.max() ?? 0)\n"
                        .utf8))
            }

            let x1Pred = x + v * (1.0 - tCur)
            let x0Pred = x - v * tCur

            if step < numSteps - 1 {
                x = x0Pred * (1.0 - tNext) + x1Pred * tNext
            } else {
                x = x1Pred
            }
            // MLX.eval (lazy-graph materialization, not code evaluation):
            // bounds the compute graph to one ODE step.
            eval(x)
        }
        return x
    }
}

/// solver.py `DistillEulerSolver`: EulerSolver over the distilled wrapper.
public final class DistillEulerSolver: EulerSolver {
    public override init(model: any LuxFlowMatchingModel) {
        super.init(wrapping: LuxDistillDiffusionModel(model: model))
    }
}
