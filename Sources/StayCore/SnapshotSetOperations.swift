import Foundation

// Design goal: keep snapshot set transformations pure and deterministic so they
// can be unit-tested without coordinator timing concerns.
enum SnapshotSetOperations {
    typealias AppIdentity = String

    static func mergeLatestWithFallback(latest: [WindowSnapshot], fallback: [WindowSnapshot])
        -> [WindowSnapshot]
    {
        guard !latest.isEmpty else {
            return fallback
        }

        guard !fallback.isEmpty else {
            return latest
        }

        let latestByApp = Dictionary(grouping: latest, by: appIdentity)
        let fallbackByApp = Dictionary(grouping: fallback, by: appIdentity)
        let allKeys = Set(latestByApp.keys).union(fallbackByApp.keys).sorted()

        var merged: [WindowSnapshot] = []
        merged.reserveCapacity(max(latest.count, fallback.count))

        for key in allKeys {
            let latestForApp = latestByApp[key] ?? []
            let fallbackForApp = fallbackByApp[key] ?? []

            // Prefer latest per-app snapshots whenever that app was seen at
            // willSleep. Only use persisted fallback snapshots when latest
            // captured no snapshots for that app.
            if !latestForApp.isEmpty {
                merged.append(contentsOf: latestForApp)
            } else if !fallbackForApp.isEmpty {
                merged.append(contentsOf: fallbackForApp)
            }
        }

        return merged
    }

    static func removeResolved(from pending: [WindowSnapshot], resolved: [WindowSnapshot])
        -> [WindowSnapshot]
    {
        guard !pending.isEmpty, !resolved.isEmpty else {
            return pending
        }

        var pendingRemovalCountBySnapshot: [WindowSnapshot: Int] = [:]
        for snapshot in resolved {
            pendingRemovalCountBySnapshot[snapshot, default: 0] += 1
        }

        var filtered: [WindowSnapshot] = []
        filtered.reserveCapacity(pending.count)

        for snapshot in pending {
            let pendingRemovalCount = pendingRemovalCountBySnapshot[snapshot] ?? 0
            if pendingRemovalCount > 0 {
                pendingRemovalCountBySnapshot[snapshot] = pendingRemovalCount - 1
            } else {
                filtered.append(snapshot)
            }
        }

        return filtered
    }

    static func appIdentity(for snapshot: WindowSnapshot) -> AppIdentity {
        if let bundleID = snapshot.appBundleID, !bundleID.isEmpty {
            return "bundle:\(bundleID)"
        }
        return "pid:\(snapshot.appPID)"
    }
}
