// FILE: SimulatorPairingPayloadProbeTests.swift
// Purpose: Verifies simulator pairing payload probing reports source and parse failures clearly.
// Layer: Unit Test
// Exports: XCTestCase
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class SimulatorPairingPayloadProbeTests: XCTestCase {
    func testProbeReturnsEnvironmentPayloadWhenValid() throws {
        let rawValue = validPayload(expiresAt: futureMillis())

        let result = probeSimulatorPairingPayload(
            environment: ["REMODEX_SIM_PAIRING_PAYLOAD": rawValue],
            pasteboardString: nil
        )

        switch result {
        case .success(let payload, let source):
            XCTAssertEqual(source, .environment)
            XCTAssertEqual(payload.sessionId, "session-1")
        default:
            XCTFail("expected success from environment payload")
        }
    }

    func testProbeReportsClipboardParseError() throws {
        let result = probeSimulatorPairingPayload(
            environment: [:],
            pasteboardString: "{\"invalid\":true}"
        )

        switch result {
        case .failure(let failure):
            XCTAssertEqual(failure.source, .pasteboard)
            XCTAssertTrue(failure.message.contains("Not a valid secure pairing code"))
            XCTAssertEqual(failure.rawPreview, "{\"invalid\":true}")
        default:
            XCTFail("expected parse failure from pasteboard payload")
        }
    }

    func testProbeReportsExpiredPayload() throws {
        let rawValue = validPayload(expiresAt: 1)

        let result = probeSimulatorPairingPayload(
            environment: ["REMODEX_SIM_PAIRING_PAYLOAD": rawValue],
            pasteboardString: nil
        )

        switch result {
        case .failure(let failure):
            XCTAssertEqual(failure.source, .environment)
            XCTAssertTrue(failure.message.contains("expired"))
        default:
            XCTFail("expected expiration failure")
        }
    }
}

private func validPayload(expiresAt: Int64) -> String {
    """
    {"v":2,"relay":"wss://relay.example.com/relay","relayAuthKey":"secret","sessionId":"session-1","macDeviceId":"mac-1","macIdentityPublicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","expiresAt":\(expiresAt)}
    """
}

private func futureMillis() -> Int64 {
    Int64((Date().timeIntervalSince1970 + 3600) * 1000)
}
