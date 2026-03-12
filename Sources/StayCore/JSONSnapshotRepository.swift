import Foundation

// Design goal: persistence is best-effort; in-memory snapshots still allow restore.
/// JSON-backed snapshot repository.
public final class JSONSnapshotRepository: SnapshotRepository {
    private let url: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Creates a repository that reads/writes snapshots at `url`.
    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    /// Loads snapshots from disk, or an empty array when unavailable/invalid.
    public func load() -> [WindowSnapshot] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }

        return (try? decoder.decode([WindowSnapshot].self, from: data)) ?? []
    }

    /// Persists snapshots atomically. Failures are intentionally non-fatal.
    public func save(_ snapshots: [WindowSnapshot]) {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let data = try encoder.encode(snapshots)
            try data.write(to: url, options: .atomic)
        } catch {
            // Fail silently. The app can still restore from in-memory snapshots.
        }
    }

    /// Removes snapshots whose saved display is no longer present.
    @discardableResult
    public func invalidateSnapshots(keepingDisplayIDs activeDisplayIDs: Set<UInt32>) -> Int {
        let snapshots = load()
        guard !snapshots.isEmpty else {
            return 0
        }

        let filteredSnapshots = snapshots.filter { snapshot in
            guard let screenDisplayID = snapshot.screenDisplayID else {
                return true
            }

            return activeDisplayIDs.contains(screenDisplayID)
        }

        let removedCount = snapshots.count - filteredSnapshots.count
        if removedCount > 0 {
            save(filteredSnapshots)
        }

        return removedCount
    }

    /// Default snapshot file location inside Application Support.
    public static func defaultURL(appName: String = "Stay", fileManager: FileManager = .default)
        -> URL
    {
        let supportDirectory =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        return
            supportDirectory
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("window-layout.json", isDirectory: false)
    }
}
