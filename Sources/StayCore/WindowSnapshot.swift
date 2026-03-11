import CoreGraphics
import Foundation

// Design goal: store only the minimal stable window metadata needed for restore.
/// Codable rectangle used for persisted window frames.
public struct CodableRect: Codable, Equatable, Hashable, Sendable {
    /// X origin.
    public var x: Double
    /// Y origin.
    public var y: Double
    /// Width.
    public var width: Double
    /// Height.
    public var height: Double

    /// Creates a codable rectangle from scalar components.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Creates a codable rectangle from a CoreGraphics rectangle.
    public init(_ rect: CGRect) {
        self.init(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    /// Converts to `CGRect`.
    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Persisted identity and frame metadata for a single window.
public struct WindowSnapshot: Codable, Equatable, Hashable, Sendable {
    /// Process identifier of the owning app at capture time.
    public var appPID: Int32
    /// Bundle identifier of the owning app, when available.
    public var appBundleID: String?
    /// Localized app name captured for diagnostics/fallback matching.
    public var appName: String
    /// Window title at capture time, when available.
    public var windowTitle: String?
    // Window number is the strongest cross-layer identity when available.
    // It comes from AX ("AXWindowNumber") or WindowServer ("kCGWindowNumber").
    public var windowNumber: Int?
    public var windowRole: String?
    public var windowSubrole: String?
    /// Ordered AX index among captured windows for that app.
    public var windowIndex: Int
    /// Captured frame.
    public var frame: CodableRect
    /// Display identifier resolved from the captured frame, when available.
    public var screenDisplayID: UInt32?

    /// Creates a captured snapshot.
    public init(
        appPID: Int32,
        appBundleID: String?,
        appName: String,
        windowTitle: String?,
        windowNumber: Int? = nil,
        windowRole: String? = nil,
        windowSubrole: String? = nil,
        windowIndex: Int,
        frame: CodableRect,
        screenDisplayID: UInt32?
    ) {
        self.appPID = appPID
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.windowNumber = windowNumber
        self.windowRole = windowRole
        self.windowSubrole = windowSubrole
        self.windowIndex = windowIndex
        self.frame = frame
        self.screenDisplayID = screenDisplayID
    }
}
