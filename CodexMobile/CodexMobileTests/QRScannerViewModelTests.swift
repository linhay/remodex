// FILE: QRScannerViewModelTests.swift
// Purpose: Verifies QR scanner view-model state helpers.
// Layer: Unit Test
// Exports: QRScannerViewModelTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class QRScannerViewModelTests: XCTestCase {
    private static var retainedViewModels: [QRScannerViewModel] = []

    func testCanSubmitManualEntryRequiresNonWhitespaceInput() {
        let viewModel = QRScannerViewModel()
        Self.retainedViewModels.append(viewModel)

        viewModel.manualEntryText = "   "
        XCTAssertFalse(viewModel.canSubmitManualEntry)

        viewModel.manualEntryText = "{\"session_id\":\"abc\"}"
        XCTAssertTrue(viewModel.canSubmitManualEntry)
    }

    func testDismissManualEntryResetsSheetStateAndInput() {
        let viewModel = QRScannerViewModel()
        Self.retainedViewModels.append(viewModel)
        viewModel.isShowingManualEntry = true
        viewModel.manualEntryText = "payload"

        viewModel.dismissManualEntry()

        XCTAssertFalse(viewModel.isShowingManualEntry)
        XCTAssertEqual(viewModel.manualEntryText, "")
    }
}
