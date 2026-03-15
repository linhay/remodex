// FILE: SidebarViewModel.swift
// Purpose: Owns SidebarView local state and non-visual orchestration.
// Layer: ViewModel
// Exports: SidebarViewModel
// Depends on: Foundation, Observation, CodexService, Sidebar helpers

import Foundation
import Observation

@Observable
final class SidebarViewModel {
    var searchText = ""
    var isCreatingThread = false
    var groupedThreads: [SidebarThreadGroup] = []
    var isShowingNewChatProjectPicker = false
    var projectGroupPendingArchive: SidebarThreadGroup?
    var threadPendingDeletion: CodexThread?
    var createThreadErrorMessage: String?
    var runBadgeStateByThreadID: [String: CodexThreadRunBadgeState] = [:]
    var sidebarDiffTotalsByThreadID: [String: TurnSessionDiffTotals] = [:]

    @ObservationIgnored private var groupingRebuildDebouncer = SidebarGroupingRebuildDebouncer()
    @ObservationIgnored private var sidebarMetricHydrationTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarMetricRevision = 0

    func canCreateThread(codex: CodexService) -> Bool {
        codex.isConnected && codex.isInitialized
    }

    func newChatProjectChoices(from threads: [CodexThread]) -> [SidebarProjectChoice] {
        SidebarThreadGrouping.makeProjectChoices(from: threads)
    }

    func filteredThreads(from threads: [CodexThread]) -> [CodexThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return threads
        }

        return threads.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.projectDisplayName.localizedCaseInsensitiveContains(query)
        }
    }

    func rebuildGroupedThreads(codex: CodexService) {
        groupedThreads = SidebarThreadGrouping.makeGroups(from: filteredThreads(from: codex.threads))
        refreshSidebarThreadMetrics(codex: codex)
    }

    func scheduleGroupedThreadsRebuild(codex: CodexService) {
        groupingRebuildDebouncer.schedule { [weak self] in
            self?.rebuildGroupedThreads(codex: codex)
        }
    }

    func cancelBackgroundWork() {
        groupingRebuildDebouncer.cancel()
        sidebarMetricHydrationTask?.cancel()
        sidebarMetricHydrationTask = nil
    }

    private func refreshSidebarThreadMetrics(codex: CodexService) {
        sidebarMetricHydrationTask?.cancel()
        sidebarMetricRevision += 1
        let revision = sidebarMetricRevision

        let visibleThreadIDs = SidebarThreadMetricStaging.visibleThreadIDs(from: groupedThreads)
        let partition = SidebarThreadMetricStaging.partitionThreadIDs(
            from: codex.threads,
            visibleThreadIDs: visibleThreadIDs
        )

        var visibleRunBadgeByThreadID: [String: CodexThreadRunBadgeState] = [:]
        var visibleDiffTotalsByThreadID: [String: TurnSessionDiffTotals] = [:]

        for threadID in partition.visible {
            if let state = codex.threadRunBadgeState(for: threadID) {
                visibleRunBadgeByThreadID[threadID] = state
            }
            if let totals = diffTotals(for: threadID, codex: codex) {
                visibleDiffTotalsByThreadID[threadID] = totals
            }
        }

        runBadgeStateByThreadID = visibleRunBadgeByThreadID
        sidebarDiffTotalsByThreadID = visibleDiffTotalsByThreadID

        guard !partition.deferred.isEmpty else {
            return
        }

        sidebarMetricHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, revision == self.sidebarMetricRevision else {
                return
            }

            var hydratedRunBadgeByThreadID = self.runBadgeStateByThreadID
            var hydratedDiffTotalsByThreadID = self.sidebarDiffTotalsByThreadID

            for threadID in partition.deferred {
                if let state = codex.threadRunBadgeState(for: threadID) {
                    hydratedRunBadgeByThreadID[threadID] = state
                }
                if let totals = self.diffTotals(for: threadID, codex: codex) {
                    hydratedDiffTotalsByThreadID[threadID] = totals
                }
            }

            guard !Task.isCancelled, revision == self.sidebarMetricRevision else {
                return
            }

            self.runBadgeStateByThreadID = hydratedRunBadgeByThreadID
            self.sidebarDiffTotalsByThreadID = hydratedDiffTotalsByThreadID
        }
    }

    private func diffTotals(for threadID: String, codex: CodexService) -> TurnSessionDiffTotals? {
        let messages = codex.messages(for: threadID)
        return TurnSessionDiffSummaryCalculator.totals(
            from: messages,
            scope: .unpushedSession
        )
    }
}
