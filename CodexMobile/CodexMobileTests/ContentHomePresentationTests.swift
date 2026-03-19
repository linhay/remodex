// FILE: ContentHomePresentationTests.swift
// Purpose: Verifies home presentation and thread auto-selection rules.
// Layer: Unit Test
// Exports: ContentHomePresentationTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class ContentHomePresentationTests: XCTestCase {
    func testSimulatorPairingProbePrefersEnvironmentPayload() {
        let result = probeSimulatorPairingPayload(
            environment: ["REMODEX_SIM_PAIRING_PAYLOAD": validSimulatorPairingPayloadJSON()],
            pasteboardString: "invalid"
        )

        guard case .success(_, let source) = result else {
            return XCTFail("Expected environment payload to be used.")
        }

        XCTAssertEqual(source, .environment)
    }

    func testSimulatorPairingProbeDoesNotReadPasteboardWithoutExplicitFlag() {
        let result = probeSimulatorPairingPayload(
            environment: [:],
            pasteboardString: validSimulatorPairingPayloadJSON()
        )

        guard case .missing = result else {
            return XCTFail("Expected missing when pasteboard probe is disabled.")
        }
    }

    func testSimulatorPairingProbeReadsPasteboardWithExplicitFlag() {
        let result = probeSimulatorPairingPayload(
            environment: ["REMODEX_SIM_PAIRING_ALLOW_PASTEBOARD": "1"],
            pasteboardString: validSimulatorPairingPayloadJSON()
        )

        guard case .success(_, let source) = result else {
            return XCTFail("Expected pasteboard payload to be used.")
        }

        XCTAssertEqual(source, .pasteboard)
    }

    func testAccountHomeShowsHeroOnlyWhenNoAccounts() {
        XCTAssertTrue(ContentAccountHomePresentationPolicy.showsHeroSection(hasAccounts: false))
        XCTAssertFalse(ContentAccountHomePresentationPolicy.showsHeroSection(hasAccounts: true))
    }

    func testRootDestinationShowsOnboardingBeforeFirstLaunch() {
        XCTAssertEqual(
            ContentRootDestination.resolve(
                hasSeenOnboarding: false,
                isShowingManualScanner: false
            ),
            .onboarding
        )
    }

    func testRootDestinationStaysOnHomeWhenNotManuallyScanning() {
        XCTAssertEqual(
            ContentRootDestination.resolve(
                hasSeenOnboarding: true,
                isShowingManualScanner: false
            ),
            .home
        )
    }

    func testRootDestinationShowsScannerOnlyWhenRequested() {
        XCTAssertEqual(
            ContentRootDestination.resolve(
                hasSeenOnboarding: true,
                isShowingManualScanner: true
            ),
            .scanner
        )
    }

    func testThreadSelectionKeepsCurrentThreadWhenStillAvailable() {
        XCTAssertEqual(
            ContentThreadSelectionPolicy.selectedThreadID(
                currentSelectedThreadID: "thread-1",
                activeThreadID: nil,
                pendingNotificationOpenThreadID: nil,
                availableThreadIDs: ["thread-1", "thread-2"]
            ),
            "thread-1"
        )
    }

    func testThreadSelectionDoesNotAutoPickFirstThreadWhenNothingIsSelected() {
        XCTAssertNil(
            ContentThreadSelectionPolicy.selectedThreadID(
                currentSelectedThreadID: nil,
                activeThreadID: nil,
                pendingNotificationOpenThreadID: nil,
                availableThreadIDs: ["thread-1", "thread-2"]
            )
        )
    }

    func testThreadSelectionClearsMissingSelectionInsteadOfJumpingToAnotherThread() {
        XCTAssertNil(
            ContentThreadSelectionPolicy.selectedThreadID(
                currentSelectedThreadID: "missing-thread",
                activeThreadID: nil,
                pendingNotificationOpenThreadID: nil,
                availableThreadIDs: ["thread-1", "thread-2"]
            )
        )
    }

    func testSidebarPresentationOpensWhenThreadsExistButNoSelection() {
        XCTAssertTrue(
            ContentSidebarPresentationPolicy.shouldOpenSidebar(
                resolvedSelectionID: nil,
                availableThreadCount: 2
            )
        )
    }

    func testSidebarPresentationStaysClosedWhenSelectionExists() {
        XCTAssertFalse(
            ContentSidebarPresentationPolicy.shouldOpenSidebar(
                resolvedSelectionID: "thread-1",
                availableThreadCount: 2
            )
        )
    }

    func testActiveThreadSelectionDoesNotAutoPickFirstThreadWhenNothingIsActive() {
        XCTAssertNil(
            CodexActiveThreadSelectionPolicy.retainedActiveThreadID(
                currentActiveThreadID: nil,
                availableThreadIDs: ["thread-1", "thread-2"]
            )
        )
    }

    func testActiveThreadSelectionClearsMissingThreadInsteadOfFallingBackToFirst() {
        XCTAssertNil(
            CodexActiveThreadSelectionPolicy.retainedActiveThreadID(
                currentActiveThreadID: "missing-thread",
                availableThreadIDs: ["thread-1", "thread-2"]
            )
        )
    }

    func testActiveThreadSelectionRetainsExistingThreadWhenStillPresent() {
        XCTAssertEqual(
            CodexActiveThreadSelectionPolicy.retainedActiveThreadID(
                currentActiveThreadID: "thread-2",
                availableThreadIDs: ["thread-1", "thread-2"]
            ),
            "thread-2"
        )
    }

    func testPreferredThreadToOpenPrefersLiveThread() {
        let archived = CodexThread(id: "archived", title: "Archived", syncState: .archivedLocal)
        let live = CodexThread(id: "live", title: "Live", syncState: .live)

        XCTAssertEqual(
            ContentRelayAccountHomePolicy.preferredThreadToOpen(from: [archived, live])?.id,
            "live"
        )
    }

    func testPreferredThreadToOpenFallsBackToFirstThread() {
        let archived = CodexThread(id: "archived", title: "Archived", syncState: .archivedLocal)

        XCTAssertEqual(
            ContentRelayAccountHomePolicy.preferredThreadToOpen(from: [archived])?.id,
            "archived"
        )
    }

    func testAccountHomeModalDismissesWhenThreadIsSelected() {
        XCTAssertTrue(
            ContentAccountHomeModalPolicy.shouldDismissAfterSelectingThread(
                selectedThreadID: "thread-1"
            )
        )
    }

    func testAccountHomeModalStaysWhenNoThreadSelected() {
        XCTAssertFalse(
            ContentAccountHomeModalPolicy.shouldDismissAfterSelectingThread(
                selectedThreadID: nil
            )
        )
    }

    private func validSimulatorPairingPayloadJSON() -> String {
        """
        {"v":2,"relay":"wss://relay.section.trade/relay","relayCandidates":["wss://relay.section.trade/relay"],"relayAuthKey":"BEB68550-073F-4315-AD88-F35D59461383","sessionId":"0d390a79-0bf6-427d-94b2-fcb3ec135f01","macDeviceId":"mac-6","macIdentityPublicKey":"noaqKODSyYcybfE1FJVYNxnPv0u4kwWiiXsx5njX92o=","expiresAt":1773886515038}
        """
    }
}
