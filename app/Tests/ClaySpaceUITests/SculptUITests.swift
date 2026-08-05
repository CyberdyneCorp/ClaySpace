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

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // Suppress the first-launch gestures sheet via the defaults
        // argument domain.
        app.launchArguments += ["-hasSeenGesturesSheet", "YES"]
        app.launch()
        return app
    }

    @MainActor
    func testLaunchShowsShellAndSeededDocument() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["ClaySpace"].waitForExistence(timeout: 10))
        let count = app.staticTexts["shapeCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "1", "the seeded base ball")
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
