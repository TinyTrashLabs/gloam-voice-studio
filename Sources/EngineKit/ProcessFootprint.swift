import Foundation

/// Process physical-memory footprint — the figure Activity Monitor shows.
///
/// Lives in EngineKit rather than the app because model loads are measured
/// where they actually happen (inside `GloamEngine`), not at whichever call
/// site happened to ask for one. A load triggered by Generate, an API request
/// or a bake costs exactly as much as one started from the model picker.
public enum ProcessFootprint {
    public static func bytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    public static var gigabytes: Double { Double(bytes()) / 1_073_741_824 }
}
