import XCTest
import simd
import claycore
@testable import ClaySpace

/// A/B latency probe for the bake backend. TEMPORARY — this is a measurement,
/// not a verification, and it asserts nothing about time so it cannot fail a
/// suite for being run on a busy machine.
///
/// The experiment is the same app code against two frameworks: one built with
/// `CLAY_BACKEND_METAL=ON` and one without. `ClayEngine.evalBackend` discovers
/// which, so the run labels itself and the two logs are directly comparable.
@MainActor
final class PolishLatencyProbe: XCTestCase {

    func testPolishLatencyByBackend() async {
        let backend = ClayEngine.evalBackend
            .map { String(cString: $0) } ?? "cpu (no metal registered)"
        var names = [CChar](repeating: 0, count: 256)
        var size = names.count
        let listed = clay_list_backends(&names, &size) == CLAY_OK
            ? String(cString: names) : "?"
        print("BACKEND in use: \(backend)   |   registered: \(listed)")
        print("iter | items | polishMs | bakeMs | slab %grid | stepScale")

        let state = BrushMatrix.makeState(voxel: false)
        state.activeTool = .sculpt
        state.sculptBrush = .standard
        state.brushStrength = 1
        state.brushSize = 0.6

        for iteration in 1...8 {
            BrushMatrix.drive(state, along: BrushFixture.centerDrag)
            _ = await state.engine.quiesce()

            guard let ray = state.ray(through: BrushFixture.centerTap[0]),
                  let hit = state.engine.raycast(origin: ray.origin,
                                                 direction: ray.direction)
            else { return XCTFail("no surface at iteration \(iteration)") }

            let polishClock = ContinuousClock().now
            _ = state.engine.polishSurface(center: hit.position,
                                           normal: hit.normal,
                                           radius: 0.16, strength: 1,
                                           mode: CLAY_FLATTEN_CUT_ONLY)
            let polishMs = ContinuousClock().now - polishClock

            let bakeClock = ContinuousClock().now
            _ = await state.engine.quiesce()
            let bakeMs = ContinuousClock().now - bakeClock

            var slab = 100.0
            if let cache = state.engine.fieldCache {
                let total = Double(cache.dims.x) * Double(cache.dims.y) * Double(cache.dims.z)
                if let d = cache.dirtyCells {
                    slab = 100 * (Double(d.max.x - d.min.x + 1)
                                  * Double(d.max.y - d.min.y + 1)
                                  * Double(d.max.z - d.min.z + 1)) / total
                }
            }
            print(String(format: "%4d | %5d | %8.1f | %6.1f | %9.1f%% | %.4f",
                         iteration, state.engine.items.count,
                         Double(polishMs.components.attoseconds) / 1e15,
                         Double(bakeMs.components.attoseconds) / 1e15,
                         slab, state.engine.safeStepScale))
        }
    }
}
