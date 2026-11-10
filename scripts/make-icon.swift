import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let shape = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(red: 0.05, green: 0.38, blue: 0.8, alpha: 1), ending: NSColor(red: 0.13, green: 0.65, blue: 0.95, alpha: 1))!.draw(in: shape, angle: 65)
        for y in [CGFloat(290), 440, 590] {
            NSColor.white.withAlphaComponent(y == 590 ? 1 : 0.86).setFill()
            NSBezierPath(roundedRect: NSRect(x: 280, y: y, width: 464, height: 125), xRadius: 35, yRadius: 35).fill()
            NSColor(red: 0.15, green: 0.51, blue: 0.87, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 320, y: y+48, width: 28, height: 28)).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
