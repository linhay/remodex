// FILE: CodexService.swift
// Purpose: Central state container for Codex app-server communication.
// Layer: Service
// Exports: CodexService, CodexApprovalRequest
// Depends on: Foundation, Observation, RPCMessage, CodexThread, CodexMessage, UserNotifications

import Foundation
import Network
import Observation
import UIKit
import UserNotifications

struct CodexApprovalRequest: Identifiable, Sendable {
    let id: String
    let requestID: JSONValue
    let method: String
    let command: String?
    let reason: String?
    let threadId: String?
    let turnId: String?
    let params: JSONValue?
}

struct CodexRecentActivityLine {
    let line: String
    let timestamp: Date
}

struct CodexRunningThreadWatch: Equatable, Sendable {
    let threadId: String
    let expiresAt: Date
}

struct CodexSecureControlWaiter {
    let id: UUID
    let continuation: CheckedContinuation<String, Error>
}

struct CodexBridgeUpdatePrompt: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
    let command: String
}

struct CodexThreadCompletionBanner: Identifiable, Equatable, Sendable {
    let id = UUID()
    let threadId: String
    let title: String
}

struct CodexRelayAutoSwitchRecord: Equatable, Sendable {
    let fromBaseURL: String?
    let toBaseURL: String
    let latencyMs: Int
    let previousLatencyMs: Int?
    let timestamp: Date
}

enum CodexThreadRunBadgeState: Equatable, Sendable {
    case running
    case ready
    case failed
}

enum CodexRunCompletionResult: String, Equatable, Sendable {
    case completed
    case failed
}

enum CodexNotificationPayloadKeys {
    static let source = "source"
    static let threadId = "threadId"
    static let turnId = "turnId"
    static let result = "result"
}

// Tracks the real terminal outcome of a run, including user interruption.
enum CodexTurnTerminalState: String, Equatable, Sendable {
    case completed
    case failed
    case stopped
}

enum CodexConnectionRecoveryState: Equatable, Sendable {
    case idle
    case retrying(attempt: Int, message: String)
}

enum CodexConnectionPhase: Equatable, Sendable {
    case offline
    case connecting
    case loadingChats
    case syncing
    case connected
}

enum CodexRelaySourcePreference: String, CaseIterable, Equatable, Sendable {
    case auto
    case lanFirst
    case publicFirst

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .lanFirst:
            return "LAN first"
        case .publicFirst:
            return "Public first"
        }
    }
}

enum CodexPendingThreadComposerAction: Equatable, Sendable {
    case codeReview(target: CodexPendingCodeReviewTarget)
}

enum CodexPendingCodeReviewTarget: Equatable, Sendable {
    case uncommittedChanges
    case baseBranch
}

struct TurnTimelineRenderSnapshot: Equatable {
    let threadID: String
    let messages: [CodexMessage]
    let timelineChangeToken: Int
    let activeTurnID: String?
    let isThreadRunning: Bool
    let latestTurnTerminalState: CodexTurnTerminalState?
    let stoppedTurnIDs: Set<String>
    let assistantRevertStatesByMessageID: [String: AssistantRevertPresentation]
    let repoRefreshSignal: String?

    static func empty(threadID: String) -> TurnTimelineRenderSnapshot {
        TurnTimelineRenderSnapshot(
            threadID: threadID,
            messages: [],
            timelineChangeToken: 0,
            activeTurnID: nil,
            isThreadRunning: false,
            latestTurnTerminalState: nil,
            stoppedTurnIDs: [],
            assistantRevertStatesByMessageID: [:],
            repoRefreshSignal: nil
        )
    }
}

@MainActor
@Observable
final class ThreadTimelineState {
    let threadID: String
    var messages: [CodexMessage]
    var messageRevision: Int
    var activeTurnID: String?
    var isThreadRunning: Bool
    var latestTurnTerminalState: CodexTurnTerminalState?
    var stoppedTurnIDs: Set<String>
    var repoRefreshSignal: String?
    var renderSnapshot: TurnTimelineRenderSnapshot

    init(threadID: String) {
        self.threadID = threadID
        self.messages = []
        self.messageRevision = 0
        self.activeTurnID = nil
        self.isThreadRunning = false
        self.latestTurnTerminalState = nil
        self.stoppedTurnIDs = []
        self.repoRefreshSignal = nil
        self.renderSnapshot = TurnTimelineRenderSnapshot.empty(threadID: threadID)
    }
}

struct AssistantRevertStateCacheEntry {
    let messageRevision: Int
    let busyRepoRevision: Int
    let revertStateRevision: Int
    let statesByMessageID: [String: AssistantRevertPresentation]
}

@MainActor
@Observable
final class CodexService {
    // --- Public state ---------------------------------------------------------

    var threads: [CodexThread] = []
    var isConnected = false
    var isConnecting = false
    var isInitialized = false
    var isLoadingThreads = false
    // Tracks the non-blocking bootstrap that hydrates chats/models after the socket is ready.
    var isBootstrappingConnectionSync = false
    var currentOutput = ""
    var activeThreadId: String?
    var activeTurnId: String?
    var activeTurnIdByThread: [String: String] = [:]

    var runningThreadIDs: Set<String> = []
    // Protects active runs that are real but have not yielded a stable turnId yet.
    var protectedRunningFallbackThreadIDs: Set<String> = []
    var readyThreadIDs: Set<String> = []
    var failedThreadIDs: Set<String> = []
    // Threads that started a real run and haven't completed yet; survives sync-poll clearing.
    @ObservationIgnored var threadsPendingCompletionHaptic: Set<String> = []
    // Keeps the latest terminal outcome per thread so UI can react to real run completion.
    var latestTurnTerminalStateByThread: [String: CodexTurnTerminalState] = [:]
    // Preserves terminal outcome per turn so completed/stopped blocks stay distinguishable.
    var terminalStateByTurnID: [String: CodexTurnTerminalState] = [:]
    var pendingApproval: CodexApprovalRequest?
    var lastRawMessage: String?
    var lastErrorMessage: String?
    var connectionRecoveryState: CodexConnectionRecoveryState = .idle
    // Per-thread queued drafts for client-side turn queueing while a run is active.
    var queuedTurnDraftsByThread: [String: [QueuedTurnDraft]] = [:]
    // Per-thread queue pause state (active by default when absent).
    var queuePauseStateByThread: [String: QueuePauseState] = [:]
    var messagesByThread: [String: [CodexMessage]] = [:]
    // Monotonic per-thread revision so views can react to message mutations without hashing full transcripts.
    var messageRevisionByThread: [String: Int] = [:]
    var syncRealtimeEnabled = true
    var availableModels: [CodexModelOption] = []
    var selectedModelId: String?
    var selectedReasoningEffort: String?
    var selectedServiceTier: CodexServiceTier?
    var selectedAccessMode: CodexAccessMode = .onRequest
    var selectedRelaySourcePreference: CodexRelaySourcePreference = .auto
    var selectedRelayBaseURL: String?
    var isLoadingModels = false
    var modelsErrorMessage: String?
    var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    var pendingNotificationOpenThreadID: String?
    var supportsStructuredSkillInput = true
    // Runtime compatibility flag for `turn/start.collaborationMode` plan turns.
    var supportsTurnCollaborationMode = false
    // Runtime compatibility flag for `thread/start|turn/start.serviceTier` speed controls.
    var supportsServiceTier = true
    // Seeds brand-new chats with one-shot composer actions like code review.
    var pendingComposerActionByThreadID: [String: CodexPendingThreadComposerAction] = [:]

    // Relay session persistence
    var relayAccountProfiles: [CodexRelayAccountProfile] = []
    var activeRelayAccountID: String?
    var relayAccountManagementMessage: String?
    var relaySessionId: String?
    var relayUrl: String?
    var relayCandidates: [String] = []
    var relayAuthKey: String?
    var relayMacDeviceId: String?
    var relayMacIdentityPublicKey: String?
    var relayProtocolVersion: Int = codexSecureProtocolVersion
    var lastAppliedBridgeOutboundSeq = 0
    var secureConnectionState: CodexSecureConnectionState = .notPaired
    var secureMacFingerprint: String?
    // Keeps the bridge-update UX visible even if connection cleanup resets secure transport state.
    var bridgeUpdatePrompt: CodexBridgeUpdatePrompt?
    var hasPresentedServiceTierBridgeUpdatePrompt = false
    // Mirrors the sidebar ready-dot with a tappable in-app banner when another chat finishes.
    var threadCompletionBanner: CodexThreadCompletionBanner?
    var relayAutoSwitchRecord: CodexRelayAutoSwitchRecord?

    // --- Internal wiring ------------------------------------------------------

    var webSocketConnection: NWConnection?
    let webSocketQueue = DispatchQueue(label: "CodexMobile.WebSocket", qos: .userInitiated)
    var pendingRequests: [String: CheckedContinuation<RPCMessage, Error>] = [:]
    // Test hook: intercepts outbound RPC requests without requiring a live socket.
    @ObservationIgnored var requestTransportOverride: ((String, JSONValue?) async throws -> RPCMessage)?
    var streamingAssistantMessageByTurnID: [String: String] = [:]
    var streamingSystemMessageByItemID: [String: String] = [:]
    /// Rich metadata for command execution tool calls, keyed by itemId.
    var commandExecutionDetailsByItemID: [String: CommandExecutionDetails] = [:]
    // Debounces disk writes while streaming to keep UI responsive.
    var messagePersistenceDebounceTask: Task<Void, Never>?
    // Dedupes completion payloads when servers omit turn/item identifiers.
    var assistantCompletionFingerprintByThread: [String: (text: String, timestamp: Date)] = [:]
    // Dedupes concise activity feed lines per thread/turn to avoid visual spam.
    var recentActivityLineByThread: [String: CodexRecentActivityLine] = [:]
    var contextWindowUsageByThread: [String: ContextWindowUsage] = [:]
    var rateLimitBuckets: [CodexRateLimitBucket] = []
    var isLoadingRateLimits = false
    var rateLimitsErrorMessage: String?
    var threadIdByTurnID: [String: String] = [:]
    var hydratedThreadIDs: Set<String> = []
    var loadingThreadIDs: Set<String> = []
    var resumedThreadIDs: Set<String> = []
    var isAppInForeground = true
    var threadListSyncTask: Task<Void, Never>?
    var activeThreadSyncTask: Task<Void, Never>?
    var runningThreadWatchSyncTask: Task<Void, Never>?
    var threadListBackfillTask: Task<Void, Never>?
    var threadListBackfillToken: UUID?
    var postConnectSyncTask: Task<Void, Never>?
    var postConnectSyncToken: UUID?
    var connectedServerIdentity: String?
    var runningThreadWatchByID: [String: CodexRunningThreadWatch] = [:]
    var backgroundTurnGraceTaskID: UIBackgroundTaskIdentifier = .invalid
    var hasConfiguredNotifications = false
    var runCompletionNotificationDedupedAt: [String: Date] = [:]
    var notificationCenterDelegateProxy: CodexNotificationCenterDelegateProxy?
    var shouldAutoReconnectOnForeground = false
    var secureSession: CodexSecureSession?
    var pendingHandshake: CodexPendingHandshake?
    var phoneIdentityState: CodexPhoneIdentityState
    var trustedMacRegistry: CodexTrustedMacRegistry
    var pendingSecureControlContinuations: [String: [CodexSecureControlWaiter]] = [:]
    var bufferedSecureControlMessages: [String: [String]] = [:]
    // Assistant-scoped patch ledger used by the revert-changes flow.
    var aiChangeSetsByID: [String: AIChangeSet] = [:]
    var aiChangeSetIDByTurnID: [String: String] = [:]
    var aiChangeSetIDByAssistantMessageID: [String: String] = [:]
    // Canonical repo roots keyed by observed working directories from bridge git/status responses.
    var repoRootByWorkingDirectory: [String: String] = [:]
    var knownRepoRoots: Set<String> = []
    // Service-owned per-thread UI state keeps the active chat isolated from unrelated thread mutations.
    @ObservationIgnored var threadTimelineStateByThread: [String: ThreadTimelineState] = [:]
    @ObservationIgnored var stoppedTurnIDsByThread: [String: Set<String>] = [:]
    @ObservationIgnored var latestAssistantOutputByThread: [String: String] = [:]
    @ObservationIgnored var latestRepoAffectingMessageSignalByThread: [String: String] = [:]
    @ObservationIgnored var assistantRevertStateCacheByThread: [String: AssistantRevertStateCacheEntry] = [:]
    @ObservationIgnored var assistantRevertStateRevision: Int = 0
    @ObservationIgnored var busyRepoRoots: Set<String> = []
    @ObservationIgnored var busyRepoRootsRevision: Int = 0

    let encoder: JSONEncoder
    let decoder: JSONDecoder
    var messagePersistence = CodexMessagePersistence()
    var aiChangeSetPersistence = AIChangeSetPersistence()
    let defaults: UserDefaults
    let userNotificationCenter: CodexUserNotificationCentering

    static let selectedModelIdDefaultsKey = "codex.selectedModelId"
    static let selectedReasoningEffortDefaultsKey = "codex.selectedReasoningEffort"
    static let selectedServiceTierDefaultsKey = "codex.selectedServiceTier"
    static let selectedAccessModeDefaultsKey = "codex.selectedAccessMode"
    static let selectedRelaySourcePreferenceDefaultsKey = "codex.selectedRelaySourcePreference"
    static let selectedRelayBaseURLDefaultsKey = "codex.selectedRelayBaseURL"
    static let locallyArchivedThreadIDsKey = "codex.locallyArchivedThreadIDs"
    static let activeRelayAccountIDDefaultsKey = "codex.activeRelayAccountID"
    static let notificationsPromptedDefaultsKey = "codex.notifications.prompted"

    init(
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        defaults: UserDefaults = .standard,
        userNotificationCenter: CodexUserNotificationCentering = UNUserNotificationCenter.current()
    ) {
        self.encoder = encoder
        self.decoder = decoder
        self.defaults = defaults
        self.userNotificationCenter = userNotificationCenter
        self.phoneIdentityState = codexPhoneIdentityStateFromSecureStore()
        self.trustedMacRegistry = codexTrustedMacRegistryFromSecureStore()
        loadPersistedRelayAccounts()
        restoreActiveRelayAccount()
        configurePersistenceForActiveRelayAccount()
        loadAccountScopedCaches()
        loadAccountScopedRuntimeSelections()
        refreshSecureStateForActiveAccountIfNeeded()
    }

    // Remembers whether we can offer reconnect without forcing a fresh QR scan.
    var hasSavedRelaySession: Bool {
        normalizedRelaySessionId != nil && !normalizedRelayBaseURLsForReconnect.isEmpty
    }

    // Normalizes the persisted relay session id before reuse in reconnect flows.
    var normalizedRelaySessionId: String? {
        relaySessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    // Normalizes the persisted relay base URL before reuse in reconnect flows.
    var normalizedRelayURL: String? {
        relayUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var normalizedRelayBaseURLsForReconnect: [String] {
        var result: [String] = []
        var seen = Set<String>()

        func appendUnique(_ candidate: String?) {
            guard let candidate = candidate?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty else {
                return
            }
            let normalized = candidate.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            guard !normalized.isEmpty, !seen.contains(normalized) else {
                return
            }
            seen.insert(normalized)
            result.append(normalized)
        }

        appendUnique(normalizedRelayURL)
        relayCandidates.forEach { appendUnique($0) }
        return result
    }

    var normalizedRelayAuthKey: String? {
        relayAuthKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var normalizedRelayMacDeviceId: String? {
        relayMacDeviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var normalizedRelayMacIdentityPublicKey: String? {
        relayMacIdentityPublicKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    // Separates transport readiness from post-connect hydration so the UI can explain delays honestly.
    var connectionPhase: CodexConnectionPhase {
        if isConnecting {
            return .connecting
        }

        guard isConnected else {
            return .offline
        }

        if threads.isEmpty && (isBootstrappingConnectionSync || isLoadingThreads) {
            return .loadingChats
        }

        if isBootstrappingConnectionSync || isLoadingModels || isLoadingThreads {
            return .syncing
        }

        return .connected
    }
}

extension CodexService {
    var activeRelayAccount: CodexRelayAccountProfile? {
        guard let activeRelayAccountID else {
            return nil
        }
        return relayAccountProfiles.first(where: { $0.id == activeRelayAccountID })
    }

    var sortedRelayAccounts: [CodexRelayAccountProfile] {
        relayAccountProfiles.sorted { lhs, rhs in
            if lhs.id == activeRelayAccountID { return true }
            if rhs.id == activeRelayAccountID { return false }
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func accountScopedDefaultsKey(_ baseKey: String, accountId: String? = nil) -> String {
        guard let accountID = (accountId ?? activeRelayAccountID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            return baseKey
        }
        return "\(baseKey).\(accountID)"
    }

    func switchRelayAccount(to accountId: String) -> Bool {
        guard relayAccountProfiles.contains(where: { $0.id == accountId }),
              activeRelayAccountID != accountId else {
            return false
        }

        persistCurrentAccountCaches()
        activeRelayAccountID = accountId
        defaults.set(accountId, forKey: Self.activeRelayAccountIDDefaultsKey)
        applyActiveRelayAccountFields()
        configurePersistenceForActiveRelayAccount()
        loadAccountScopedCaches()
        loadAccountScopedRuntimeSelections()
        refreshSecureStateForActiveAccountIfNeeded()
        updateActiveRelayAccount { profile in
            profile.lastUsedAt = Date()
        }
        relayAccountManagementMessage = nil
        return true
    }

    func renameRelayAccount(id: String, displayName: String) {
        guard let index = relayAccountProfiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        relayAccountProfiles[index].displayName = trimmed
        persistRelayAccounts()
    }

    @discardableResult
    func deleteRelayAccount(id: String) -> Bool {
        guard id != activeRelayAccountID else {
            relayAccountManagementMessage = "当前账号不可删除，请先切换到其他账号。"
            return false
        }
        guard let index = relayAccountProfiles.firstIndex(where: { $0.id == id }) else {
            return false
        }
        relayAccountProfiles.remove(at: index)
        persistRelayAccounts()
        relayAccountManagementMessage = nil
        return true
    }

    func exportRelayAccount(id: String) -> Data? {
        guard let profile = relayAccountProfiles.first(where: { $0.id == id }) else {
            return nil
        }
        let envelope = CodexRelayAccountExportEnvelope(
            v: CodexRelayAccountExportEnvelope.currentVersion,
            exportedAt: Date(),
            profile: profile
        )
        return try? JSONEncoder().encode(envelope)
    }

    @discardableResult
    func importRelayAccount(data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(CodexRelayAccountExportEnvelope.self, from: data),
              envelope.v == CodexRelayAccountExportEnvelope.currentVersion else {
            return false
        }

        var importedProfile = envelope.profile
        if importedProfile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            importedProfile = newRelayAccountProfile(
                displayName: importedProfile.displayName,
                relay: importedProfile.relayURL,
                relayCandidates: importedProfile.relayCandidates,
                relayAuthKey: importedProfile.relayAuthKey,
                sessionId: importedProfile.relaySessionId,
                macDeviceId: importedProfile.relayMacDeviceId,
                macIdentityPublicKey: importedProfile.relayMacIdentityPublicKey,
                protocolVersion: importedProfile.relayProtocolVersion,
                lastAppliedBridgeOutboundSeq: importedProfile.lastAppliedBridgeOutboundSeq
            )
        }

        upsertRelayAccount(importedProfile)
        _ = switchRelayAccount(to: importedProfile.id)
        return true
    }

    func markActiveRelayAccountConnected() {
        guard let activeRelayAccountID,
              let index = relayAccountProfiles.firstIndex(where: { $0.id == activeRelayAccountID }) else {
            return
        }
        relayAccountProfiles[index].lastConnectedAt = Date()
        relayAccountProfiles[index].lastErrorMessage = nil
        relayAccountProfiles[index].lastUsedAt = Date()
        persistRelayAccounts()
    }

    func markActiveRelayAccountError(_ message: String?) {
        guard let activeRelayAccountID,
              let index = relayAccountProfiles.firstIndex(where: { $0.id == activeRelayAccountID }) else {
            return
        }
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        relayAccountProfiles[index].lastErrorMessage = trimmed?.nilIfEmpty
        persistRelayAccounts()
    }
}

extension CodexService {
    func loadPersistedRelayAccounts() {
        relayAccountProfiles = SecureStore.readCodable([CodexRelayAccountProfile].self, for: CodexSecureKeys.relayAccounts) ?? []
        guard relayAccountProfiles.isEmpty else {
            return
        }

        guard let legacy = legacyRelayProfileIfPresent() else {
            return
        }
        relayAccountProfiles = [legacy]
        activeRelayAccountID = legacy.id
        defaults.set(legacy.id, forKey: Self.activeRelayAccountIDDefaultsKey)
        persistRelayAccounts()
        clearLegacyRelaySessionKeys()
    }

    func restoreActiveRelayAccount() {
        if let savedActiveID = defaults.string(forKey: Self.activeRelayAccountIDDefaultsKey),
           relayAccountProfiles.contains(where: { $0.id == savedActiveID }) {
            activeRelayAccountID = savedActiveID
        } else {
            activeRelayAccountID = relayAccountProfiles.first?.id
            if let activeRelayAccountID {
                defaults.set(activeRelayAccountID, forKey: Self.activeRelayAccountIDDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.activeRelayAccountIDDefaultsKey)
            }
        }
        applyActiveRelayAccountFields()
    }

    func applyActiveRelayAccountFields() {
        guard let activeRelayAccount else {
            relaySessionId = nil
            relayUrl = nil
            relayCandidates = []
            relayAuthKey = nil
            relayMacDeviceId = nil
            relayMacIdentityPublicKey = nil
            relayProtocolVersion = codexSecureProtocolVersion
            lastAppliedBridgeOutboundSeq = 0
            return
        }

        relaySessionId = activeRelayAccount.relaySessionId
        relayUrl = activeRelayAccount.relayURL
        relayCandidates = activeRelayAccount.relayCandidates
        relayAuthKey = activeRelayAccount.relayAuthKey
        relayMacDeviceId = activeRelayAccount.relayMacDeviceId
        relayMacIdentityPublicKey = activeRelayAccount.relayMacIdentityPublicKey
        relayProtocolVersion = activeRelayAccount.relayProtocolVersion
        lastAppliedBridgeOutboundSeq = activeRelayAccount.lastAppliedBridgeOutboundSeq
    }

    func persistRelayAccounts() {
        SecureStore.writeCodable(relayAccountProfiles, for: CodexSecureKeys.relayAccounts)
    }

    func updateActiveRelayAccount(using updater: (inout CodexRelayAccountProfile) -> Void) {
        guard let activeRelayAccountID,
              let index = relayAccountProfiles.firstIndex(where: { $0.id == activeRelayAccountID }) else {
            return
        }
        updater(&relayAccountProfiles[index])
        persistRelayAccounts()
    }

    func upsertRelayAccount(_ profile: CodexRelayAccountProfile) {
        if let index = relayAccountProfiles.firstIndex(where: { $0.id == profile.id }) {
            relayAccountProfiles[index] = profile
        } else {
            relayAccountProfiles.append(profile)
        }
        persistRelayAccounts()
    }

    func newRelayAccountProfile(
        displayName: String,
        relay: String,
        relayCandidates: [String],
        relayAuthKey: String?,
        sessionId: String,
        macDeviceId: String,
        macIdentityPublicKey: String,
        protocolVersion: Int,
        lastAppliedBridgeOutboundSeq: Int
    ) -> CodexRelayAccountProfile {
        let now = Date()
        return CodexRelayAccountProfile(
            id: UUID().uuidString.lowercased(),
            displayName: displayName,
            createdAt: now,
            lastUsedAt: now,
            lastConnectedAt: nil,
            lastErrorMessage: nil,
            relaySessionId: sessionId,
            relayURL: relay,
            relayCandidates: relayCandidates,
            relayAuthKey: relayAuthKey,
            relayMacDeviceId: macDeviceId,
            relayMacIdentityPublicKey: macIdentityPublicKey,
            relayProtocolVersion: protocolVersion,
            lastAppliedBridgeOutboundSeq: lastAppliedBridgeOutboundSeq
        )
    }

    func legacyRelayProfileIfPresent() -> CodexRelayAccountProfile? {
        guard let relaySessionId = SecureStore.readString(for: CodexSecureKeys.relaySessionId)?.nilIfEmpty,
              let relayUrl = SecureStore.readString(for: CodexSecureKeys.relayUrl)?.nilIfEmpty,
              let relayMacDeviceId = SecureStore.readString(for: CodexSecureKeys.relayMacDeviceId)?.nilIfEmpty,
              let relayMacIdentityPublicKey = SecureStore.readString(for: CodexSecureKeys.relayMacIdentityPublicKey)?.nilIfEmpty else {
            return nil
        }

        let relayAuthKey = SecureStore.readString(for: CodexSecureKeys.relayAuthKey)
        let relayCandidates = (SecureStore.readString(for: CodexSecureKeys.relayCandidates)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? [relayUrl]
        let protocolVersion = Int(SecureStore.readString(for: CodexSecureKeys.relayProtocolVersion) ?? "") ?? codexSecureProtocolVersion
        let lastAppliedSeq = Int(SecureStore.readString(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq) ?? "") ?? 0
        let host = URLComponents(string: relayUrl)?.host ?? "Relay"
        return newRelayAccountProfile(
            displayName: "Migrated · \(host)",
            relay: relayUrl,
            relayCandidates: relayCandidates,
            relayAuthKey: relayAuthKey,
            sessionId: relaySessionId,
            macDeviceId: relayMacDeviceId,
            macIdentityPublicKey: relayMacIdentityPublicKey,
            protocolVersion: protocolVersion,
            lastAppliedBridgeOutboundSeq: lastAppliedSeq
        )
    }

    func clearLegacyRelaySessionKeys() {
        SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        SecureStore.deleteValue(for: CodexSecureKeys.relayCandidates)
        SecureStore.deleteValue(for: CodexSecureKeys.relayAuthKey)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.deleteValue(for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.deleteValue(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
    }

    func configurePersistenceForActiveRelayAccount() {
        messagePersistence = CodexMessagePersistence(accountScope: activeRelayAccountID)
        aiChangeSetPersistence = AIChangeSetPersistence(accountScope: activeRelayAccountID)
    }

    func persistCurrentAccountCaches() {
        messagePersistence.save(messagesByThread)
        aiChangeSetPersistence.save(
            aiChangeSetsByID.values.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id < $1.id
            }
        )
    }

    func loadAccountScopedCaches() {
        messageRevisionByThread = [:]
        threadIdByTurnID = [:]
        threadTimelineStateByThread = [:]
        stoppedTurnIDsByThread = [:]
        latestAssistantOutputByThread = [:]
        latestRepoAffectingMessageSignalByThread = [:]
        assistantRevertStateCacheByThread = [:]
        assistantRevertStateRevision = 0
        queuedTurnDraftsByThread = [:]
        queuePauseStateByThread = [:]
        activeThreadId = nil
        activeTurnId = nil
        activeTurnIdByThread = [:]
        currentOutput = ""
        threads = []
        let loadedMessages = messagePersistence.load().mapValues { messages in
            messages.map { message in
                var value = message
                value.isStreaming = false
                return value
            }
        }
        CodexMessageOrderCounter.seed(from: loadedMessages)
        messagesByThread = loadedMessages

        let loadedChangeSets = aiChangeSetPersistence.load()
        aiChangeSetsByID = loadedChangeSets.reduce(into: [:]) { partialResult, changeSet in
            partialResult[changeSet.id] = changeSet
        }
        aiChangeSetIDByTurnID = loadedChangeSets.reduce(into: [:]) { partialResult, changeSet in
            partialResult[changeSet.turnId] = changeSet.id
        }
        aiChangeSetIDByAssistantMessageID = loadedChangeSets.reduce(into: [:]) { partialResult, changeSet in
            if let assistantMessageId = changeSet.assistantMessageId {
                partialResult[assistantMessageId] = changeSet.id
            }
        }
    }

    func loadAccountScopedRuntimeSelections() {
        let savedModelId = defaults.string(forKey: accountScopedDefaultsKey(Self.selectedModelIdDefaultsKey))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        selectedModelId = (savedModelId?.isEmpty == false) ? savedModelId : nil

        let savedReasoning = defaults.string(forKey: accountScopedDefaultsKey(Self.selectedReasoningEffortDefaultsKey))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        selectedReasoningEffort = (savedReasoning?.isEmpty == false) ? savedReasoning : nil

        let savedServiceTier = defaults.string(forKey: accountScopedDefaultsKey(Self.selectedServiceTierDefaultsKey))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if savedServiceTier == "flex" {
            selectedServiceTier = nil
        } else if let savedServiceTier,
                  let parsedServiceTier = CodexServiceTier(rawValue: savedServiceTier) {
            selectedServiceTier = parsedServiceTier
        } else {
            selectedServiceTier = nil
        }

        if let savedAccessMode = defaults.string(forKey: accountScopedDefaultsKey(Self.selectedAccessModeDefaultsKey)),
           let parsedAccessMode = CodexAccessMode(rawValue: savedAccessMode) {
            selectedAccessMode = parsedAccessMode
        } else {
            selectedAccessMode = .onRequest
        }

        if let savedRelaySourcePreference = defaults.string(forKey: accountScopedDefaultsKey(Self.selectedRelaySourcePreferenceDefaultsKey)),
           let parsedRelaySourcePreference = CodexRelaySourcePreference(rawValue: savedRelaySourcePreference) {
            selectedRelaySourcePreference = parsedRelaySourcePreference
        } else {
            selectedRelaySourcePreference = .auto
        }

        let savedRelayBaseURL = defaults.string(forKey: accountScopedDefaultsKey(Self.selectedRelayBaseURLDefaultsKey))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        selectedRelayBaseURL = (savedRelayBaseURL?.isEmpty == false) ? savedRelayBaseURL : nil
    }

    func refreshSecureStateForActiveAccountIfNeeded() {
        if let relayMacDeviceId,
           let trustedMac = trustedMacRegistry.records[relayMacDeviceId] {
            secureConnectionState = .trustedMac
            secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
        } else if activeRelayAccountID == nil {
            secureConnectionState = .notPaired
            secureMacFingerprint = nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
