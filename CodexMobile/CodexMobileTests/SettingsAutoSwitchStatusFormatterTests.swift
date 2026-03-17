// FILE: SettingsAutoSwitchStatusFormatterTests.swift
// Purpose: Verifies auto-switch status copy shown in Settings connection section.
// Layer: Unit Test
// Exports: SettingsAutoSwitchStatusFormatterTests
// Depends on: XCTest, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

final class SettingsAutoSwitchStatusFormatterTests: XCTestCase {
    func testStatusTextShowsFromToHostsAndLatency() {
        let record = CodexRelayAutoSwitchRecord(
            fromBaseURL: "wss://relay-a.example.com/relay",
            toBaseURL: "wss://relay-b.example.com/relay",
            latencyMs: 24,
            previousLatencyMs: 68,
            timestamp: Date(timeIntervalSince1970: 100)
        )

        let text = SettingsAutoSwitchStatusFormatter.statusText(
            record: record,
            now: Date(timeIntervalSince1970: 105)
        )

        XCTAssertTrue(text.contains("relay-a.example.com -> relay-b.example.com"))
        XCTAssertTrue(text.contains("24ms"))
        XCTAssertTrue(text.contains("5s 前"))
    }

    func testStatusTextFallsBackToSingleHostWhenFromMissing() {
        let record = CodexRelayAutoSwitchRecord(
            fromBaseURL: nil,
            toBaseURL: "ws://linhey.local:8788/relay",
            latencyMs: 18,
            previousLatencyMs: nil,
            timestamp: Date(timeIntervalSince1970: 200)
        )

        let text = SettingsAutoSwitchStatusFormatter.statusText(
            record: record,
            now: Date(timeIntervalSince1970: 201)
        )

        XCTAssertFalse(text.contains("->"))
        XCTAssertTrue(text.contains("linhey.local"))
        XCTAssertTrue(text.contains("刚刚"))
    }
}
