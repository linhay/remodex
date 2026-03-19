// FILE: ContentViewModel.swift
// Purpose: Owns non-visual orchestration logic for the root screen (connection, relay pairing, sync throttling).
// Layer: ViewModel
// Exports: ContentViewModel
// Depends on: Foundation, Observation, CodexService, SecureStore

import Foundation
import Observation

struct RelayHealthProbeResult: Equatable, Sendable {
    let isReachable: Bool
    let latencyMs: Int?

    static let unreachable = RelayHealthProbeResult(isReachable: false, latencyMs: nil)
}

@MainActor
@Observable
final class ContentViewModel {
    private struct RelayPairingSnapshot {
        let sessionId: String
        let relayURL: String?
        let relayCandidates: [String]
        let relayAuthKey: String?
        let relayMacDeviceId: String?
        let relayMacIdentityPublicKey: String?
        let relayProtocolVersion: Int
        let lastAppliedBridgeOutboundSeq: Int
    }

    private var hasAttemptedInitialAutoConnect = false
    private var lastSidebarOpenSyncAt: Date = .distantPast
    private let autoReconnectBackoffNanoseconds: [UInt64] = [1_000_000_000, 3_000_000_000]
    private let autoRelaySwitchIntervalNanoseconds: UInt64 = 45_000_000_000
    private let autoRelaySwitchMinImprovementMs = 25
    private(set) var isRunningAutoReconnect = false
    var relayHealthProbeOverride: ((String) async -> Bool)?
    var relayHealthProbeResultOverride: ((String) async -> RelayHealthProbeResult)?
    var autoSwitchReconnectOverride: ((CodexService, [String]) async throws -> Void)?
    var connectOverride: ((CodexService, String) async throws -> Void)?
    var isShowingAddAccountScanner = false
    var renamingAccountID: String?
    var pendingAccountDisplayName = ""
    var deletingAccountID: String?
    var pendingDeleteConfirmationAccountID: String?

    var isAttemptingAutoReconnect: Bool {
        isRunningAutoReconnect
    }

    // Throttles sidebar-open sync requests to avoid redundant thread refresh churn.
    func shouldRequestSidebarFreshSync(isConnected: Bool) -> Bool {
        guard isConnected else {
            return false
        }

        let now = Date()
        guard now.timeIntervalSince(lastSidebarOpenSyncAt) >= 0.8 else {
            return false
        }

        lastSidebarOpenSyncAt = now
        return true
    }

    // Connects to the relay WebSocket using a scanned QR code payload.
    func connectToRelay(pairingPayload: CodexPairingQRPayload, codex: CodexService) async {
        await stopAutoReconnectForManualScan(codex: codex)
        codex.rememberRelayPairing(pairingPayload)
        let serverURLs = await resolvedServerURLs(codex: codex)
        simDebugLog("connectToRelay candidates \(serverURLs.joined(separator: ", "))")

        do {
            try await connectWithAutoRecovery(
                codex: codex,
                serverURLs: serverURLs,
                performAutoRetry: true
            )
            simDebugLog("connectToRelay succeeded")
        } catch {
            simDebugLog("connectToRelay failed \(String(describing: error))")
            if codex.lastErrorMessage?.isEmpty ?? true {
                codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
            }
        }
    }

    // Connects or disconnects the relay.
    func toggleConnection(codex: CodexService) async {
        guard !codex.isConnecting, !isRunningAutoReconnect else {
            return
        }

        if codex.isConnected {
            await codex.disconnect()
            return
        }

        let serverURLs = await resolvedServerURLs(codex: codex)
        guard !serverURLs.isEmpty else {
            return
        }

        do {
            try await connectWithAutoRecovery(
                codex: codex,
                serverURLs: serverURLs,
                performAutoRetry: true
            )
        } catch {
            if codex.lastErrorMessage?.isEmpty ?? true {
                codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
            }
        }
    }

    // Lets the manual QR flow take over instead of competing with the foreground reconnect loop.
    func stopAutoReconnectForManualScan(codex: CodexService) async {
        codex.shouldAutoReconnectOnForeground = false
        codex.connectionRecoveryState = .idle
        codex.lastErrorMessage = nil

        while isRunningAutoReconnect || codex.isConnecting {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // Attempts one automatic connection on app launch using saved relay session.
    func attemptAutoConnectOnLaunchIfNeeded(codex: CodexService) async {
        guard !hasAttemptedInitialAutoConnect else {
            return
        }
        hasAttemptedInitialAutoConnect = true

        guard !codex.isConnected, !codex.isConnecting else {
            return
        }

        let serverURLs = await resolvedServerURLs(codex: codex)
        guard !serverURLs.isEmpty else {
            return
        }

        do {
            try await connectWithAutoRecovery(
                codex: codex,
                serverURLs: serverURLs,
                performAutoRetry: true
            )
        } catch {
            // Keep the saved pairing so temporary Mac/relay outages can recover on the next retry.
        }
    }

    // Reconnects after benign background disconnects.
    func attemptAutoReconnectOnForegroundIfNeeded(codex: CodexService) async {
        guard codex.shouldAutoReconnectOnForeground, !isRunningAutoReconnect else {
            return
        }

        isRunningAutoReconnect = true
        defer { isRunningAutoReconnect = false }

        var attempt = 0
        let maxAttempts = 20

        // Keep trying while the relay pairing is still valid.
        // This lets network changes recover on their own instead of dropping back to a manual reconnect button.
        while codex.shouldAutoReconnectOnForeground, attempt < maxAttempts {
            let serverURLs = await resolvedServerURLs(codex: codex)
            guard !serverURLs.isEmpty else {
                codex.shouldAutoReconnectOnForeground = false
                codex.connectionRecoveryState = .idle
                return
            }

            if codex.isConnected {
                codex.shouldAutoReconnectOnForeground = false
                codex.connectionRecoveryState = .idle
                codex.lastErrorMessage = nil
                return
            }

            if codex.isConnecting {
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }

            var lastError: Error?
            for serverURL in serverURLs {
                codex.connectionRecoveryState = .retrying(
                    attempt: max(1, attempt + 1),
                    message: "Reconnecting..."
                )
                do {
                    try await connect(codex: codex, serverURL: serverURL)
                    codex.connectionRecoveryState = .idle
                    codex.lastErrorMessage = nil
                    codex.shouldAutoReconnectOnForeground = false
                    return
                } catch {
                    lastError = error
                }
            }

            if let error = lastError {
                let isRetryable = codex.isRecoverableTransientConnectionError(error)
                    || codex.isBenignBackgroundDisconnect(error)

                guard isRetryable else {
                    codex.connectionRecoveryState = .idle
                    codex.shouldAutoReconnectOnForeground = false
                    codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
                    return
                }

                codex.lastErrorMessage = nil
                codex.connectionRecoveryState = .retrying(
                    attempt: attempt + 1,
                    message: codex.recoveryStatusMessage(for: error)
                )

                let backoffIndex = min(attempt, autoReconnectBackoffNanoseconds.count - 1)
                let backoff = autoReconnectBackoffNanoseconds[backoffIndex]
                attempt += 1
                try? await Task.sleep(nanoseconds: backoff)
            }
        }

        // Exhausted all attempts — stop retrying but keep the saved pairing for next foreground cycle.
        if attempt >= maxAttempts {
            codex.shouldAutoReconnectOnForeground = false
            codex.connectionRecoveryState = .idle
            codex.lastErrorMessage = "Could not reconnect. Tap Reconnect to try again."
        }
    }

    func relayAccountLastConnectedText(_ account: CodexRelayAccountProfile) -> String? {
        guard let date = account.lastConnectedAt else {
            return nil
        }
        return "Last connected: \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    func requestRename(for account: CodexRelayAccountProfile) {
        pendingAccountDisplayName = account.displayName
        renamingAccountID = account.id
    }

    func confirmRename(codex: CodexService) {
        guard let renamingAccountID else {
            return
        }

        codex.renameRelayAccount(
            id: renamingAccountID,
            displayName: pendingAccountDisplayName
        )
        self.renamingAccountID = nil
    }

    func requestDelete(for account: CodexRelayAccountProfile) {
        deletingAccountID = account.id
        pendingDeleteConfirmationAccountID = nil
    }

    func continueDeleteConfirmation() {
        guard let deletingAccountID else {
            return
        }
        self.deletingAccountID = nil
        pendingDeleteConfirmationAccountID = deletingAccountID
    }

    func cancelDeleteFlow() {
        deletingAccountID = nil
        pendingDeleteConfirmationAccountID = nil
    }

    func confirmDelete(codex: CodexService) {
        guard let pendingDeleteConfirmationAccountID else {
            return
        }

        _ = codex.deleteRelayAccount(id: pendingDeleteConfirmationAccountID)
        cancelDeleteFlow()
    }

    func openRelayAccount(_ accountId: String, codex: CodexService) async -> CodexThread? {
        let didSwitch = codex.switchRelayAccount(to: accountId)
        if didSwitch {
            HapticFeedback.shared.triggerImpactFeedback()
        }

        // If this account already has local threads, open one immediately.
        let cachedThread = ContentRelayAccountHomePolicy.preferredThreadToOpen(from: codex.threads)

        if didSwitch && codex.isConnected {
            await codex.disconnect()
        }

        if !codex.isConnected && !codex.isConnecting {
            await toggleConnection(codex: codex)
        }

        if codex.isConnecting || (codex.isConnected && !codex.isInitialized) {
            _ = await waitForConnectionReady(codex: codex, timeoutSeconds: 4)
        }

        // If the first wait window missed the handshake tail, try one more reconnect pass.
        if (!codex.isConnected || !codex.isInitialized) && !codex.isConnecting {
            await toggleConnection(codex: codex)
            _ = await waitForConnectionReady(codex: codex, timeoutSeconds: 4)
        }

        guard codex.isConnected, codex.isInitialized else {
            return cachedThread
        }

        if codex.threads.isEmpty {
            try? await codex.listThreads()
        }

        if let thread = ContentRelayAccountHomePolicy.preferredThreadToOpen(from: codex.threads) {
            return thread
        }

        if let thread = try? await codex.startThread() {
            return thread
        }

        return cachedThread
    }

    func waitForConnectionReady(
        codex: CodexService,
        timeoutSeconds: TimeInterval = 6
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            if codex.isConnected, codex.isInitialized, !codex.isConnecting {
                return true
            }

            if !codex.isConnected, !codex.isConnecting {
                return false
            }

            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        return codex.isConnected && codex.isInitialized && !codex.isConnecting
    }
}

extension ContentViewModel {
    func connect(codex: CodexService, serverURL: String) async throws {
        if let connectOverride {
            try await connectOverride(codex, serverURL)
            return
        }

        try await codex.connect(serverURL: serverURL, token: "", role: "iphone")
    }

    func connectWithAutoRecovery(
        codex: CodexService,
        serverURLs: [String],
        performAutoRetry: Bool
    ) async throws {
        guard !isRunningAutoReconnect else {
            return
        }

        isRunningAutoReconnect = true
        defer { isRunningAutoReconnect = false }

        let maxAttemptIndex = performAutoRetry ? autoReconnectBackoffNanoseconds.count : 0
        var lastError: Error?
        let pairingSnapshot = RelayPairingSnapshot(
            sessionId: codex.normalizedRelaySessionId ?? "",
            relayURL: codex.normalizedRelayURL,
            relayCandidates: codex.normalizedRelayBaseURLsForReconnect,
            relayAuthKey: codex.normalizedRelayAuthKey,
            relayMacDeviceId: codex.normalizedRelayMacDeviceId,
            relayMacIdentityPublicKey: codex.normalizedRelayMacIdentityPublicKey,
            relayProtocolVersion: codex.relayProtocolVersion,
            lastAppliedBridgeOutboundSeq: codex.lastAppliedBridgeOutboundSeq
        )
        guard !serverURLs.isEmpty else {
            throw CodexServiceError.invalidInput("No saved relay URL found.")
        }

        for attemptIndex in 0...maxAttemptIndex {
            var sawRetryableError = false
            if attemptIndex > 0 {
                codex.connectionRecoveryState = .retrying(
                    attempt: attemptIndex,
                    message: "Connection timed out. Retrying..."
                )
            }

            for serverURL in serverURLs {
                do {
                    try await connect(codex: codex, serverURL: serverURL)
                    codex.connectionRecoveryState = .idle
                    codex.lastErrorMessage = nil
                    codex.shouldAutoReconnectOnForeground = false
                    return
                } catch {
                    lastError = error
                    restoreRelayPairingIfNeeded(codex: codex, snapshot: pairingSnapshot)
                    let isRetryable = codex.isRecoverableTransientConnectionError(error)
                        || codex.isBenignBackgroundDisconnect(error)
                    if isRetryable {
                        sawRetryableError = true
                    }
                }
            }

            if let lastError {
                let canRetry = performAutoRetry
                    && sawRetryableError
                    && attemptIndex < autoReconnectBackoffNanoseconds.count

                guard canRetry else {
                    codex.connectionRecoveryState = .idle
                    codex.shouldAutoReconnectOnForeground = false
                    codex.lastErrorMessage = codex.userFacingConnectFailureMessage(lastError)
                    throw lastError
                }

                codex.lastErrorMessage = nil
                codex.connectionRecoveryState = .retrying(
                    attempt: attemptIndex + 1,
                    message: codex.recoveryStatusMessage(for: lastError)
                )
            }
            if attemptIndex < autoReconnectBackoffNanoseconds.count {
                try? await Task.sleep(nanoseconds: autoReconnectBackoffNanoseconds[attemptIndex])
            }
        }

        if let lastError {
            codex.connectionRecoveryState = .idle
            codex.shouldAutoReconnectOnForeground = false
            codex.lastErrorMessage = codex.userFacingConnectFailureMessage(lastError)
            throw lastError
        }
    }

    private func restoreRelayPairingIfNeeded(codex: CodexService, snapshot: RelayPairingSnapshot) {
        guard codex.normalizedRelaySessionId == nil,
              !snapshot.sessionId.isEmpty else {
            return
        }

        codex.relaySessionId = snapshot.sessionId
        codex.relayUrl = snapshot.relayURL
        codex.relayCandidates = snapshot.relayCandidates
        codex.relayAuthKey = snapshot.relayAuthKey
        codex.relayMacDeviceId = snapshot.relayMacDeviceId
        codex.relayMacIdentityPublicKey = snapshot.relayMacIdentityPublicKey
        codex.relayProtocolVersion = snapshot.relayProtocolVersion
        codex.lastAppliedBridgeOutboundSeq = snapshot.lastAppliedBridgeOutboundSeq
        codex.updateActiveRelayAccount { profile in
            profile.relaySessionId = snapshot.sessionId
            profile.relayURL = snapshot.relayURL ?? profile.relayURL
            profile.relayCandidates = snapshot.relayCandidates
            profile.relayAuthKey = snapshot.relayAuthKey
            if let snapshotDeviceId = snapshot.relayMacDeviceId {
                profile.relayMacDeviceId = snapshotDeviceId
            }
            if let snapshotPublicKey = snapshot.relayMacIdentityPublicKey {
                profile.relayMacIdentityPublicKey = snapshotPublicKey
            }
            profile.relayProtocolVersion = snapshot.relayProtocolVersion
            profile.lastAppliedBridgeOutboundSeq = snapshot.lastAppliedBridgeOutboundSeq
        }
    }

    func resolvedServerURLs(codex: CodexService) async -> [String] {
        guard let sessionId = codex.normalizedRelaySessionId else {
            return []
        }
        let prioritizedRelayBases = await prioritizeRelayBaseURLs(
            codex.normalizedRelayBaseURLsForReconnect,
            sourcePreference: codex.selectedRelaySourcePreference,
            preferredBaseURL: codex.selectedRelayBaseURL
        )
        return prioritizedRelayBases.map { "\($0)/\(sessionId)" }
    }

    func relayAutoSwitchInterval() -> UInt64 {
        autoRelaySwitchIntervalNanoseconds
    }

    // In Auto mode, periodically switches to a clearly lower-latency relay source.
    func autoSwitchRelayIfNeeded(codex: CodexService) async {
        guard codex.selectedRelayBaseURL == nil,
              codex.selectedRelaySourcePreference == .auto,
              codex.isConnected,
              !codex.isConnecting,
              !isRunningAutoReconnect,
              let sessionId = codex.normalizedRelaySessionId else {
            return
        }

        let sources = codex.normalizedRelayBaseURLsForReconnect
        guard sources.count > 1 else {
            return
        }

        let probeResults = await probeLatencyByRelaySource(sources)
        guard let best = fastestReachableRelaySource(from: sources, probeResults: probeResults),
              let bestLatency = probeResults[best]?.latencyMs else {
            return
        }

        let currentBase = connectedRelayBaseURL(
            connectedServerIdentity: codex.connectedServerIdentity,
            sessionId: sessionId
        )
        guard let currentBase,
              currentBase != best else {
            return
        }

        let currentLatency = probeResults[currentBase]?.latencyMs
        let shouldSwitch: Bool
        if let currentLatency {
            shouldSwitch = (currentLatency - bestLatency) >= autoRelaySwitchMinImprovementMs
        } else {
            shouldSwitch = true
        }

        guard shouldSwitch else {
            return
        }

        let prioritized = [best] + sources.filter { $0 != best }
        let serverURLs = prioritized.map { "\($0)/\(sessionId)" }

        do {
            codex.connectionRecoveryState = .retrying(attempt: 0, message: "Switching to lower-latency relay...")
            if let autoSwitchReconnectOverride {
                try await autoSwitchReconnectOverride(codex, serverURLs)
            } else {
                try await connectWithAutoRecovery(
                    codex: codex,
                    serverURLs: serverURLs,
                    performAutoRetry: true
                )
            }
            codex.relayAutoSwitchRecord = CodexRelayAutoSwitchRecord(
                fromBaseURL: currentBase,
                toBaseURL: best,
                latencyMs: bestLatency,
                previousLatencyMs: currentLatency,
                timestamp: Date()
            )
        } catch {
            // Non-fatal: next timer tick can retry.
        }
    }

    // Prefers LAN relays only when they look reachable, otherwise keeps public relays first.
    func prioritizeRelayBaseURLs(
        _ relayBaseURLs: [String],
        sourcePreference: CodexRelaySourcePreference,
        preferredBaseURL: String? = nil
    ) async -> [String] {
        let orderedByPreference = await prioritizedBySourcePreference(
            relayBaseURLs,
            sourcePreference: sourcePreference
        )

        guard let preferredBaseURL = preferredBaseURL?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression),
              !preferredBaseURL.isEmpty,
              orderedByPreference.contains(preferredBaseURL) else {
            return orderedByPreference
        }

        return [preferredBaseURL] + orderedByPreference.filter { $0 != preferredBaseURL }
    }

    private func prioritizedBySourcePreference(
        _ relayBaseURLs: [String],
        sourcePreference: CodexRelaySourcePreference
    ) async -> [String] {
        if sourcePreference == .auto {
            let probeResults = await probeLatencyByRelaySource(relayBaseURLs)
            let hasReachable = relayBaseURLs.contains { probeResults[$0]?.isReachable == true }
            if hasReachable {
                return sortRelayBaseURLsByLatency(relayBaseURLs, probeResults: probeResults)
            }
        }

        let localURLs = relayBaseURLs.filter(isLikelyLANRelayURL)
        guard !localURLs.isEmpty else {
            return relayBaseURLs
        }

        let remoteURLs = relayBaseURLs.filter { !isLikelyLANRelayURL($0) }

        switch sourcePreference {
        case .lanFirst:
            return localURLs + remoteURLs
        case .publicFirst:
            return remoteURLs + localURLs
        case .auto:
            break
        }

        for localURL in localURLs {
            if await probeRelayHealthForPrioritization(baseURL: localURL) {
                let remaining = relayBaseURLs.filter { $0 != localURL }
                return [localURL] + remaining
            }
        }

        return remoteURLs + localURLs
    }

    func rankRelayBaseURLsByLatency(_ relayBaseURLs: [String]) async -> [String] {
        guard !relayBaseURLs.isEmpty else {
            return relayBaseURLs
        }

        let probeResults = await probeLatencyByRelaySource(relayBaseURLs)

        let hasReachable = relayBaseURLs.contains { probeResults[$0]?.isReachable == true }
        guard hasReachable else {
            return relayBaseURLs
        }

        return sortRelayBaseURLsByLatency(relayBaseURLs, probeResults: probeResults)
    }

    private func sortRelayBaseURLsByLatency(
        _ relayBaseURLs: [String],
        probeResults: [String: RelayHealthProbeResult]
    ) -> [String] {
        let indexed = relayBaseURLs.enumerated().map { (offset: $0.offset, source: $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            let leftResult = probeResults[lhs.source] ?? .unreachable
            let rightResult = probeResults[rhs.source] ?? .unreachable
            if leftResult.isReachable != rightResult.isReachable {
                return leftResult.isReachable && !rightResult.isReachable
            }

            let leftLatency = leftResult.latencyMs ?? Int.max
            let rightLatency = rightResult.latencyMs ?? Int.max
            if leftLatency != rightLatency {
                return leftLatency < rightLatency
            }
            return lhs.offset < rhs.offset
        }
        return sorted.map(\.source)
    }

    private func probeLatencyByRelaySource(_ relayBaseURLs: [String]) async -> [String: RelayHealthProbeResult] {
        var results: [String: RelayHealthProbeResult] = [:]
        for source in relayBaseURLs {
            results[source] = await probeRelayHealthWithLatency(baseURL: source)
        }
        return results
    }

    private func fastestReachableRelaySource(
        from relayBaseURLs: [String],
        probeResults: [String: RelayHealthProbeResult]
    ) -> String? {
        relayBaseURLs
            .filter { probeResults[$0]?.isReachable == true }
            .min { lhs, rhs in
                let left = probeResults[lhs]?.latencyMs ?? Int.max
                let right = probeResults[rhs]?.latencyMs ?? Int.max
                return left < right
            }
    }

    private func connectedRelayBaseURL(
        connectedServerIdentity: String?,
        sessionId: String
    ) -> String? {
        guard var identity = connectedServerIdentity?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !identity.isEmpty else {
            return nil
        }

        let suffix = "/\(sessionId)"
        if identity.hasSuffix(suffix) {
            identity.removeLast(suffix.count)
        }

        return identity.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    private func probeRelayHealthForPrioritization(baseURL: String) async -> Bool {
        if let relayHealthProbeOverride {
            return await relayHealthProbeOverride(baseURL)
        }
        return await probeRelayHealth(baseURL: baseURL)
    }

    func isLikelyLANRelayURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value.lowercased()),
              let host = components.host else {
            return false
        }
        if host.hasSuffix(".local") {
            return true
        }
        if host == "localhost" || host == "127.0.0.1" {
            return true
        }
        let octets = host.split(separator: ".")
        if octets.count == 4,
           let first = Int(octets[0]),
           let second = Int(octets[1]) {
            if first == 10 || first == 127 || (first == 192 && second == 168) {
                return true
            }
            if first == 172 && (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    func firstLANRelayBaseURL(from relayBaseURLs: [String]) -> String? {
        relayBaseURLs.first(where: isLikelyLANRelayURL)
    }

    func firstPublicRelayBaseURL(from relayBaseURLs: [String]) -> String? {
        relayBaseURLs.first(where: { !isLikelyLANRelayURL($0) })
    }

    func probeRelayHealth(baseURL: String) async -> Bool {
        if let relayHealthProbeOverride {
            return await relayHealthProbeOverride(baseURL)
        }
        return await probeRelayHealthWithLatency(baseURL: baseURL).isReachable
    }

    func probeRelayHealthWithLatency(baseURL: String) async -> RelayHealthProbeResult {
        if let relayHealthProbeResultOverride {
            return await relayHealthProbeResultOverride(baseURL)
        }
        if let relayHealthProbeOverride {
            let reachable = await relayHealthProbeOverride(baseURL)
            return reachable
                ? RelayHealthProbeResult(isReachable: true, latencyMs: nil)
                : .unreachable
        }
        guard var components = URLComponents(string: baseURL) else {
            return .unreachable
        }
        if components.scheme == "ws" {
            components.scheme = "http"
        } else if components.scheme == "wss" {
            components.scheme = "https"
        }
        components.path = "/health"
        components.query = nil
        components.fragment = nil
        guard let healthURL = components.url else {
            return .unreachable
        }

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 0.45
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let startedAt = DispatchTime.now().uptimeNanoseconds
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                guard (200...299).contains(httpResponse.statusCode) else {
                    return .unreachable
                }
                let endedAt = DispatchTime.now().uptimeNanoseconds
                let deltaMs = Int((endedAt - startedAt) / 1_000_000)
                return RelayHealthProbeResult(
                    isReachable: true,
                    latencyMs: max(1, deltaMs)
                )
            }
        } catch {}
        return .unreachable
    }
}
