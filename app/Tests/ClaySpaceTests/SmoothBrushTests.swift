import XCTest
@testable import ClaySpace

/// The Smooth (Relax) brush, against the claims in the spec:
/// "A bump is smoothed away", "Relax respects frozen clay", and
/// "Smoothing at a mask boundary" (the mask must be applied exactly once).
@MainActor
final class SmoothBrushTests: XCTestCase {

    /// Builds a Standard bump along the probe line — what a user would
    /// reach for Smooth after.
    private func seedBump(_ state: ViewportState) {
        state.activeTool = .sculpt
        state.sculptBrush = .standard
        state.brushStrength = 1
        for point in BrushFixture.centerDrag {
            state.pencilBegan(at: point, pressure: 0.9)
            state.pencilEnded(at: point)
        }
    }

    private func stroke(_ state: ViewportState) {
        BrushMatrix.drive(state, along: BrushFixture.centerDrag)
    }

    /// Distances at the probe line, nil-free, so the numbers can be reported.
    private func profile(_ state: ViewportState) -> [Float] {
        BrushMatrix.measure(state).surfaceDistances.compactMap { $0 }
    }

    func testABumpIsSmoothedAway() async {
        let state = BrushMatrix.makeState(voxel: false)
        seedBump(state)
        _ = await state.engine.quiesce()
        let before = profile(state)

        state.sculptBrush = .smooth
        state.brushStrength = 1
        stroke(state)
        let settled = await state.engine.quiesce()
        let after = profile(state)

        XCTAssertTrue(settled, "the bake never settled")
        XCTAssertFalse(before.isEmpty, "no surface under the probe line to smooth")
        XCTAssertEqual(before.count, after.count,
                       "the probe line lost surface: \(before) -> \(after)")

        // The peak is the probe NEAREST the camera; smoothing it away means
        // that nearest distance grows. Reported either way so a failure says
        // which direction it actually went.
        let peakBefore = before.min() ?? 0
        let peakAfter = after.min() ?? 0
        XCTAssertGreaterThan(peakAfter, peakBefore,
                             "the peak did not come down. "
                             + "before \(before) after \(after)")
    }

    func testRelaxRespectsFrozenClay() async {
        let state = BrushMatrix.makeState(voxel: false)
        seedBump(state)
        _ = await state.engine.quiesce()

        // Freeze the whole probe region, then try to smooth it.
        state.activeTool = .freeze
        for point in BrushFixture.centerDrag {
            state.pencilBegan(at: point, pressure: 1)
            state.pencilEnded(at: point)
        }
        _ = await state.engine.quiesce()
        let before = profile(state)

        state.activeTool = .sculpt
        state.sculptBrush = .smooth
        state.brushStrength = 1
        stroke(state)
        _ = await state.engine.quiesce()
        let after = profile(state)

        XCTAssertEqual(before.count, after.count)
        for (start, end) in zip(before, after) {
            XCTAssertEqual(start, end, accuracy: 0.002,
                           "frozen clay moved: \(before) -> \(after)")
        }
    }
}

extension SmoothBrushTests {

    /// Diagnostic: does the regional volume swap move the surface even when
    /// the verb it wraps does essentially nothing? `replaceRegion` samples
    /// the document, hands the volume to a verb, then hard-subtracts a box
    /// and hard-adds the volume back. If that round trip is not
    /// surface-preserving, every brush riding it inherits the error —
    /// hPolish, Flatten and Move Topological included.
    func testRegionalSwapIsSurfacePreserving() async {
        let state = BrushMatrix.makeState(voxel: false)
        _ = await state.engine.quiesce()
        let before = profile(state)

        // Strength this small is an identity relax in all but name.
        let anchor = SIMD3<Float>(0, 0.35, 0)
        _ = state.engine.relaxSurface(center: anchor, radius: 0.25, strength: 0.001)
        _ = await state.engine.quiesce()
        let after = profile(state)

        XCTAssertEqual(before.count, after.count)
        let shifts = zip(before, after).map { $0 - $1 }
        let worst = shifts.map(abs).max() ?? 0
        XCTAssertLessThan(worst, 0.01,
                          "the regional swap moved the surface on its own, "
                          + "with no meaningful verb applied: \(before) -> "
                          + "\(after), shifts \(shifts)")
    }

    /// Diagnostic: is `region_radius` actually confining the relax? The
    /// header is explicit that 0 "relaxes everywhere, which is a filter not
    /// a brush", so a small region must leave distant probes alone.
    func testRelaxIsConfinedToItsRegion() async {
        let state = BrushMatrix.makeState(voxel: false)
        _ = await state.engine.quiesce()
        let before = profile(state)

        // Small region at the top of the ball; the outer probes are far
        // outside it and must not move.
        _ = state.engine.relaxSurface(center: SIMD3<Float>(0, 0.35, 0),
                                      radius: 0.05, strength: 1)
        _ = await state.engine.quiesce()
        let after = profile(state)

        let shifts = zip(before, after).map { $0 - $1 }
        XCTAssertEqual(before.count, after.count)
        XCTAssertLessThan(abs(shifts.first ?? 0), 0.01,
                          "a probe far outside region_radius moved: "
                          + "\(before) -> \(after), shifts \(shifts)")
        XCTAssertLessThan(abs(shifts.last ?? 0), 0.01,
                          "a probe far outside region_radius moved: "
                          + "\(before) -> \(after), shifts \(shifts)")
    }

    /// The freeze reaches relax through `clay_relax_params.mask` rather than
    /// being applied app-side. This checks the parameter is actually wired:
    /// a fully frozen region must come back unchanged.
    func testRelaxHonoursTheMaskParameter() async {
        let state = BrushMatrix.makeState(voxel: false)
        _ = await state.engine.quiesce()

        let anchor = SIMD3<Float>(0, 0.35, 0)
        // Freeze generously around the anchor, straight through the engine so
        // the test does not depend on the freeze TOOL's plumbing.
        state.engine.maskPaint(at: anchor, radius: 0.4, erase: false,
                               voxelContext: false)
        _ = await state.engine.quiesce()
        let before = profile(state)

        _ = state.engine.relaxSurface(center: anchor, radius: 0.3, strength: 1)
        _ = await state.engine.quiesce()
        let after = profile(state)

        let shifts = zip(before, after).map { $0 - $1 }
        let worst = shifts.map(abs).max() ?? 0
        XCTAssertLessThan(worst, 0.01,
                          "frozen clay was relaxed anyway — the mask is not "
                          + "reaching clay_relax_params: \(before) -> \(after)")
    }
}
