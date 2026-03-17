// FILE: SettingsConnectionDisplayResolverTests.swift
// Purpose: Verifies Settings connection display prefers the actual connected source over saved defaults.
// Layer: Unit Test
// Exports: SettingsConnectionDisplayResolverTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class SettingsConnectionDisplayResolverTests: XCTestCase {
    func testConnectedStatePrefersActualConnectedSource() {
        let value = SettingsConnectionDisplayResolver.displayURL(
            isConnected: true,
            connectedServerIdentity: "ws://linhey.local:8788/relay/session-1",
            selectedRelayBaseURL: "ws://linhey.local:8788/relay",
            fallbackRelayURL: "wss://relay.section.trade/relay"
        )

        XCTAssertEqual(value, "ws://linhey.local:8788/relay/session-1")
    }

    func testDisconnectedStatePrefersSelectedRelayBaseURL() {
        let value = SettingsConnectionDisplayResolver.displayURL(
            isConnected: false,
            connectedServerIdentity: "wss://relay.section.trade:443/relay/session-1",
            selectedRelayBaseURL: "ws://linhey.local:8788/relay",
            fallbackRelayURL: "wss://relay.section.trade/relay"
        )

        XCTAssertEqual(value, "ws://linhey.local:8788/relay")
    }

    func testFallsBackToSavedRelayURLWhenNoSelectionExists() {
        let value = SettingsConnectionDisplayResolver.displayURL(
            isConnected: false,
            connectedServerIdentity: nil,
            selectedRelayBaseURL: nil,
            fallbackRelayURL: "wss://relay.section.trade/relay"
        )

        XCTAssertEqual(value, "wss://relay.section.trade/relay")
    }
}
