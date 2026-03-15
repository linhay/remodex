// FILE: SidebarThreadMetricStaging.swift
// Purpose: Splits sidebar metric calculation into visible-first and deferred phases.
// Layer: View Helper
// Exports: SidebarThreadMetricStaging
// Depends on: Foundation

import Foundation

enum SidebarThreadMetricStaging {
    struct Partition {
        let visible: [String]
        let deferred: [String]
    }

    static func visibleThreadIDs(from groups: [SidebarThreadGroup]) -> Set<String> {
        Set(groups.flatMap(\.threads).map(\.id))
    }

    static func partitionThreadIDs(from threads: [CodexThread], visibleThreadIDs: Set<String>) -> Partition {
        var visible: [String] = []
        var deferred: [String] = []

        for thread in threads {
            if visibleThreadIDs.contains(thread.id) {
                visible.append(thread.id)
            } else {
                deferred.append(thread.id)
            }
        }

        return Partition(visible: visible, deferred: deferred)
    }
}
