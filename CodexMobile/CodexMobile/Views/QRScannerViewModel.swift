// FILE: QRScannerViewModel.swift
// Purpose: Owns QRScannerView local state and lightweight input helpers.
// Layer: ViewModel
// Exports: QRScannerViewModel
// Depends on: Foundation, Observation

import Foundation
import Observation

@Observable
final class QRScannerViewModel {
    var scannerError: String?
    var hasCameraPermission = false
    var isCheckingPermission = true
    var isShowingManualEntry = false
    var manualEntryText = ""

    var canSubmitManualEntry: Bool {
        !manualEntryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func clearManualEntry() {
        manualEntryText = ""
    }

    func dismissManualEntry() {
        isShowingManualEntry = false
        clearManualEntry()
    }
}
