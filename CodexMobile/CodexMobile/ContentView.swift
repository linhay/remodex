// FILE: ContentView.swift
// Purpose: Root layout orchestrator — navigation shell, sidebar drawer, and top-level state wiring.
// Layer: View
// Exports: ContentView
// Depends on: SidebarView, TurnView, SettingsView, CodexService, ContentViewModel

import SwiftUI

func simDebugLog(_ message: @autoclosure () -> String) {
#if targetEnvironment(simulator)
    print("[sim-debug] \(message())")
#endif
}

struct ContentView: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel = ContentViewModel()
    @State private var isSidebarOpen = false
    @State private var sidebarDragOffset: CGFloat = 0
    @State private var selectedThread: CodexThread?
    @State private var isAccountHomePresented = true
    @State private var navigationPath = NavigationPath()
    @State private var showSettings = false
    @State private var isShowingManualScanner = false
    @State private var isSearchActive = false
    @State private var isRetryingBridgeUpdate = false
    @State private var threadCompletionBannerDismissTask: Task<Void, Never>?
    @State private var openAccountTask: Task<Void, Never>?
    @State private var openingAccountID: String?
    @State private var latestOpenAccountRequestID = UUID()
    @AppStorage("codex.hasSeenOnboarding") private var hasSeenOnboarding = false

    private let sidebarWidth: CGFloat = 330
    private let settingsAccentColor = Color(.plan)
    private static let sidebarSpring = Animation.spring(response: 0.35, dampingFraction: 0.85)

    var body: some View {
        rootContent
            // Keep launch/foreground reconnect observers alive even while the QR scanner is visible.
            .task {
                let isRunningXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                if ProcessInfo.processInfo.arguments.contains("-CodexUITestsOpenSettings") {
                    showSettings = true
                }
                seedRelayAccountsForUITestsIfNeeded()
                applyUITestTimelineFixtureIfNeeded()
                guard !isRunningXCTest else {
                    hasSeenOnboarding = true
                    return
                }
                #if targetEnvironment(simulator)
                hasSeenOnboarding = true
                if !codex.isConnected,
                   !codex.isConnecting,
                   let simulatorProbe = simulatorPairingPayloadProbe(),
                   case .success(let simulatorPayload, let source) = simulatorProbe {
                    simDebugLog("found pairing payload from \(source.rawValue) for session \(simulatorPayload.sessionId)")
                    await viewModel.connectToRelay(
                        pairingPayload: simulatorPayload,
                        codex: codex
                    )
                } else {
                    logSimulatorPairingProbeFailureIfNeeded()
                }
                #endif
                await viewModel.attemptAutoConnectOnLaunchIfNeeded(codex: codex)
            }
            .task(id: scenePhase) {
                guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
                    return
                }
                guard scenePhase == .active else {
                    return
                }

                while !Task.isCancelled, scenePhase == .active {
                    await viewModel.autoSwitchRelayIfNeeded(codex: codex)
                    try? await Task.sleep(nanoseconds: viewModel.relayAutoSwitchInterval())
                }
            }
            .onChange(of: showSettings) { _, show in
                if ContentSettingsNavigationGate.shouldAppendSettingsRoute(
                    showSettings: show,
                    navigationPathIsEmpty: navigationPath.isEmpty
                ) {
                    navigationPath.append("settings")
                }
                showSettings = false
            }
            .onChange(of: isSidebarOpen) { wasOpen, isOpen in
                guard !wasOpen, isOpen else {
                    return
                }
                if viewModel.shouldRequestSidebarFreshSync(isConnected: codex.isConnected) {
                    codex.requestImmediateSync(threadId: codex.activeThreadId)
                }
            }
            .onChange(of: navigationPath) { _, _ in
                if isSidebarOpen {
                    closeSidebar()
                }
            }
            .onChange(of: selectedThread) { previousThread, thread in
                codex.handleDisplayedThreadChange(
                    from: previousThread?.id,
                    to: thread?.id
                )
                codex.activeThreadId = thread?.id
                if ContentAccountHomeModalPolicy.shouldDismissAfterSelectingThread(
                    selectedThreadID: thread?.id
                ) {
                    dismissAccountHome()
                }
            }
            .onChange(of: codex.activeThreadId) { _, activeThreadId in
                guard let activeThreadId,
                      let matchingThread = codex.threads.first(where: { $0.id == activeThreadId }),
                      selectedThread?.id != matchingThread.id else {
                    return
                }
                selectedThread = matchingThread
            }
            .onChange(of: codex.threads) { _, threads in
                syncSelectedThread(with: threads)
            }
            .onChange(of: scenePhase) { _, phase in
                codex.setForegroundState(phase != .background)
                guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
                    return
                }
                if phase == .active {
                    Task {
                        await viewModel.attemptAutoReconnectOnForegroundIfNeeded(codex: codex)
                    }
                }
            }
            .onChange(of: codex.shouldAutoReconnectOnForeground) { _, shouldReconnect in
                guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
                    return
                }
                guard shouldReconnect, scenePhase == .active else {
                    return
                }
                Task {
                    await viewModel.attemptAutoReconnectOnForegroundIfNeeded(codex: codex)
                }
            }
            .onChange(of: codex.threadCompletionBanner) { _, banner in
                scheduleThreadCompletionBannerDismiss(for: banner)
            }
            // Presents actionable recovery when the saved bridge package is too old/new for this app build.
            .sheet(item: bridgeUpdatePromptBinding, onDismiss: {
                codex.bridgeUpdatePrompt = nil
                isRetryingBridgeUpdate = false
            }) { prompt in
                BridgeUpdateSheet(
                    prompt: prompt,
                    isRetrying: isRetryingBridgeUpdate,
                    onRetry: {
                        retryBridgeConnectionAfterUpdate()
                    },
                    onScanNewQR: {
                        presentManualScannerForBridgeRecovery()
                    },
                    onDismiss: {
                        codex.bridgeUpdatePrompt = nil
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .overlay(alignment: .top) {
                if let banner = codex.threadCompletionBanner {
                    ThreadCompletionBannerView(
                        banner: banner,
                        onTap: {
                            openCompletedThreadFromBanner(banner)
                        },
                        onDismiss: {
                            dismissThreadCompletionBanner()
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.88), value: codex.threadCompletionBanner?.id)
            .alert("Rename Account", isPresented: isRenamingAccountBinding) {
                TextField("Account name", text: $viewModel.pendingAccountDisplayName)
                Button("Save") {
                    viewModel.confirmRename(codex: codex)
                }
                Button("Cancel", role: .cancel) {
                    viewModel.renamingAccountID = nil
                }
            } message: {
                Text("Use a clear name for this pairing profile.")
            }
            .confirmationDialog("Delete Account", isPresented: isDeletingAccountBinding) {
                Button("Continue", role: .destructive) {
                    viewModel.continueDeleteConfirmation()
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cancelDeleteFlow()
                }
            } message: {
                Text("This will start account deletion. You will be asked to confirm again.")
            }
            .alert("Delete Account Permanently?", isPresented: isDeleteFinalConfirmBinding) {
                Button("Delete", role: .destructive) {
                    viewModel.confirmDelete(codex: codex)
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cancelDeleteFlow()
                }
            } message: {
                Text("This only removes the saved pairing profile and cannot be undone.")
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch ContentRootDestination.resolve(
            hasSeenOnboarding: hasSeenOnboarding,
            isShowingManualScanner: isShowingManualScanner
        ) {
        case .onboarding:
            OnboardingView {
                withAnimation { hasSeenOnboarding = true }
            }
        case .scanner:
            qrScannerBody
        case .home:
            homeNavigationBody
        }
    }

    private var qrScannerBody: some View {
        QRScannerView(
            onScan: { pairingPayload in
                Task {
                    isShowingManualScanner = false
                    await viewModel.connectToRelay(
                        pairingPayload: pairingPayload,
                        codex: codex
                    )
                }
            },
            onClose: {
                isShowingManualScanner = false
            }
        )
    }

    private var effectiveSidebarWidth: CGFloat {
        isSearchActive ? UIScreen.main.bounds.width : sidebarWidth
    }

    private var mainAppBody: some View {
        ZStack(alignment: .leading) {
            if sidebarVisible {
                SidebarView(
                    selectedThread: $selectedThread,
                    showSettings: $showSettings,
                    isSearchActive: $isSearchActive,
                    onNavigateToAccountsHome: {
                        presentAccountHome()
                    },
                    onClose: { closeSidebar() }
                )
                .frame(width: effectiveSidebarWidth)
                .animation(.easeInOut(duration: 0.25), value: isSearchActive)
            }

            mainNavigationLayer
                .offset(x: contentOffset)

            if sidebarVisible {
                (colorScheme == .dark ? Color.white : Color.black)
                    .opacity(contentDimOpacity)
                    .ignoresSafeArea()
                    .offset(x: contentOffset)
                    .allowsHitTesting(isSidebarOpen)
                    .onTapGesture { closeSidebar() }
            }
        }
        .gesture(edgeDragGesture)
    }

    private var homeNavigationBody: some View {
        mainAppBody
            .fullScreenCover(isPresented: $isAccountHomePresented) {
                NavigationStack {
                    accountHomeBody
                }
                .interactiveDismissDisabled(true)
            }
    }

    // MARK: - Layers

    private var mainNavigationLayer: some View {
        NavigationStack(path: $navigationPath) {
            chatContent
                .adaptiveNavigationBar()
                .navigationDestination(for: String.self) { destination in
                    if destination == "settings" {
                        SettingsView()
                            .adaptiveNavigationBar()
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatContent: some View {
        Group {
            if let thread = selectedThread {
                TurnView(thread: thread)
                    .id(thread.id)
                    .accessibilityIdentifier("turn.view.root")
            } else {
                ZStack {
                    Color(.systemBackground)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.secondary)
                        Text("Select a chat from the sidebar")
                            .font(AppFont.subheadline())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                hamburgerButton
            }
        }
    }

    private var accountHomeBody: some View {
        AccountPageView(
            connectionPhase: homeConnectionPhase,
            securityLabel: codex.secureConnectionState.statusLabel,
            hasAccounts: !codex.sortedRelayAccounts.isEmpty,
            hasSavedRelaySession: codex.hasSavedRelaySession,
            accounts: codex.sortedRelayAccounts,
            activeRelayAccountID: codex.activeRelayAccountID,
            isConnected: codex.isConnected,
            accountMessage: codex.relayAccountManagementMessage,
            openingAccountID: openingAccountID,
            accentColor: settingsAccentColor,
            lastConnectedText: { account in
                viewModel.relayAccountLastConnectedText(account)
            },
            onToggleConnection: {
                Task {
                    await viewModel.toggleConnection(codex: codex)
                }
            },
            onAddAccount: {
                HapticFeedback.shared.triggerImpactFeedback()
                viewModel.isShowingAddAccountScanner = true
            },
            onScanNewQRCode: {
                Task {
                    await viewModel.stopAutoReconnectForManualScan(codex: codex)
                }
                isShowingManualScanner = true
            },
            onOpenAccount: { accountId in
                startOpeningAccount(accountId)
            },
            onRenameAccount: { account in
                viewModel.requestRename(for: account)
            },
            onDeleteAccount: { account in
                viewModel.requestDelete(for: account)
            }
        )
        .adaptiveNavigationBar()
        .toolbar {
            if !codex.sortedRelayAccounts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    addAccountToolbarButton
                }
            }
        }
        .sheet(isPresented: $viewModel.isShowingAddAccountScanner) {
            NavigationStack {
                QRScannerView(
                    onScan: { pairingPayload in
                        Task {
                            viewModel.isShowingAddAccountScanner = false
                            await viewModel.connectToRelay(
                                pairingPayload: pairingPayload,
                                codex: codex
                            )
                        }
                    },
                    onClose: {
                        viewModel.isShowingAddAccountScanner = false
                    }
                )
            }
        }
        .onDisappear {
            cancelOpeningAccountIfNeeded()
        }
    }

    private var hamburgerButton: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            toggleSidebar()
        } label: {
            TwoLineHamburgerIcon()
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .padding(8)
                .contentShape(Circle())
                .adaptiveToolbarItem(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Menu")
        .accessibilityIdentifier("chat.menu.button")
    }

    private var addAccountToolbarButton: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback()
            viewModel.isShowingAddAccountScanner = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .padding(8)
                .contentShape(Circle())
                .adaptiveToolbarItem(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Account")
    }

    // MARK: - Sidebar Geometry

    private var sidebarVisible: Bool {
        isSidebarOpen || sidebarDragOffset > 0
    }

    private var contentOffset: CGFloat {
        if isSidebarOpen {
            return max(0, effectiveSidebarWidth + sidebarDragOffset)
        } else {
            return max(0, sidebarDragOffset)
        }
    }

    private var contentDimOpacity: Double {
        let progress = min(1, contentOffset / effectiveSidebarWidth)
        return 0.08 * progress
    }

    // MARK: - Gestures

    private var edgeDragGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard navigationPath.isEmpty else { return }

                if !isSidebarOpen {
                    guard value.startLocation.x < 30 else { return }
                    sidebarDragOffset = max(0, value.translation.width)
                } else {
                    sidebarDragOffset = min(0, value.translation.width)
                }
            }
            .onEnded { value in
                guard navigationPath.isEmpty else { return }

                let currentWidth = effectiveSidebarWidth
                let threshold = currentWidth * 0.4

                if !isSidebarOpen {
                    guard value.startLocation.x < 30 else {
                        sidebarDragOffset = 0
                        return
                    }
                    let shouldOpen = value.translation.width > threshold
                        || value.predictedEndTranslation.width > currentWidth * 0.5
                    finishGesture(open: shouldOpen)
                } else {
                    let shouldClose = -value.translation.width > threshold
                        || -value.predictedEndTranslation.width > currentWidth * 0.5
                    finishGesture(open: !shouldClose)
                }
            }
    }

    // MARK: - Sidebar Actions

    private func toggleSidebar() {
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        withAnimation(Self.sidebarSpring) {
            isSidebarOpen.toggle()
            sidebarDragOffset = 0
        }
    }

    private func closeSidebar() {
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        withAnimation(Self.sidebarSpring) {
            isSidebarOpen = false
            sidebarDragOffset = 0
        }
    }

    // Keeps home status honest during reconnect loops while letting post-connect sync show separately.
    private var homeConnectionPhase: CodexConnectionPhase {
        if viewModel.isAttemptingAutoReconnect && !codex.isConnected {
            return .connecting
        }
        return codex.connectionPhase
    }

    private var isRenamingAccountBinding: Binding<Bool> {
        Binding(
            get: { viewModel.renamingAccountID != nil },
            set: { if !$0 { viewModel.renamingAccountID = nil } }
        )
    }

    private var isDeletingAccountBinding: Binding<Bool> {
        Binding(
            get: { viewModel.deletingAccountID != nil },
            set: { if !$0 { viewModel.cancelDeleteFlow() } }
        )
    }

    private var isDeleteFinalConfirmBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingDeleteConfirmationAccountID != nil },
            set: { if !$0 { viewModel.cancelDeleteFlow() } }
        )
    }

    private func finishGesture(open: Bool) {
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        withAnimation(Self.sidebarSpring) {
            isSidebarOpen = open
            sidebarDragOffset = 0
        }
    }

    private var bridgeUpdatePromptBinding: Binding<CodexBridgeUpdatePrompt?> {
        Binding(
            get: { codex.bridgeUpdatePrompt },
            set: { codex.bridgeUpdatePrompt = $0 }
        )
    }

    // Re-tries the saved relay session after the user updates the Mac package.
    private func retryBridgeConnectionAfterUpdate() {
        guard !isRetryingBridgeUpdate else {
            return
        }

        isRetryingBridgeUpdate = true

        Task {
            await viewModel.toggleConnection(codex: codex)
            await MainActor.run {
                isRetryingBridgeUpdate = false
            }
        }
    }

    private func simulatorPairingPayloadProbe() -> SimulatorPairingPayloadProbeResult? {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        let pasteboardString: String? = shouldProbeSimulatorPairingPasteboard(environment: environment)
            ? UIPasteboard.general.string
            : nil
        return probeSimulatorPairingPayload(
            environment: environment,
            pasteboardString: pasteboardString
        )
        #else
        return nil
        #endif
    }

    private func logSimulatorPairingProbeFailureIfNeeded() {
        #if targetEnvironment(simulator)
        switch simulatorPairingPayloadProbe() {
        case .none, .missing:
            simDebugLog("no valid simulator pairing payload on launch")
        case .failure(let failure):
            simDebugLog(
                "simulator pairing payload invalid from \(failure.source.rawValue): \(failure.message); raw=\(failure.rawPreview)"
            )
        case .success:
            break
        }
        #endif
    }

    // Switches the user back to the QR path when the old relay session is no longer useful.
    private func presentManualScannerForBridgeRecovery() {
        codex.bridgeUpdatePrompt = nil
        isRetryingBridgeUpdate = false

        Task {
            await viewModel.stopAutoReconnectForManualScan(codex: codex)
            await MainActor.run {
                isShowingManualScanner = true
            }
        }
    }

    // Auto-hides the banner unless the user taps through to the finished chat first.
    private func scheduleThreadCompletionBannerDismiss(for banner: CodexThreadCompletionBanner?) {
        threadCompletionBannerDismissTask?.cancel()

        guard let banner else {
            threadCompletionBannerDismissTask = nil
            return
        }

        threadCompletionBannerDismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if codex.threadCompletionBanner?.id == banner.id {
                    codex.threadCompletionBanner = nil
                }
            }
        }
    }

    // Lets the user jump straight to the chat that produced the ready sidebar badge.
    private func openCompletedThreadFromBanner(_ banner: CodexThreadCompletionBanner) {
        threadCompletionBannerDismissTask?.cancel()
        codex.threadCompletionBanner = nil

        guard let thread = codex.threads.first(where: { $0.id == banner.threadId }) else {
            return
        }

        if isSidebarOpen {
            closeSidebar()
        }
        dismissAccountHome()
        selectedThread = thread
        codex.activeThreadId = thread.id
        codex.markThreadAsViewed(thread.id)
    }

    private func dismissThreadCompletionBanner() {
        threadCompletionBannerDismissTask?.cancel()
        codex.threadCompletionBanner = nil
    }

    private func openThread(_ thread: CodexThread) {
        cancelOpeningAccountIfNeeded()
        dismissAccountHome()
        selectedThread = thread
        codex.activeThreadId = thread.id
        codex.markThreadAsViewed(thread.id)
    }

    private func startOpeningAccount(_ accountId: String) {
        cancelOpeningAccountIfNeeded()

        let requestID = UUID()
        latestOpenAccountRequestID = requestID
        openingAccountID = accountId
        dismissAccountHome()

        openAccountTask = Task {
            let thread = await viewModel.openRelayAccount(accountId, codex: codex)
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard latestOpenAccountRequestID == requestID else {
                    return
                }
                openAccountTask = nil
                openingAccountID = nil
                if let thread {
                    openThread(thread)
                } else {
                    presentAccountHome()
                }
            }
        }
    }

    private func cancelOpeningAccountIfNeeded() {
        openAccountTask?.cancel()
        openAccountTask = nil
        openingAccountID = nil
    }

    private func dismissAccountHome() {
        if isAccountHomePresented {
            withAnimation(.easeInOut(duration: 0.22)) {
                isAccountHomePresented = false
            }
        }
    }

    private func presentAccountHome() {
        if !isAccountHomePresented {
            withAnimation(.easeInOut(duration: 0.22)) {
                isAccountHomePresented = true
            }
        }
    }

    // Keeps selected thread coherent with server list updates.
    private func syncSelectedThread(with threads: [CodexThread]) {
        let resolvedSelectionID = ContentThreadSelectionPolicy.selectedThreadID(
            currentSelectedThreadID: selectedThread?.id,
            activeThreadID: codex.activeThreadId,
            pendingNotificationOpenThreadID: codex.pendingNotificationOpenThreadID,
            availableThreadIDs: threads.map(\.id)
        )

        if ContentSidebarPresentationPolicy.shouldOpenSidebar(
            resolvedSelectionID: resolvedSelectionID,
            availableThreadCount: threads.count
        ), !isSidebarOpen {
            withAnimation(Self.sidebarSpring) {
                isSidebarOpen = true
            }
        }

        if selectedThread?.id != resolvedSelectionID {
            selectedThread = threads.first(where: { $0.id == resolvedSelectionID })
            return
        }

        if let selected = selectedThread,
           let refreshed = threads.first(where: { $0.id == selected.id }) {
            selectedThread = refreshed
        }
    }

    private func seedRelayAccountsForUITestsIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-CodexUITestsSeedRelayAccounts"),
              codex.relayAccountProfiles.isEmpty else {
            return
        }

        let relayAuthKey = "uitest-auth-key"
        let macIdentityPublicKey = Data(repeating: 7, count: 32).base64EncodedString()

        let accountA = CodexPairingQRPayload(
            v: codexPairingQRVersion,
            relay: "ws://127.0.0.1:8788/relay",
            relayCandidates: [
                "ws://127.0.0.1:8788/relay",
                "ws://localhost:8788/relay",
            ],
            relayAuthKey: relayAuthKey,
            sessionId: "uitest-session-public",
            macDeviceId: "uitest-mac-public",
            macIdentityPublicKey: macIdentityPublicKey,
            expiresAt: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        )
        codex.rememberRelayPairing(accountA)

        let accountB = CodexPairingQRPayload(
            v: codexPairingQRVersion,
            relay: "ws://localhost:8788/relay",
            relayCandidates: [
                "ws://localhost:8788/relay",
                "ws://127.0.0.1:8788/relay",
            ],
            relayAuthKey: relayAuthKey,
            sessionId: "uitest-session-lan",
            macDeviceId: "uitest-mac-lan",
            macIdentityPublicKey: macIdentityPublicKey,
            expiresAt: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        )
        codex.rememberRelayPairing(accountB)
    }

    // Seeds a deterministic local timeline so UI performance tests don't depend on relay connectivity.
    private func applyUITestTimelineFixtureIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-CodexUITestsFixture") else {
            return
        }

        let messageCount = max(1, uiTestIntArgumentValue(flag: "-CodexUITestsMessageCount", fallback: 200))
        let threadId = "uitest-thread"
        let fixtureThread = CodexThread(
            id: threadId,
            title: "UI Test Conversation",
            updatedAt: Date(),
            syncState: .live
        )
        codex.upsertThread(fixtureThread)

        let existingCount = codex.messagesByThread[threadId]?.count ?? 0
        if existingCount != messageCount {
            let seedDate = Date()
            var fixtureMessages: [CodexMessage] = []
            fixtureMessages.reserveCapacity(messageCount)

            for index in 0 ..< messageCount {
                let role: CodexMessageRole = index.isMultiple(of: 2) ? .user : .assistant
                fixtureMessages.append(
                    CodexMessage(
                        threadId: threadId,
                        role: role,
                        text: "Fixture message \(index + 1)",
                        createdAt: seedDate.addingTimeInterval(Double(index))
                    )
                )
            }

            codex.messagesByThread[threadId] = fixtureMessages
        }

        selectedThread = fixtureThread
        codex.activeThreadId = threadId
        isAccountHomePresented = false
        hasSeenOnboarding = true
    }

    private func uiTestIntArgumentValue(flag: String, fallback: Int) -> Int {
        let args = ProcessInfo.processInfo.arguments
        guard let flagIndex = args.firstIndex(of: flag),
              flagIndex + 1 < args.count,
              let parsed = Int(args[flagIndex + 1]) else {
            return fallback
        }

        return parsed
    }
}

enum ContentSettingsNavigationGate {
    static func shouldAppendSettingsRoute(
        showSettings: Bool,
        navigationPathIsEmpty: Bool
    ) -> Bool {
        showSettings && navigationPathIsEmpty
    }
}

enum SimulatorPairingPayloadSource: String, Equatable {
    case environment
    case pasteboard
}

struct SimulatorPairingPayloadFailure: Equatable {
    let source: SimulatorPairingPayloadSource
    let message: String
    let rawPreview: String
}

enum SimulatorPairingPayloadProbeResult {
    case missing
    case success(CodexPairingQRPayload, SimulatorPairingPayloadSource)
    case failure(SimulatorPairingPayloadFailure)
}

func probeSimulatorPairingPayload(
    environment: [String: String],
    pasteboardString: String?
) -> SimulatorPairingPayloadProbeResult {
    if let rawValue = environment["REMODEX_SIM_PAIRING_PAYLOAD"] {
        return parseSimulatorPairingPayload(rawValue, source: .environment)
    }

    guard shouldProbeSimulatorPairingPasteboard(environment: environment) else {
        return .missing
    }

    if let pasteboardString, !pasteboardString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return parseSimulatorPairingPayload(pasteboardString, source: .pasteboard)
    }

    return .missing
}

private func shouldProbeSimulatorPairingPasteboard(environment: [String: String]) -> Bool {
    guard let raw = environment["REMODEX_SIM_PAIRING_ALLOW_PASTEBOARD"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() else {
        return false
    }

    return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
}

private func parseSimulatorPairingPayload(
    _ rawValue: String,
    source: SimulatorPairingPayloadSource
) -> SimulatorPairingPayloadProbeResult {
    do {
        return .success(try CodexPairingQRPayload.parse(from: rawValue), source)
    } catch {
        return .failure(
            SimulatorPairingPayloadFailure(
                source: source,
                message: error.localizedDescription,
                rawPreview: simulatorPairingRawPreview(rawValue)
            )
        )
    }
}

private func simulatorPairingRawPreview(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= 120 {
        return trimmed
    }

    return "\(trimmed.prefix(120))..."
}

enum ContentAccountHomePresentationPolicy {
    static func showsHeroSection(hasAccounts: Bool) -> Bool {
        !hasAccounts
    }
}

enum ContentAccountHomeModalPolicy {
    static func shouldDismissAfterSelectingThread(selectedThreadID: String?) -> Bool {
        selectedThreadID != nil
    }
}

enum ContentRelayAccountHomePolicy {
    static func preferredThreadToOpen(from threads: [CodexThread]) -> CodexThread? {
        threads.first(where: { $0.syncState == .live }) ?? threads.first
    }
}

enum ContentRootDestination: Equatable {
    case onboarding
    case scanner
    case home

    static func resolve(
        hasSeenOnboarding: Bool,
        isShowingManualScanner: Bool
    ) -> Self {
        guard hasSeenOnboarding else {
            return .onboarding
        }

        return isShowingManualScanner ? .scanner : .home
    }
}

enum ContentThreadSelectionPolicy {
    static func selectedThreadID(
        currentSelectedThreadID: String?,
        activeThreadID: String?,
        pendingNotificationOpenThreadID: String?,
        availableThreadIDs: [String]
    ) -> String? {
        guard let currentSelectedThreadID else {
            return nil
        }

        if availableThreadIDs.contains(currentSelectedThreadID) {
            return currentSelectedThreadID
        }

        if activeThreadID == currentSelectedThreadID {
            return currentSelectedThreadID
        }

        if pendingNotificationOpenThreadID != nil {
            return nil
        }

        return nil
    }
}

enum ContentSidebarPresentationPolicy {
    static func shouldOpenSidebar(
        resolvedSelectionID: String?,
        availableThreadCount: Int
    ) -> Bool {
        resolvedSelectionID == nil && availableThreadCount > 0
    }
}

private struct TwoLineHamburgerIcon: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 1)
                .frame(width: 20, height: 2)

            RoundedRectangle(cornerRadius: 1)
                .frame(width: 10, height: 2)
        }
        .frame(width: 20, height: 14, alignment: .leading)
    }
}

#Preview {
    ContentView()
        .environment(CodexService())
}
