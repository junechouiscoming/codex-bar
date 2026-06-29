#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("Usage: make-app-icon.swift <output.icns>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let fileManager = FileManager.default
let rootURL = outputURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let iconsetURL = rootURL
    .appendingPathComponent(".build", isDirectory: true)
    .appendingPathComponent("AppIcon.iconset", isDirectory: true)

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for size in sizes {
    let image = drawIcon(size: CGFloat(size.pixels))
    let destination = iconsetURL.appendingPathComponent(size.name)
    try writePNG(image, to: destination)
}

try? fileManager.removeItem(at: outputURL)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    fputs("iconutil failed\n", stderr)
    exit(process.terminationStatus)
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSGraphicsContext.current?.imageInterpolation = .high

    let cornerRadius = size * 0.22
    let shape = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.04, dy: size * 0.04), xRadius: cornerRadius, yRadius: cornerRadius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.70, green: 0.90, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.97, green: 0.99, blue: 0.99, alpha: 1)
    ])
    gradient?.draw(in: shape, angle: 135)

    NSColor.white.withAlphaComponent(0.42).setStroke()
    shape.lineWidth = max(1, size * 0.012)
    shape.stroke()

    drawSegmentedBar(
        in: NSRect(x: size * 0.20, y: size * 0.56, width: size * 0.60, height: size * 0.105),
        segments: 9,
        filled: 7,
        fill: NSColor(calibratedRed: 0.16, green: 0.63, blue: 0.43, alpha: 1),
        empty: NSColor.white.withAlphaComponent(0.42)
    )
    drawSegmentedBar(
        in: NSRect(x: size * 0.20, y: size * 0.36, width: size * 0.60, height: size * 0.105),
        segments: 9,
        filled: 5,
        fill: NSColor(calibratedRed: 0.24, green: 0.49, blue: 0.86, alpha: 1),
        empty: NSColor.white.withAlphaComponent(0.42)
    )

    let markRect = NSRect(x: size * 0.38, y: size * 0.73, width: size * 0.24, height: size * 0.08)
    let mark = NSBezierPath(roundedRect: markRect, xRadius: markRect.height / 2, yRadius: markRect.height / 2)
    NSColor(calibratedRed: 0.06, green: 0.24, blue: 0.30, alpha: 0.82).setFill()
    mark.fill()

    image.unlockFocus()
    return image
}

func drawSegmentedBar(in rect: NSRect, segments: Int, filled: Int, fill: NSColor, empty: NSColor) {
    let gap = rect.width * 0.035
    let segmentWidth = (rect.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
    for index in 0..<segments {
        let x = rect.minX + CGFloat(index) * (segmentWidth + gap)
        let segmentRect = NSRect(x: x, y: rect.minY, width: segmentWidth, height: rect.height)
        let path = NSBezierPath(
            roundedRect: segmentRect,
            xRadius: rect.height * 0.36,
            yRadius: rect.height * 0.36
        )
        (index < filled ? fill : empty).setFill()
        path.fill()
    }
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }

    try pngData.write(to: url)
}
