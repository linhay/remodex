// FILE: ContentAccountDeletionTests.swift
// Purpose: Verifies account deletion requires two-step confirmation from account page menu.
// Layer: Unit Test
// Exports: ContentAccountDeletionTests
// Depends on: Foundation, XCTest, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

@MainActor
final class ContentAccountDeletionTests: XCTestCase {
    func testRequestDeleteSetsFirstConfirmationStateOnly() {
        let service = makeServiceWithTwoAccounts()
        let viewModel = ContentViewModel()
        let candidate = try! nonActiveAccount(from: service)

        viewModel.requestDelete(for: candidate)

        XCTAssertEqual(viewModel.deletingAccountID, candidate.id)
        XCTAssertNil(viewModel.pendingDeleteConfirmationAccountID)
    }

    func testContinueDeleteMovesToSecondConfirmationState() {
        let service = makeServiceWithTwoAccounts()
        let viewModel = ContentViewModel()
        let candidate = try! nonActiveAccount(from: service)

        viewModel.requestDelete(for: candidate)
        viewModel.continueDeleteConfirmation()

        XCTAssertNil(viewModel.deletingAccountID)
        XCTAssertEqual(viewModel.pendingDeleteConfirmationAccountID, candidate.id)
    }

    func testConfirmDeleteWithoutSecondConfirmationDoesNotDeleteAccount() {
        let service = makeServiceWithTwoAccounts()
        let viewModel = ContentViewModel()
        let candidate = try! nonActiveAccount(from: service)

        viewModel.requestDelete(for: candidate)
        viewModel.confirmDelete(codex: service)

        XCTAssertTrue(service.relayAccountProfiles.contains(where: { $0.id == candidate.id }))
    }

    func testConfirmDeleteRemovesCurrentAccountAndSwitchesToRemainingAccount() {
        let service = makeServiceWithTwoAccounts()
        let viewModel = ContentViewModel()
        let currentAccount = try! activeAccount(from: service)
        let expectedNextAccount = try! nonActiveAccount(from: service)

        viewModel.requestDelete(for: currentAccount)
        viewModel.continueDeleteConfirmation()
        viewModel.confirmDelete(codex: service)

        XCTAssertFalse(service.relayAccountProfiles.contains(where: { $0.id == currentAccount.id }))
        XCTAssertEqual(service.activeRelayAccountID, expectedNextAccount.id)
        XCTAssertNil(service.relayAccountManagementMessage)
    }

    func testConfirmDeleteCurrentLastAccountClearsActiveAccount() {
        let suiteName = "ContentAccountDeletionTests.Single.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        let viewModel = ContentViewModel()

        let expiresAt = Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000)
        let publicKey = Data(repeating: 9, count: 32).base64EncodedString()
        service.rememberRelayPairing(
            CodexPairingQRPayload(
                v: codexPairingQRVersion,
                relay: "ws://127.0.0.1:8788/relay",
                sessionId: "session-only",
                macDeviceId: "mac-only",
                macIdentityPublicKey: publicKey,
                expiresAt: expiresAt
            )
        )
        let currentAccount = try! activeAccount(from: service)

        viewModel.requestDelete(for: currentAccount)
        viewModel.continueDeleteConfirmation()
        viewModel.confirmDelete(codex: service)

        XCTAssertTrue(service.relayAccountProfiles.isEmpty)
        XCTAssertNil(service.activeRelayAccountID)
        XCTAssertNil(service.relayAccountManagementMessage)
    }

    private func makeServiceWithTwoAccounts() -> CodexService {
        let suiteName = "ContentAccountDeletionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)

        let expiresAt = Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000)
        let publicKey = Data(repeating: 7, count: 32).base64EncodedString()

        service.rememberRelayPairing(
            CodexPairingQRPayload(
                v: codexPairingQRVersion,
                relay: "ws://127.0.0.1:8788/relay",
                sessionId: "session-a",
                macDeviceId: "mac-a",
                macIdentityPublicKey: publicKey,
                expiresAt: expiresAt
            )
        )

        service.rememberRelayPairing(
            CodexPairingQRPayload(
                v: codexPairingQRVersion,
                relay: "ws://localhost:8788/relay",
                sessionId: "session-b",
                macDeviceId: "mac-b",
                macIdentityPublicKey: publicKey,
                expiresAt: expiresAt
            )
        )

        return service
    }

    private func nonActiveAccount(from service: CodexService) throws -> CodexRelayAccountProfile {
        guard let account = service.relayAccountProfiles.first(where: { $0.id != service.activeRelayAccountID }) else {
            throw NSError(domain: "ContentAccountDeletionTests", code: 1)
        }
        return account
    }

    private func activeAccount(from service: CodexService) throws -> CodexRelayAccountProfile {
        guard let activeID = service.activeRelayAccountID,
              let account = service.relayAccountProfiles.first(where: { $0.id == activeID }) else {
            throw NSError(domain: "ContentAccountDeletionTests", code: 2)
        }
        return account
    }
}
