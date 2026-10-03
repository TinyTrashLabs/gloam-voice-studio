import Foundation
import MLX
import MLXNN

/// Errors that can occur during weight loading.
public enum WeightLoadingError: Error, CustomStringConvertible {
    case weightsDirectoryNotFound(String)
    case weightsFileNotFound(String)
    case keyMismatch(String)
    case loadFailed(String)

    public var description: String {
        switch self {
        case .weightsDirectoryNotFound(let path):
            return "Weights directory not found: \(path)"
        case .weightsFileNotFound(let path):
            return "Weights file not found: \(path). Run the conversion script first."
        case .keyMismatch(let detail):
            return "Weight key mismatch: \(detail)"
        case .loadFailed(let detail):
            return "Failed to load weights: \(detail)"
        }
    }
}

/// Loads safetensors weight files into MLX Module parameter trees.
///
/// Follows the same pattern as emotion2VecMLX's WeightLoader:
/// `MLX.loadArrays` → `ModuleParameters.unflattened` → `Module.update(verify: .noUnusedKeys)`
struct WeightLoader {

    /// Expected weight file name for the vocals model.
    static let vocalsWeightsFile = "htdemucs_ft_vocals.safetensors"

    /// Load weights from a safetensors file into a Module.
    ///
    /// - Parameters:
    ///   - module: The MLX Module to load weights into.
    ///   - url: Path to the `.safetensors` file.
    /// - Throws: `WeightLoadingError` if the file is missing or keys don't match.
    static func loadWeights(into module: Module, from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WeightLoadingError.weightsFileNotFound(url.path)
        }

        do {
            let arrays = try MLX.loadArrays(url: url)
            let parameters = ModuleParameters.unflattened(arrays)
            try module.update(parameters: parameters, verify: .noUnusedKeys)
            MLX.eval(module.parameters())
        } catch let error as WeightLoadingError {
            throw error
        } catch {
            throw WeightLoadingError.loadFailed(error.localizedDescription)
        }
    }

    /// Validate that the weights directory contains the expected files.
    ///
    /// - Parameter directory: Path to the weights directory.
    /// - Throws: `WeightLoadingError` if required files are missing.
    static func validateWeightsDirectory(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw WeightLoadingError.weightsDirectoryNotFound(directory.path)
        }

        let filePath = directory.appendingPathComponent(vocalsWeightsFile).path
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw WeightLoadingError.weightsFileNotFound(filePath)
        }
    }
}
