import XCTest
import Foundation

/// TEMPORARY diagnostic for the device host kill (change:
/// add-brush-verification, task 1.1). The suite dies of SIGKILL part-way
/// through on device, and the victim MOVES between runs — the signature of
/// something accumulating rather than one bad test. This prints the host's
/// footprint and remaining headroom after every case so the climb is
/// visible in the log. Delete once the cause is fixed.
final class MemoryProbe: NSObject, XCTestObservation, @unchecked Sendable {
    nonisolated(unsafe) static let shared = MemoryProbe()
    nonisolated(unsafe) private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        XCTestObservationCenter.shared.addTestObserver(shared)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        print("MEMPROBE footprint=\(Self.footprintMB())MB "
              + "available=\(Self.availableMB())MB after \(testCase.name)")
    }

    /// Resident footprint the way jetsam counts it.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size)
            / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint) / (1024 * 1024)
    }

    /// How much this process may still allocate before jetsam kills it.
    static func availableMB() -> Int {
        Int(os_proc_available_memory()) / (1024 * 1024)
    }
}
