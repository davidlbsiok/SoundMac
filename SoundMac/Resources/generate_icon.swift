import AppKit

let size = 1024
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()

let context = NSGraphicsContext.current!.cgContext

// macOS-style rounded square background with a purple/blue gradient
let cornerRadius = CGFloat(size) * 0.225
let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
path.addClip()

let colors = [
    NSColor(red: 0.36, green: 0.20, blue: 0.92, alpha: 1.0).cgColor,
    NSColor(red: 0.02, green: 0.55, blue: 0.95, alpha: 1.0).cgColor
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0.0, 1.0])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Three vertical "equalizer" bars, like a soundboard mixer
let barWidth = CGFloat(size) * 0.12
let spacing = CGFloat(size) * 0.09
let bars: [(CGFloat, CGFloat)] = [(0.34, 0.30), (0.55, 0.30), (0.42, 0.30)] // (heightFraction, unused)
let heights: [CGFloat] = [0.42, 0.66, 0.52]
let totalWidth = barWidth * 3 + spacing * 2
var x = (CGFloat(size) - totalWidth) / 2

NSColor.white.setFill()
for h in heights {
    let barHeight = CGFloat(size) * h
    let y = (CGFloat(size) - barHeight) / 2
    let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
    let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
    barPath.fill()
    x += barWidth + spacing
}

// small knob dots on the bars, to read as mixer sliders
NSColor(white: 1.0, alpha: 0.55).setFill()
x = (CGFloat(size) - totalWidth) / 2
let knobRadius = barWidth * 0.62
let knobYFractions: [CGFloat] = [0.66, 0.40, 0.55]
for knobY in knobYFractions {
    let cx = x + barWidth / 2
    let cy = CGFloat(size) * knobY
    let knobRect = NSRect(x: cx - knobRadius, y: cy - knobRadius, width: knobRadius * 2, height: knobRadius * 2)
    NSBezierPath(ovalIn: knobRect).fill()
    x += barWidth + spacing
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render icon")
}

let url = URL(fileURLWithPath: "/tmp/soundmac_icon/icon_1024.png")
try! png.write(to: url)
print("wrote \(url.path)")
