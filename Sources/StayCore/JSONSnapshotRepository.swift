import Foundation

// Design goal: persistence is best-effort; in-memory snapshots still allow restore.
public final class JSONSnapshotRepository: SnapshotRepository {
    private let url: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() -> [WindowSnapshot] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }

        return (try? decoder.decode([WindowSnapshot].self, from: data)) ?? []
    }

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
