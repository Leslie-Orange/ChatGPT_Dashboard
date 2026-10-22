#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

private enum Icon {
    static let canvas = 1024
    static let tileCenter = 512.0
    static let tileHalfSize = 412.0
    static let squircleExponent = 4.0
    static let tileSamples = 256

    static let tileFill = "#FCFCFB"
    static let tileStroke = "#E7E7E5"
    static let tileStrokeWidth = 4.0

    static let trackFill = "#E3E3E1"
    static let barFill = "#171717"

    static let trackX = 232.0
    static let trackWidth = 560.0
    static let trackHeight = 112.0
    static let firstTrackY = 350.0
    static let secondTrackY = 562.0
    static let firstProgress = 0.75
    static let secondProgress = 0.45

    static var tilePoints: [CGPoint] {
        (0..<tileSamples).map { index in
            let angle = (Double(index) / Double(tileSamples)) * 2.0 * Double.pi - Double.pi / 2.0
            let cosine = pow(abs(cos(angle)), 2.0 / squircleExponent) * (cos(angle) < 0 ? -1.0 : 1.0)
            let sine = pow(abs(sin(angle)), 2.0 / squircleExponent) * (sin(angle) < 0 ? -1.0 : 1.0)
            return CGPoint(
                x: rounded(tileCenter + tileHalfSize * cosine),
                y: rounded(tileCenter + tileHalfSize * sine)
            )
        }
    }

    static var tilePathData: String {
        let points = tilePoints
        guard let first = points.first else { return "" }
        var commands = ["M \(coordinate(first.x)),\(coordinate(first.y))"]
        commands.append(contentsOf: points.dropFirst().map { "L \(coordinate($0.x)),\(coordinate($0.y))" })
        commands.append("Z")
        return stride(from: 0, to: commands.count, by: 8).map { start in
            let end = min(start + 8, commands.count)
            return commands[start..<end].joined(separator: " ")
        }.joined(separator: "\n      ")
    }

    static func rounded(_ value: Double) -> Double {
        (value * 1000.0).rounded() / 1000.0
    }

    static func coordinate(_ value: CGFloat) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }

    static func svgDocument() -> String {
        let path = tilePathData
        let firstWidth = trackWidth * firstProgress
        let secondWidth = trackWidth * secondProgress

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
          <title>Quota dashboard</title>
          <defs>
            <clipPath id="tile-clip" clipPathUnits="userSpaceOnUse">
              <path d="\(path)"/>
            </clipPath>
          </defs>
          <path d="\(path)" fill="\(tileFill)"/>
          <path d="\(path)" fill="none" stroke="\(tileStroke)" stroke-width="\(coordinate(tileStrokeWidth))" clip-path="url(#tile-clip)"/>
          <rect x="\(coordinate(trackX))" y="\(coordinate(firstTrackY))" width="\(coordinate(trackWidth))" height="\(coordinate(trackHeight))" rx="\(coordinate(trackHeight / 2) )" fill="\(trackFill)"/>
          <rect x="\(coordinate(trackX))" y="\(coordinate(firstTrackY))" width="\(coordinate(firstWidth))" height="\(coordinate(trackHeight))" rx="\(coordinate(trackHeight / 2) )" fill="\(barFill)"/>
          <rect x="\(coordinate(trackX))" y="\(coordinate(secondTrackY))" width="\(coordinate(trackWidth))" height="\(coordinate(trackHeight))" rx="\(coordinate(trackHeight / 2) )" fill="\(trackFill)"/>
          <rect x="\(coordinate(trackX))" y="\(coordinate(secondTrackY))" width="\(coordinate(secondWidth))" height="\(coordinate(trackHeight))" rx="\(coordinate(trackHeight / 2) )" fill="\(barFill)"/>
        </svg>
        """
    }
}

private struct OutputPaths {
    let png: URL
    let svg: URL?
}

private func parseArguments() throws -> OutputPaths {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let defaultRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    var pngURL: URL?
    var svgURL: URL?
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--help" || argument == "-h" {
            print("Usage: render-icon.swift [--png OUTPUT.png] [--svg OUTPUT.svg]")
            exit(0)
        }
        guard index + 1 < arguments.count else {
            throw NSError(domain: "render-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing value for \(argument)"])
        }
        let url = URL(fileURLWithPath: arguments[index + 1])
        switch argument {
        case "--png": pngURL = url
        case "--svg": svgURL = url
        default:
            throw NSError(domain: "render-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown argument: \(argument)"])
        }
        index += 2
    }

    return OutputPaths(
        png: pngURL ?? defaultRoot.appendingPathComponent("AppIcon.png"),
        svg: svgURL
    )
}

private func color(_ hex: String) -> CGColor {
    let digits = String(hex.dropFirst())
    let value = UInt64(digits, radix: 16)!
    return CGColor(
        red: CGFloat((value >> 16) & 0xFF) / 255.0,
        green: CGFloat((value >> 8) & 0xFF) / 255.0,
        blue: CGFloat(value & 0xFF) / 255.0,
        alpha: 1.0
    )
}

private func makeTilePath() -> CGPath {
    let path = CGMutablePath()
    let points = Icon.tilePoints
    guard let first = points.first else { return path }
    path.move(to: first)
    for point in points.dropFirst() {
        path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

private func drawCapsule(context: CGContext, y: Double, width: Double, fill: String) {
    let rect = CGRect(x: Icon.trackX, y: y, width: width, height: Icon.trackHeight)
    let path = CGPath(roundedRect: rect, cornerWidth: Icon.trackHeight / 2, cornerHeight: Icon.trackHeight / 2, transform: nil)
    context.addPath(path)
    context.setFillColor(color(fill))
    context.fillPath()
}

private func renderPNG(to outputURL: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    guard let context = CGContext(
        data: nil,
        width: Icon.canvas,
        height: Icon.canvas,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    ) else {
        throw NSError(domain: "render-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create RGBA bitmap context"])
    }

    context.clear(CGRect(x: 0, y: 0, width: Icon.canvas, height: Icon.canvas))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.saveGState()
    context.translateBy(x: 0, y: CGFloat(Icon.canvas))
    context.scaleBy(x: 1, y: -1)

    let tilePath = makeTilePath()
    context.addPath(tilePath)
    context.setFillColor(color(Icon.tileFill))
    context.fillPath()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.addPath(tilePath)
    context.setStrokeColor(color(Icon.tileStroke))
    context.setLineWidth(Icon.tileStrokeWidth)
    context.strokePath()
    context.restoreGState()

    drawCapsule(context: context, y: Icon.firstTrackY, width: Icon.trackWidth, fill: Icon.trackFill)
    drawCapsule(context: context, y: Icon.firstTrackY, width: Icon.trackWidth * Icon.firstProgress, fill: Icon.barFill)
    drawCapsule(context: context, y: Icon.secondTrackY, width: Icon.trackWidth, fill: Icon.trackFill)
    drawCapsule(context: context, y: Icon.secondTrackY, width: Icon.trackWidth * Icon.secondProgress, fill: Icon.barFill)

    context.restoreGState()

    guard let image = context.makeImage() else {
        throw NSError(domain: "render-icon", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create rendered CGImage"])
    }
    let representation = NSBitmapImageRep(cgImage: image)
    guard let pngData = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render-icon", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    try pngData.write(to: outputURL, options: .atomic)
}

do {
    let outputs = try parseArguments()
    try renderPNG(to: outputs.png)
    if let svgURL = outputs.svg {
        try Icon.svgDocument().write(to: svgURL, atomically: true, encoding: .utf8)
    }
    print("Rendered 1024x1024 RGBA icon: \(outputs.png.path)")
    if let svgURL = outputs.svg {
        print("Wrote matching SVG source: \(svgURL.path)")
    }
} catch {
    fputs("render-icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
