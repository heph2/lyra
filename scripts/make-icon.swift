#!/usr/bin/env swift
//
// Renders Lyra's app icon to Lyra/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png.
//
// Kept as a script rather than a checked-in binary so the mark can be tweaked
// in one place. Run it from the repo root: swift scripts/make-icon.swift
//
import AppKit
import CoreGraphics
import Foundation

let side = 1024
let scale = CGFloat(side) / 1024.0

guard let context = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Could not create a bitmap context")
}

let rect = CGRect(x: 0, y: 0, width: side, height: side)

// Background: a deep vertical gradient so the icon reads on both light and
// dark home screens.
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let background = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(srgbRed: 0.129, green: 0.118, blue: 0.153, alpha: 1),
        CGColor(srgbRed: 0.055, green: 0.051, blue: 0.071, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    background,
    start: CGPoint(x: 0, y: side),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// A lyre suggested with strings: vertical lines of varying height, which double
// as an equaliser. Simple enough to stay legible at 40pt.
let accentTop = CGColor(srgbRed: 0.980, green: 0.616, blue: 0.322, alpha: 1)
let accentBottom = CGColor(srgbRed: 0.902, green: 0.353, blue: 0.235, alpha: 1)
let strings = CGGradient(
    colorsSpace: colorSpace,
    colors: [accentTop, accentBottom] as CFArray,
    locations: [0, 1]
)!

let heights: [CGFloat] = [0.34, 0.58, 0.82, 0.62, 0.42]
let barWidth: CGFloat = 74 * scale
let gap: CGFloat = 46 * scale
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
let originX = (CGFloat(side) - totalWidth) / 2
let baseY = CGFloat(side) * 0.22

context.saveGState()
let barsPath = CGMutablePath()
for (index, fraction) in heights.enumerated() {
    let x = originX + CGFloat(index) * (barWidth + gap)
    let height = CGFloat(side) * 0.56 * fraction
    barsPath.addRoundedRect(
        in: CGRect(x: x, y: baseY, width: barWidth, height: height),
        cornerWidth: barWidth / 2,
        cornerHeight: barWidth / 2
    )
}
context.addPath(barsPath)
context.clip()
context.drawLinearGradient(
    strings,
    start: CGPoint(x: 0, y: CGFloat(side) * 0.78),
    end: CGPoint(x: 0, y: baseY),
    options: []
)
context.restoreGState()

guard let image = context.makeImage() else { fatalError("Could not render the icon") }

let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: "Lyra/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

let bitmap = NSBitmapImageRep(cgImage: image)
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode PNG")
}
try data.write(to: output)
print("Wrote \(output.path)")
