// FILE: QRScannerCameraSessionPolicyTests.swift
// Purpose: Verifies QR camera session activation rules.
// Layer: Unit Test
// Exports: QRScannerCameraSessionPolicyTests
// Depends on: XCTest, SwiftUI, CodexMobile

import SwiftUI
import XCTest
@testable import CodexMobile

final class QRScannerCameraSessionPolicyTests: XCTestCase {
    func testRunsOnlyWhenPermissionGrantedManualEntryHiddenAndSceneActive() {
        XCTAssertTrue(
            QRScannerCameraSessionPolicy.shouldRunCameraSession(
                hasCameraPermission: true,
                isShowingManualEntry: false,
                scenePhase: .active
            )
        )
    }

    func testDoesNotRunWhenManualEntrySheetIsShown() {
        XCTAssertFalse(
            QRScannerCameraSessionPolicy.shouldRunCameraSession(
                hasCameraPermission: true,
                isShowingManualEntry: true,
                scenePhase: .active
            )
        )
    }

    func testDoesNotRunWhenAppIsNotActive() {
        XCTAssertFalse(
            QRScannerCameraSessionPolicy.shouldRunCameraSession(
                hasCameraPermission: true,
                isShowingManualEntry: false,
                scenePhase: .background
            )
        )
        XCTAssertFalse(
            QRScannerCameraSessionPolicy.shouldRunCameraSession(
                hasCameraPermission: true,
                isShowingManualEntry: false,
                scenePhase: .inactive
            )
        )
    }
}
