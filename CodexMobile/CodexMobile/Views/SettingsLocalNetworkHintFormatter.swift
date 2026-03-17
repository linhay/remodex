// FILE: SettingsLocalNetworkHintFormatter.swift
// Purpose: Builds a user-facing hint when local relay connectivity appears on cellular data.
// Layer: View helper
// Exports: SettingsLocalNetworkHintFormatter
// Depends on: Foundation

import Foundation

enum SettingsLocalNetworkHintFormatter {
    static func hintText(
        hasCellularInterface: Bool,
        hasReachableOrCurrentLocalRelay: Bool
    ) -> String? {
        guard hasCellularInterface, hasReachableOrCurrentLocalRelay else {
            return nil
        }

        return "当前是蜂窝网络，但检测到本地直连链路（如热点/USB/系统共享），所以 local 源仍可能可达。"
    }
}
