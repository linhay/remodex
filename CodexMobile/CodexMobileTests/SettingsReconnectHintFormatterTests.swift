// FILE: SettingsReconnectHintFormatterTests.swift
// Purpose: Verifies reconnect hint copy used in Settings connection UI.
// Layer: Unit Test
// Exports: SettingsReconnectHintFormatterTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class SettingsReconnectHintFormatterTests: XCTestCase {
    func testHintMentionsRetryAndQRCodeFallback() {
        let hint = SettingsReconnectHintFormatter.hintText()

        XCTAssertTrue(hint.localizedCaseInsensitiveContains("retry"))
        XCTAssertTrue(hint.localizedCaseInsensitiveContains("QR"))
    }
}
