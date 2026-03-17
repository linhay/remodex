// FILE: CodexSkillsListDecodeTests.swift
// Purpose: Verifies skills/list response decoding across supported payload shapes.
// Layer: Unit Test
// Exports: CodexSkillsListDecodeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexSkillsListDecodeTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    actor AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testFetchServerThreadsPaginatesAndRequestsExplicitSourceKinds() async throws {
        let service = makeService()
        var capturedParams: [RPCObject] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/list")
            let object = params?.objectValue ?? [:]
            capturedParams.append(object)

            switch capturedParams.count {
            case 1:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "thread-1", cwd: "/Users/me/work/app"),
                        ]),
                        "nextCursor": .string("cursor-2"),
                    ]),
                    includeJSONRPC: false
                )
            case 2:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "thread-2", cwd: "/Users/me/work/site"),
                        ]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected extra thread/list request")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            }
        }

        let threads = try await service.fetchServerThreads()

        XCTAssertEqual(threads.map(\.id), ["thread-1", "thread-2"])
        XCTAssertEqual(capturedParams.count, 2)
        XCTAssertEqual(capturedParams[0]["cursor"], .null)
        XCTAssertEqual(capturedParams[1]["cursor"]?.stringValue, "cursor-2")

        let requestedSourceKinds = capturedParams[0]["sourceKinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(requestedSourceKinds.contains("appServer"))
        XCTAssertTrue(requestedSourceKinds.contains("cli"))
        XCTAssertTrue(requestedSourceKinds.contains("vscode"))
    }

    func testListThreadsDefaultsToRecentProjectFocusedLimit() async throws {
        let service = makeService()
        var capturedParams: [RPCObject] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/list")
            let object = params?.objectValue ?? [:]
            capturedParams.append(object)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "data": .array([]),
                    "nextCursor": .null,
                ]),
                includeJSONRPC: false
            )
        }

        try await service.listThreads()

        XCTAssertEqual(capturedParams.count, 1)
        XCTAssertEqual(capturedParams[0]["limit"]?.intValue, 20)
        XCTAssertNil(capturedParams[0]["archived"]?.boolValue)
    }

    func testPerformPostConnectSyncPassLoadsThreadsBeforeModels() async throws {
        let service = makeService()
        var requestedMethods: [String] = []
        var firstThreadListParams: RPCObject?

        service.requestTransportOverride = { method, params in
            requestedMethods.append(method)

            switch method {
            case "thread/list":
                let object = params?.objectValue ?? [:]
                if firstThreadListParams == nil {
                    firstThreadListParams = object
                }
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            case "model/list":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected request method: \(method)")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        await service.performPostConnectSyncPass()

        XCTAssertEqual(requestedMethods.first, "thread/list")
        XCTAssertTrue(requestedMethods.contains("model/list"))
        XCTAssertEqual(firstThreadListParams?["limit"]?.intValue, 20)
    }

    func testListThreadsLoadsFirstPageBeforeBackgroundBackfill() async throws {
        let service = makeService()
        let backfillGate = AsyncGate()
        var capturedParams: [RPCObject] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/list")
            let object = params?.objectValue ?? [:]
            capturedParams.append(object)

            let archived = object["archived"]?.boolValue == true
            let cursor = object["cursor"]

            switch (archived, cursor) {
            case (false, .some(.null)):
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "active-1", cwd: "/Users/me/work/app"),
                        ]),
                        "nextCursor": .string("active-cursor-2"),
                    ]),
                    includeJSONRPC: false
                )
            case (false, .some(.string("active-cursor-2"))):
                await backfillGate.wait()
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "active-2", cwd: "/Users/me/work/site"),
                        ]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            case (true, .some(.null)):
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "archived-1", cwd: "/Users/me/work/old"),
                        ]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected thread/list request: \(object)")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            }
        }

        let firstPageLoaded = XCTestExpectation(description: "listThreads returns after first active page")
        Task {
            do {
                try await service.listThreads()
                firstPageLoaded.fulfill()
            } catch {
                XCTFail("listThreads failed unexpectedly: \(error)")
            }
        }

        await fulfillment(of: [firstPageLoaded], timeout: 0.5)
        XCTAssertEqual(service.threads.map(\.id), ["active-1"])
        XCTAssertFalse(service.isLoadingThreads)

        await backfillGate.open()
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            Set(service.threads.map(\.id)) == Set(["active-1", "active-2", "archived-1"])
        }
    }

    func testListThreadsPaginatesActiveAndArchivedResultsUntilCursorIsExhausted() async throws {
        let service = makeService()
        var capturedParams: [RPCObject] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/list")
            let object = params?.objectValue ?? [:]
            capturedParams.append(object)

            let archived = object["archived"]?.boolValue == true
            let cursor = object["cursor"]

            switch (archived, cursor) {
            case (false, .some(.null)):
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "active-1", cwd: "/Users/me/work/app"),
                        ]),
                        "nextCursor": .string("active-cursor-2"),
                    ]),
                    includeJSONRPC: false
                )
            case (false, .some(.string("active-cursor-2"))):
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "active-2", cwd: "/Users/me/work/site"),
                        ]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            case (true, .some(.null)):
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "archived-1", cwd: "/Users/me/work/old"),
                        ]),
                        "nextCursor": .string("archived-cursor-2"),
                    ]),
                    includeJSONRPC: false
                )
            case (true, .some(.string("archived-cursor-2"))):
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "archived-2", cwd: "/Users/me/work/older"),
                        ]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected thread/list request: \(object)")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            }
        }

        try await service.listThreads()
        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            Set(service.threads.map(\.id)) == Set(["active-1", "active-2", "archived-1", "archived-2"])
        }

        XCTAssertEqual(capturedParams.count, 5)
        XCTAssertEqual(Set(service.threads.map(\.id)), Set(["active-1", "active-2", "archived-1", "archived-2"]))
        XCTAssertEqual(Set(service.threads.filter { $0.syncState == .live }.map(\.id)), Set(["active-1", "active-2"]))
        XCTAssertEqual(Set(service.threads.filter { $0.syncState == .archivedLocal }.map(\.id)), Set(["archived-1", "archived-2"]))
    }

    func testFetchServerThreadsStopsPaginationWhenCursorRepeats() async throws {
        let service = makeService()
        var capturedParams: [RPCObject] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/list")
            let object = params?.objectValue ?? [:]
            capturedParams.append(object)

            switch capturedParams.count {
            case 1:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "loop-1", cwd: "/Users/me/work/app"),
                        ]),
                        "nextCursor": .string("loop-cursor"),
                    ]),
                    includeJSONRPC: false
                )
            case 2:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "loop-2", cwd: "/Users/me/work/site"),
                        ]),
                        "nextCursor": .string("loop-cursor"),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected extra thread/list request when cursor repeats: \(object)")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            }
        }

        let threads = try await service.fetchServerThreads()

        XCTAssertEqual(capturedParams.count, 2)
        XCTAssertEqual(threads.map(\.id), ["loop-1", "loop-2"])
    }

    func testDecodeSkillsListParsesBucketedDataShape() {
        let service = makeService()
        let result: JSONValue = .object([
            "data": .array([
                .object([
                    "cwd": .string("/Users/me/work/repo"),
                    "skills": .array([
                        .object([
                            "name": .string("review"),
                            "description": .string("Review recent changes"),
                            "path": .string("/Users/me/work/repo/.agents/skills/review/SKILL.md"),
                            "scope": .string("project"),
                            "enabled": .bool(true),
                        ]),
                    ]),
                ]),
            ]),
        ])

        let skills = service.decodeSkillMetadata(from: result)

        XCTAssertEqual(skills?.count, 1)
        XCTAssertEqual(skills?.first?.name, "review")
        XCTAssertEqual(skills?.first?.description, "Review recent changes")
        XCTAssertEqual(skills?.first?.scope, "project")
        XCTAssertEqual(skills?.first?.enabled, true)
    }

    func testDecodeSkillsListParsesFlatSkillsShape() {
        let service = makeService()
        let result: JSONValue = .object([
            "skills": .array([
                .object([
                    "name": .string("check-code"),
                    "description": .string("Audit code changes"),
                    "path": .string("/Users/me/.codex/skills/check-code/SKILL.md"),
                    "scope": .string("global"),
                    "enabled": .bool(true),
                ]),
            ]),
        ])

        let skills = service.decodeSkillMetadata(from: result)

        XCTAssertEqual(skills?.count, 1)
        XCTAssertEqual(skills?.first?.name, "check-code")
        XCTAssertEqual(skills?.first?.scope, "global")
    }

    func testPrioritizeRelayBaseURLsPrefersLANWhenRelaySourceIsLANFirst() async {
        let viewModel = ContentViewModel()
        viewModel.relayHealthProbeOverride = { _ in false }

        let ordered = await viewModel.prioritizeRelayBaseURLs(
            ["wss://relay.example.com/relay", "ws://linhey.local:8788/relay"],
            sourcePreference: .lanFirst
        )

        XCTAssertEqual(ordered, ["ws://linhey.local:8788/relay", "wss://relay.example.com/relay"])
    }

    func testPrioritizeRelayBaseURLsPrefersPublicWhenRelaySourceIsPublicFirst() async {
        let viewModel = ContentViewModel()
        viewModel.relayHealthProbeOverride = { _ in true }

        let ordered = await viewModel.prioritizeRelayBaseURLs(
            ["ws://linhey.local:8788/relay", "wss://relay.example.com/relay"],
            sourcePreference: .publicFirst
        )

        XCTAssertEqual(ordered, ["wss://relay.example.com/relay", "ws://linhey.local:8788/relay"])
    }

    func testPrioritizeRelayBaseURLsAutoPrefersHealthyLANRelay() async {
        let viewModel = ContentViewModel()
        viewModel.relayHealthProbeOverride = { baseURL in
            baseURL == "ws://linhey.local:8788/relay"
        }

        let ordered = await viewModel.prioritizeRelayBaseURLs(
            ["wss://relay.example.com/relay", "ws://linhey.local:8788/relay"],
            sourcePreference: .auto
        )

        XCTAssertEqual(ordered, ["ws://linhey.local:8788/relay", "wss://relay.example.com/relay"])
    }

    func testPrioritizeRelayBaseURLsAutoPrefersLowestLatencyRelay() async {
        let viewModel = ContentViewModel()
        viewModel.relayHealthProbeResultOverride = { baseURL in
            switch baseURL {
            case "wss://relay-a.example.com/relay":
                return RelayHealthProbeResult(isReachable: true, latencyMs: 90)
            case "ws://linhey.local:8788/relay":
                return RelayHealthProbeResult(isReachable: true, latencyMs: 30)
            case "wss://relay-b.example.com/relay":
                return RelayHealthProbeResult(isReachable: true, latencyMs: 55)
            default:
                return .unreachable
            }
        }

        let ordered = await viewModel.prioritizeRelayBaseURLs(
            [
                "wss://relay-a.example.com/relay",
                "ws://linhey.local:8788/relay",
                "wss://relay-b.example.com/relay",
            ],
            sourcePreference: .auto
        )

        XCTAssertEqual(
            ordered,
            [
                "ws://linhey.local:8788/relay",
                "wss://relay-b.example.com/relay",
                "wss://relay-a.example.com/relay",
            ]
        )
    }

    func testPrioritizeRelayBaseURLsPlacesPreferredSourceFirst() async {
        let viewModel = ContentViewModel()

        let ordered = await viewModel.prioritizeRelayBaseURLs(
            [
                "wss://relay-a.example.com/relay",
                "ws://linhey.local:8788/relay",
                "wss://relay-b.example.com/relay",
            ],
            sourcePreference: .publicFirst,
            preferredBaseURL: "wss://relay-b.example.com/relay"
        )

        XCTAssertEqual(
            ordered,
            [
                "wss://relay-b.example.com/relay",
                "wss://relay-a.example.com/relay",
                "ws://linhey.local:8788/relay",
            ]
        )
    }

    func testRelayBaseURLMappingResolvesLANAndPublicCandidates() {
        let viewModel = ContentViewModel()
        let urls = [
            "ws://linhey.local:8788/relay",
            "wss://relay.example.com/relay",
        ]

        XCTAssertEqual(viewModel.firstLANRelayBaseURL(from: urls), "ws://linhey.local:8788/relay")
        XCTAssertEqual(viewModel.firstPublicRelayBaseURL(from: urls), "wss://relay.example.com/relay")
    }

    func testRelayBaseURLMappingReturnsNilWhenCategoryMissing() {
        let viewModel = ContentViewModel()

        XCTAssertNil(viewModel.firstLANRelayBaseURL(from: ["wss://relay.example.com/relay"]))
        XCTAssertNil(viewModel.firstPublicRelayBaseURL(from: ["ws://linhey.local:8788/relay"]))
    }

    func testProbeRelayHealthWithLatencyUsesOverrideForReachableResult() async {
        let viewModel = ContentViewModel()
        viewModel.relayHealthProbeResultOverride = { _ in
            RelayHealthProbeResult(isReachable: true, latencyMs: 42)
        }

        let result = await viewModel.probeRelayHealthWithLatency(baseURL: "wss://relay.example.com/relay")

        XCTAssertEqual(result, RelayHealthProbeResult(isReachable: true, latencyMs: 42))
    }

    func testProbeRelayHealthWithLatencyUsesOverrideForUnreachableResult() async {
        let viewModel = ContentViewModel()
        viewModel.relayHealthProbeResultOverride = { _ in .unreachable }

        let result = await viewModel.probeRelayHealthWithLatency(baseURL: "wss://relay.example.com/relay")

        XCTAssertEqual(result, .unreachable)
    }

    func testProbeRelayHealthBoolAPIFallsBackToLatencyResultReachability() async {
        let viewModel = ContentViewModel()
        viewModel.relayHealthProbeResultOverride = { _ in
            RelayHealthProbeResult(isReachable: true, latencyMs: 18)
        }

        let isReachable = await viewModel.probeRelayHealth(baseURL: "wss://relay.example.com/relay")

        XCTAssertTrue(isReachable)
    }

    func testAutoSwitchRelayIfNeededRecordsLatestSwitchOnSuccess() async {
        let viewModel = ContentViewModel()
        let service = makeService()
        service.selectedRelaySourcePreference = .auto
        service.selectedRelayBaseURL = nil
        service.isConnected = true
        service.isConnecting = false
        service.relaySessionId = "session-1"
        service.relayCandidates = [
            "wss://relay-a.example.com/relay",
            "wss://relay-b.example.com/relay",
        ]
        service.connectedServerIdentity = "wss://relay-a.example.com/relay/session-1"

        viewModel.relayHealthProbeResultOverride = { source in
            if source == "wss://relay-a.example.com/relay" {
                return RelayHealthProbeResult(isReachable: true, latencyMs: 80)
            }
            if source == "wss://relay-b.example.com/relay" {
                return RelayHealthProbeResult(isReachable: true, latencyMs: 20)
            }
            return .unreachable
        }

        var attemptedServerURLs: [String] = []
        viewModel.autoSwitchReconnectOverride = { codex, serverURLs in
            attemptedServerURLs = serverURLs
            codex.isConnected = true
            codex.connectedServerIdentity = serverURLs.first
        }

        await viewModel.autoSwitchRelayIfNeeded(codex: service)

        XCTAssertEqual(
            attemptedServerURLs.first,
            "wss://relay-b.example.com/relay/session-1"
        )
        XCTAssertEqual(service.relayAutoSwitchRecord?.fromBaseURL, "wss://relay-a.example.com/relay")
        XCTAssertEqual(service.relayAutoSwitchRecord?.toBaseURL, "wss://relay-b.example.com/relay")
        XCTAssertEqual(service.relayAutoSwitchRecord?.latencyMs, 20)
        XCTAssertEqual(service.relayAutoSwitchRecord?.previousLatencyMs, 80)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexSkillsListDecodeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]

        // Keep instances alive to avoid deallocation issues in the unit-test runtime.
        Self.retainedServices.append(service)
        return service
    }

    private func makeThreadJSON(id: String, cwd: String) -> JSONValue {
        .object([
            "id": .string(id),
            "title": .string(id),
            "cwd": .string(cwd),
        ])
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64,
        intervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        XCTFail("Condition was not met within timeout")
    }
}
