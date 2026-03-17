// FILE: SettingsLocalNetworkHintFormatterTests.swift
// Purpose: Verifies the local-relay-on-cellular hint is shown only when conditions match.
// Layer: Unit Test
// Exports: SettingsLocalNetworkHintFormatterTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class SettingsLocalNetworkHintFormatterTests: XCTestCase {
    func testHintShownWhenCellularAndLocalRelayReachable() {
        let hint = SettingsLocalNetworkHintFormatter.hintText(
            hasCellularInterface: true,
            hasReachableOrCurrentLocalRelay: true
        )

        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("local") == true)
    }

    func testHintHiddenWhenCellularOnlyWithoutLocalRelay() {
        let hint = SettingsLocalNetworkHintFormatter.hintText(
            hasCellularInterface: true,
            hasReachableOrCurrentLocalRelay: false
        )

        XCTAssertNil(hint)
    }

    func testHintHiddenWhenNoCellularInterface() {
        let hint = SettingsLocalNetworkHintFormatter.hintText(
            hasCellularInterface: false,
            hasReachableOrCurrentLocalRelay: true
        )

        XCTAssertNil(hint)
    }
}
