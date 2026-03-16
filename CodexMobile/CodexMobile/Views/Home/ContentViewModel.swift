// FILE: ContentViewModel.swift
// Purpose: Owns non-visual orchestration logic for the root screen (connection, relay pairing, sync throttling).
// Layer: ViewModel
// Exports: ContentViewModel
// Depends on: Foundation, Observation, CodexService, SecureStore

import Foundation
import Observation

@MainActor
@Observable
final class ContentViewModel {
    private var hasAttemptedInitialAutoConnect = false
    private var lastSidebarOpenSyncAt: Date = .distantPast
    private let autoReconnectBackoffNanoseconds: [UInt64] = [1_000_000_000, 3_000_000_000]
    private(set) var isRunningAutoReconnect = false
    var relayHealthProbeOverride: ((String) async -> Bool)?

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
            codex.clearSavedRelaySession()
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
}

extension ContentViewModel {
    func connect(codex: CodexService, serverURL: String) async throws {
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
        guard !serverURLs.isEmpty else {
            throw CodexServiceError.invalidInput("No saved relay URL found.")
        }

        for attemptIndex in 0...maxAttemptIndex {
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
                    let isRetryable = codex.isRecoverableTransientConnectionError(error)
                        || codex.isBenignBackgroundDisconnect(error)

                    guard performAutoRetry,
                          isRetryable,
                          attemptIndex < autoReconnectBackoffNanoseconds.count else {
                        codex.connectionRecoveryState = .idle
                        codex.shouldAutoReconnectOnForeground = false
                        codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
                        throw error
                    }
                }
            }

            if let lastError {
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

    func resolvedServerURLs(codex: CodexService) async -> [String] {
        guard let sessionId = codex.normalizedRelaySessionId else {
            return []
        }
        let prioritizedRelayBases = await prioritizeRelayBaseURLs(
            codex.normalizedRelayBaseURLsForReconnect,
            sourcePreference: codex.selectedRelaySourcePreference
        )
        return prioritizedRelayBases.map { "\($0)/\(sessionId)" }
    }

    // Prefers LAN relays only when they look reachable, otherwise keeps public relays first.
    func prioritizeRelayBaseURLs(
        _ relayBaseURLs: [String],
        sourcePreference: CodexRelaySourcePreference
    ) async -> [String] {
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

    func probeRelayHealth(baseURL: String) async -> Bool {
        guard var components = URLComponents(string: baseURL) else {
            return false
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
            return false
        }

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 0.45
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return (200...299).contains(httpResponse.statusCode)
            }
        } catch {}
        return false
    }
}
