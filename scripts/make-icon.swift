import AppKit

// make-icon.swift <out.png> [--dev]
// --dev draws the icon of a suffixed instance: orange, like its menu bar
// icon, with a DEV band, so it is not mistaken for the release in Finder.
let size: CGFloat = 1024
let args = CommandLine.arguments.dropFirst()
let dev = args.contains("--dev")
let out = args.first { $0 != "--dev" } ?? "icon.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
let colors = dev
    ? [NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.04, alpha: 1),
       NSColor(calibratedRed: 0.86, green: 0.30, blue: 0.05, alpha: 1)]
    : [NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.47, alpha: 1),
       NSColor(calibratedRed: 0.10, green: 0.33, blue: 0.62, alpha: 1)]
NSGradient(colors: colors)!.draw(in: path, angle: -60)
let config = NSImage.SymbolConfiguration(pointSize: dev ? 380 : 440, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "clock.badge.checkmark", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let y = dev ? 330 + (594 - s.height) / 2 : (size - s.height) / 2
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: y, width: s.width, height: s.height))
}
if dev {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSColor(calibratedWhite: 0, alpha: 0.35).setFill()
    NSRect(x: 100, y: 100, width: 824, height: 210).fill()
    NSGraphicsContext.restoreGraphicsState()
    let label = NSAttributedString(string: "DEV", attributes: [
        .font: NSFont.systemFont(ofSize: 150, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: 12,
    ])
    let l = label.size()
    label.draw(at: NSPoint(x: (size - l.width) / 2, y: 100 + (210 - l.height) / 2))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
