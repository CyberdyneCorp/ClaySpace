import XCTest
import simd
import claycore
@testable import ClaySpace

/// Mask Extract, against the spec: "A frozen patch becomes a new item",
/// "The mask never reaches the surface", "Nothing is frozen".
///
/// Extract does NOT ride the regional volume swap, so none of this is
/// blocked on `fix-regional-swap-tearing`.
@MainActor
final class MaskExtractTests: XCTestCase {

    private func freshState() async -> ViewportState {
        let state = BrushMatrix.makeState(voxel: false)
        _ = await state.engine.quiesce()
        return state
    }

    /// Freezes a patch ON the surface, which is the case Extract is for.
    private func freezeSurfacePatch(_ state: ViewportState) -> Bool {
        guard let ray = state.ray(through: BrushFixture.centerTap[0]),
              let hit = state.engine.raycast(origin: ray.origin,
                                             direction: ray.direction)
        else { return false }
        state.engine.maskPaint(at: hit.position, radius: 0.18, erase: false,
                               voxelContext: false)
        return true
    }

    func testAFrozenPatchBecomesANewItem() async {
        let state = await freshState()
        XCTAssertTrue(freezeSurfacePatch(state), "no surface to freeze")
        _ = await state.engine.quiesce()

        let itemsBefore = state.engine.items.count
        let maskedBefore = maskedCellCount(state)

        XCTAssertTrue(state.engine.extractMask(thickness: 0.15),
                      "extract refused: \(state.engine.lastError ?? "no error")")
        _ = await state.engine.quiesce()

        XCTAssertEqual(state.engine.items.count, itemsBefore + 1,
                       "extract should add exactly one item")
        XCTAssertEqual(maskedCellCount(state), maskedBefore,
                       "extract must leave the mask untouched")

        // One undo step: the item goes away and nothing else changes.
        _ = state.engine.undo()
        _ = await state.engine.quiesce()
        XCTAssertEqual(state.engine.items.count, itemsBefore,
                       "extract must undo in ONE step")
    }

    func testNothingIsFrozen() async {
        let state = await freshState()
        let itemsBefore = state.engine.items.count

        XCTAssertFalse(state.engine.extractMask(thickness: 0.15),
                       "extract should refuse with no mask")
        XCTAssertEqual(state.engine.items.count, itemsBefore,
                       "a refused extract must add nothing")
        XCTAssertNotNil(state.engine.lastError, "the refusal must be reported")
    }

    func testAThicknessOfZeroIsRefused() async {
        let state = await freshState()
        XCTAssertTrue(freezeSurfacePatch(state), "no surface to freeze")
        _ = await state.engine.quiesce()
        let itemsBefore = state.engine.items.count

        XCTAssertFalse(state.engine.extractMask(thickness: 0),
                       "extract should refuse a non-positive thickness")
        XCTAssertEqual(state.engine.items.count, itemsBefore)
        XCTAssertNotNil(state.engine.lastError)
    }

    /// The mistake the ABI warns an empty item would disguise: clay is frozen,
    /// but nowhere near the surface being extracted.
    func testAMaskThatNeverReachesTheSurface() async {
        let state = await freshState()
        // Well outside the seeded ball.
        state.engine.maskPaint(at: SIMD3<Float>(3, 3, 3), radius: 0.2,
                               erase: false, voxelContext: false)
        _ = await state.engine.quiesce()
        let itemsBefore = state.engine.items.count

        let extracted = state.engine.extractMask(thickness: 0.15)
        _ = await state.engine.quiesce()

        // Whether the engine refuses or returns something, what must NOT
        // happen is a silent empty item landing in the document.
        if extracted {
            XCTAssertEqual(state.engine.items.count, itemsBefore + 1,
                           "if extract reports success it must have produced "
                           + "an item")
        } else {
            XCTAssertEqual(state.engine.items.count, itemsBefore,
                           "a refused extract must add nothing")
            XCTAssertNotNil(state.engine.lastError,
                            "a mask that never reaches the surface must be "
                            + "reported, not swallowed")
        }
    }

    private func maskedCellCount(_ state: ViewportState) -> Int {
        state.engine.maskPaintedCount(voxelContext: false)
    }
}
