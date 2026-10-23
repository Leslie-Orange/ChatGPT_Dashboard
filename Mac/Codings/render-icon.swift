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

    static let tileFill = "#FCFCFD"

    struct GaugeSection: Decodable {
        let color: String
        let paths: [String]
    }

    struct Shapes: Decodable {
        let knot: [String]
        let gauge: [GaugeSection]
    }

    static func shapes() throws -> Shapes {
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("AppIcon-shapes.json")
        return try JSONDecoder().decode(Shapes.self, from: Data(contentsOf: sourceURL))
    }

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

    static func rounded(_ value: Double) -> Double {
        (value * 1000.0).rounded() / 1000.0
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

    static func coordinate(_ value: CGFloat) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }

    static func svgDocument(shapes: Shapes) -> String {
        let path = tilePathData
        let gaugePaths = shapes.gauge.map { section in
            section.paths.map { "<path d=\"\($0)\" fill=\"\(section.color)\"/>" }
                .joined(separator: "\n    ")
        }.joined(separator: "\n    ")
        let knotPaths = shapes.knot.map { "<path d=\"\($0)\" fill=\"#000000\"/>" }
            .joined(separator: "\n    ")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
          <title>Quota dashboard — woven knot and six-step gauge</title>
          <defs>
            <clipPath id="tile-clip" clipPathUnits="userSpaceOnUse">
              <path d="\(path)"/>
            </clipPath>
          </defs>
          <path d="\(path)" fill="\(tileFill)"/>
          <g fill-rule="evenodd">\(gaugePaths)</g>
          <g fill-rule="evenodd">\(knotPaths)</g>
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
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        components: [CGFloat((value >> 16) & 0xFF) / 255.0, CGFloat((value >> 8) & 0xFF) / 255.0, CGFloat(value & 0xFF) / 255.0, 1.0]
    )!
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

private func makeVectorPath(from source: String) throws -> CGPath {
    let expression = try NSRegularExpression(pattern: #"[A-Z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?"#)
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    let tokens = expression.matches(in: source, range: range).compactMap {
        Range($0.range, in: source).map { String(source[$0]) }
    }

    let path = CGMutablePath()
    var index = 0
    var hasOpenSubpath = false
    while index < tokens.count {
        let command = tokens[index]
        index += 1
        func number() throws -> CGFloat {
            guard index < tokens.count, let value = Double(tokens[index]) else {
                throw NSError(domain: "render-icon", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid vector path data"])
            }
            index += 1
            return CGFloat(value)
        }

        switch command {
        case "M":
            if hasOpenSubpath { path.closeSubpath() }
            path.move(to: CGPoint(x: try number(), y: try number()))
            hasOpenSubpath = true
        case "L":
            path.addLine(to: CGPoint(x: try number(), y: try number()))
        case "C":
            let first = CGPoint(x: try number(), y: try number())
            let second = CGPoint(x: try number(), y: try number())
            let end = CGPoint(x: try number(), y: try number())
            path.addCurve(to: end, control1: first, control2: second)
        case "Z":
            path.closeSubpath()
            hasOpenSubpath = false
        default:
            throw NSError(domain: "render-icon", code: 7, userInfo: [NSLocalizedDescriptionKey: "Unsupported vector path command: \(command)"])
        }
    }
    if hasOpenSubpath { path.closeSubpath() }
    return path
}

private func fillPaths(_ paths: [String], in context: CGContext, color fill: String) throws {
    context.setFillColor(color(fill))
    for pathData in paths {
        context.addPath(try makeVectorPath(from: pathData))
    }
    context.drawPath(using: .eoFill)
}

private func renderPNG(to outputURL: URL, shapes: Icon.Shapes) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
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

    for section in shapes.gauge {
        try fillPaths(section.paths, in: context, color: section.color)
    }
    try fillPaths(shapes.knot, in: context, color: "#000000")

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
    let shapes = try Icon.shapes()
    try renderPNG(to: outputs.png, shapes: shapes)
    if let svgURL = outputs.svg {
        try Icon.svgDocument(shapes: shapes).write(to: svgURL, atomically: true, encoding: .utf8)
    }
    print("Rendered 1024x1024 RGBA icon: \(outputs.png.path)")
    if let svgURL = outputs.svg {
        print("Wrote matching SVG source: \(svgURL.path)")
    }
} catch {
    fputs("render-icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
