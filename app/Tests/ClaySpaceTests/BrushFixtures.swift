import XCTest
import CoreGraphics
import simd
@testable import ClaySpace

/// What a brush is FOR, as something a test can check. Direction is stated
/// where the brush has one; `reshapes` is for brushes whose whole job is to
/// move the surface without a fixed sign (Move, Pinch, Noise…). A reshaping
/// brush still has to move the surface at the probe — "did an edit get
/// recorded" is not a verification.
enum BrushEffect {
    case addsMaterial
    case removesMaterial
    case reshapes
    /// The brush's claim is that a PEAK COMES DOWN. Relaxing a smooth
    /// sphere barely moves it, so "something moved" would say nothing —
    /// the fixture seeds a bump and this checks that bump subsides.
    case smooths
    /// The brush's claim is a PLANAR FACET, so movement alone is not
    /// proof. hPolish and Flatten passed as `.reshapes` while rendering
    /// indistinguishably from an untouched sphere — `.reshapes` accepts
    /// any probe moving more than `minDelta`, and the default `0.004` is
    /// a thirtieth of a `0.12` voxel cell. This asserts the shape.
    case flattens
}

/// One brush, everything needed to exercise it, and what it must do.
struct BrushFixture {
    let name: String
    /// Distinguishes a second fixture for the same brush. The NAME stays the
    /// brush's own, so the completeness tests keep matching fixtures against
    /// real brushes; the variant qualifies the golden reference so two
    /// fixtures for one brush do not share a picture.
    let variant: String?
    let isVoxel: Bool
    /// Optional material to act on — a warp brush needs a surface, and a
    /// voxel verb that is not `place` needs cells to work with.
    let seed: (@MainActor @Sendable (ViewportState) -> Void)?
    /// Selects the tool and brush under test.
    let select: @MainActor @Sendable (ViewportState) -> Void
    /// Screen path for the stroke; a single point is a tap.
    let stroke: [CGPoint]
    let effect: BrushEffect
    /// Minimum movement, in world units, that counts as the brush working.
    let minDelta: Float
    /// Strength dial, where the brush's default is too subtle to probe.
    let strength: Float?
    /// Guard the regional volume swap: assert the surface was not TORN, and
    /// that the BAKE the renderer samples still matches the document.
    ///
    /// Both are needed and neither implies the other. The effect claims cannot
    /// express tearing — `.reshapes` passes on any large movement, and a tear
    /// is nothing but a large movement. And the tear check alone cannot see a
    /// bad bake, because it probes the document, which every edit rebuilds
    /// correctly; the artist sees the bake.
    let guardsRegionalSwap: Bool
    /// Whether this fixture asserts the brush's effect claim at all.
    ///
    /// A tear guard does not: the plain-ball fixture already carries the
    /// brush's claim, and making the detail fixture re-assert it couples a
    /// tearing probe to defects that have nothing to do with tearing. Smooth
    /// is the live example — it is inert (`add-smooth-and-extract-brushes`
    /// 4.12b), so a detail fixture asserting `.reshapes` would sit red for a
    /// reason it was never built to report, and a permanently red guard
    /// guards nothing.
    let assertsEffect: Bool

    init(_ name: String, variant: String? = nil, isVoxel: Bool = false,
         seed: (@MainActor @Sendable (ViewportState) -> Void)? = nil,
         select: @escaping @MainActor @Sendable (ViewportState) -> Void,
         stroke: [CGPoint] = BrushFixture.centerDrag,
         effect: BrushEffect, minDelta: Float = 0.004,
         strength: Float? = nil, guardsRegionalSwap: Bool = false,
         assertsEffect: Bool = true) {
        self.name = name
        self.variant = variant
        self.guardsRegionalSwap = guardsRegionalSwap
        self.assertsEffect = assertsEffect
        self.isVoxel = isVoxel
        self.seed = seed
        self.select = select
        self.stroke = stroke
        self.effect = effect
        self.minDelta = minDelta
        self.strength = strength
    }

    /// A drag across the middle of the seeded ball.
    static let centerDrag: [CGPoint] = stride(from: 360, through: 440, by: 10)
        .map { CGPoint(x: CGFloat($0), y: 300) }
    static let centerTap: [CGPoint] = [CGPoint(x: 400, y: 300)]
    /// Grab and smudge displace by how far the Pencil travelled, so they
    /// need a drag long enough to move material more than a cell.
    static let longDrag: [CGPoint] = stride(from: 380, through: 560, by: 10)
        .map { CGPoint(x: CGFloat($0), y: 300) }
    /// Where the surface is measured. Several points across the stroke,
    /// not one: a high-frequency brush like Noise can put a zero crossing
    /// under a single probe and read as "did nothing".
    static let probePoints: [CGPoint] = [360, 380, 400, 420, 440]
        .map { CGPoint(x: CGFloat($0), y: 300) }
}

/// The measurement a probe takes. SDF brushes move a surface the raycaster
/// can find; voxel verbs move a mesh, which needs its own signature since a
/// verb can rearrange cells without changing how many there are.
struct BrushMeasurement {
    /// Camera-to-surface distance at each probe point; nil where the ray
    /// missed.
    let surfaceDistances: [Float?]
    let voxelVertexCount: Int
    let voxelChecksum: Double
}

@MainActor
enum BrushMatrix {

    // MARK: Registry
    //
    // Built per brush rather than generated, because the point of each entry
    // is the claim it makes about that brush.

    static let sdfFixtures: [BrushFixture] = [
        BrushFixture("standard", select: { $0.sculptBrush = .standard },
                     effect: .addsMaterial),
        BrushFixture("crease", select: { $0.sculptBrush = .crease },
                     effect: .removesMaterial),
        BrushFixture("carve", select: { $0.sculptBrush = .carve },
                     effect: .removesMaterial),
        BrushFixture("snakeHook", select: { $0.sculptBrush = .snakeHook },
                     effect: .reshapes),
        BrushFixture("move", select: { $0.sculptBrush = .move }, effect: .reshapes),
        BrushFixture("moveTopo", select: { $0.sculptBrush = .moveTopo }, effect: .reshapes),
        BrushFixture("tube", select: { $0.sculptBrush = .tube }, effect: .addsMaterial),
        // The flatten family claims a facet, so it is probed for one. Both
        // ran at the default strength and passed as `.reshapes` while
        // rendering as an untouched ball; full strength is what the brush
        // is for, and `minDelta` rises to a cell-scale movement.
        BrushFixture("polish", select: { $0.sculptBrush = .polish },
                     effect: .flattens, minDelta: 0.02, strength: 1),
        BrushFixture("flatten", select: { $0.sculptBrush = .flatten },
                     effect: .flattens, minDelta: 0.02, strength: 1),
        // The relax region must be SMALL against the bump, or it lifts the
        // whole object uniformly instead of taking the peak down.
        BrushFixture("smooth", seed: seedBump,
                     select: { $0.sculptBrush = .smooth; $0.brushSize = 0.1 },
                     stroke: BrushFixture.centerTap,
                     effect: .smooths, minDelta: 0.004, strength: 1),
        // A command brush: it acts once on touch-down against the existing
        // freeze, so the "stroke" is a single tap and there is no drag.
        BrushFixture("extract", seed: seedFrozenPatch,
                     select: { $0.sculptBrush = .extract },
                     stroke: BrushFixture.centerTap,
                     effect: .addsMaterial, minDelta: 0.01),
        BrushFixture("magnify", select: { $0.sculptBrush = .magnify }, effect: .reshapes),
        BrushFixture("pinch", select: { $0.sculptBrush = .pinch }, effect: .reshapes),
        // Noise at its default strength moves the surface by ~2e-05 — real,
        // but far below anything a probe should call a pass. The dial is
        // what a user reaches for anyway.
        BrushFixture("noise", select: { $0.sculptBrush = .noise }, effect: .reshapes,
                     strength: 1),

        // The regional-swap riders, over DETAIL (fix-regional-swap-tearing
        // 4.1). Every fixture above acts on a plain ball, which is the one
        // case where the sampled region has a single smooth surface to
        // reproduce — and therefore the case least able to catch a swap that
        // loses it. That blind spot is why the tearing in hPolish, Flatten
        // and Move Topological shipped: it took a new brush to expose a
        // defect three shipped verbs already had.
        //
        // `.reshapes` here only asserts the brush is not a no-op; the real
        // assertion is `refusesToTear`.
        BrushFixture("polish", variant: "detail", seed: seedDetailedRidge,
                     select: { $0.sculptBrush = .polish },
                     effect: .reshapes, strength: 1, guardsRegionalSwap: true,
                     assertsEffect: false),
        BrushFixture("flatten", variant: "detail", seed: seedDetailedRidge,
                     select: { $0.sculptBrush = .flatten },
                     effect: .reshapes, strength: 1, guardsRegionalSwap: true,
                     assertsEffect: false),
        BrushFixture("moveTopo", variant: "detail", seed: seedDetailedRidge,
                     select: { $0.sculptBrush = .moveTopo },
                     effect: .reshapes, guardsRegionalSwap: true,
                     assertsEffect: false),
        BrushFixture("smooth", variant: "detail", seed: seedDetailedRidge,
                     select: { $0.sculptBrush = .smooth; $0.brushSize = 0.1 },
                     stroke: BrushFixture.centerTap,
                     effect: .reshapes, strength: 1, guardsRegionalSwap: true,
                     assertsEffect: false),
    ]

    /// Relax needs something to relax, and it has to be a PRONOUNCED and
    /// LOCAL bump. A ridge drawn across the whole probe line gave only 0.015
    /// of relief, and the brush's default radius then covered the entire
    /// ball — every probe moved together by 0.065 and the relief did not
    /// change at all, which says nothing about smoothing.
    static let seedBump: @MainActor @Sendable (ViewportState) -> Void = { state in
        state.activeTool = .sculpt
        state.sculptBrush = .standard
        state.brushStrength = 1
        state.brushSize = 0.8
        for _ in 0..<3 { // build it up; one tap is a dimple, not a bump
            state.pencilBegan(at: BrushFixture.centerTap[0], pressure: 1)
            state.pencilEnded(at: BrushFixture.centerTap[0])
        }
    }

    /// Clay that carries DETAIL across the whole probe line, which is what a
    /// regional brush's sampled region actually has to reproduce.
    ///
    /// `seedBump` piles three taps on ONE spot, so four of the five probes
    /// still sit on plain ball — the sampled region is mostly smooth and the
    /// seam stays benign. This lays a ridge of separate bumps along the probe
    /// line instead, so every probe has detail under it and a swap that loses
    /// the region has nowhere to hide.
    static let seedDetailedRidge: @MainActor @Sendable (ViewportState) -> Void = { state in
        state.activeTool = .sculpt
        state.sculptBrush = .standard
        state.brushStrength = 1
        state.brushSize = 0.35
        for point in BrushFixture.probePoints {
            for _ in 0..<2 { // one tap is a dimple, not a feature
                state.pencilBegan(at: point, pressure: 1)
                state.pencilEnded(at: point)
            }
        }
    }

    /// Extract consumes a freeze that already exists, so the fixture paints
    /// one. Straight through the engine rather than the freeze TOOL, because
    /// the tool path has an open question of its own (add-smooth-and-extract
    /// task 4.7) and this fixture is about Extract.
    static let seedFrozenPatch: @MainActor @Sendable (ViewportState) -> Void = { state in
        guard let ray = state.ray(through: BrushFixture.centerTap[0]),
              let hit = state.engine.raycast(origin: ray.origin,
                                             direction: ray.direction) else { return }
        state.engine.maskPaint(at: hit.position, radius: 0.18, erase: false,
                               voxelContext: false)
    }

    /// Voxel verbs other than `place` need cells to act on, so they seed a
    /// blob first and then switch to the verb under test.
    private static let seedVoxels: @MainActor @Sendable (ViewportState) -> Void = { state in
        state.voxelVerb = .place
        for point in BrushFixture.centerDrag {
            state.pencilBegan(at: point, pressure: 0.8)
            state.pencilEnded(at: point)
        }
    }

    /// A ring of stamps with an unfilled middle — a cavity for the verb
    /// whose whole job is closing one.
    private static let seedRingWithCavity: @MainActor @Sendable (ViewportState) -> Void = { state in
        state.voxelVerb = .place
        for step in 0..<12 {
            let angle = Double(step) / 12 * 2 * .pi
            let point = CGPoint(x: 400 + 34 * cos(angle), y: 300 + 34 * sin(angle))
            state.pencilBegan(at: point, pressure: 0.8)
            state.pencilEnded(at: point)
        }
    }

    static let voxelFixtures: [BrushFixture] = [
        BrushFixture("place", isVoxel: true, select: { $0.voxelVerb = .place },
                     effect: .addsMaterial),
        BrushFixture("smooth", isVoxel: true, seed: seedVoxels,
                     select: { $0.voxelVerb = .smooth }, effect: .reshapes),
        BrushFixture("inflate", isVoxel: true, seed: seedVoxels,
                     select: { $0.voxelVerb = .inflate }, effect: .addsMaterial),
        BrushFixture("deflate", isVoxel: true, seed: seedVoxels,
                     select: { $0.voxelVerb = .deflate }, effect: .removesMaterial),
        BrushFixture("flatten", isVoxel: true, seed: seedVoxels,
                     select: { $0.voxelVerb = .flatten }, effect: .reshapes),
        BrushFixture("scrape", isVoxel: true, seed: seedVoxels,
                     select: { $0.voxelVerb = .scrape }, effect: .reshapes),
        BrushFixture("pinch", isVoxel: true, seed: seedVoxels,
                     select: { $0.voxelVerb = .pinch }, effect: .reshapes),
        BrushFixture("magnify", isVoxel: true, seed: seedVoxels,
                     select: { $0.voxelVerb = .magnify }, effect: .reshapes),
        BrushFixture("grab", isVoxel: true, seed: seedVoxels,
                     select: { $0.voxelVerb = .grab },
                     stroke: BrushFixture.longDrag, effect: .reshapes),
        BrushFixture("smudge", isVoxel: true, seed: seedVoxels,
                     select: { $0.voxelVerb = .smudge }, effect: .reshapes),
        // fill_cavities fills CAVITIES: seeding a solid blob and asking it
        // to work would be testing nothing. This seeds a ring with a hole
        // in the middle, which is the shape the verb exists for.
        BrushFixture("fill", isVoxel: true, seed: seedRingWithCavity,
                     select: { $0.voxelVerb = .fill },
                     stroke: BrushFixture.centerTap, effect: .addsMaterial),
    ]

    static var all: [BrushFixture] { sdfFixtures + voxelFixtures }

    // MARK: Runner

    /// Fresh state with the default seeded document, sized like the iPad
    /// viewport the fixtures' screen coordinates assume.
    static func makeState(voxel: Bool) -> ViewportState {
        let state = ViewportState()
        state.viewportSize = CGSize(width: 800, height: 600)
        if voxel { state.setMode(.voxel) }
        state.activate(.sculpt, announce: false)
        return state
    }

    static func measure(_ state: ViewportState) -> BrushMeasurement {
        let distances: [Float?] = BrushFixture.probePoints.map { point in
            guard let ray = state.ray(through: point),
                  let hit = state.engine.raycast(origin: ray.origin,
                                                 direction: ray.direction)
            else { return nil }
            return simd_distance(ray.origin, hit.position)
        }
        let positions = state.engine.voxelPositions
        // Sum of coordinates: catches a verb that moved cells without
        // changing how many there are.
        let checksum = positions.reduce(0.0) { $0 + Double($1) }
        return BrushMeasurement(surfaceDistances: distances,
                                voxelVertexCount: positions.count,
                                voxelChecksum: checksum)
    }

    static func drive(_ state: ViewportState, along stroke: [CGPoint]) {
        guard let first = stroke.first else { return }
        state.pencilBegan(at: first, pressure: 0.7)
        for point in stroke.dropFirst() {
            state.pencilMoved(to: point, pressure: 0.7)
        }
        state.pencilEnded(at: stroke.last ?? first)
    }

    /// Seed → select → stroke → settle → measure. Returns the before/after
    /// pair and the state, so the caller can assert and capture.
    static func run(_ fixture: BrushFixture) async
        -> (state: ViewportState, before: BrushMeasurement, after: BrushMeasurement, settled: Bool) {
        let state = makeState(voxel: fixture.isVoxel)
        fixture.seed?(state)
        _ = await state.engine.quiesce()
        fixture.select(state)
        if let strength = fixture.strength { state.brushStrength = strength }
        let before = measure(state)
        drive(state, along: fixture.stroke)
        let settled = await state.engine.quiesce()
        return (state, before, measure(state), settled)
    }

    /// The worst disagreement between the BAKED field and the document, over
    /// the cells the bake covers, or nil when there is no cache to check.
    ///
    /// Every other probe in this file reads the DOCUMENT — `engine.raycast` is
    /// `clay_raycast(doc,…)` and `evalDistance` is `clay_eval_points(doc,…)`.
    /// The document is rebuilt correctly by every edit, so those probes are
    /// blind to a bake that is stale or scoped too small. The artist does not
    /// look at the document: the renderer samples this cache. A regional verb
    /// that leaves part of its footprint un-rebaked shows up here and nowhere
    /// else in the suite.
    static func worstBakeError(_ state: ViewportState) -> (error: Float,
                                                           at: SIMD3<Float>)? {
        guard let cache = state.engine.fieldCache else { return nil }
        let dims = cache.dims
        var worst: Float = 0
        var worstAt = SIMD3<Float>.zero
        // Stride rather than every cell: a stale region is a contiguous block
        // of cells, never a single one, so sampling catches it and a full
        // 192³ sweep through the C ABI would dominate the suite's runtime.
        let step = 4
        for z in stride(from: 0, to: Int(dims.z), by: step) {
            for y in stride(from: 0, to: Int(dims.y), by: step) {
                for x in stride(from: 0, to: Int(dims.x), by: step) {
                    let cell = SIMD3<Float>(Float(x) / Float(max(dims.x - 1, 1)),
                                            Float(y) / Float(max(dims.y - 1, 1)),
                                            Float(z) / Float(max(dims.z - 1, 1)))
                    let world = cache.origin + cell * cache.extent
                    let baked = Float(cache.distances[(z * Int(dims.y) + y)
                                                      * Int(dims.x) + x])
                    let document = state.engine.evalDistance(at: world)
                    guard document.isFinite else { continue }
                    // Only where either side is near the surface: the narrow
                    // band is what the bake stores and what the renderer
                    // marches; far cells are clamped and disagree by design.
                    guard min(abs(baked), abs(document)) < 0.25 else { continue }
                    let error = abs(baked - document)
                    if error > worst { worst = error; worstAt = world }
                }
            }
        }
        return (worst, worstAt)
    }

    /// How far the baked field may depart from the document before the bake
    /// is considered stale rather than merely quantized.
    ///
    /// Calibrated, not guessed. With a healthy bake the four regional verbs
    /// report 0.0332–0.0378 — fp16 storage plus grid quantization. With the
    /// bake deliberately scoped to a quarter of its region they report
    /// 0.8404–0.9248. This sits an order of magnitude clear of the noise and
    /// well under the defect.
    static let bakeErrorThreshold: Float = 0.15

    /// Asserts the field the RENDERER samples still matches the document.
    static func assertBakeIsFaithful(_ fixture: BrushFixture,
                                     _ state: ViewportState,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        guard let worst = worstBakeError(state) else {
            return XCTFail("\(fixture.name): no field cache to check — the "
                           + "bake guard cannot pass by finding nothing",
                           file: file, line: line)
        }
        XCTAssertLessThan(
            worst.error, bakeErrorThreshold,
            "\(fixture.name): the BAKE disagrees with the document by "
            + "\(worst.error) at \(worst.at). The document is correct and the "
            + "render is not, which is what the artist sees as a crater. "
            + "Healthy is ~0.035; a quarter-scoped bake gives ~0.9",
            file: file, line: line)
    }

    /// How far a probe may move before the surface is considered TORN rather
    /// than sculpted. Matches `RegionalSwapTests`: these brushes act with a
    /// small region, and the observed tearing moved probes by more than half
    /// a world unit.
    static let tearThreshold: Float = 0.3

    /// Asserts the brush did not tear the surface: no probe jumped further
    /// than a brush plausibly moves it, and no probe that had surface under
    /// it lost that surface entirely.
    ///
    /// Separate from `assertEffect` because the effect claims cannot express
    /// this — `.reshapes` is satisfied by any large movement, and a tear IS a
    /// large movement.
    static func assertNoTear(_ fixture: BrushFixture,
                             before: BrushMeasurement, after: BrushMeasurement,
                             file: StaticString = #filePath, line: UInt = #line) {
        for (index, pair) in zip(before.surfaceDistances,
                                 after.surfaceDistances).enumerated() {
            switch pair {
            case (.some(let start), .some(let end)):
                XCTAssertLessThan(
                    abs(start - end), tearThreshold,
                    "\(fixture.name) tore the surface at probe \(index): "
                    + "\(start) -> \(end). This is the regional swap losing "
                    + "the region it sampled, not the brush sculpting. "
                    + "before \(before.surfaceDistances) "
                    + "after \(after.surfaceDistances)",
                    file: file, line: line)
            case (.some, .none):
                XCTFail("\(fixture.name) removed the surface entirely at probe "
                        + "\(index) — a hole through the object. "
                        + "before \(before.surfaceDistances) "
                        + "after \(after.surfaceDistances)",
                        file: file, line: line)
            default:
                break // no surface there to begin with
            }
        }
    }

    /// Asserts the brush did what it claims. Failures name the brush, so a
    /// red suite reads as "carve stopped cutting", not "assertion failed".
    static func assertEffect(_ fixture: BrushFixture,
                             before: BrushMeasurement, after: BrushMeasurement,
                             file: StaticString = #filePath, line: UInt = #line) {
        if fixture.isVoxel {
            let grew = after.voxelVertexCount > before.voxelVertexCount
            let shrank = after.voxelVertexCount < before.voxelVertexCount
            let moved = after.voxelChecksum != before.voxelChecksum
                || after.voxelVertexCount != before.voxelVertexCount
            switch fixture.effect {
            case .addsMaterial:
                XCTAssertTrue(grew || moved,
                              "voxel \(fixture.name) added nothing",
                              file: file, line: line)
            case .removesMaterial:
                XCTAssertTrue(shrank || moved,
                              "voxel \(fixture.name) removed nothing",
                              file: file, line: line)
            case .reshapes, .flattens, .smooths:
                // Voxel measurement is a vertex count and a checksum, not
                // surface distances, so there is no probe line to fit and
                // planarity cannot be judged here. `.flattens` degrades to
                // "the mesh changed" for voxel verbs — stated rather than
                // silently implied.
                XCTAssertTrue(moved, "voxel \(fixture.name) left the mesh untouched",
                              file: file, line: line)
            }
            return
        }

        // Nearer the camera means more material at that probe.
        let deltas = zip(before.surfaceDistances, after.surfaceDistances)
            .compactMap { start, end -> Float? in
                guard let start, let end else { return nil }
                return start - end
            }
        guard !deltas.isEmpty else {
            return XCTFail("\(fixture.name): no surface under any probe point",
                           file: file, line: line)
        }
        // Direction is about BULK movement, so the mean carries it; a
        // reshaping brush only has to move the surface somewhere, so the
        // largest movement carries that.
        let delta = fixture.effect == .reshapes || fixture.effect == .flattens
            || fixture.effect == .smooths
            ? (deltas.max(by: { abs($0) < abs($1) }) ?? 0)
            : deltas.reduce(0, +) / Float(deltas.count)
        switch fixture.effect {
        case .addsMaterial:
            XCTAssertGreaterThan(delta, fixture.minDelta,
                                 "\(fixture.name) did not raise the surface "
                                 + "(moved \(delta))", file: file, line: line)
        case .removesMaterial:
            XCTAssertLessThan(delta, -fixture.minDelta,
                              "\(fixture.name) did not cut into the surface "
                              + "(moved \(delta))", file: file, line: line)
        case .reshapes:
            XCTAssertGreaterThan(abs(delta), fixture.minDelta,
                                 "\(fixture.name) left the surface where it was "
                                 + "(moved \(delta))", file: file, line: line)
        case .smooths:
            // The peak is the probe NEAREST the camera, so a peak coming
            // down means that nearest distance grows.
            guard let peakBefore = before.surfaceDistances.compactMap({ $0 }).min(),
                  let peakAfter = after.surfaceDistances.compactMap({ $0 }).min()
            else {
                return XCTFail("\(fixture.name): no surface under the probes",
                               file: file, line: line)
            }
            XCTAssertGreaterThan(peakAfter - peakBefore, fixture.minDelta,
                                 "\(fixture.name) did not bring the peak down "
                                 + "(peak moved \(peakAfter - peakBefore))",
                                 file: file, line: line)
        case .flattens:
            XCTAssertGreaterThan(abs(delta), fixture.minDelta,
                                 "\(fixture.name) left the surface where it was "
                                 + "(moved \(delta))", file: file, line: line)
            guard let curveBefore = BrushMatrix.planarityResidual(before.surfaceDistances),
                  let curveAfter = BrushMatrix.planarityResidual(after.surfaceDistances)
            else {
                return XCTFail("\(fixture.name): not enough surface under the "
                               + "probe line to judge planarity",
                               file: file, line: line)
            }
            // A facet is the claim, so the probed span must get STRAIGHTER.
            // Relative, because the absolute residual depends on how much
            // of the sphere the probe line spans.
            XCTAssertLessThan(curveAfter, curveBefore * 0.7,
                              "\(fixture.name) moved the surface but did not "
                              + "flatten it: residual \(curveBefore) -> "
                              + "\(curveAfter). A flatten that leaves the "
                              + "region as curved as it found it has not done "
                              + "its job", file: file, line: line)
        }
    }

    /// How far the probed surface departs from a straight line, as RMS
    /// residual about a least-squares fit through the camera-to-surface
    /// distances. A sphere's probe line is curved and scores high; a real
    /// facet is straight and scores near zero.
    ///
    /// This reuses the probe points the matrix already samples — the
    /// measurement was always available, it just was not being asked for.
    /// `nil` when fewer than three points found surface, since two points
    /// define a line and cannot disagree with one.
    static func planarityResidual(_ distances: [Float?]) -> Float? {
        let samples = distances.enumerated().compactMap { index, distance -> (Float, Float)? in
            guard let distance else { return nil }
            return (Float(index), distance)
        }
        guard samples.count >= 3 else { return nil }
        let n = Float(samples.count)
        let meanX = samples.reduce(0) { $0 + $1.0 } / n
        let meanY = samples.reduce(0) { $0 + $1.1 } / n
        let varianceX = samples.reduce(0) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
        guard varianceX > 0 else { return nil }
        let covariance = samples.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let slope = covariance / varianceX
        let intercept = meanY - slope * meanX
        let squared = samples.reduce(Float(0)) { total, sample in
            let residual = sample.1 - (slope * sample.0 + intercept)
            return total + residual * residual
        }
        return (squared / n).squareRoot()
    }
}
