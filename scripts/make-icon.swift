#!/usr/bin/env swift
//
// Builds the app icon from lyra-logo.png.
//
//   swift scripts/make-icon.swift
//
// The source logo is drawn as a rounded square sitting on a white page. iOS
// applies its own corner mask, so shipping it as-is would round the already
// rounded corners and leave white slivers poking out. This crops away the white
// page and repaints what is left of it in the background purple, producing a
// full-bleed square for the system to mask cleanly.
//
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appending(path: "lyra-logo.png")
let outputURL = root.appending(
    path: "Lyra/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
)

let outputSide = 1024
/// A channel value above this counts as "page white" rather than artwork.
let whiteThreshold: UInt8 = 236

// MARK: - Load the source into a known RGBA layout

guard let sourceData = try? Data(contentsOf: sourceURL),
      let provider = CGDataProvider(data: sourceData as CFData),
      let decoded = CGImage(
        pngDataProviderSource: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
      )
else {
    fatalError("Could not read \(sourceURL.path)")
}

let width = decoded.width
let height = decoded.height
let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

pixels.withUnsafeMutableBytes { buffer in
    guard let context = CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not create a context for the source image") }

    context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
}

@inline(__always)
func isPageWhite(_ index: Int) -> Bool {
    pixels[index] > whiteThreshold
        && pixels[index + 1] > whiteThreshold
        && pixels[index + 2] > whiteThreshold
}

// MARK: - Crop away the white page

var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width {
        guard !isPageWhite(y * bytesPerRow + x * 4) else { continue }
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
guard maxX > minX, maxY > minY else { fatalError("The source image looks blank") }

let cropWidth = maxX - minX + 1
let cropHeight = maxY - minY + 1

// Sample the background well inside the artwork's top-left, past the rounded
// corner but before the lyre starts.
let sampleX = minX + cropWidth / 8
let sampleY = minY + cropHeight / 8
let sampleIndex = sampleY * bytesPerRow + sampleX * 4
let background = (r: pixels[sampleIndex], g: pixels[sampleIndex + 1], b: pixels[sampleIndex + 2])

// MARK: - Repaint the leftover white corners

let cropBytesPerRow = cropWidth * 4
var cropped = [UInt8](repeating: 0, count: cropBytesPerRow * cropHeight)

for y in 0..<cropHeight {
    let sourceRow = (minY + y) * bytesPerRow
    let destinationRow = y * cropBytesPerRow
    for x in 0..<cropWidth {
        let source = sourceRow + (minX + x) * 4
        let destination = destinationRow + x * 4

        if isPageWhite(source) {
            cropped[destination] = background.r
            cropped[destination + 1] = background.g
            cropped[destination + 2] = background.b
        } else {
            cropped[destination] = pixels[source]
            cropped[destination + 1] = pixels[source + 1]
            cropped[destination + 2] = pixels[source + 2]
        }
        cropped[destination + 3] = 255
    }
}

// MARK: - Scale to 1024 and write

let croppedImage: CGImage = cropped.withUnsafeMutableBytes { buffer in
    guard let context = CGContext(
        data: buffer.baseAddress,
        width: cropWidth,
        height: cropHeight,
        bitsPerComponent: 8,
        bytesPerRow: cropBytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        fatalError("Could not rebuild the cropped image")
    }
    return image
}

guard let output = CGContext(
    data: nil,
    width: outputSide,
    height: outputSide,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("Could not create the output context") }

output.interpolationQuality = .high
// Paint the background first so any rounding difference in aspect ratio fills
// with purple rather than black.
output.setFillColor(
    red: CGFloat(background.r) / 255,
    green: CGFloat(background.g) / 255,
    blue: CGFloat(background.b) / 255,
    alpha: 1
)
output.fill(CGRect(x: 0, y: 0, width: outputSide, height: outputSide))
output.draw(croppedImage, in: CGRect(x: 0, y: 0, width: outputSide, height: outputSide))

guard let finalImage = output.makeImage(),
      let png = NSBitmapImageRep(cgImage: finalImage).representation(using: .png, properties: [:])
else { fatalError("Could not encode the icon") }

try png.write(to: outputURL)
print("Wrote \(outputURL.lastPathComponent) — \(outputSide)×\(outputSide), cropped from \(cropWidth)×\(cropHeight)")
