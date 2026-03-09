import CoreGraphics
import Foundation

// Design goal: store only the minimal stable window metadata needed for restore.
public struct CodableRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct WindowSnapshot: Codable, Equatable, Hashable, Sendable {
    public var appPID: Int32
    public var appBundleID: String?
    public var appName: String
    public var windowTitle: String?
    public var windowIndex: Int
    public var frame: CodableRect
    public var screenDisplayID: UInt32?

    public init(
        appPID: Int32,
        appBundleID: String?,
        appName: String,
        windowTitle: String?,
        windowIndex: Int,
        frame: CodableRect,
        screenDisplayID: UInt32?
    ) {
        self.appPID = appPID
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.windowIndex = windowIndex
        self.frame = frame
        self.screenDisplayID = screenDisplayID
    }
}
