// FILE: SettingsReconnectHintFormatter.swift
// Purpose: Supplies user-facing reconnect guidance for Settings connection UI.
// Layer: View helper
// Exports: SettingsReconnectHintFormatter
// Depends on: Foundation

import Foundation

enum SettingsReconnectHintFormatter {
    static func hintText() -> String {
        "Auth mismatch can be fixed and retried from this screen. Session closed/replaced errors still require scanning a new QR code."
    }
}
