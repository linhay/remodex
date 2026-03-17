// FILE: SettingsConnectionDisplayResolver.swift
// Purpose: Resolves which relay URL Settings should display as the current connection source.
// Layer: View helper
// Exports: SettingsConnectionDisplayResolver
// Depends on: Foundation

import Foundation

enum SettingsConnectionDisplayResolver {
    static func displayURL(
        isConnected: Bool,
        connectedServerIdentity: String?,
        selectedRelayBaseURL: String?,
        fallbackRelayURL: String?
    ) -> String? {
        if isConnected,
           let connectedServerIdentity = normalizedURL(connectedServerIdentity) {
            return connectedServerIdentity
        }

        if let selectedRelayBaseURL = normalizedURL(selectedRelayBaseURL) {
            return selectedRelayBaseURL
        }

        return normalizedURL(fallbackRelayURL)
    }

    private static func normalizedURL(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }
}
