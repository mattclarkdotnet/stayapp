import Foundation
import StayCore

// Design goal: keep the manual-tools submenu and snapshot summary derivable from
// pure data so menu restructuring can be tested without AppKit menu objects.
struct AdvancedMenuPresentation: Equatable {
    let isManualCaptureEnabled: Bool
    let isManualRestoreEnabled: Bool
    let latestSnapshotItemTitle: String
    let latestSnapshotEntries: [String]

    init(isPaused: Bool, snapshots: [WindowSnapshot]) {
        isManualCaptureEnabled = !isPaused
        isManualRestoreEnabled = !isPaused
        latestSnapshotItemTitle = "Latest Snapshot"

        let sortedSnapshots = snapshots.sorted { lhs, rhs in
            let appComparison = lhs.appName.localizedCaseInsensitiveCompare(rhs.appName)
            if appComparison != .orderedSame {
                return appComparison == .orderedAscending
            }

            return lhs.windowIndex < rhs.windowIndex
        }

        if sortedSnapshots.isEmpty {
            latestSnapshotEntries = ["No saved layout"]
        } else {
            latestSnapshotEntries = sortedSnapshots.map(Self.snapshotEntryTitle(for:))
        }
    }

    private static func snapshotEntryTitle(for snapshot: WindowSnapshot) -> String {
        let trimmedTitle =
            snapshot.windowTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let windowLabel: String
        if let trimmedTitle, !trimmedTitle.isEmpty {
            windowLabel = trimmedTitle
        } else if let windowRole = snapshot.windowRole, !windowRole.isEmpty {
            windowLabel = "\(windowRole) \(snapshot.windowIndex + 1)"
        } else {
            windowLabel = "Window \(snapshot.windowIndex + 1)"
        }

        return "\(snapshot.appName) - \(windowLabel)"
    }
}
