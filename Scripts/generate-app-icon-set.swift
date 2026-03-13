#!/usr/bin/swift

import AppKit
import Foundation

private let iconSpecs: [(base: Int, scale: Int, name: String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

private let fileManager = FileManager.default
private let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
private let outputDirectory =
    scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("AppBundle", isDirectory: true)
    .appendingPathComponent("Assets.xcassets", isDirectory: true)
    .appendingPathComponent("AppIcon.appiconset", isDirectory: true)

try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for spec in iconSpecs {
    let pixelSize = CGFloat(spec.base * spec.scale)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixelSize),
        pixelsHigh: Int(pixelSize),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    let inset = pixelSize * 0.07
    let iconRect = rect.insetBy(dx: inset, dy: inset)
    let radius = pixelSize * 0.22

    NSColor(calibratedRed: 0.07, green: 0.15, blue: 0.24, alpha: 1).setFill()
    NSBezierPath(rect: rect).fill()

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.55, alpha: 1),
        ending: NSColor(calibratedRed: 0.03, green: 0.12, blue: 0.23, alpha: 1)
    )!
    let iconPath = NSBezierPath(
        roundedRect: iconRect,
        xRadius: radius,
        yRadius: radius
    )
    gradient.draw(in: iconPath, angle: -90)

    NSColor(calibratedWhite: 1.0, alpha: 0.12).setStroke()
    iconPath.lineWidth = max(1, pixelSize * 0.015)
    iconPath.stroke()

    let text = NSString(string: "S")
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    let fontSize = pixelSize * 0.54
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.96),
        .paragraphStyle: paragraph,
    ]

    let textSize = text.size(withAttributes: attributes)
    let textRect = NSRect(
        x: (pixelSize - textSize.width) / 2,
        y: (pixelSize - textSize.height) / 2 - pixelSize * 0.05,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: textRect, withAttributes: attributes)

    let destinationURL = outputDirectory.appendingPathComponent(spec.name, isDirectory: false)
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "StayIconGeneration", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Unable to encode \(spec.name) as PNG."
            ])
    }

    try pngData.write(to: destinationURL)
}

print("Generated app icons in \(outputDirectory.path)")
