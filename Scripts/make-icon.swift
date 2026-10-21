#!/usr/bin/env swift
import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let iconsetDestination = arguments.first ?? "build/Cacophony.iconset"
let iconDestination = arguments.dropFirst().first ?? "build/Cacophony.icon"

let brandGreen = NSColor(
    calibratedRed: 30.0 / 255,
    green: 215.0 / 255,
    blue: 96.0 / 255,
    alpha: 1
)
let nearBlack = NSColor(calibratedWhite: 18.0 / 255, alpha: 1)
let nearWhite = NSColor(calibratedWhite: 0.98, alpha: 1)

func makeBitmap(pixels: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
}

func drawMark(color: NSColor) {
    color.set()

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
}

func writePNG(_ bitmap: NSBitmapImageRep, to path: String) throws {
    try bitmap.representation(using: .png, properties: [:])!.write(
        to: URL(fileURLWithPath: path)
    )
}

// Draw at each native resolution so the small Finder icons remain crisp.
try FileManager.default.createDirectory(
    atPath: iconsetDestination,
    withIntermediateDirectories: true
)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = makeBitmap(pixels: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let tile = NSBezierPath(
            roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
            xRadius: 200,
            yRadius: 200
        )
        brandGreen.setFill()
        tile.fill()
        drawMark(color: nearBlack)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = URL(fileURLWithPath: iconsetDestination)
            .appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}

// A native .icon package gives macOS 26+ proper light, dark, and tinted
// appearances instead of auto-processing the legacy .icns.
try FileManager.default.createDirectory(
    atPath: "\(iconDestination)/Assets",
    withIntermediateDirectories: true
)

let background = makeBitmap(pixels: 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: background)
brandGreen.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
NSGraphicsContext.restoreGraphicsState()
try writePNG(background, to: "\(iconDestination)/Assets/background.png")

for (name, color) in [("mark.png", nearBlack), ("mark-light.png", nearWhite)] {
    let bitmap = makeBitmap(pixels: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    drawMark(color: color)
    NSGraphicsContext.restoreGraphicsState()
    try writePNG(bitmap, to: "\(iconDestination)/Assets/\(name)")
}

let iconJSON = """
{
  "fill" : {
    "solid" : "srgb:0.117647,0.843137,0.376471,1.00000"
  },
  "groups" : [
    {
      "name" : "BlackMark",
      "layers" : [
        {
          "name" : "mark",
          "image-name" : "mark.png",
          "glass" : false,
          "opacity" : 1,
          "position" : {
            "scale" : 1,
            "translation-in-points" : [ 0, 0 ]
          }
        }
      ],
      "lighting" : "individual",
      "specular" : false,
      "shadow" : {
        "kind" : "none",
        "opacity" : 0
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0
      },
      "blur-material" : 0,
      "hidden-specializations" : [
        {
          "appearance" : "light",
          "value" : false
        },
        {
          "appearance" : "dark",
          "value" : true
        },
        {
          "appearance" : "tinted",
          "value" : true
        }
      ]
    },
    {
      "name" : "WhiteMark",
      "layers" : [
        {
          "name" : "mark-dark",
          "image-name" : "mark-light.png",
          "glass" : false,
          "opacity" : 1,
          "position" : {
            "scale" : 1,
            "translation-in-points" : [ 0, 0 ]
          }
        }
      ],
      "lighting" : "individual",
      "specular" : false,
      "shadow" : {
        "kind" : "none",
        "opacity" : 0
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0
      },
      "blur-material" : 0,
      "hidden-specializations" : [
        {
          "appearance" : "light",
          "value" : true
        },
        {
          "appearance" : "dark",
          "value" : false
        },
        {
          "appearance" : "tinted",
          "value" : false
        }
      ]
    },
    {
      "name" : "Background",
      "layers" : [
        {
          "name" : "background",
          "image-name" : "background.png",
          "glass" : false,
          "hidden" : false,
          "opacity" : 1,
          "position" : {
            "scale" : 1,
            "translation-in-points" : [ 0, 0 ]
          }
        }
      ],
      "lighting" : "individual",
      "specular" : false,
      "shadow" : {
        "kind" : "none",
        "opacity" : 0
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0
      },
      "blur-material" : 0,
      "hidden-specializations" : [
        {
          "appearance" : "light",
          "value" : true
        },
        {
          "appearance" : "dark",
          "value" : false
        },
        {
          "appearance" : "tinted",
          "value" : true
        }
      ]
    }
  ],
  "supported-platforms" : {
    "squares" : "shared"
  }
}
"""

try iconJSON.write(
    toFile: "\(iconDestination)/icon.json",
    atomically: true,
    encoding: .utf8
)
