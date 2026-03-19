// FILE: TurnComposerMetaMapperTests.swift
// Purpose: Verifies menu-mapper helpers keep picker selection values valid.
// Layer: Unit Test
// Exports: TurnComposerMetaMapperTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class TurnComposerMetaMapperTests: XCTestCase {
    func testSanitizedPickerSelectionFallsBackWhenSelectionMissing() {
        let selection = TurnComposerMetaMapper.sanitizedPickerSelection(
            selectedValue: nil,
            availableValues: ["low", "high"],
            fallbackValue: "auto"
        )

        XCTAssertEqual(selection, "auto")
    }

    func testSanitizedPickerSelectionFallsBackWhenSelectionUnsupported() {
        let selection = TurnComposerMetaMapper.sanitizedPickerSelection(
            selectedValue: "medium",
            availableValues: ["low", "high"],
            fallbackValue: "auto"
        )

        XCTAssertEqual(selection, "auto")
    }

    func testSanitizedPickerSelectionKeepsSupportedSelection() {
        let selection = TurnComposerMetaMapper.sanitizedPickerSelection(
            selectedValue: "medium",
            availableValues: ["low", "medium", "high"],
            fallbackValue: "auto"
        )

        XCTAssertEqual(selection, "medium")
    }

    func testTurnErrorBannerPolicyHidesNilAndBlankMessage() {
        XCTAssertFalse(TurnErrorBannerCopyPolicy.shouldShowBanner(nil))
        XCTAssertFalse(TurnErrorBannerCopyPolicy.shouldShowBanner("   \n"))
    }

    func testTurnErrorBannerPolicyShowsNonEmptyMessage() {
        XCTAssertTrue(TurnErrorBannerCopyPolicy.shouldShowBanner("Network timeout"))
    }
}
