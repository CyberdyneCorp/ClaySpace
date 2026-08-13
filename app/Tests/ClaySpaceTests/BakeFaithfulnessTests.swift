import XCTest
import simd
import claycore
@testable import ClaySpace

/// The bake must agree with the document after every settled gesture — the
/// property BrushMatrixTests checks once per brush, here hammered across
/// repeated continuous-warp drags because the observed failure is
/// intermittent: 2 of 5 suite runs, always on a warp verb, always after the
/// 16 ms mid-drag bakes landed differently against the drag's pacing.
///
/// ClayCore is exonerated by direct C-harness A/Bs (cull vs none, metal vs
/// cpu, resident-state loops, mid-undo-group saves — all bit-faithful), so
/// a failure here is the app's scheduling handing the bake a wrong input,
/// and this test existing is what keeps it reproducible while that is
/// hunted — and pinned once fixed.
@MainActor
final class BakeFaithfulnessTests: XCTestCase {

    private func drag(at row: CGFloat) -> [CGPoint] {
        stride(from: 340, through: 460, by: 10).map { CGPoint(x: CGFloat($0), y: row) }
    }

    func testRepeatedWarpDragsBakeFaithfully() async throws {
        let state = BrushMatrix.makeState(voxel: false)
        state.activeTool = .sculpt
        state.sculptBrush = .standard
        state.brushStrength = 1
        state.brushSize = 0.5

        // Seed some relief so the scene resembles a real sculpt.
        BrushMatrix.drive(state, along: BrushFixture.centerDrag)
        _ = await state.engine.quiesce()

        state.sculptBrush = .polish
        for round in 0..<10 {
            BrushMatrix.drive(state, along: drag(at: 280 + CGFloat(round) * 12))
            let settled = await state.engine.quiesce()
            XCTAssertTrue(settled, "round \(round): bake never settled")
            guard let worst = BrushMatrix.worstBakeError(state) else {
                return XCTFail("round \(round): no field cache")
            }
            // Diagnostics BEFORE the assert: which path baked last, where
            // its slab sat, whether the bad cell is inside it, and whether
            // a forced full rebake heals it — together they say "stale
            // cells the partial path never covered" vs "wrong values in
            // the slab it did".
            if worst.error >= BrushMatrix.bakeErrorThreshold,
               let cache = state.engine.fieldCache {
                let spacing = cache.extent / SIMD3<Float>(cache.dims)
                var slabDescription = "none"
                var inside = false
                if let dirty = cache.dirtyCells {
                    let lo = cache.origin + SIMD3<Float>(dirty.min) * spacing
                    let hi = cache.origin + (SIMD3<Float>(dirty.max) + 1) * spacing
                    slabDescription = "\(lo) .. \(hi)"
                    inside = all(worst.at .>= lo) && all(worst.at .<= hi)
                }
                print("DIAG round \(round): error \(worst.error) at \(worst.at)")
                print("DIAG lastBakeWasPartial=\(state.engine.lastBakeWasPartial) "
                      + "items=\(state.engine.items.count) "
                      + "baked=\(cache.bakedItemCount)")
                print("DIAG last slab: \(slabDescription)  badPointInside=\(inside)")
                print("DIAG gesture: stroking=\(state.engine.isStroking) "
                      + "transforming=\(state.engine.isTransforming) "
                      + "warpOpen=\(state.engine.warpSessionOpen)")
                print("DIAG bakes: completed=\(state.engine.bakesCompleted) "
                      + "lastExit=\(state.engine.lastBakeExit) "
                      + "version=\(state.engine.version)")
                let before = state.engine.bakesCompleted
                state.engine.scheduleBake(debounceMilliseconds: 0)
                _ = await state.engine.quiesce()
                let healed = BrushMatrix.worstBakeError(state)
                print("DIAG after full rebake: \(String(describing: healed))")
                print("DIAG rebake ran: \(state.engine.bakesCompleted - before) "
                      + "lastExit=\(state.engine.lastBakeExit) "
                      + "version=\(state.engine.version)")

                // The full rebake reproduces the error, so the snapshot it
                // just baked from is still on disk. Interrogate the exact
                // bad point: live vs snapshot (round trip), and both sample
                // mappings (worstBakeError maps cell x to x/(n-1); the bake
                // samples (x+0.5)/n — the disagreement could be the ruler).
                if let freshCache = state.engine.fieldCache {
                    let dims = freshCache.dims
                    let rel = (worst.at - freshCache.origin) / freshCache.extent
                    let idx = SIMD3<Int>(
                        Int((rel.x * Float(dims.x - 1)).rounded()),
                        Int((rel.y * Float(dims.y - 1)).rounded()),
                        Int((rel.z * Float(dims.z - 1)).rounded()))
                    let cellCentered = freshCache.origin
                        + (SIMD3<Float>(Float(idx.x) + 0.5, Float(idx.y) + 0.5,
                                        Float(idx.z) + 0.5)
                           / SIMD3<Float>(dims)) * freshCache.extent
                    let baked = Float(freshCache.distances[
                        (idx.z * Int(dims.y) + idx.y) * Int(dims.x) + idx.x])
                    let liveVertex = state.engine.evalDistance(at: worst.at)
                    let liveCell = state.engine.evalDistance(at: cellCentered)
                    print("DIAG cell \(idx) baked=\(baked) "
                          + "liveAtVertexMap=\(liveVertex) liveAtCellMap=\(liveCell)")

                    let snapshotPath = FileManager.default.temporaryDirectory
                        .appendingPathComponent("clayspace-bake.clayspace").path
                    var loaded: OpaquePointer?
                    if clay_document_load(snapshotPath, &loaded) == CLAY_OK,
                       let snap = loaded {
                        var d: Float = 0
                        var rgb = [Float](repeating: 0, count: 3)
                        _ = clay_eval_points(snap, nil,
                                             [worst.at.x, worst.at.y, worst.at.z],
                                             1, &d, &rgb)
                        var dc: Float = 0
                        _ = clay_eval_points(snap, nil,
                                             [cellCentered.x, cellCentered.y,
                                              cellCentered.z], 1, &dc, &rgb)
                        print("DIAG snapshot cpu: atVertexMap=\(d) atCellMap=\(dc)")
                        // The bake evaluates through Metal; evalDistance is
                        // CPU. Same loaded doc, same points, metal backend —
                        // a parity gap on this document's tape shows here.
                        var dm: Float = 0, dmc: Float = 0
                        let metalOK = "metal".withCString { m in
                            clay_eval_points(snap, m,
                                             [worst.at.x, worst.at.y, worst.at.z],
                                             1, &dm, &rgb) == CLAY_OK
                            && clay_eval_points(snap, m,
                                               [cellCentered.x, cellCentered.y,
                                                cellCentered.z], 1, &dmc, &rgb)
                                == CLAY_OK
                        }
                        print("DIAG snapshot metal(ok=\(metalOK)): "
                              + "atVertexMap=\(dm) atCellMap=\(dmc)")

                        // The bake's actual shape: one huge eval_grid on
                        // this snapshot, metal vs cpu, IN THIS ENVIRONMENT
                        // (the simulator's paravirtual GPU when run here).
                        let gd = freshCache.dims
                        let gtotal = Int(gd.x) * Int(gd.y) * Int(gd.z)
                        let gspacing = freshCache.extent / SIMD3<Float>(gd)
                        var gq = clay_grid_query()
                        gq.struct_size = UInt32(MemoryLayout<clay_grid_query>.size)
                        let gorigin = freshCache.origin + gspacing * 0.5
                        gq.origin = (gorigin.x, gorigin.y, gorigin.z)
                        gq.spacing = gspacing.x
                        gq.dims = (gd.x, gd.y, gd.z)
                        var gcpu = [Float](repeating: 0, count: gtotal)
                        var gmet = [Float](repeating: 0, count: gtotal)
                        let cpuOK = clay_eval_grid(snap, nil, &gq, nil, nil,
                                                   &gcpu, nil, gtotal) == CLAY_OK
                        let metOK = "metal".withCString { m in
                            clay_eval_grid(snap, m, &gq, nil, nil,
                                           &gmet, nil, gtotal) == CLAY_OK
                        }
                        var gworst: Float = 0
                        var gwi = 0
                        if cpuOK && metOK {
                            for i in 0..<gtotal {
                                let d = abs(gcpu[i] - gmet[i])
                                if d > gworst { gworst = d; gwi = i }
                            }
                        }
                        let gx = gwi % Int(gd.x)
                        let gy = (gwi / Int(gd.x)) % Int(gd.y)
                        let gz = gwi / (Int(gd.x) * Int(gd.y))
                        print("DIAG big-grid \(gd) cpuOK=\(cpuOK) metalOK=\(metOK) "
                              + "|cpu-metal|=\(gworst) at cell (\(gx),\(gy),\(gz)) "
                              + "cpu=\(cpuOK ? gcpu[gwi] : .nan) "
                              + "metal=\(metOK ? gmet[gwi] : .nan)")
                        clay_document_destroy(snap)
                    } else {
                        print("DIAG snapshot: could not load \(snapshotPath)")
                    }
                }
            }
            XCTAssertLessThan(worst.error, BrushMatrix.bakeErrorThreshold,
                              "round \(round): bake disagrees with the document "
                              + "by \(worst.error) at \(worst.at)")
        }
    }
}
