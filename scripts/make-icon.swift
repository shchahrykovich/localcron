// Draws the app icon: a rounded square with a clock.
//   swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.47, alpha: 1),
                    NSColor(calibratedRed: 0.10, green: 0.33, blue: 0.62, alpha: 1)])!.draw(in: path, angle: -60)
let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "clock.badge.checkmark", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
