import XCTest

/// End-to-end through real touch synthesis: launch → tap the viewport →
/// a shape lands in the document (visible in the inspector's counter).
///
/// The finger-tap-as-pencil shim exists only in simulator builds (on
/// device, fingers are strictly camera), so the tap test skips itself on
/// hardware; the launch smoke test runs everywhere.
final class SculptUITests: XCTestCase {

    private var isSimulator: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
    }

    // @MainActor on the helpers, not just the tests: XCUIApplication and
    // XCUIElement are main-actor isolated, and a nonisolated helper that
    // touches them compiles on Xcode 26 but not on the older Xcode CI
    // runs — which is how this reached main without anyone seeing it.
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // Suppress the first-launch gestures sheet via the defaults
        // argument domain; start from a fresh document, not the autosave.
        app.launchArguments += ["-hasSeenGesturesSheet", "YES", "-resetDocument"]
        app.launch()
        return app
    }

    @MainActor
    func testLaunchShowsShellAndSeededDocument() {
        let app = launch()
        XCTAssertTrue(app.buttons["documentsButton"].waitForExistence(timeout: 10))
        let count = app.staticTexts["shapeCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "1", "the seeded base ball")
    }

    @MainActor
    func testRadialSculptRendersAndAppSurvives() throws {
        try XCTSkipUnless(isSimulator, "finger-tap sculpt shim is simulator-only")
        let app = launch()
        let count = app.staticTexts["shapeCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))

        // Arm radial through the real UI, then sculpt twice; each tap makes
        // the renderer trace the ring for many frames. A GPU/render fault
        // here kills the app and fails the test.
        app.buttons["Radial symmetry"].tap()
        XCTAssertTrue(app.staticTexts["radialCount"].waitForExistence(timeout: 3),
                      "radial armed — stepper visible")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.55)).tap()
        XCTAssertTrue(count.wait(for: \.label, toEqual: "2", timeout: 5),
                      "sculpt tap adds — and the Radial button tap did NOT (chrome swallow)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45)).tap()
        XCTAssertTrue(count.wait(for: \.label, toEqual: "3", timeout: 5))

        // Bump the count and combine with mirror; give the bake time to land.
        app.buttons["More copies"].tap()
        app.buttons["Mirror X"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertTrue(count.wait(for: \.label, toEqual: "4", timeout: 6),
                      "stepper/mirror button taps must not sculpt (chrome swallow)")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.buttons["documentsButton"].exists,
                      "app is alive after radial+mirror renders and bakes")
    }

    @MainActor
    func testVoxelModePlacesCubes() throws {
        try XCTSkipUnless(isSimulator, "finger-tap shim is simulator-only")
        let app = launch()
        XCTAssertTrue(app.staticTexts["shapeCount"].waitForExistence(timeout: 10))
        app.buttons["Voxels"].tap()

        let voxels = app.staticTexts["voxelCount"]
        XCTAssertTrue(voxels.waitForExistence(timeout: 5))
        XCTAssertEqual(voxels.label, "0")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.75)).tap()
        XCTAssertTrue(waitForNonZero(voxels, timeout: 5), "tap stamped voxels")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.72)).tap()
        XCTAssertTrue(app.buttons["documentsButton"].exists, "raster pass renders, app alive")
        Thread.sleep(forTimeInterval: 2.6) // let autosave persist the grid
    }

    @MainActor
    private func waitForNonZero(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = Int(element.label), value > 0 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    @MainActor
    func testExportFlowProducesAShareableMesh() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["shapeCount"].waitForExistence(timeout: 10))
        app.buttons["exportButton"].tap()
        let run = app.buttons["exportRun"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        run.tap()
        XCTAssertTrue(app.otherElements["exportStats"].waitForExistence(timeout: 30)
                        || app.staticTexts["exportStats"].waitForExistence(timeout: 5),
                      "mesh stats appear after the background export")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Share'"))
                        .firstMatch.exists, "share affordance offered")
    }

    @MainActor
    func testShapeToolBarPlacesPrimitives() throws {
        try XCTSkipUnless(isSimulator, "finger-tap shim is simulator-only")
        let app = launch()
        let count = app.staticTexts["shapeCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))

        app.buttons["Shape"].tap() // tool rail
        XCTAssertTrue(app.buttons["Shape Box"].waitForExistence(timeout: 3),
                      "shape bar appears for the Shape tool")
        app.buttons["Shape Box"].tap()
        app.buttons["Shape Torus"].tap()
        XCTAssertEqual(count.label, "1",
                       "bar taps are chrome — they must not place shapes")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        XCTAssertTrue(count.wait(for: \.label, toEqual: "2", timeout: 5),
                      "viewport tap placed the picked primitive")
        app.buttons["Undo"].tap()
        XCTAssertTrue(count.wait(for: \.label, toEqual: "1", timeout: 5),
                      "placement undoes as one step")
    }

    @MainActor
    func testViewportStaysLiveWhileGizmoAndModePickerAreShowing() throws {
        // Device-found regression: the gizmo mode picker registered a
        // FULL-SCREEN chrome rect (the .position wrapper's frame), so any
        // active selection swallowed every viewport touch. This walks the
        // real touch router with a selection + picker on screen.
        try XCTSkipUnless(isSimulator, "finger-tap shim is simulator-only")
        let app = launch()
        let count = app.staticTexts["shapeCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))

        // Select the seeded ball → gizmo + mode picker appear.
        app.buttons["Select"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Gizmo move"].waitForExistence(timeout: 4),
                      "selection shows the mode picker")

        // With the picker on screen, the viewport must still take edits:
        // switch to Sculpt and tap — a shape must land.
        app.buttons["Sculpt"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.68)).tap()
        XCTAssertTrue(count.wait(for: \.label, toEqual: "2", timeout: 5),
                      "viewport touches must not be swallowed while the gizmo shows")

        // The picker itself still works as chrome.
        app.buttons["Gizmo scale"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3)).tap()
        XCTAssertTrue(count.wait(for: \.label, toEqual: "3", timeout: 5),
                      "mode switch is chrome; the next viewport tap still sculpts")
    }

    @MainActor
    func testTapOnViewportAddsAShape() throws {
        try XCTSkipUnless(isSimulator, "finger-tap sculpt shim is simulator-only")
        let app = launch()
        let count = app.staticTexts["shapeCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertEqual(count.label, "1")

        // Tap the middle of the viewport (rail left, inspector right).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.55)).tap()

        let incremented = count.wait(for: \.label, toEqual: "2", timeout: 5)
        XCTAssertTrue(incremented, "the tap raycast the document and placed a sphere")

        // Undo via the tool rail unwinds it.
        app.buttons["Undo"].tap()
        XCTAssertTrue(count.wait(for: \.label, toEqual: "1", timeout: 5))
    }
}

private extension XCUIElement {
    func wait<V: Equatable>(for keyPath: KeyPath<XCUIElement, V>, toEqual value: V,
                            timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if self[keyPath: keyPath] == value { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return self[keyPath: keyPath] == value
    }
}
