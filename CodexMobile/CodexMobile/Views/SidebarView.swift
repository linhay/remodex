// FILE: SidebarView.swift
// Purpose: Orchestrates the sidebar experience with modular presentation components.
// Layer: View
// Exports: SidebarView
// Depends on: CodexService, Sidebar* components/helpers

import SwiftUI

struct SidebarView: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.colorScheme) private var colorScheme

    @Binding var selectedThread: CodexThread?
    @Binding var showSettings: Bool
    @Binding var isSearchActive: Bool

    let onClose: () -> Void

    @State private var viewModel = SidebarViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(alignment: .leading, spacing: 0) {
            SidebarHeaderView()

            SidebarSearchField(text: $viewModel.searchText, isActive: $isSearchActive)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 6)

            SidebarNewChatButton(
                isCreatingThread: viewModel.isCreatingThread,
                isEnabled: viewModel.canCreateThread(codex: codex),
                statusMessage: nil,
                action: handleNewChatButtonTap
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            SidebarThreadListView(
                isFiltering: !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isConnected: codex.isConnected,
                isCreatingThread: viewModel.isCreatingThread,
                threads: codex.threads,
                groups: viewModel.groupedThreads,
                selectedThread: selectedThread,
                bottomContentInset: 0,
                timingLabelProvider: { SidebarRelativeTimeFormatter.compactLabel(for: $0) },
                diffTotalsByThreadID: viewModel.sidebarDiffTotalsByThreadID,
                runBadgeStateByThreadID: viewModel.runBadgeStateByThreadID,
                onSelectThread: selectThread,
                onCreateThreadInProjectGroup: { group in
                    handleNewChatTap(preferredProjectPath: group.projectPath)
                },
                onArchiveProjectGroup: { group in
                    viewModel.projectGroupPendingArchive = group
                },
                onRenameThread: { thread, newName in
                    codex.renameThread(thread.id, name: newName)
                },
                onArchiveToggleThread: { thread in
                    if thread.syncState == .archivedLocal {
                        codex.unarchiveThread(thread.id)
                    } else {
                        codex.archiveThread(thread.id)
                        if selectedThread?.id == thread.id {
                            selectedThread = nil
                        }
                    }
                },
                onDeleteThread: { thread in
                    viewModel.threadPendingDeletion = thread
                }
            )
            .refreshable {
                await refreshThreads()
            }

            HStack(spacing: 10) {
                SidebarFloatingSettingsButton(colorScheme: colorScheme, action: openSettings)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task {
            viewModel.rebuildGroupedThreads(codex: codex)
            if codex.isConnected, codex.threads.isEmpty {
                await refreshThreads()
            }
        }
        .onChange(of: codex.threads) { _, _ in
            viewModel.scheduleGroupedThreadsRebuild(codex: codex)
        }
        .onChange(of: viewModel.searchText) { _, _ in
            viewModel.scheduleGroupedThreadsRebuild(codex: codex)
        }
        .onDisappear {
            viewModel.cancelBackgroundWork()
        }
        .overlay {
            if codex.isLoadingThreads {
                ProgressView()
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: $viewModel.isShowingNewChatProjectPicker) {
            SidebarNewChatProjectPickerSheet(
                choices: viewModel.newChatProjectChoices(from: codex.threads),
                onSelectProject: { projectPath in
                    handleNewChatTap(preferredProjectPath: projectPath)
                },
                onSelectWithoutProject: {
                    handleNewChatTap(preferredProjectPath: nil)
                }
            )
        }
        .confirmationDialog(
            "Archive \"\(viewModel.projectGroupPendingArchive?.label ?? "project")\"?",
            isPresented: Binding(
                get: { viewModel.projectGroupPendingArchive != nil },
                set: { if !$0 { viewModel.projectGroupPendingArchive = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Archive Project") {
                archivePendingProjectGroup()
            }
            Button("Cancel", role: .cancel) {
                viewModel.projectGroupPendingArchive = nil
            }
        } message: {
            Text("All active chats in this project will be archived.")
        }
        .confirmationDialog(
            "Delete \"\(viewModel.threadPendingDeletion?.displayTitle ?? "conversation")\"?",
            isPresented: Binding(
                get: { viewModel.threadPendingDeletion != nil },
                set: { if !$0 { viewModel.threadPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let thread = viewModel.threadPendingDeletion {
                    if selectedThread?.id == thread.id {
                        selectedThread = nil
                    }
                    codex.deleteThread(thread.id)
                }
                viewModel.threadPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                viewModel.threadPendingDeletion = nil
            }
        }
        .alert(
            "Action failed",
            isPresented: Binding(
                get: { viewModel.createThreadErrorMessage != nil },
                set: { if !$0 { viewModel.createThreadErrorMessage = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) {
                    viewModel.createThreadErrorMessage = nil
                }
            },
            message: {
                Text(viewModel.createThreadErrorMessage ?? "Please try again.")
            }
        )
    }

    // MARK: - Actions

    private func refreshThreads() async {
        guard codex.isConnected else { return }
        do {
            try await codex.listThreads()
        } catch {
            // Error stored in CodexService.
        }
    }

    // Shows a native sheet so folder names and full paths stay readable on small screens.
    private func handleNewChatButtonTap() {
        if viewModel.newChatProjectChoices(from: codex.threads).isEmpty {
            handleNewChatTap(preferredProjectPath: nil)
            return
        }

        viewModel.isShowingNewChatProjectPicker = true
    }

    private func handleNewChatTap(preferredProjectPath: String?) {
        Task { @MainActor in
            guard codex.isConnected else {
                viewModel.createThreadErrorMessage = "Connect to runtime first."
                return
            }
            guard codex.isInitialized else {
                viewModel.createThreadErrorMessage = "Runtime is still initializing. Wait a moment and retry."
                return
            }

            viewModel.createThreadErrorMessage = nil
            viewModel.isCreatingThread = true
            defer { viewModel.isCreatingThread = false }

            do {
                let thread = try await codex.startThread(preferredProjectPath: preferredProjectPath)
                selectedThread = thread
                onClose()
            } catch {
                let message = error.localizedDescription
                codex.lastErrorMessage = message
                viewModel.createThreadErrorMessage = message.isEmpty ? "Unable to create a chat right now." : message
            }
        }
    }

    private func selectThread(_ thread: CodexThread) {
        viewModel.searchText = ""
        codex.activeThreadId = thread.id
        codex.markThreadAsViewed(thread.id)
        selectedThread = thread
        onClose()
    }

    private func openSettings() {
        viewModel.searchText = ""
        showSettings = true
        onClose()
    }

    // Archives every live chat in the selected project group and clears the current selection if needed.
    private func archivePendingProjectGroup() {
        guard let group = viewModel.projectGroupPendingArchive else { return }

        let threadIDs = SidebarThreadGrouping.liveThreadIDsForProjectGroup(group, in: codex.threads)
        let selectedThreadWasArchived = selectedThread.map { selected in
            threadIDs.contains(selected.id)
        } ?? false

        _ = codex.archiveThreadGroup(threadIDs: threadIDs)

        if selectedThreadWasArchived {
            selectedThread = codex.threads.first(where: { thread in
                thread.syncState == .live && !threadIDs.contains(thread.id)
            })
        }

        viewModel.projectGroupPendingArchive = nil
    }
}

private struct SidebarNewChatProjectPickerSheet: View {
    let choices: [SidebarProjectChoice]
    let onSelectProject: (String) -> Void
    let onSelectWithoutProject: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose a project for this chat.")
                        .font(AppFont.body())
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section("Projects") {
                    ForEach(choices) { choice in
                        Button {
                            dismiss()
                            onSelectProject(choice.projectPath)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "folder")
                                    .font(AppFont.body(weight: .medium))
                                    .foregroundStyle(.secondary)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(choice.label)
                                        .font(AppFont.body(weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(choice.projectPath)
                                        .font(AppFont.mono(.caption))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section {
                    Button {
                        dismiss()
                        onSelectWithoutProject()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "plus.bubble")
                                .font(AppFont.body(weight: .medium))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("No Project")
                                    .font(AppFont.body(weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text("Start a chat without a working directory.")
                                    .font(AppFont.body())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    // Explains the existing scoping rule at the exact moment the user chooses it.
                    Text("Chats started in a project stay scoped to that working directory. If you pick No Project, the chat is global.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Start new chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents(choices.count > 4 ? [.medium, .large] : [.medium])
    }
}
