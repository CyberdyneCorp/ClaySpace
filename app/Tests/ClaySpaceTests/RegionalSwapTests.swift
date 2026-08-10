import XCTest
import simd
import claycore
@testable import ClaySpace

/// The regional volume swap (`ClayEngine.replaceRegion`) is shared by every
/// brush that hands a region to a ClayCore volume verb: hPolish, Flatten,
/// Move Topological — all shipping — and now Relax.
///
/// Smooth was found to tear the surface over detailed geometry, leaving a
/// box-shaped crater with hard edges. The brush fixtures could never have
/// caught it: every one of them acts on a plain seeded ball, where the
/// sampled region contains a single smooth surface and the seam is benign.
///
/// These tests put DETAIL under the brush and ask whether the swap survives
/// it, for each verb that rides the path. A failure here is a defect in
/// shipped code, not in the new brush.
@MainActor
final class RegionalSwapTests: XCTestCase {

    /// How far a probe may move before the surface is considered torn rather
    /// than sculpted. The brushes under test act with a small region; the
    /// observed tearing moved probes by more than half a world unit.
    private let tearThreshold: Float = 0.3

    private func profile(_ state: ViewportState) -> [Float?] {
        BrushMatrix.measure(state).surfaceDistances
    }

    /// A ball with a pronounced Standard bump on it — detail the sampled
    /// region has to reproduce, which a plain ball never demands.
    private func seededBump() async -> ViewportState {
        let state = BrushMatrix.makeState(voxel: false)
        BrushMatrix.seedBump(state)
        _ = await state.engine.quiesce()
        return state
    }

    /// Where the bump is, in world space, so every verb acts at the same place.
    private func bumpAnchor(_ state: ViewportState) -> (point: SIMD3<Float>,
                                                        normal: SIMD3<Float>)? {
        guard let ray = state.ray(through: BrushFixture.centerTap[0]),
              let hit = state.engine.raycast(origin: ray.origin,
                                             direction: ray.direction)
        else { return nil }
        return (hit.position, hit.normal)
    }

    /// Attaches what the verb actually produced. A tear is obvious in a
    /// picture and arguable in a list of floats.
    private func capture(_ state: ViewportState, named name: String) {
        guard let image = BrushCapture.render(engine: state.engine,
                                              camera: state.camera) else { return }
        BrushCapture.attach(image, named: "tear-\(name)", to: self)
    }

    /// Reports the tear rather than just failing, so a red run says which
    /// verb and by how much.
    private func assertNoTear(_ name: String, before: [Float?], after: [Float?],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(before.count, after.count, file: file, line: line)
        for (index, pair) in zip(before, after).enumerated() {
            switch pair {
            case (.some(let start), .some(let end)):
                XCTAssertLessThan(abs(start - end), tearThreshold,
                                  "\(name) tore the surface at probe \(index): "
                                  + "\(start) -> \(end). before \(before) "
                                  + "after \(after)", file: file, line: line)
            case (.some, .none):
                XCTFail("\(name) removed the surface entirely at probe \(index). "
                        + "before \(before) after \(after)", file: file, line: line)
            default:
                break // no surface there to begin with
            }
        }
    }

    func testPolishDoesNotTearDetailedGeometry() async {
        let state = await seededBump()
        guard let anchor = bumpAnchor(state) else { return XCTFail("no bump to act on") }
        let before = profile(state)
        state.engine.polishSurface(center: anchor.point, normal: anchor.normal,
                                   radius: 0.16, strength: 1,
                                   mode: CLAY_FLATTEN_CUT_ONLY)
        _ = await state.engine.quiesce()
        capture(state, named: "polish")
        assertNoTear("hPolish", before: before, after: profile(state))
    }

    func testFlattenDoesNotTearDetailedGeometry() async {
        let state = await seededBump()
        guard let anchor = bumpAnchor(state) else { return XCTFail("no bump to act on") }
        let before = profile(state)
        state.engine.polishSurface(center: anchor.point, normal: anchor.normal,
                                   radius: 0.16, strength: 1,
                                   mode: CLAY_FLATTEN_TWO_SIDED)
        _ = await state.engine.quiesce()
        capture(state, named: "flatten")
        assertNoTear("Flatten", before: before, after: profile(state))
    }

    func testMoveTopologicalDoesNotTearDetailedGeometry() async {
        let state = await seededBump()
        guard let anchor = bumpAnchor(state) else { return XCTFail("no bump to act on") }
        let before = profile(state)
        state.engine.moveTopologicalSurface(anchor: anchor.point,
                                            displacement: anchor.normal * 0.04,
                                            radius: 0.16)
        _ = await state.engine.quiesce()
        capture(state, named: "moveTopo")
        assertNoTear("Move Topological", before: before, after: profile(state))
    }

    /// The one already known to tear, kept alongside the others so the
    /// comparison is in one place.
    func testRelaxDoesNotTearDetailedGeometry() async {
        let state = await seededBump()
        guard let anchor = bumpAnchor(state) else { return XCTFail("no bump to act on") }
        let before = profile(state)
        _ = state.engine.relaxSurface(center: anchor.point, radius: 0.16, strength: 1)
        _ = await state.engine.quiesce()
        capture(state, named: "relax")
        assertNoTear("Relax", before: before, after: profile(state))
    }

    /// Separates WHICH detail tears it. The seed uses Standard, which is
    /// CLAY_OP_RELIEF — a region op, not a plain solid. Snake Hook builds the
    /// same kind of lump with CLAY_OP_ADD. If relief tears and add does not,
    /// the fault is in sampling relief rather than in detail as such.
    func testWhichKindOfDetailTears() async {
        for (label, brush) in [("RELIEF   (Standard)", ViewportState.SculptBrush.standard),
                               ("INCISE   (Crease)", ViewportState.SculptBrush.crease),
                               ("ADD      (Snake Hook)", ViewportState.SculptBrush.snakeHook),
                               ("SUBTRACT (Carve)", ViewportState.SculptBrush.carve)] {
            let state = BrushMatrix.makeState(voxel: false)
            state.activeTool = .sculpt
            state.sculptBrush = brush
            state.brushStrength = 1
            state.brushSize = 0.8
            for _ in 0..<3 {
                state.pencilBegan(at: BrushFixture.centerTap[0], pressure: 1)
                state.pencilEnded(at: BrushFixture.centerTap[0])
            }
            _ = await state.engine.quiesce()
            guard let anchor = bumpAnchor(state) else {
                XCTFail("\(label): no surface"); continue
            }
            let before = profile(state)
            state.engine.polishSurface(center: anchor.point, normal: anchor.normal,
                                       radius: 0.16, strength: 1,
                                       mode: CLAY_FLATTEN_CUT_ONLY)
            _ = await state.engine.quiesce()
            let after = profile(state)
            let worst = zip(before, after).compactMap { pair -> Float? in
                guard let a = pair.0, let b = pair.1 else { return nil }
                return abs(a - b)
            }.max() ?? 0
            // A HOLE is the signature, not mere movement: carve legitimately
            // moves the surface a long way. A probe that recedes past the
            // object is the ray passing clean through it.
            let holes = zip(before, after).filter { pair in
                guard let a = pair.0, let b = pair.1 else { return false }
                return b - a > 0.4
            }.count
            let fmt = { (xs: [Float?]) in xs.map { $0.map { String(format: "%.3f", $0) } ?? "nil" }.joined(separator: " ") }
            print("TEAR-PROBE \(label): holes \(holes)  worst \(String(format: "%.3f", worst))")
            print("           before \(fmt(before))")
            print("           after  \(fmt(after))")
            XCTAssertEqual(holes, 0,
                           "\(label) opened \(holes) hole(s): before \(before) "
                           + "after \(after)")
        }
    }
}
