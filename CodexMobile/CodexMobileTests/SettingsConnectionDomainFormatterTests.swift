// FILE: SettingsConnectionDomainFormatterTests.swift
// Purpose: Verifies relay domain extraction for Settings connection UI.
// Layer: Unit Test
// Exports: SettingsConnectionDomainFormatterTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class SettingsConnectionDomainFormatterTests: XCTestCase {
    func testDomainExtractedFromWebSocketURL() {
        XCTAssertEqual(
            SettingsConnectionDomainFormatter.domainLabel(from: "wss://relay.example.com/session"),
            "relay.example.com"
        )
    }

    func testDomainExtractedFromURLWithPort() {
        XCTAssertEqual(
            SettingsConnectionDomainFormatter.domainLabel(from: "https://localhost:8080/ws"),
            "localhost"
        )
    }

    func testInvalidOrEmptyURLFallsBackToNotSet() {
        XCTAssertEqual(SettingsConnectionDomainFormatter.domainLabel(from: nil), "not set")
        XCTAssertEqual(SettingsConnectionDomainFormatter.domainLabel(from: ""), "not set")
        XCTAssertEqual(SettingsConnectionDomainFormatter.domainLabel(from: "not-a-url"), "not set")
    }
}
