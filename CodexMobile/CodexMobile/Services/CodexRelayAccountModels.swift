// FILE: CodexRelayAccountModels.swift
// Purpose: Defines persisted relay account profiles for multi-account pairing.
// Layer: Service support
// Exports: CodexRelayAccountProfile, CodexRelayAccountExportEnvelope
// Depends on: Foundation

import Foundation

struct CodexRelayAccountProfile: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var displayName: String
    let createdAt: Date
    var lastUsedAt: Date
    var lastConnectedAt: Date?
    var lastErrorMessage: String?

    var relaySessionId: String
    var relayURL: String
    var relayCandidates: [String]
    var relayAuthKey: String?
    var relayMacDeviceId: String
    var relayMacIdentityPublicKey: String
    var relayProtocolVersion: Int
    var lastAppliedBridgeOutboundSeq: Int
}

struct CodexRelayAccountExportEnvelope: Codable, Sendable {
    let v: Int
    let exportedAt: Date
    let profile: CodexRelayAccountProfile

    static let currentVersion = 1
}
