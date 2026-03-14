// FILE: RelayIntegrationTests.swift
// Purpose: Verifies a real relay-secured pairing can connect and send a turn when explicitly opted in.
// Layer: Integration Test
// Exports: RelayIntegrationTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class RelayIntegrationTests: XCTestCase {
    func testRelaySecuredTurnStartSucceeds() async throws {
        guard let payload = try loadPairingPayloadFromEnvironment() else {
            throw XCTSkip("Set REMODEX_SIM_PAIRING_PAYLOAD to run the relay integration test.")
        }

        let defaults = UserDefaults(suiteName: "RelayIntegrationTests.\(UUID().uuidString)")!
        let service = CodexService(defaults: defaults)
        service.clearSavedRelaySession()
        service.rememberRelayPairing(payload)

        let serverURL = "\(payload.relay)/\(payload.sessionId)"
        let prompt = "relay key integration test"
        let thread = try await withRelayConnection(service: service, serverURL: serverURL) {
            try await service.startThread()
        } afterConnect: { thread in
            try await service.startTurn(userInput: prompt, threadId: thread.id)
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }

        XCTAssertTrue(
            service.messages(for: thread.id).contains { message in
                message.role == .user && message.text.contains(prompt)
            }
        )
        XCTAssertEqual(service.activeThreadId, thread.id)
    }

    private func loadPairingPayloadFromEnvironment() throws -> CodexPairingQRPayload? {
        let environment = ProcessInfo.processInfo.environment
        let inlinePayload = environment["REMODEX_SIM_PAIRING_PAYLOAD"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filePath = environment["REMODEX_SIM_PAIRING_PAYLOAD_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = inlinePayload?.isEmpty == false
            ? inlinePayload
            : loadPairingPayloadFromFile(path: filePath)

        guard let rawValue, !rawValue.isEmpty else {
            return nil
        }

        let data = try XCTUnwrap(rawValue.data(using: .utf8))
        let payload = try JSONDecoder().decode(CodexPairingQRPayload.self, from: data)
        let expiryDate = Date(timeIntervalSince1970: TimeInterval(payload.expiresAt) / 1000)

        if expiryDate.addingTimeInterval(codexSecureClockSkewToleranceSeconds) < Date() {
            throw XCTSkip("REMODEX_SIM_PAIRING_PAYLOAD is expired. Generate a fresh pairing payload first.")
        }

        return payload
    }

    private func loadPairingPayloadFromFile(path: String?) -> String? {
        guard let path, !path.isEmpty else {
            return nil
        }

        guard let data = FileManager.default.contents(atPath: path),
              let rawValue = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        return rawValue
    }

    private func withRelayConnection<T>(
        service: CodexService,
        serverURL: String,
        operation: () async throws -> T,
        afterConnect: ((T) async throws -> Void)? = nil
    ) async throws -> T {
        try await service.connect(serverURL: serverURL, token: "", role: "iphone")

        do {
            let result = try await operation()
            try await afterConnect?(result)
            await service.disconnect()
            service.clearSavedRelaySession()
            return result
        } catch {
            await service.disconnect()
            service.clearSavedRelaySession()
            throw error
        }
    }
}
