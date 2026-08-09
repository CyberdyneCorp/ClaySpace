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
        if let image = BrushCapture.render(engine: result.state.engine,
                                           camera: result.state.camera) {
            BrushCapture.attach(image, named: "brush-\(fixture.name)", to: self)
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
