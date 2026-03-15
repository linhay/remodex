// FILE: ContentSettingsNavigationGateTests.swift
// Purpose: Verifies settings navigation route append gating.
// Layer: Unit Test
// Exports: ContentSettingsNavigationGateTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class ContentSettingsNavigationGateTests: XCTestCase {
    func testShowSettingsAppendsRouteWhenPathIsEmpty() {
        XCTAssertTrue(
            ContentSettingsNavigationGate.shouldAppendSettingsRoute(
                showSettings: true,
                navigationPathIsEmpty: true
            )
        )
    }

    func testRepeatedShowSettingsDoesNotAppendWhenPathIsNotEmpty() {
        XCTAssertFalse(
            ContentSettingsNavigationGate.shouldAppendSettingsRoute(
                showSettings: true,
                navigationPathIsEmpty: false
            )
        )
    }

    func testShowSettingsCanAppendAgainAfterPathBecomesEmpty() {
        XCTAssertTrue(
            ContentSettingsNavigationGate.shouldAppendSettingsRoute(
                showSettings: true,
                navigationPathIsEmpty: true
            )
        )
    }
}
