import Foundation

enum StayOperatingState: Equatable {
    case ready
    case paused
}

// Design goal: keep the visible menu-bar state derivable from a small pure model
// so UX polish can be tested without instantiating AppKit menu objects.
struct StayMenuPresentation: Equatable {
    static let menuBarSymbolName = "macwindow"
    static let menuBarAccessibilityDescription = "Stay"

    let operatingState: StayOperatingState
    let stateTitle: String
    let detailTitle: String

    init(statusDetail: String, isPaused: Bool) {
        if isPaused {
            operatingState = .paused
            stateTitle = "Status: Paused"
        } else {
            operatingState = .ready
            stateTitle = "Status: Ready"
        }

        detailTitle = statusDetail
    }
}
