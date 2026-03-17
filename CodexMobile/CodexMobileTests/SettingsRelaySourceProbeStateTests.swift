// FILE: SettingsRelaySourceProbeStateTests.swift
// Purpose: Verifies probe-state mapping for relay source lists.
// Layer: Unit Test
// Exports: SettingsRelaySourceProbeStateTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class SettingsRelaySourceProbeStateTests: XCTestCase {
    func testProbingStatesUsesEverySourceAsKey() {
        let sources = [
            "wss://relay.section.trade/relay",
            "ws://linhey.local:8788/relay",
        ]

        let states = RelaySourceProbeState.probingStates(for: sources)

        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states["wss://relay.section.trade/relay"], .probing)
        XCTAssertEqual(states["ws://linhey.local:8788/relay"], .probing)
    }

    func testProbingStatesReturnsEmptyForNoSources() {
        let states = RelaySourceProbeState.probingStates(for: [])

        XCTAssertTrue(states.isEmpty)
    }
}
