// FILE: SidebarViewModelTests.swift
// Purpose: Verifies SidebarViewModel filtering and create-chat gating behavior.
// Layer: Unit Test
// Exports: SidebarViewModelTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class SidebarViewModelTests: XCTestCase {
    private static var retainedViewModels: [SidebarViewModel] = []
    private static var retainedServices: [CodexService] = []

    func testFilteredThreadsReturnsAllWhenSearchQueryIsEmpty() {
        let viewModel = SidebarViewModel()
        Self.retainedViewModels.append(viewModel)
        viewModel.searchText = "   "

        let threads = [
            makeThread(id: "thread-a", title: "Fix login", cwd: "/Users/me/work/app"),
            makeThread(id: "thread-b", title: "Ship docs", cwd: "/Users/me/work/docs"),
        ]

        let filtered = viewModel.filteredThreads(from: threads)

        XCTAssertEqual(filtered.map(\.id), ["thread-a", "thread-b"])
    }

    func testFilteredThreadsMatchesTitleOrProjectNameCaseInsensitive() {
        let viewModel = SidebarViewModel()
        Self.retainedViewModels.append(viewModel)
        let threads = [
            makeThread(id: "thread-a", title: "Fix Login Form", cwd: "/Users/me/work/app"),
            makeThread(id: "thread-b", title: "Release", cwd: "/Users/me/work/ServerAPI"),
            makeThread(id: "thread-c", title: "Refactor", cwd: "/Users/me/work/docs"),
        ]

        viewModel.searchText = "login"
        XCTAssertEqual(viewModel.filteredThreads(from: threads).map(\.id), ["thread-a"])

        viewModel.searchText = "serverapi"
        XCTAssertEqual(viewModel.filteredThreads(from: threads).map(\.id), ["thread-b"])
    }

    func testCanCreateThreadRequiresConnectedAndInitialized() {
        let viewModel = SidebarViewModel()
        Self.retainedViewModels.append(viewModel)
        let codex = CodexService()
        Self.retainedServices.append(codex)

        codex.isConnected = false
        codex.isInitialized = true
        XCTAssertFalse(viewModel.canCreateThread(codex: codex))

        codex.isConnected = true
        codex.isInitialized = false
        XCTAssertFalse(viewModel.canCreateThread(codex: codex))

        codex.isConnected = true
        codex.isInitialized = true
        XCTAssertTrue(viewModel.canCreateThread(codex: codex))
    }

    func testNewChatProjectChoicesSkipsNoProjectAndArchivedGroups() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = SidebarViewModel()
        Self.retainedViewModels.append(viewModel)
        let threads = [
            makeThread(id: "thread-app", title: "App", updatedAt: now, cwd: "/Users/me/work/app"),
            makeThread(id: "thread-none", title: "Global", updatedAt: now.addingTimeInterval(-60), cwd: nil),
            makeThread(
                id: "thread-archived",
                title: "Archived",
                updatedAt: now.addingTimeInterval(-120),
                cwd: "/Users/me/work/archive",
                syncState: .archivedLocal
            ),
        ]

        let choices = viewModel.newChatProjectChoices(from: threads)

        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices.first?.label, "app")
        XCTAssertEqual(choices.first?.projectPath, "/Users/me/work/app")
    }
}

private extension SidebarViewModelTests {
    func makeThread(
        id: String,
        title: String,
        updatedAt: Date = .now,
        cwd: String?,
        syncState: CodexThreadSyncState = .live
    ) -> CodexThread {
        CodexThread(
            id: id,
            title: title,
            updatedAt: updatedAt,
            cwd: cwd,
            syncState: syncState
        )
    }
}
