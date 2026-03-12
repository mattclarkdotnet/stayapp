import AppKit
import CoreGraphics
import Foundation

// Design goal: reliably map windows to their original display and clamp restores
// to visible regions, even if coordinates are slightly off during wake transitions.
protocol ScreenCoordinateServicing {
    func displayID(for frame: CGRect) -> UInt32?
    func adjustedFrame(_ frame: CGRect, preferredDisplayID: UInt32?) -> CGRect
    func currentDisplayIDs() -> Set<UInt32>
}

final class NSScreenCoordinateService: ScreenCoordinateServicing, DisplayInventoryReading {
    func displayID(for frame: CGRect) -> UInt32? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return nil
        }

        let scoredScreens = screens.map { screen in
            (screen: screen, area: frame.intersection(screen.frame).area)
        }

        if let best = scoredScreens.max(by: { $0.area < $1.area }), best.area > 0 {
            return displayID(for: best.screen)
        }

        let windowCenter = CGPoint(x: frame.midX, y: frame.midY)
        let nearest = screens.min { lhs, rhs in
            distanceSquared(from: windowCenter, to: lhs.frame.center)
                < distanceSquared(from: windowCenter, to: rhs.frame.center)
        }

        return nearest.flatMap(displayID(for:))
    }

    func adjustedFrame(_ frame: CGRect, preferredDisplayID: UInt32?) -> CGRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return frame
        }

        if let preferredDisplayID,
            let preferredScreen = screens.first(where: { displayID(for: $0) == preferredDisplayID })
        {
            return clamp(frame: frame, to: preferredScreen.visibleFrame)
        }

        let scoredScreens = screens.map { screen in
            (screen: screen, area: frame.intersection(screen.visibleFrame).area)
        }

        if let best = scoredScreens.max(by: { $0.area < $1.area }), best.area > 0 {
            return clamp(frame: frame, to: best.screen.visibleFrame)
        }

        return clamp(frame: frame, to: screens[0].visibleFrame)
    }

    func currentDisplayIDs() -> Set<UInt32> {
        Set(NSScreen.screens.compactMap(displayID(for:)))
    }

    private func clamp(frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)

        let maxX = visibleFrame.maxX - width
        let maxY = visibleFrame.maxY - height

        let x = min(max(frame.origin.x, visibleFrame.minX), maxX)
        let y = min(max(frame.origin.y, visibleFrame.minY), maxY)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func displayID(for screen: NSScreen) -> UInt32? {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
        else {
            return nil
        }
        return number.uint32Value
    }

    private func distanceSquared(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return (dx * dx) + (dy * dy)
    }
}

extension CGRect {
    fileprivate var area: CGFloat {
        guard !isNull, width > 0, height > 0 else {
            return 0
        }
        return width * height
    }

    fileprivate var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
