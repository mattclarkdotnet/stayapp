import CoreGraphics
import Foundation
import OSLog
import StayCore

// Design goal: do not restore until every captured display is available and awake.
// If any window lacks a captured display ID, readiness remains false so coordinator
// keeps retrying (with timeout fallback) instead of restoring too early.
final class DisplayWakeReadinessChecker: RestoreReadinessChecking {
    private let logger = Logger(subsystem: "com.stay.app", category: "DisplayWakeReadinessChecker")

    func isReady(toRestore snapshots: [WindowSnapshot]) -> Bool {
        guard !snapshots.isEmpty else {
            logger.debug("Readiness check: empty snapshot list treated as ready")
            return true
        }

        if snapshots.contains(where: { $0.screenDisplayID == nil }) {
            logger.debug("Readiness check: at least one snapshot missing display ID")
            return false
        }

        let requiredDisplays = Set(snapshots.compactMap { $0.screenDisplayID })
        guard !requiredDisplays.isEmpty else {
            logger.debug("Readiness check: required display set is empty")
            return false
        }

        let onlineDisplays = currentOnlineDisplayIDs()
        logger.debug(
            "Readiness check: required=\(Self.sortedIDs(requiredDisplays), privacy: .public) online=\(Self.sortedIDs(onlineDisplays), privacy: .public)"
        )

        for displayID in requiredDisplays {
            guard onlineDisplays.contains(displayID) else {
                logger.debug(
                    "Readiness check: display \(displayID, privacy: .public) is not online")
                return false
            }

            if CGDisplayIsAsleep(displayID) != 0 {
                logger.debug("Readiness check: display \(displayID, privacy: .public) is asleep")
                return false
            }
        }

        logger.debug("Readiness check: all required displays are online and awake")
        return true
    }

    private func currentOnlineDisplayIDs() -> Set<CGDirectDisplayID> {
        var displayCount: UInt32 = 0
        let countResult = CGGetOnlineDisplayList(0, nil, &displayCount)
        if countResult != .success {
            logger.error(
                "CGGetOnlineDisplayList (count query) failed with code \(countResult.rawValue, privacy: .public)"
            )
            return []
        }

        guard displayCount > 0 else {
            return []
        }

        var displays = Array(repeating: CGDirectDisplayID(), count: Int(displayCount))
        let listResult = CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        if listResult != .success {
            logger.error(
                "CGGetOnlineDisplayList (list query) failed with code \(listResult.rawValue, privacy: .public)"
            )
            return []
        }

        return Set(displays.prefix(Int(displayCount)))
    }

    private static func sortedIDs(_ ids: Set<CGDirectDisplayID>) -> String {
        ids.sorted().map(String.init).joined(separator: ",")
    }
}
