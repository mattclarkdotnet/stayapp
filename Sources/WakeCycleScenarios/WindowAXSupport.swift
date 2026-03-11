import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Design intent: isolate low-level AX frame and display mapping operations from
// scenario orchestration logic.
extension WakeCycleScenarioRunner {
    func scenarioFrame(on screen: NSScreen, offset: Int) -> CGRect {
        let visible = screen.visibleFrame
        let width = min(max(460, visible.width * 0.5), visible.width - 90)
        let height = min(max(340, visible.height * 0.58), visible.height - 110)
        let x = visible.minX + 50 + (CGFloat(offset) * 35)
        let y = visible.minY + 70 + (CGFloat(offset) * 25)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    @discardableResult
    func moveMainWindowToScreen(element: AXUIElement, screen: NSScreen, offset: Int) -> Bool {
        guard let frame = frameForWindow(element) else {
            return false
        }
        let visible = screen.visibleFrame
        let preferred = CGPoint(
            x: visible.minX + 50 + (CGFloat(offset) * 35),
            y: visible.minY + 70 + (CGFloat(offset) * 25)
        )
        let origin = clampedRectOrigin(size: frame.size, preferred: preferred, in: visible)
        return setWindowOrigin(element, origin: origin)
    }

    @discardableResult
    func moveChildWindowsToScreen(elements: [AXUIElement], screen: NSScreen) -> Bool {
        guard !elements.isEmpty else {
            return true
        }

        let windows = elements.compactMap { element -> (element: AXUIElement, frame: CGRect)? in
            guard let frame = frameForWindow(element) else {
                return nil
            }
            return (element: element, frame: frame)
        }
        guard windows.count == elements.count else {
            return false
        }

        var group = windows[0].frame
        for window in windows.dropFirst() {
            group = group.union(window.frame)
        }

        let visible = screen.visibleFrame
        let preferred = CGPoint(x: visible.maxX - group.width - 40, y: visible.minY + 40)
        let targetGroupOrigin = clampedRectOrigin(
            size: group.size, preferred: preferred, in: visible)
        let delta = CGPoint(
            x: targetGroupOrigin.x - group.minX, y: targetGroupOrigin.y - group.minY)

        return windows.allSatisfy { window in
            let targetOrigin = CGPoint(
                x: window.frame.minX + delta.x,
                y: window.frame.minY + delta.y
            )
            return setWindowOrigin(window.element, origin: targetOrigin)
        }
    }

    func clampedRectOrigin(size: CGSize, preferred: CGPoint, in bounds: CGRect) -> CGPoint {
        let minX = bounds.minX
        let minY = bounds.minY
        let maxX = max(bounds.maxX - size.width, minX)
        let maxY = max(bounds.maxY - size.height, minY)
        let x = min(max(preferred.x, minX), maxX)
        let y = min(max(preferred.y, minY), maxY)
        return CGPoint(x: x, y: y)
    }

    func setWindowFrame(_ window: AXUIElement, frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard
            let position = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, position)
        let sizeResult = AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, sizeValue)
        if positionResult == .success && sizeResult == .success {
            return true
        }

        var mutableFrame = frame
        if let frameValue = AXValueCreate(.cgRect, &mutableFrame) {
            let frameResult = AXUIElementSetAttributeValue(
                window, "AXFrame" as CFString, frameValue)
            if frameResult == .success {
                return true
            }
        }

        return false
    }

    @discardableResult
    func setWindowOrigin(_ window: AXUIElement, origin: CGPoint) -> Bool {
        var mutableOrigin = origin
        guard let position = AXValueCreate(.cgPoint, &mutableOrigin) else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, position)
        if positionResult == .success {
            return true
        }

        guard var frame = frameForWindow(window) else {
            return false
        }
        frame.origin = origin
        if let frameValue = AXValueCreate(.cgRect, &frame) {
            let frameResult = AXUIElementSetAttributeValue(
                window, "AXFrame" as CFString, frameValue)
            if frameResult == .success {
                return true
            }
        }
        return false
    }

    func isFrameSettable(_ window: AXUIElement) -> Bool {
        var positionSettable = DarwinBoolean(false)
        let positionResult = AXUIElementIsAttributeSettable(
            window, kAXPositionAttribute as CFString, &positionSettable
        )
        guard positionResult == .success, positionSettable.boolValue else {
            return false
        }

        var sizeSettable = DarwinBoolean(false)
        let sizeResult = AXUIElementIsAttributeSettable(
            window, kAXSizeAttribute as CFString, &sizeSettable
        )
        return sizeResult == .success && sizeSettable.boolValue
    }

    func frameForWindow(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
                == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
                == .success,
            let positionRef = positionValue,
            let sizeRef = sizeValue,
            CFGetTypeID(positionRef) == AXValueGetTypeID(),
            CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else {
            return nil
        }

        let positionAX = unsafeDowncast(positionRef as AnyObject, to: AXValue.self)
        let sizeAX = unsafeDowncast(sizeRef as AnyObject, to: AXValue.self)

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &origin),
            AXValueGetValue(sizeAX, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: origin, size: size)
    }

    func windowArea(_ frame: CGRect) -> CGFloat {
        frame.width * frame.height
    }

    func windowNumber(of window: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success
        else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    func stringValue(of element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    func displayID(for screen: NSScreen) -> UInt32? {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
        else {
            return nil
        }
        return number.uint32Value
    }

    func displayID(for frame: CGRect) -> UInt32? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return nil
        }

        let scored = screens.map { screen in
            (screen: screen, area: frame.intersection(screen.frame).area)
        }

        if let best = scored.max(by: { $0.area < $1.area }), best.area > 0 {
            return displayID(for: best.screen)
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let nearest = screens.min { lhs, rhs in
            distanceSquared(center, lhs.frame.center) < distanceSquared(center, rhs.frame.center)
        }
        return nearest.flatMap(displayID(for:))
    }
}
