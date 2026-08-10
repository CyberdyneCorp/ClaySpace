import XCTest
import simd
@testable import ClaySpace

/// The per-brush verification matrix. Every brush the UI can reach is
/// exercised through the app's own Pencil path and checked against what
/// that brush is for.
@MainActor
final class BrushMatrixTests: XCTestCase {

    // Which brushes each test method runs. Data rather than literals inline
    // in the methods, so `testEveryBrushIsActuallyRun` can check that the
    // groups between them cover every fixture. `smooth` was registered and
    // matched no group — the fixture existed and never ran.
    static let surfaceGroup = ["standard", "crease", "carve", "snakeHook"]
    static let displacementGroup = ["move", "moveTopo", "tube"]
    static let shapingGroup = ["polish", "flatten", "smooth", "extract", "magnify",
                               "pinch", "noise"]
    static let voxelBuildingGroup = ["place", "inflate", "deflate", "scrape",
                                     "flatten", "smooth"]
    static let voxelShapingGroup = ["pinch", "magnify", "grab", "smudge", "fill"]

    /// Having a fixture is not the same as being run. Every registered
    /// fixture must belong to a group some test method actually drives,
    /// or it sits in the registry proving nothing.
    func testEveryBrushIsActuallyRun() {
        let sdfRun = Set(Self.surfaceGroup + Self.displacementGroup + Self.shapingGroup)
        let sdfRegistered = Set(BrushMatrix.sdfFixtures.map(\.name))
        XCTAssertTrue(sdfRegistered.subtracting(sdfRun).isEmpty,
                      "SDF fixtures registered but run by no test: "
                      + "\(sdfRegistered.subtracting(sdfRun))")
        XCTAssertTrue(sdfRun.subtracting(sdfRegistered).isEmpty,
                      "test groups naming brushes with no fixture: "
                      + "\(sdfRun.subtracting(sdfRegistered))")

        let voxelRun = Set(Self.voxelBuildingGroup + Self.voxelShapingGroup)
        let voxelRegistered = Set(BrushMatrix.voxelFixtures.map(\.name))
        XCTAssertTrue(voxelRegistered.subtracting(voxelRun).isEmpty,
                      "voxel fixtures registered but run by no test: "
                      + "\(voxelRegistered.subtracting(voxelRun))")
        XCTAssertTrue(voxelRun.subtracting(voxelRegistered).isEmpty,
                      "test groups naming verbs with no fixture: "
                      + "\(voxelRun.subtracting(voxelRegistered))")
    }

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
        if fixture.assertsEffect {
            BrushMatrix.assertEffect(fixture, before: result.before,
                                     after: result.after)
        }
        if fixture.guardsRegionalSwap {
            BrushMatrix.assertNoTear(fixture, before: result.before,
                                     after: result.after)
            BrushMatrix.assertBakeIsFaithful(fixture, result.state)
        }
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
        var reference = fixture.isVoxel ? "voxel-\(fixture.name)" : fixture.name
        if let variant = fixture.variant { reference += "-\(variant)" }
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
            Self.surfaceGroup.contains($0.name)
        })
    }

    func testDisplacementBrushes() async {
        await verifyAll(BrushMatrix.sdfFixtures.filter {
            Self.displacementGroup.contains($0.name)
        })
    }

    func testShapingBrushes() async {
        await verifyAll(BrushMatrix.sdfFixtures.filter {
            Self.shapingGroup.contains($0.name)
        })
    }

    // MARK: Voxel verbs

    func testVoxelBuildingVerbs() async {
        await verifyAll(BrushMatrix.voxelFixtures.filter {
            Self.voxelBuildingGroup.contains($0.name)
        })
    }

    func testVoxelShapingVerbs() async {
        await verifyAll(BrushMatrix.voxelFixtures.filter {
            Self.voxelShapingGroup.contains($0.name)
        })
    }
}
