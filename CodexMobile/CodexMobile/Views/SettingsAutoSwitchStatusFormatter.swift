// FILE: SettingsAutoSwitchStatusFormatter.swift
// Purpose: Formats the latest relay auto-switch status line for Settings.
// Layer: View helper
// Exports: SettingsAutoSwitchStatusFormatter
// Depends on: Foundation

import Foundation

enum SettingsAutoSwitchStatusFormatter {
    static func statusText(record: CodexRelayAutoSwitchRecord, now: Date = Date()) -> String {
        let toHost = hostLabel(from: record.toBaseURL) ?? record.toBaseURL
        let fromHost = hostLabel(from: record.fromBaseURL)
        let elapsed = elapsedLabel(since: record.timestamp, now: now)

        if let fromHost, fromHost != toHost {
            return "自动切换：\(fromHost) -> \(toHost) · \(record.latencyMs)ms · \(elapsed)"
        }

        return "自动切换：\(toHost) · \(record.latencyMs)ms · \(elapsed)"
    }

    private static func hostLabel(from rawURL: String?) -> String? {
        guard let rawURL,
              let components = URLComponents(string: rawURL),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        return host
    }

    private static func elapsedLabel(since timestamp: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(timestamp)))
        if seconds <= 1 {
            return "刚刚"
        }
        return "\(seconds)s 前"
    }
}
