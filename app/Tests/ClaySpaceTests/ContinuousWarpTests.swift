import XCTest
import simd
import claycore
@testable import ClaySpace

/// hPolish and Smooth were TAP verbs: the anchor was captured on touch-down,
/// the drag did nothing, and the verb ran once on lift at the point where the
/// gesture STARTED. Dragging across a surface polished one spot and discarded
/// the rest of the gesture silently — no error, no refusal, just a brush that
/// ignored most of what the artist did.
///
/// These pin the continuous behaviour, and the properties that make it a
/// gesture rather than a burst of separate edits.
@MainActor
final class ContinuousWarpTests: XCTestCase {

    /// A drag long enough to cross several travel-spacings.
    private var longDrag: [CGPoint] {
        stride(from: 330, through: 470, by: 10).map { CGPoint(x: CGFloat($0), y: 300) }
    }

    private func seeded() async -> ViewportState {
        let state = BrushMatrix.makeState(voxel: false)
        BrushFixtures_seedRidge(state)
        _ = await state.engine.quiesce()
        return state
    }

    /// `BrushMatrix.seedDetailedRidge` is private to the fixtures; this is the
    /// same gesture, kept local so the test states its own setup.
    private func BrushFixtures_seedRidge(_ state: ViewportState) {
        state.activeTool = .sculpt
        state.sculptBrush = .standard
        state.brushStrength = 1
        state.brushSize = 0.35
        for point in BrushFixture.probePoints {
            for _ in 0..<2 {
                state.pencilBegan(at: point, pressure: 1)
                state.pencilEnded(at: point)
            }
        }
    }

    func testPolishAppliesAlongTheDragNotOnlyAtItsStart() async {
        let state = await seeded()
        state.sculptBrush = .polish
        state.brushStrength = 1
        let before = state.engine.items.count

        BrushMatrix.drive(state, along: longDrag)
        _ = await state.engine.quiesce()

        // Each application is a box-subtract plus a volume-add.
        let added = state.engine.items.count - before
        XCTAssertGreaterThan(added, 2,
                             "hPolish applied \(added / 2) time(s) across a "
                             + "14-sample drag — it is still a tap brush, and "
                             + "the drag is being discarded")
    }

    func testSmoothAppliesAlongTheDrag() async {
        let state = await seeded()
        state.sculptBrush = .smooth
        state.brushStrength = 1
        let before = state.engine.items.count

        BrushMatrix.drive(state, along: longDrag)
        _ = await state.engine.quiesce()

        let added = state.engine.items.count - before
        XCTAssertGreaterThan(added, 2,
                             "Smooth applied \(added / 2) time(s) across the drag")
    }

    /// A gesture is ONE edit. Ten dabs that each undo separately would make
    /// the brush unusable in exactly the way the old one-shot version was not.
    func testAContinuousDragUndoesAsOneStep() async {
        let state = await seeded()
        let settled = state.engine.items.count
        state.sculptBrush = .polish
        state.brushStrength = 1

        BrushMatrix.drive(state, along: longDrag)
        _ = await state.engine.quiesce()
        XCTAssertGreaterThan(state.engine.items.count, settled + 2,
                             "the drag did not apply more than once")

        state.engine.undo()
        _ = await state.engine.quiesce()
        XCTAssertEqual(state.engine.items.count, settled,
                       "one undo did not take back the whole gesture")
    }

    /// A tap is still a tap: the gesture never travels, so the lift path has
    /// to apply once or the brush would do nothing at all.
    func testATapStillPolishes() async {
        let state = await seeded()
        state.sculptBrush = .polish
        state.brushStrength = 1
        let before = state.engine.items.count

        BrushMatrix.drive(state, along: BrushFixture.centerTap)
        _ = await state.engine.quiesce()

        XCTAssertEqual(state.engine.items.count - before, 2,
                       "a tap should apply exactly once")
    }
}
