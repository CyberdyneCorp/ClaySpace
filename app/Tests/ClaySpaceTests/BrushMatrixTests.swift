import XCTest
import simd
@testable import ClaySpace

/// The per-brush verification matrix. Every brush the UI can reach is
/// exercised through the app's own Pencil path and checked against what
/// that brush is for.
@MainActor
final class BrushMatrixTests: XCTestCase {

    /// A brush cannot ship without a fixture: the matrix is checked against
    /// the enumerations themselves, so adding a case to either one and
    /// forgetting to verify it fails here rather than going unnoticed.
    func testEveryBrushHasAFixture() {
        let sdfNames = Set(BrushMatrix.sdfFixtures.map(\.name))
        let missingSDF = ViewportState.SculptBrush.allCases
            .map(\.rawValue).filter { !sdfNames.contains($0) }
        XCTAssertTrue(missingSDF.isEmpty,
                      "SDF brushes with no verification fixture: \(missingSDF)")

        let voxelNames = Set(BrushMatrix.voxelFixtures.map(\.name))
        let missingVoxel = ClayEngine.VoxelVerb.allCases
            .map(\.rawValue).filter { !voxelNames.contains($0) }
        XCTAssertTrue(missingVoxel.isEmpty,
                      "voxel verbs with no verification fixture: \(missingVoxel)")

        // And nothing registered that is not a real brush — a fixture for a
        // renamed case would otherwise sit there passing forever.
        let realSDF = Set(ViewportState.SculptBrush.allCases.map(\.rawValue))
        XCTAssertTrue(sdfNames.subtracting(realSDF).isEmpty,
                      "fixtures for brushes that do not exist: "
                      + "\(sdfNames.subtracting(realSDF))")
        let realVoxel = Set(ClayEngine.VoxelVerb.allCases.map(\.rawValue))
        XCTAssertTrue(voxelNames.subtracting(realVoxel).isEmpty,
                      "fixtures for verbs that do not exist: "
                      + "\(voxelNames.subtracting(realVoxel))")
    }

    /// Runs one fixture and captures its result for inspection.
    private func verify(_ fixture: BrushFixture) async {
        let result = await BrushMatrix.run(fixture)
        XCTAssertTrue(result.settled,
                      "\(fixture.name): the bake never settled, so the probe "
                      + "would have measured a half-built field")
        BrushMatrix.assertEffect(fixture, before: result.before, after: result.after)
        guard let after = BrushCapture.render(engine: result.state.engine,
                                              camera: result.state.camera)
        else { return }
        BrushCapture.attach(after, named: "brush-\(fixture.name)", to: self)

        // Behaviour is judged above by the probes; the image is a SECOND,
        // separately-reported check. A driver update shifts every image at
        // once while every brush still works — if that arrives as "brushes
        // broken", the suite trains people to ignore it.
        // Qualify voxel verbs: `flatten`, `magnify` and `pinch` each exist
        // BOTH as an SDF brush and as a voxel verb, and the reference name
        // was only brush+view. Each pair therefore shared one file — the
        // voxel one won, because the voxel tests run last alphabetically —
        // so three SDF brushes were being compared against a voxel verb's
        // picture. It passed: SDF flatten against the voxel flatten
        // reference measures mean 0.859 and 0.97% outliers, inside both
        // tolerances. Six of the 23 brushes had no reference of their own.
        let reference = fixture.isVoxel ? "voxel-\(fixture.name)" : fixture.name
        switch GoldenStore.verify(after, brush: reference, view: "after", in: self) {
        case .matched, .rebaselined:
            break
        case .missingBaseline(let name):
            XCTFail("IMAGE BASELINE MISSING for \(fixture.name): no reference "
                    + "'\(name)' for this device class. Capture one with "
                    + "CLAY_GOLDEN_REBASELINE=1 rather than comparing against "
                    + "another device's images")
        case .drifted(let name, let difference):
            XCTFail("IMAGE DRIFT (not a behaviour failure) for \(fixture.name): "
                    + "\(name) differs by mean \(difference.meanAbsolute) and "
                    + "\(difference.outlierPixels) outlier pixels "
                    + "(\(difference.outlierFraction * 100)%). The brush still "
                    + "passed its geometric probes")
        }
    }

    private func verifyAll(_ fixtures: [BrushFixture]) async {
        for fixture in fixtures { await verify(fixture) }
    }

    // MARK: SDF brushes

    func testSurfaceBrushes() async {
        await verifyAll(BrushMatrix.sdfFixtures.filter {
            ["standard", "crease", "carve", "snakeHook"].contains($0.name)
        })
    }

    func testDisplacementBrushes() async {
        await verifyAll(BrushMatrix.sdfFixtures.filter {
            ["move", "moveTopo", "tube"].contains($0.name)
        })
    }

    func testShapingBrushes() async {
        await verifyAll(BrushMatrix.sdfFixtures.filter {
            ["polish", "flatten", "magnify", "pinch", "noise"].contains($0.name)
        })
    }

    // MARK: Voxel verbs

    func testVoxelBuildingVerbs() async {
        await verifyAll(BrushMatrix.voxelFixtures.filter {
            ["place", "smooth", "inflate", "deflate", "flatten", "scrape"]
                .contains($0.name)
        })
    }

    func testVoxelShapingVerbs() async {
        await verifyAll(BrushMatrix.voxelFixtures.filter {
            ["pinch", "magnify", "grab", "smudge", "fill"].contains($0.name)
        })
    }
}
