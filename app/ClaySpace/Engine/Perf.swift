import os

/// Signpost intervals for the workloads the performance study tracks
/// (docs/06 §1): bake, voxel mesh rebuild, document save, export, mask
/// field. Profile with Instruments' os_signpost lane; the debug frame
/// HUD (MetalViewport, -showPerfHUD YES) covers frame cadence + GPU ms.
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.cyberdyne.clayspace",
                                         category: "perf")

    @discardableResult
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }
}
