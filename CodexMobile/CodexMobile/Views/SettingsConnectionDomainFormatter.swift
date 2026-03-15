// FILE: SettingsConnectionDomainFormatter.swift
// Purpose: Extracts a human-readable relay domain label for Settings.
// Layer: View Helper
// Exports: SettingsConnectionDomainFormatter
// Depends on: Foundation

import Foundation

enum SettingsConnectionDomainFormatter {
    static func domainLabel(from relayURL: String?) -> String {
        guard let rawRelayURL = relayURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawRelayURL.isEmpty,
              let url = URL(string: rawRelayURL),
              let host = url.host,
              !host.isEmpty else {
            return "not set"
        }
        return host
    }
}
