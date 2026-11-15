#!/usr/bin/env swift
import AppKit

// Frozen CueWave ribbons, enlarged for a recognizable home-screen silhouette.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
func render(width: Int, height: Int, destination: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let scale = Double(height)
    let span = scale * 0.78
    let origin = (Double(width) - span) / 2
    var paths: [String] = []
    for layer in 0..<4 {
        let phase = Double(layer) * 0.9
        let amplitude = (0.10 + Double(layer) * 0.025) * scale
        let path = NSBezierPath()
        var svg = ""
        for side in [1.0, -1.0] {
            for sample in 0...240 {
                let x = side == 1 ? Double(sample) / 240 : 1 - Double(sample) / 240
                let envelope = pow(sin(x * .pi), 3)
                let center = sin(x * .pi * 3 + phase) * amplitude * envelope
                let thickness = (0.012 + 0.045 * (1 + sin(phase + x * .pi * 2)) / 2) * scale * envelope
                let point = NSPoint(x: origin + x * span, y: scale / 2 + center + side * thickness)
                let start = side == 1 && sample == 0
                if start { path.move(to: point) } else { path.line(to: point) }
                svg += "\(start ? "M" : "L")\(point.x),\(scale - point.y) "
            }
        }
        path.close()
        let color = layer.isMultiple(of: 2) ? NSColor(srgbRed: 1, green: 0.32, blue: 0.32, alpha: 0.75)
            : NSColor(srgbRed: 0.85, green: 0.06, blue: 0.12, alpha: 0.75)
        color.setFill()
        path.fill()
        paths.append("<path d=\"\(svg)Z\" fill=\"\(layer.isMultiple(of: 2) ? "#ff5252" : "#d90f1f")\" fill-opacity=\"0.75\"/>")
    }
    if width != height {
        let label = NSAttributedString(string: "Voca", attributes: [
            .font: NSFont.systemFont(ofSize: 80, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: (Double(width) - size.width) / 2, y: 210))
        paths.append("<text x=\"\(width / 2)\" y=\"796\" text-anchor=\"middle\" font-family=\"-apple-system, Helvetica Neue, sans-serif\" font-size=\"80\" font-weight=\"500\" fill=\"white\">Voca</text>")
    }
    NSGraphicsContext.restoreGraphicsState()
    let url = root.appendingPathComponent(destination)
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: url)
    let decoded = NSBitmapImageRep(data: data)!
    precondition(decoded.pixelsWide == width && decoded.pixelsHigh == height && !decoded.hasAlpha)
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\"><rect width=\"100%\" height=\"100%\" fill=\"black\"/>\(paths.joined())</svg>"
    try svg.write(to: root.appendingPathComponent("Resources/Brand/voca-\(width == height ? "square" : "3x2").svg"), atomically: true, encoding: .utf8)
}
try render(width: 1024, height: 1024, destination: "Voca/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try render(width: 1536, height: 1024, destination: "Resources/Brand/voca-3x2.png")
print("Verified opaque 1024×1024 app icon and 1536×1024 (3:2) logo.")
