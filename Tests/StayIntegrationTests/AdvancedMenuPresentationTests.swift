import Foundation
import Testing

@testable import Stay
@testable import StayCore

@Suite("AdvancedMenuPresentation")
struct AdvancedMenuPresentationTests {
    @Test("Ready state keeps manual actions enabled and formats latest snapshot entries")
    func readyStatePresentation() {
        let presentation = AdvancedMenuPresentation(
            isPaused: false,
            snapshots: [
                snapshot(appName: "Finder", title: "Project Notes", index: 1),
                snapshot(appName: "TextEdit", title: nil, index: 0),
            ]
        )

        #expect(presentation.isManualCaptureEnabled)
        #expect(presentation.isManualRestoreEnabled)
        #expect(presentation.latestSnapshotItemTitle == "Latest Snapshot")
        #expect(
            presentation.latestSnapshotEntries == [
                "Finder - Project Notes",
                "TextEdit - Window 1",
            ])
    }

    @Test("Paused state disables manual actions")
    func pausedStateDisablesManualActions() {
        let presentation = AdvancedMenuPresentation(
            isPaused: true,
            snapshots: [snapshot(appName: "Finder", title: "A", index: 0)]
        )

        #expect(!presentation.isManualCaptureEnabled)
        #expect(!presentation.isManualRestoreEnabled)
    }

    @Test("Empty snapshots show a placeholder entry")
    func emptySnapshotPlaceholder() {
        let presentation = AdvancedMenuPresentation(
            isPaused: false,
            snapshots: []
        )

        #expect(presentation.latestSnapshotEntries == ["No saved layout"])
    }
}

private func snapshot(appName: String, title: String?, index: Int) -> WindowSnapshot {
    WindowSnapshot(
        appPID: 1,
        appBundleID: "com.example.\(appName.lowercased())",
        appName: appName,
        windowTitle: title,
        windowIndex: index,
        frame: CodableRect(x: 0, y: 0, width: 100, height: 100),
        screenDisplayID: 1
    )
}
