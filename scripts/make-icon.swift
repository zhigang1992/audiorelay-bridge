import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels)
        let background = NSBezierPath(roundedRect: NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88), xRadius: p * 0.2, yRadius: p * 0.2)
        NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.30, blue: 0.70, alpha: 1),
                   ending: NSColor(srgbRed: 0.12, green: 0.62, blue: 0.72, alpha: 1))!.draw(in: background, angle: 75)
        // Original geometric headphone mark; no AudioRelay or BlackHole branding.
        NSColor.white.setStroke()
        let arch = NSBezierPath()
        arch.lineWidth = p * 0.065
        arch.lineCapStyle = .round
        arch.move(to: NSPoint(x: p * 0.29, y: p * 0.40))
        arch.line(to: NSPoint(x: p * 0.29, y: p * 0.55))
        arch.curve(to: NSPoint(x: p * 0.71, y: p * 0.55), controlPoint1: NSPoint(x: p * 0.29, y: p * 0.83), controlPoint2: NSPoint(x: p * 0.71, y: p * 0.83))
        arch.line(to: NSPoint(x: p * 0.71, y: p * 0.40))
        arch.stroke()
        NSColor.white.setFill()
        for x in [0.24, 0.63] {
            NSBezierPath(roundedRect: NSRect(x: p * x, y: p * 0.30, width: p * 0.13, height: p * 0.23), xRadius: p * 0.045, yRadius: p * 0.045).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
