import Foundation
import Testing

@testable import Stay

@Suite("StayMenuPresentation")
struct StayMenuPresentationTests {
    @Test("Ready presentation shows a ready status line")
    func readyPresentation() {
        let presentation = StayMenuPresentation(
            statusDetail: "Watching sleep/wake",
            isPaused: false
        )

        #expect(presentation.operatingState == .ready)
        #expect(presentation.stateTitle == "Status: Ready")
        #expect(presentation.detailTitle == "Watching sleep/wake")
    }

    @Test("Paused presentation shows a paused status line")
    func pausedPresentation() {
        let presentation = StayMenuPresentation(
            statusDetail: SeparateSpacesSuspensionPolicy.suspendedStatusLine,
            isPaused: true
        )

        #expect(presentation.operatingState == .paused)
        #expect(presentation.stateTitle == "Status: Paused")
        #expect(presentation.detailTitle == SeparateSpacesSuspensionPolicy.suspendedStatusLine)
    }

    @Test("Menu bar uses the Stay icon metadata")
    func menuBarIconMetadata() {
        #expect(StayMenuPresentation.menuBarSymbolName == "macwindow")
        #expect(StayMenuPresentation.menuBarAccessibilityDescription == "Stay")
    }
}
