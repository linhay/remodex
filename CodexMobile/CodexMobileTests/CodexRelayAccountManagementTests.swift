// FILE: CodexRelayAccountManagementTests.swift
// Purpose: Verifies multi-account relay profile management and key recovery scenarios.
// Layer: Unit Test
// Exports: CodexRelayAccountManagementTests
// Depends on: XCTest, Network, CodexMobile

import Network
import XCTest
@testable import CodexMobile

@MainActor
final class CodexRelayAccountManagementTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    override func setUp() {
        super.setUp()
        clearRelaySecureStoreKeys()
    }

    override func tearDown() {
        clearRelaySecureStoreKeys()
        super.tearDown()
    }

    func testRememberRelayPairingCreatesAccountsAndSwitchesActive() {
        let service = makeService()

        service.rememberRelayPairing(makePayload(sessionId: "session-a", relay: "wss://relay-a.example.com/relay", macDeviceId: "mac-a"))
        service.rememberRelayPairing(makePayload(sessionId: "session-b", relay: "wss://relay-b.example.com/relay", macDeviceId: "mac-b"))

        XCTAssertEqual(service.relayAccountProfiles.count, 2)
        XCTAssertEqual(service.activeRelayAccount?.relaySessionId, "session-b")
        XCTAssertEqual(service.relaySessionId, "session-b")
    }

    func testDeleteAccountRejectsCurrentButAllowsNonCurrent() {
        let service = makeService()
        service.rememberRelayPairing(makePayload(sessionId: "session-a", relay: "wss://relay-a.example.com/relay", macDeviceId: "mac-a"))
        service.rememberRelayPairing(makePayload(sessionId: "session-b", relay: "wss://relay-b.example.com/relay", macDeviceId: "mac-b"))

        let currentId = tryUnwrap(service.activeRelayAccountID)
        let nonCurrentId = tryUnwrap(service.relayAccountProfiles.first(where: { $0.id != currentId })?.id)

        let deleteCurrent = service.deleteRelayAccount(id: currentId)
        let deleteNonCurrent = service.deleteRelayAccount(id: nonCurrentId)

        XCTAssertFalse(deleteCurrent)
        XCTAssertTrue(deleteNonCurrent)
        XCTAssertEqual(service.relayAccountProfiles.count, 1)
        XCTAssertEqual(service.activeRelayAccountID, currentId)
    }

    func testSwitchAccountThenConnectionDropKeepsSelectedAccount() {
        let service = makeService()
        service.rememberRelayPairing(makePayload(sessionId: "session-a", relay: "wss://relay-a.example.com/relay", macDeviceId: "mac-a"))
        service.rememberRelayPairing(makePayload(sessionId: "session-b", relay: "wss://relay-b.example.com/relay", macDeviceId: "mac-b"))

        let targetId = tryUnwrap(service.relayAccountProfiles.first(where: { $0.relaySessionId == "session-a" })?.id)
        service.isConnected = true

        let didSwitch = service.switchRelayAccount(to: targetId)
        service.handleReceiveError(NWError.posix(.ENOTCONN))

        XCTAssertTrue(didSwitch)
        XCTAssertEqual(service.activeRelayAccountID, targetId)
        XCTAssertEqual(service.activeRelayAccount?.relaySessionId, "session-a")
    }

    func testDeleteThenImmediateNewScanAddsFreshAccount() {
        let service = makeService()
        service.rememberRelayPairing(makePayload(sessionId: "session-a", relay: "wss://relay-a.example.com/relay", macDeviceId: "mac-a"))
        service.rememberRelayPairing(makePayload(sessionId: "session-b", relay: "wss://relay-b.example.com/relay", macDeviceId: "mac-b"))

        let currentId = tryUnwrap(service.activeRelayAccountID)
        let nonCurrentId = tryUnwrap(service.relayAccountProfiles.first(where: { $0.id != currentId })?.id)
        XCTAssertTrue(service.deleteRelayAccount(id: nonCurrentId))

        service.rememberRelayPairing(makePayload(sessionId: "session-c", relay: "wss://relay-c.example.com/relay", macDeviceId: "mac-c"))

        XCTAssertEqual(service.relayAccountProfiles.count, 2)
        XCTAssertEqual(service.activeRelayAccount?.relaySessionId, "session-c")
    }

    private func makePayload(sessionId: String, relay: String, macDeviceId: String) -> CodexPairingQRPayload {
        CodexPairingQRPayload(
            v: codexPairingQRVersion,
            relay: relay,
            relayCandidates: [relay],
            relayAuthKey: "test-key",
            sessionId: sessionId,
            macDeviceId: macDeviceId,
            macIdentityPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
            expiresAt: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        )
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexRelayAccountManagementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    private func tryUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("Expected non-nil value", file: file, line: line)
            fatalError("Expected non-nil value")
        }
        return value
    }

    private func clearRelaySecureStoreKeys() {
        let keys: [String] = [
            CodexSecureKeys.relaySessionId,
            CodexSecureKeys.relayUrl,
            CodexSecureKeys.relayCandidates,
            CodexSecureKeys.relayAuthKey,
            CodexSecureKeys.relayMacDeviceId,
            CodexSecureKeys.relayMacIdentityPublicKey,
            CodexSecureKeys.relayProtocolVersion,
            CodexSecureKeys.relayLastAppliedBridgeOutboundSeq,
            CodexSecureKeys.relayAccounts,
        ]

        keys.forEach { SecureStore.deleteValue(for: $0) }
    }
}
