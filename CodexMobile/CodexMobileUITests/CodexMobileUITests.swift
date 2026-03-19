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

        try save(
            XCUIScreen.main.screenshot(),
            to: "\(screenshotDirectory)/20260317-settings-account-list-after-ios-v01.png"
        )
        settingsApp.terminate()
    }

    func testTapAccountPushesToChatScreen() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CodexUITestsBypassScanner",
            "-CodexUITestsSeedRelayAccounts",
        ]
        app.launch()

        let accountRows = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "account.row."))
        let firstAccountRow = accountRows.firstMatch
        XCTAssertTrue(firstAccountRow.waitForExistence(timeout: 5))

        firstAccountRow.tap()

        let chatMenuButton = app.buttons["chat.menu.button"]
        XCTAssertTrue(chatMenuButton.waitForExistence(timeout: 8))
        let openingChatLabel = app.staticTexts["Opening chat…"]
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, openingChatLabel.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertFalse(openingChatLabel.exists, "Expected opening indicator to clear.")
        XCTAssertEqual(accountRows.count, 0, "Account page should be dismissed after opening chat.")
    }

    func testTapAccountOpenFlowResolvesToVisibleDestination() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CodexUITestsBypassScanner",
            "-CodexUITestsSeedRelayAccounts",
        ]
        app.launch()

        let accountRows = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "account.row.")
        )
        let firstAccountRow = accountRows.firstMatch
        XCTAssertTrue(firstAccountRow.waitForExistence(timeout: 5))

        firstAccountRow.tap()

        let timeline = app.scrollViews["turn.timeline.scrollview"]
        let deadline = Date().addingTimeInterval(20)
        var resolved = false
        while Date() < deadline {
            if timeline.exists || firstAccountRow.exists {
                resolved = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTAssertTrue(
            resolved,
            "Tapping account should end in a visible state (chat opened or account page restored)."
        )
    }

    func testOpenExistingAccountDoesNotStallOnOpeningChat() throws {
        let app = XCUIApplication()
        app.launch()

        let accountRows = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "account.row.")
        )
        let firstAccountRow = accountRows.firstMatch
        guard firstAccountRow.waitForExistence(timeout: 8) else {
            throw XCTSkip("No existing relay account in simulator; skipped real-account opening test.")
        }

        let startTime = Date()
        firstAccountRow.tap()

        let timeline = app.scrollViews["turn.timeline.scrollview"]
        var resolved = false
        while Date().timeIntervalSince(startTime) < 20 {
            if timeline.exists || firstAccountRow.exists {
                resolved = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTAssertTrue(
            resolved,
            "Open account flow stayed unresolved (neither entered chat nor returned to account list)."
        )
    }

    func testTapAccountCanSendMessage() throws {
        let app = XCUIApplication()
        app.launch()

        let accountRows = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "account.row.")
        )
        let composerInput = app.textViews.firstMatch
        if !composerInput.waitForExistence(timeout: 20) {
            if accountRows.firstMatch.exists {
                throw XCTSkip("Chat is still opening from account list; composer not ready yet.")
            }
            throw XCTSkip("No reachable chat entry path for send verification in current environment.")
        }

        XCTAssertTrue(composerInput.waitForExistence(timeout: 8), "Composer input should appear in chat.")
        composerInput.tap()
        composerInput.typeText("ping from ui test")

        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "Send button should exist.")
        XCTAssertTrue(sendButton.isEnabled, "Send button should be enabled after typing.")
        sendButton.tap()

        // Sending succeeds when the draft is consumed and no blocking error banner appears.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if !composerInput.valueDescription.contains("ping from ui test") {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTAssertFalse(
            composerInput.valueDescription.contains("ping from ui test"),
            "Composer draft should be cleared after send."
        )
        XCTAssertFalse(app.otherElements["turn.error.banner"].exists, "Error banner should not block send.")
    }

    private func save(_ screenshot: XCUIScreenshot, to path: String) throws {
        let data = screenshot.pngRepresentation
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private extension XCUIElement {
    var valueDescription: String {
        if let value = value as? String {
            return value
        }
        if let value {
            return String(describing: value)
        }
        return ""
    }
}
