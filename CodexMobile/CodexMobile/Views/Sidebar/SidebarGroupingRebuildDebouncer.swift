// FILE: SidebarGroupingRebuildDebouncer.swift
// Purpose: Debounces sidebar group rebuild requests so rapid thread/search changes do not thrash rendering.
// Layer: View Helper
// Exports: SidebarGroupingRebuildDebouncer
// Depends on: Foundation

import Foundation

@MainActor
final class SidebarGroupingRebuildDebouncer {
    private var pendingTask: Task<Void, Never>?

    func schedule(
        delayNanoseconds: UInt64 = 150_000_000,
        action: @escaping @MainActor () -> Void
    ) {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            action()
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}
