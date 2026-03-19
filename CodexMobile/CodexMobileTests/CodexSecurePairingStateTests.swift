// FILE: CodexSecurePairingStateTests.swift
// Purpose: Verifies fresh QR scans force bootstrap mode and secure pairing failures stay actionable in UI state.
// Layer: Unit Test
// Exports: CodexSecurePairingStateTests
// Depends on: Foundation, XCTest, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

@MainActor
final class CodexSecurePairingStateTests: XCTestCase {
    func testRelayAccountSanitizerDropsUITestProfilesOutsideXCTest() {
        let uiProfile = CodexRelayAccountProfile(
            id: "ui-profile",
            displayName: "UI",
            createdAt: Date(),
            lastUsedAt: Date(),
            lastConnectedAt: nil,
            lastErrorMessage: nil,
            relaySessionId: "uitest-session-lan",
            relayURL: "ws://127.0.0.1:8788/relay",
            relayCandidates: ["ws://127.0.0.1:8788/relay"],
            relayAuthKey: nil,
            relayMacDeviceId: "uitest-mac-lan",
            relayMacIdentityPublicKey: Data(repeating: 1, count: 32).base64EncodedString(),
            relayProtocolVersion: codexSecureProtocolVersion,
            lastAppliedBridgeOutboundSeq: 0
        )
        let realProfile = CodexRelayAccountProfile(
            id: "real-profile",
            displayName: "Real",
            createdAt: Date(),
            lastUsedAt: Date(),
            lastConnectedAt: nil,
            lastErrorMessage: nil,
            relaySessionId: "real-session",
            relayURL: "wss://relay.section.trade/relay",
            relayCandidates: ["wss://relay.section.trade/relay"],
            relayAuthKey: nil,
            relayMacDeviceId: "mac-6",
            relayMacIdentityPublicKey: Data(repeating: 2, count: 32).base64EncodedString(),
            relayProtocolVersion: codexSecureProtocolVersion,
            lastAppliedBridgeOutboundSeq: 0
        )

        let sanitized = CodexRelayAccountSanitizer.sanitizedProfiles(
            [uiProfile, realProfile],
            isRunningXCTest: false
        )
        XCTAssertEqual(sanitized.map(\.id), ["real-profile"])
    }

    func testRelayAccountSanitizerKeepsUITestProfilesDuringXCTest() {
        let uiProfile = CodexRelayAccountProfile(
            id: "ui-profile",
            displayName: "UI",
            createdAt: Date(),
            lastUsedAt: Date(),
            lastConnectedAt: nil,
            lastErrorMessage: nil,
            relaySessionId: "uitest-session-lan",
            relayURL: "ws://127.0.0.1:8788/relay",
            relayCandidates: ["ws://127.0.0.1:8788/relay"],
            relayAuthKey: nil,
            relayMacDeviceId: "uitest-mac-lan",
            relayMacIdentityPublicKey: Data(repeating: 1, count: 32).base64EncodedString(),
            relayProtocolVersion: codexSecureProtocolVersion,
            lastAppliedBridgeOutboundSeq: 0
        )

        let sanitized = CodexRelayAccountSanitizer.sanitizedProfiles(
            [uiProfile],
            isRunningXCTest: true
        )
        XCTAssertEqual(sanitized.map(\.id), ["ui-profile"])
    }

    func testPairingRepairPolicyKeepsConfiguredMacDeviceId() {
        let inferred = CodexRelayPairingRepairPolicy.inferredMacDeviceId(
            configuredMacDeviceId: "mac-configured",
            configuredMacIdentityPublicKey: nil,
            trustedMacRecords: [:]
        )

        XCTAssertEqual(inferred, "mac-configured")
    }

    func testPairingRepairPolicyInfersMacDeviceIdByPublicKey() {
        let targetPublicKey = Data(repeating: 9, count: 32).base64EncodedString()
        let records: [String: CodexTrustedMacRecord] = [
            "mac-a": CodexTrustedMacRecord(
                macDeviceId: "mac-a",
                macIdentityPublicKey: Data(repeating: 1, count: 32).base64EncodedString(),
                lastPairedAt: Date()
            ),
            "mac-b": CodexTrustedMacRecord(
                macDeviceId: "mac-b",
                macIdentityPublicKey: targetPublicKey,
                lastPairedAt: Date()
            ),
        ]

        let inferred = CodexRelayPairingRepairPolicy.inferredMacDeviceId(
            configuredMacDeviceId: nil,
            configuredMacIdentityPublicKey: targetPublicKey,
            trustedMacRecords: records
        )

        XCTAssertEqual(inferred, "mac-b")
    }

    func testPairingRepairPolicyFallsBackToOnlyTrustedMac() {
        let records: [String: CodexTrustedMacRecord] = [
            "mac-only": CodexTrustedMacRecord(
                macDeviceId: "mac-only",
                macIdentityPublicKey: Data(repeating: 3, count: 32).base64EncodedString(),
                lastPairedAt: Date()
            )
        ]

        let inferred = CodexRelayPairingRepairPolicy.inferredMacDeviceId(
            configuredMacDeviceId: nil,
            configuredMacIdentityPublicKey: nil,
            trustedMacRecords: records
        )

        XCTAssertEqual(inferred, "mac-only")
    }

    func testRememberRelayPairingForcesFreshQRBootstrapEvenForTrustedMac() {
        let service = CodexService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let originalPublicKey = Data(repeating: 1, count: 32).base64EncodedString()
        let freshQRPublicKey = Data(repeating: 2, count: 32).base64EncodedString()

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: originalPublicKey,
            lastPairedAt: Date()
        )

        service.rememberRelayPairing(
            CodexPairingQRPayload(
                v: codexPairingQRVersion,
                relay: "ws://relay.local/relay",
                sessionId: "session-\(UUID().uuidString)",
                macDeviceId: macDeviceID,
                macIdentityPublicKey: freshQRPublicKey,
                expiresAt: Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
            )
        )

        XCTAssertTrue(service.shouldForceQRBootstrapOnNextHandshake)
        XCTAssertFalse(service.hasTrustedReconnectContext)
        XCTAssertEqual(service.secureConnectionState, .trustedMac)
        XCTAssertEqual(service.normalizedRelayMacIdentityPublicKey, freshQRPublicKey)
    }

    func testRememberRelayPairingShowsHandshakeStateForBrandNewMac() {
        let service = CodexService()
        let freshQRPublicKey = Data(repeating: 4, count: 32).base64EncodedString()

        service.rememberRelayPairing(
            CodexPairingQRPayload(
                v: codexPairingQRVersion,
                relay: "ws://relay.local/relay",
                sessionId: "session-\(UUID().uuidString)",
                macDeviceId: "mac-\(UUID().uuidString)",
                macIdentityPublicKey: freshQRPublicKey,
                expiresAt: Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
            )
        )

        XCTAssertTrue(service.shouldForceQRBootstrapOnNextHandshake)
        XCTAssertEqual(service.secureConnectionState, .handshaking)
        XCTAssertEqual(service.secureMacFingerprint, codexSecureFingerprint(for: freshQRPublicKey))
    }

    func testResetSecureTransportStatePreservesRePairRequiredState() {
        let service = CodexService()
        service.relaySessionId = "session-\(UUID().uuidString)"
        service.relayUrl = "ws://relay.local/relay"
        service.secureConnectionState = .rePairRequired
        service.secureMacFingerprint = "ABC123"

        service.resetSecureTransportState()

        XCTAssertEqual(service.secureConnectionState, .rePairRequired)
        XCTAssertEqual(service.secureMacFingerprint, "ABC123")
    }
}
