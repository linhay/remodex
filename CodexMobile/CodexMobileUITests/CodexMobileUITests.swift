// FILE: CodexMobileUITests.swift
// Purpose: Measures timeline scrolling and streaming append performance on deterministic fixtures.
// Layer: UI Test
// Exports: CodexMobileUITests
// Depends on: XCTest

import XCTest

final class CodexMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTurnTimelineScrollingPerformance() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CodexUITestsFixture",
            "-CodexUITestsMessageCount", "1200",
        ]
        app.launch()

        let timeline = app.scrollViews["turn.timeline.scrollview"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))

        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric]) {
            timeline.swipeUp(velocity: .fast)
            timeline.swipeUp(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
        }
    }

    func testTurnStreamingAppendPerformance() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CodexUITestsFixture",
            "-CodexUITestsMessageCount", "500",
            "-CodexUITestsAutoStream",
        ]
        app.launch()

        XCTAssertTrue(app.scrollViews["turn.timeline.scrollview"].waitForExistence(timeout: 5))

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            // Wait window where fixture appends streaming chunks into the active timeline.
            RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        }
    }

    func testCaptureSettingsAccountListScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CodexUITestsFixture",
            "-CodexUITestsMessageCount", "40",
            "-CodexUITestsBypassScanner",
        ]
        app.launch()

        let screenshotDirectory = "/Users/linhey/Desktop/Dockers/remodex/screenshots/20260317/settings"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: screenshotDirectory),
            withIntermediateDirectories: true
        )

        try save(
            XCUIScreen.main.screenshot(),
            to: "\(screenshotDirectory)/20260317-settings-account-list-before-ios-v01.png"
        )
        app.terminate()

        let settingsApp = XCUIApplication()
        settingsApp.launchArguments += [
            "-CodexUITestsFixture",
            "-CodexUITestsMessageCount", "40",
            "-CodexUITestsBypassScanner",
            "-CodexUITestsSeedRelayAccounts",
            "-CodexUITestsOpenSettings",
        ]
        settingsApp.launch()

        RunLoop.current.run(until: Date().addingTimeInterval(2))
        settingsApp.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        try save(
            XCUIScreen.main.screenshot(),
            to: "\(screenshotDirectory)/20260317-settings-account-list-after-ios-v01.png"
        )
        settingsApp.terminate()
    }

    private func save(_ screenshot: XCUIScreenshot, to path: String) throws {
        let data = screenshot.pngRepresentation
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
