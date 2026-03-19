// FILE: ContentConnectFallbackTests.swift
// Purpose: Verifies relay candidate fallback behavior when the first URL fails.
// Layer: Unit Test
// Exports: ContentConnectFallbackTests
// Depends on: Foundation, XCTest, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

@MainActor
final class ContentConnectFallbackTests: XCTestCase {
    func testConnectWithAutoRecoveryFallsBackToNextCandidateOnNonRetryableFailure() async throws {
        let service = makeService()
        let viewModel = ContentViewModel()
        var attemptedURLs: [String] = []

        enum MarkerError: Error {
            case firstCandidateFailed
        }

        viewModel.connectOverride = { _, url in
            attemptedURLs.append(url)
            if attemptedURLs.count == 1 {
                throw MarkerError.firstCandidateFailed
            }
        }

        try await viewModel.connectWithAutoRecovery(
            codex: service,
            serverURLs: ["wss://bad.example/relay/session", "ws://good.local/relay/session"],
            performAutoRetry: true
        )

        XCTAssertEqual(
            attemptedURLs,
            ["wss://bad.example/relay/session", "ws://good.local/relay/session"]
        )
    }

    func testConnectWithAutoRecoveryThrowsAfterAllCandidatesFail() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        var attemptedURLs: [String] = []

        enum MarkerError: Error {
            case allFailed
        }

        viewModel.connectOverride = { _, url in
            attemptedURLs.append(url)
            throw MarkerError.allFailed
        }

        do {
            try await viewModel.connectWithAutoRecovery(
                codex: service,
                serverURLs: ["wss://a/relay/session", "ws://b/relay/session"],
                performAutoRetry: true
            )
            XCTFail("Expected connectWithAutoRecovery to throw when all candidates fail.")
        } catch {
            // expected
        }

        XCTAssertEqual(attemptedURLs, ["wss://a/relay/session", "ws://b/relay/session"])
    }

    func testConnectWithAutoRecoveryRestoresPairingSnapshotWhenSessionGetsClearedMidFallback() async throws {
        let service = makeService()
        let viewModel = ContentViewModel()
        service.relaySessionId = "session-original"
        service.relayUrl = "wss://relay.section.trade/relay"
        service.relayCandidates = [
            "wss://relay.section.trade/relay",
            "ws://linhey.local:8788/relay",
        ]
        service.relayMacDeviceId = "mac-6"
        service.relayMacIdentityPublicKey = Data(repeating: 2, count: 32).base64EncodedString()

        enum MarkerError: Error {
            case failed
        }

        var attemptCount = 0
        viewModel.connectOverride = { codex, _ in
            attemptCount += 1
            if attemptCount == 1 {
                codex.relaySessionId = nil
                codex.relayMacDeviceId = nil
                throw MarkerError.failed
            }
        }

        try await viewModel.connectWithAutoRecovery(
            codex: service,
            serverURLs: [
                "wss://relay.section.trade/relay/session-original",
                "ws://linhey.local:8788/relay/session-original",
            ],
            performAutoRetry: false
        )

        XCTAssertEqual(service.normalizedRelaySessionId, "session-original")
        XCTAssertEqual(service.normalizedRelayMacDeviceId, "mac-6")
    }

    private func makeService() -> CodexService {
        let suiteName = "ContentConnectFallbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return CodexService(defaults: defaults)
    }
}
