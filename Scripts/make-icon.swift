#!/usr/bin/env swift
import AppKit
import Foundation

// Draw at each native resolution so the small Finder icons remain crisp.
let destination = CommandLine.arguments.dropFirst().first ?? "build/Cacophony.iconset"
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
            pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                                xRadius: 200, yRadius: 200)
        // Bright green (#1ED760) with a near-black mark (#121212).
        NSColor(calibratedRed: 30.0 / 255, green: 215.0 / 255, blue: 96.0 / 255, alpha: 1).setFill()
        tile.fill()
        NSColor(calibratedWhite: 18.0 / 255, alpha: 1).set()
        // A lift arrow doubles as the transmitter beneath two broadcast arcs.
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 512, y: 548))
        arrow.line(to: NSPoint(x: 338, y: 300))
        arrow.line(to: NSPoint(x: 468, y: 300))
        arrow.line(to: NSPoint(x: 468, y: 218))
        arrow.line(to: NSPoint(x: 556, y: 218))
        arrow.line(to: NSPoint(x: 556, y: 300))
        arrow.line(to: NSPoint(x: 686, y: 300))
        arrow.close()
        arrow.fill()
        for radius: CGFloat in [172, 290] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 512, y: 484), radius: radius,
                          startAngle: 38, endAngle: 142)
            arc.lineWidth = 58
            arc.lineCapStyle = .round
            arc.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
