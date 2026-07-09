// Generates the Debrief app icon: two waveforms (amber = them, blue = you —
// matching the transcript colors) on a dark squircle.
// Usage: swift scripts/make-icon.swift <output.png>   (emits 1024x1024 PNG)
// make-icon.sh wraps this and produces assets/AppIcon.icns.
import AppKit

let size: CGFloat = 1024
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.png>\n".utf8))
    exit(1)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Apple icon grid: 824pt squircle centered on a 1024 canvas, corner radius ~185.
let squircle = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: squircle, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path)
ctx.clip()

// Background: deep navy vertical gradient.
let colors = [CGColor(red: 0.13, green: 0.17, blue: 0.26, alpha: 1),
              CGColor(red: 0.05, green: 0.07, blue: 0.13, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

/// One waveform row: capsules of varying height mirrored around a baseline.
func drawWave(heights: [CGFloat], baseline: CGFloat, color: NSColor, maxHalf: CGFloat) {
    let barWidth: CGFloat = 40
    let gap: CGFloat = 26
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = (size - totalWidth) / 2
    ctx.setFillColor(color.cgColor)
    for h in heights {
        let half = max(maxHalf * h, barWidth / 2)
        let bar = CGRect(x: x, y: baseline - half, width: barWidth, height: half * 2)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.fillPath()
        x += barWidth + gap
    }
}

// Them (amber, upper) and You (blue, lower) — same palette as the transcript view.
drawWave(heights: [0.30, 0.55, 0.90, 0.50, 0.75, 0.35, 0.60, 0.25, 0.45],
         baseline: 640, color: NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1), maxHalf: 130)
drawWave(heights: [0.40, 0.25, 0.55, 0.85, 1.00, 0.65, 0.35, 0.70, 0.30],
         baseline: 386, color: NSColor(red: 0.30, green: 0.64, blue: 1.00, alpha: 1), maxHalf: 130)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: outputURL)
print("wrote \(outputURL.path)")
