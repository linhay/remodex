// FILE: SettingsView.swift
// Purpose: Settings for Local Mode (Codex runs on user's Mac, relay WebSocket).
// Layer: View
// Exports: SettingsView

import SwiftUI
import UIKit
import Network

enum RelaySourceProbeState: Equatable {
    case probing
    case reachable(latencyMs: Int)
    case unreachable

    static func probingStates(for sources: [String]) -> [String: RelaySourceProbeState] {
        Dictionary(uniqueKeysWithValues: sources.map { ($0, RelaySourceProbeState.probing) })
    }

    var statusText: String {
        switch self {
        case .probing:
            return "探测中..."
        case .reachable(let latencyMs):
            return "可达 · \(latencyMs)ms"
        case .unreachable:
            return "不可达"
        }
    }
}

struct SettingsView: View {
    @Environment(CodexService.self) private var codex

    private let runtimeAutoValue = "__AUTO__"
    private let runtimeNormalValue = "__NORMAL__"
    private let settingsAccentColor = Color(.plan)
    private let networkPathMonitorQueue = DispatchQueue(label: "CodexMobile.Settings.NetworkPath")

    @AppStorage("codex.appFontStyle") private var appFontStyleRawValue = AppFont.defaultStoredStyleRawValue
    @State private var contentViewModel = ContentViewModel()
    @State private var probeStateBySource: [String: RelaySourceProbeState] = [:]
    @State private var usesCellularInterface = false
    @State private var networkPathMonitor: NWPathMonitor?
    @State private var isShowingAddAccountScanner = false
    @State private var renamingAccountID: String?
    @State private var pendingAccountDisplayName = ""
    @State private var deletingAccountID: String?

    private var appFontStyleBinding: Binding<AppFont.Style> {
        Binding(
            get: { AppFont.Style(rawValue: appFontStyleRawValue) ?? AppFont.defaultStyle },
            set: { appFontStyleRawValue = $0.rawValue }
        )
    }

    private var connectionPhaseShowsProgress: Bool {
        switch codex.connectionPhase {
        case .connecting, .loadingChats, .syncing:
            return true
        case .offline, .connected:
            return false
        }
    }

    private var connectionStatusLabel: String {
        switch codex.connectionPhase {
        case .offline:
            return "offline"
        case .connecting:
            return "connecting"
        case .loadingChats:
            return "loading chats"
        case .syncing:
            return "syncing"
        case .connected:
            return "connected"
        }
    }

    private var connectionProgressLabel: String {
        switch codex.connectionPhase {
        case .connecting:
            return "Connecting to relay..."
        case .loadingChats:
            return "Loading chats..."
        case .syncing:
            return "Syncing workspace..."
        case .offline, .connected:
            return ""
        }
    }

    private var connectionDomainLabel: String {
        SettingsConnectionDomainFormatter.domainLabel(from: connectionDisplayURL)
    }

    private var connectionDomainTitle: String {
        codex.isConnected ? "Connected via" : "Preferred source"
    }

    private var connectionDisplayURL: String? {
        SettingsConnectionDisplayResolver.displayURL(
            isConnected: codex.isConnected,
            connectedServerIdentity: codex.connectedServerIdentity,
            selectedRelayBaseURL: codex.selectedRelayBaseURL,
            fallbackRelayURL: codex.normalizedRelayURL
        )
    }

    private var localRelayHintText: String? {
        SettingsLocalNetworkHintFormatter.hintText(
            hasCellularInterface: usesCellularInterface,
            hasReachableOrCurrentLocalRelay: hasReachableOrCurrentLocalRelay
        )
    }

    private var hasReachableOrCurrentLocalRelay: Bool {
        for source in codex.normalizedRelayBaseURLsForReconnect where contentViewModel.isLikelyLANRelayURL(source) {
            if isCurrentConnectedSource(source) {
                return true
            }
            if case .reachable = (probeStateBySource[source] ?? .unreachable) {
                return true
            }
        }
        return false
    }

    private var isRenamingAccountBinding: Binding<Bool> {
        Binding(
            get: { renamingAccountID != nil },
            set: { if !$0 { renamingAccountID = nil } }
        )
    }

    private var isDeletingAccountBinding: Binding<Bool> {
        Binding(
            get: { deletingAccountID != nil },
            set: { if !$0 { deletingAccountID = nil } }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                SettingsArchivedChatsCard()
                SettingsAppearanceCard(appFontStyle: appFontStyleBinding)
                SettingsNotificationsCard()
                runtimeDefaultsSection
                connectionSection
                SettingsAboutCard()
            }
            .padding()
        }
        .font(AppFont.body())
        .navigationTitle("Settings")
        .task {
            await refreshRelaySourceProbeStates()
        }
        .onAppear {
            startNetworkPathMonitor()
        }
        .onDisappear {
            stopNetworkPathMonitor()
        }
        .onChange(of: codex.normalizedRelayBaseURLsForReconnect) { _, _ in
            Task { @MainActor in
                await refreshRelaySourceProbeStates()
            }
        }
        .sheet(isPresented: $isShowingAddAccountScanner) {
            NavigationStack {
                QRScannerView { pairingPayload in
                    Task { @MainActor in
                        isShowingAddAccountScanner = false
                        await contentViewModel.connectToRelay(
                            pairingPayload: pairingPayload,
                            codex: codex
                        )
                        await refreshRelaySourceProbeStates()
                    }
                }
            }
        }
        .alert("Rename Account", isPresented: isRenamingAccountBinding) {
            TextField("Account name", text: $pendingAccountDisplayName)
            Button("Save") {
                guard let renamingAccountID else { return }
                codex.renameRelayAccount(id: renamingAccountID, displayName: pendingAccountDisplayName)
                self.renamingAccountID = nil
            }
            Button("Cancel", role: .cancel) {
                renamingAccountID = nil
            }
        } message: {
            Text("Use a clear name for this pairing profile.")
        }
        .confirmationDialog("Delete Account", isPresented: isDeletingAccountBinding) {
            Button("Delete", role: .destructive) {
                guard let deletingAccountID else { return }
                _ = codex.deleteRelayAccount(id: deletingAccountID)
                self.deletingAccountID = nil
            }
            Button("Cancel", role: .cancel) {
                deletingAccountID = nil
            }
        } message: {
            Text("This only removes the saved pairing profile.")
        }
    }
}

// MARK: - Subviews

private extension SettingsView {
    @ViewBuilder var runtimeDefaultsSection: some View {
        SettingsCard(title: "Runtime defaults") {
            HStack {
                Text("Model")
                Spacer()
                Picker("Model", selection: runtimeModelSelection) {
                    Text("Auto").tag(runtimeAutoValue)
                    ForEach(runtimeModelOptions, id: \.id) { model in
                        Text(TurnComposerMetaMapper.modelTitle(for: model))
                            .tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(settingsAccentColor)
            }

            HStack {
                Text("Reasoning")
                Spacer()
                Picker("Reasoning", selection: runtimeReasoningSelection) {
                    Text("Auto").tag(runtimeAutoValue)
                    ForEach(runtimeReasoningOptions, id: \.id) { option in
                        Text(option.title).tag(option.effort)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(settingsAccentColor)
                .disabled(runtimeReasoningOptions.isEmpty)
            }

            HStack {
                Text("Speed")
                Spacer()
                Picker("Speed", selection: runtimeServiceTierSelection) {
                    Text("Normal").tag(runtimeNormalValue)
                    ForEach(CodexServiceTier.allCases, id: \.rawValue) { tier in
                        Text(tier.displayName).tag(tier.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(settingsAccentColor)
            }

            HStack {
                Text("Access")
                Spacer()
                Picker("Access", selection: runtimeAccessSelection) {
                    ForEach(CodexAccessMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(settingsAccentColor)
            }
        }
    }

    @ViewBuilder var connectionSection: some View {
        SettingsCard(title: "Connection") {
            Text("Status: \(connectionStatusLabel)")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            Text("\(connectionDomainTitle): \(connectionDomainLabel)")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            relayAccountsSection
            relaySourceHeader
            relaySourcesList

            Text(SettingsReconnectHintFormatter.hintText())
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            if let localRelayHintText {
                Text(localRelayHintText)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            Text("Security: \(codex.secureConnectionState.statusLabel)")
                .font(AppFont.caption())
                .foregroundStyle(codex.secureConnectionState == .encrypted ? .green : .secondary)

            if let fingerprint = codex.secureMacFingerprint, !fingerprint.isEmpty {
                Text("Trusted Mac: \(fingerprint)")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            if connectionPhaseShowsProgress {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(connectionProgressLabel)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            if case .retrying(_, let message) = codex.connectionRecoveryState,
               !message.isEmpty {
                Text(message)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            if let autoSwitchRecord = codex.relayAutoSwitchRecord {
                Text(SettingsAutoSwitchStatusFormatter.statusText(record: autoSwitchRecord))
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            if let error = codex.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
            }

            if codex.isConnected {
                SettingsButton("Disconnect", role: .destructive) {
                    HapticFeedback.shared.triggerImpactFeedback()
                    disconnectRelay()
                }
            }
        }
    }

    @ViewBuilder var relaySourcesList: some View {
        if codex.normalizedRelayBaseURLsForReconnect.isEmpty {
            Text("No relay source configured.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) {
                ForEach(codex.normalizedRelayBaseURLsForReconnect, id: \.self) { source in
                    relaySourceRow(source)
                }
            }
        }
    }

    @ViewBuilder var relayAccountsSection: some View {
        HStack {
            Text("Accounts")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            relayControlButton("Add") {
                HapticFeedback.shared.triggerImpactFeedback()
                isShowingAddAccountScanner = true
            }
        }

        if codex.sortedRelayAccounts.isEmpty {
            Text("No account pairing configured.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) {
                ForEach(codex.sortedRelayAccounts) { account in
                    relayAccountRow(account)
                }
            }
        }

        if let accountMessage = codex.relayAccountManagementMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountMessage.isEmpty {
            Text(accountMessage)
                .font(AppFont.caption())
                .foregroundStyle(.red)
        }
    }

    var relaySourceHeader: some View {
        HStack {
            Text("Relay Sources")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            relayControlButton(
                codex.selectedRelayBaseURL == nil ? "Auto ✓" : "Auto"
            ) {
                let didChange = codex.setSelectedRelayBaseURL(nil)
                if didChange {
                    HapticFeedback.shared.triggerImpactFeedback()
                    retryRelayConnection()
                }
            }
            relayControlButton("Retry") {
                HapticFeedback.shared.triggerImpactFeedback()
                retryRelayConnection()
            }
        }
    }

    func relayAccountRow(_ account: CodexRelayAccountProfile) -> some View {
        let isCurrent = codex.activeRelayAccountID == account.id
        let isConnectedCurrent = isCurrent && codex.isConnected

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if isCurrent {
                        sourceBadge("Current", tint: settingsAccentColor)
                    }
                    if isConnectedCurrent {
                        sourceBadge("Connected", tint: .green)
                    }
                }
                Text(account.relayURL)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let lastConnectedText = relayAccountLastConnectedText(account) {
                    Text(lastConnectedText)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }

                if let lastError = account.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !lastError.isEmpty {
                    Text(lastError)
                        .font(AppFont.caption())
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isCurrent ? settingsAccentColor : .secondary)
                    .font(.system(size: 16, weight: .semibold))

                Button("Rename") {
                    pendingAccountDisplayName = account.displayName
                    renamingAccountID = account.id
                }
                .font(AppFont.caption(weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(settingsAccentColor)

                if !isCurrent {
                    Button("Delete") {
                        deletingAccountID = account.id
                    }
                    .font(AppFont.caption(weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCurrent ? settingsAccentColor.opacity(0.12) : Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isCurrent ? settingsAccentColor : Color(.separator), lineWidth: isCurrent ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            switchRelayAccount(account.id)
        }
    }

    func relaySourceRow(_ source: String) -> some View {
        let probeState = probeStateBySource[source] ?? .probing
        let isPreferred = codex.selectedRelayBaseURL == source
        let isCurrent = isCurrentConnectedSource(source)

        return Button {
            let didChange = codex.setSelectedRelayBaseURL(source)
            if didChange {
                HapticFeedback.shared.triggerImpactFeedback()
                retryRelayConnection()
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(relaySourceTitle(for: source))
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        if isCurrent {
                            sourceBadge("Current", tint: .green)
                        }
                        if isPreferred {
                            sourceBadge("Preferred", tint: settingsAccentColor)
                        }
                    }
                    Text(probeState.statusText)
                        .font(AppFont.caption())
                        .foregroundStyle(probeState == .unreachable ? .red : .secondary)
                    Text(source)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isPreferred ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPreferred ? settingsAccentColor : .secondary)
                    .font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isPreferred ? settingsAccentColor.opacity(0.12) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isPreferred ? settingsAccentColor : Color(.separator), lineWidth: isPreferred ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    func sourceBadge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }

    func relayControlButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(AppFont.caption(weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 1)
            )
            .buttonStyle(.plain)
    }
}

// MARK: - Runtime Bindings

private extension SettingsView {
    var runtimeModelOptions: [CodexModelOption] {
        TurnComposerMetaMapper.orderedModels(from: codex.availableModels)
    }

    var runtimeReasoningOptions: [TurnComposerReasoningDisplayOption] {
        TurnComposerMetaMapper.reasoningDisplayOptions(
            from: codex.supportedReasoningEffortsForSelectedModel().map(\.reasoningEffort)
        )
    }

    var runtimeModelSelection: Binding<String> {
        Binding(
            get: { codex.selectedModelOption()?.id ?? runtimeAutoValue },
            set: { selection in
                codex.setSelectedModelId(selection == runtimeAutoValue ? nil : selection)
            }
        )
    }

    var runtimeReasoningSelection: Binding<String> {
        Binding(
            get: { codex.selectedReasoningEffort ?? runtimeAutoValue },
            set: { selection in
                codex.setSelectedReasoningEffort(selection == runtimeAutoValue ? nil : selection)
            }
        )
    }

    var runtimeAccessSelection: Binding<CodexAccessMode> {
        Binding(
            get: { codex.selectedAccessMode },
            set: { codex.setSelectedAccessMode($0) }
        )
    }

    var runtimeServiceTierSelection: Binding<String> {
        Binding(
            get: { codex.selectedServiceTier?.rawValue ?? runtimeNormalValue },
            set: { selection in
                codex.setSelectedServiceTier(
                    selection == runtimeNormalValue ? nil : CodexServiceTier(rawValue: selection)
                )
            }
        )
    }
}

// MARK: - Actions

private extension SettingsView {
    func disconnectRelay() {
        Task { @MainActor in
            await codex.disconnect()
        }
    }

    func retryRelayConnection() {
        Task { @MainActor in
            probeStateBySource = RelaySourceProbeState.probingStates(
                for: codex.normalizedRelayBaseURLsForReconnect
            )
            if codex.isConnected {
                await codex.disconnect(preserveReconnectIntent: true)
            }
            codex.shouldAutoReconnectOnForeground = true
            codex.connectionRecoveryState = .retrying(attempt: 0, message: "Reconnecting...")
            codex.lastErrorMessage = nil
            await contentViewModel.attemptAutoReconnectOnForegroundIfNeeded(codex: codex)
            await refreshRelaySourceProbeStates()
        }
    }

    func switchRelayAccount(_ accountId: String) {
        let didChange = codex.switchRelayAccount(to: accountId)
        guard didChange else {
            return
        }
        HapticFeedback.shared.triggerImpactFeedback()
        if codex.isConnected {
            retryRelayConnection()
            return
        }
        Task { @MainActor in
            await refreshRelaySourceProbeStates()
        }
    }

    func startNetworkPathMonitor() {
        guard networkPathMonitor == nil else {
            return
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in
                usesCellularInterface = path.usesInterfaceType(.cellular)
            }
        }
        monitor.start(queue: networkPathMonitorQueue)
        networkPathMonitor = monitor
    }

    func stopNetworkPathMonitor() {
        networkPathMonitor?.cancel()
        networkPathMonitor = nil
    }

    func refreshRelaySourceProbeStates() async {
        let sources = codex.normalizedRelayBaseURLsForReconnect
        guard !sources.isEmpty else {
            probeStateBySource = [:]
            return
        }

        probeStateBySource = RelaySourceProbeState.probingStates(for: sources)
        for source in sources {
            probeStateBySource[source] = await probeState(for: source)
        }
    }

    func probeState(for baseURL: String) async -> RelaySourceProbeState {
        let result = await contentViewModel.probeRelayHealthWithLatency(baseURL: baseURL)
        if result.isReachable {
            return .reachable(latencyMs: result.latencyMs ?? 1)
        }
        return .unreachable
    }
}

// MARK: - Helpers

private extension SettingsView {
    func relaySourceTitle(for source: String) -> String {
        guard let components = URLComponents(string: source),
              let host = components.host else {
            return source
        }
        return "\(components.scheme?.uppercased() ?? "RELAY") · \(host)"
    }

    func isCurrentConnectedSource(_ source: String) -> Bool {
        guard codex.isConnected,
              let currentURL = codex.connectedServerIdentity,
              let sourceComponents = URLComponents(string: source),
              let currentComponents = URLComponents(string: currentURL) else {
            return false
        }

        let sourceScheme = sourceComponents.scheme?.lowercased()
        let currentScheme = currentComponents.scheme?.lowercased()
        let sourceHost = sourceComponents.host?.lowercased()
        let currentHost = currentComponents.host?.lowercased()
        let sourcePort = sourceComponents.port ?? (sourceScheme == "wss" ? 443 : 80)
        let currentPort = currentComponents.port ?? (currentScheme == "wss" ? 443 : 80)

        return sourceScheme == currentScheme
            && sourceHost == currentHost
            && sourcePort == currentPort
    }

    func relayAccountLastConnectedText(_ account: CodexRelayAccountProfile) -> String? {
        guard let date = account.lastConnectedAt else {
            return nil
        }
        return "Last connected: \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

// MARK: - Reusable card / button components

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

struct SettingsButton: View {
    let title: String
    var role: ButtonRole?
    var isLoading: Bool = false
    let action: () -> Void

    init(_ title: String, role: ButtonRole? = nil, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    Text(title)
                }
            }
            .font(AppFont.subheadline(weight: .medium))
            .foregroundStyle(role == .destructive ? .red : (role == .cancel ? .secondary : .primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                (role == .destructive ? Color.red : Color.primary).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Extracted independent section views

private struct SettingsAppearanceCard: View {
    @Binding var appFontStyle: AppFont.Style
    @AppStorage("codex.useLiquidGlass") private var useLiquidGlass = true
    private let settingsAccentColor = Color(.plan)

    var body: some View {
        SettingsCard(title: "Appearance") {
            HStack {
                Text("Font")
                Spacer()
                Picker("Font", selection: $appFontStyle) {
                    ForEach(AppFont.Style.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(settingsAccentColor)
            }

            Text(appFontStyle.subtitle)
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            if GlassPreference.isSupported {
                Divider()

                Toggle("Liquid Glass", isOn: $useLiquidGlass)
                    .tint(settingsAccentColor)

                Text(useLiquidGlass
                     ? "Liquid Glass effects are enabled."
                     : "Using solid material fallback.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsNotificationsCard: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SettingsCard(title: "Notifications") {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge")
                    .foregroundStyle(.primary)
                Text("Status")
                Spacer()
                Text(statusLabel)
                    .foregroundStyle(.secondary)
            }

            Text("Used for local alerts when a run finishes while the app is in background.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            if codex.notificationAuthorizationStatus == .notDetermined {
                SettingsButton("Allow notifications") {
                    HapticFeedback.shared.triggerImpactFeedback()
                    Task {
                        await codex.requestNotificationPermission()
                    }
                }
            }

            if codex.notificationAuthorizationStatus == .denied {
                SettingsButton("Open iOS Settings") {
                    HapticFeedback.shared.triggerImpactFeedback()
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
        .task {
            await codex.refreshNotificationAuthorizationStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }
            Task {
                await codex.refreshNotificationAuthorizationStatus()
            }
        }
    }

    private var statusLabel: String {
        switch codex.notificationAuthorizationStatus {
        case .authorized: "Authorized"
        case .denied: "Denied"
        case .provisional: "Provisional"
        case .ephemeral: "Ephemeral"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }
}

private struct SettingsArchivedChatsCard: View {
    @Environment(CodexService.self) private var codex

    private var archivedCount: Int {
        codex.threads.filter { $0.syncState == .archivedLocal }.count
    }

    var body: some View {
        SettingsCard(title: "Archived Chats") {
            NavigationLink {
                ArchivedChatsView()
            } label: {
                HStack {
                    Label("Archived Chats", systemImage: "archivebox")
                        .font(AppFont.subheadline(weight: .medium))
                    Spacer()
                    if archivedCount > 0 {
                        Text("\(archivedCount)")
                            .font(AppFont.caption(weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct SettingsAboutCard: View {
    var body: some View {
        SettingsCard(title: "About") {
            Text("Chats are End-to-end encrypted between your iPhone and Mac. The relay only sees ciphertext and connection metadata after the secure handshake completes.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(CodexService())
    }
}
