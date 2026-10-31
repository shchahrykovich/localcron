import AppKit
import LocalCronKit

/// Draws the menu bar icon: four styles in six states, as on the "icon in
/// the menu bar" board of the design. The drawing is 18 by 18 points, with
/// the origin at the top left like the SVG of the design.
///
/// Parts the design fills with the menu bar's color (the ring around a
/// badge, a sign cut out of the tile) are cleared instead, so the real menu
/// bar shows through on any wallpaper.
@MainActor
enum MenuBarIconRenderer {
    struct Colors {
        /// The lines: black or white like a template image, orange for a
        /// development build.
        var ink: NSColor
        var red: NSColor = .systemRed
        var orange: NSColor = .systemOrange
        var green: NSColor = .systemGreen
    }

    static let size = NSSize(width: 18, height: 18)

    /// Black on a light menu bar, white on a dark one, as a template image
    /// would be.
    static let menuBarText = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    }

    /// The icon for this state. A template image when it has no color of its
    /// own, so macOS tints it as it tints every menu bar icon.
    /// `spin` turns the working arc of the ring style, from 0 to 1.
    static func image(style: IconStyle, icon: StatusIcon, colored: Bool, dev: Bool, spin: Double = 0, now: Date = Date()) -> NSImage {
        let state = icon.state
        let tinted = colored && [IconState.working, .failed, .waiting].contains(state)
        let template = !dev && !tinted
        let colors = Colors(ink: dev ? .systemOrange : template ? .black : menuBarText)
        let fraction = icon.ringFraction(now: now)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            switch style {
            case .clock, .clockText: drawClock(cg, state: state, c: colors, colored: colored)
            case .ring: drawRing(cg, state: state, c: colors, colored: colored, fraction: fraction, spin: spin)
            case .tile: drawTile(cg, state: state, c: colors, colored: colored)
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    // MARK: Styles

    private static func drawClock(_ cg: CGContext, state: IconState, c: Colors, colored: Bool) {
        let ring = CGRect(x: 9 - 6.75, y: 9 - 6.75, width: 13.5, height: 13.5)
        if state == .down {
            cg.saveGState()
            cg.setAlpha(0.55)
            stroke(cg, c.ink, width: 1.5, dash: [2.4, 2.1]) { $0.addEllipse(in: ring) }
            hands(cg, c.ink, [(9, 5.3), (9, 9), (11.5, 10.5)], width: 1.5)
            cg.restoreGState()
            clear(cg) { cg in
                cg.setLineWidth(3.6)
                cg.setLineCap(.round)
                cg.move(to: CGPoint(x: 3.2, y: 14.8))
                cg.addLine(to: CGPoint(x: 14.8, y: 3.2))
                cg.strokePath()
            }
            stroke(cg, c.ink, width: 1.5) { $0.move(to: CGPoint(x: 3.2, y: 14.8)); $0.addLine(to: CGPoint(x: 14.8, y: 3.2)) }
            return
        }
        stroke(cg, c.ink, width: 1.5) { $0.addEllipse(in: ring) }
        hands(cg, c.ink, [(9, 5.3), (9, 9), (11.5, 10.5)], width: 1.5)
        switch state {
        case .working: badge(cg, .play, c: c, colored: colored)
        case .failed: badge(cg, .fail, c: c, colored: colored)
        case .waiting: badge(cg, .wait, c: c, colored: colored)
        case .paused: badge(cg, .pause, c: c, colored: colored)
        case .idle, .down: break
        }
    }

    private enum Badge { case play, fail, wait, pause }

    /// A sign on the bottom right corner, with a clear ring around it.
    private static func badge(_ cg: CGContext, _ kind: Badge, c: Colors, colored: Bool) {
        clear(cg) { $0.fillEllipse(in: circle(14, 14, 5.3)) }
        switch kind {
        case .pause:
            fill(cg, c.ink) { cg in
                cg.addPath(CGPath(roundedRect: CGRect(x: 11.9, y: 11.1, width: 1.8, height: 5.8), cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
                cg.addPath(CGPath(roundedRect: CGRect(x: 14.3, y: 11.1, width: 1.8, height: 5.8), cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
            }
        case .play:
            let color = colored ? c.green : c.ink
            let triangle = { (cg: CGContext) in
                cg.move(to: CGPoint(x: 12, y: 11.3))
                cg.addLine(to: CGPoint(x: 16.9, y: 14))
                cg.addLine(to: CGPoint(x: 12, y: 16.7))
                cg.closePath()
            }
            fill(cg, color, triangle)
            stroke(cg, color, width: 0.6, join: .round, triangle)
        case .fail, .wait:
            let color = kind == .fail ? (colored ? c.red : c.ink) : (colored ? c.orange : c.ink)
            fill(cg, color) { $0.addEllipse(in: circle(14, 14, 4)) }
            mark(cg, cut: colored ? .white : nil) { cg in
                if kind == .fail {
                    line(cg, (14, 11.8), (14, 14.4), width: 1.4)
                    cg.fillEllipse(in: circle(14, 16.3, 0.8))
                } else {
                    cg.fillEllipse(in: circle(14, 13.1, 1.2))
                    line(cg, (14, 13.6), (14, 16), width: 1.3)
                }
            }
        }
    }

    private static func drawRing(_ cg: CGContext, state: IconState, c: Colors, colored: Bool, fraction: Double, spin: Double) {
        let r: CGFloat = 6.5
        let ring = circle(9, 9, r)
        let track = { (alpha: CGFloat) in stroke(cg, c.ink.withAlphaComponent(alpha), width: 2) { $0.addEllipse(in: ring) } }
        /// An arc clockwise from the top, `f` of the circle.
        func arc(_ f: Double, _ color: NSColor, start: Double = 0, cap: CGLineCap = .butt) {
            guard f > 0 else { return }
            let a0 = -Double.pi / 2 + start * 2 * .pi
            stroke(cg, color, width: 2, cap: cap) { cg in
                cg.addArc(center: CGPoint(x: 9, y: 9), radius: r, startAngle: a0, endAngle: a0 + f * 2 * .pi, clockwise: false)
            }
        }
        switch state {
        case .idle:
            track(0.28)
            arc(fraction, c.ink)
        case .working:
            let g = colored ? c.green : c.ink
            track(0.28)
            arc(0.25, g, start: spin, cap: .round)
            fill(cg, g) { $0.addEllipse(in: circle(9, 9, 1.6)) }
        case .failed:
            let red = colored ? c.red : c.ink
            stroke(cg, red, width: 2) { $0.addEllipse(in: ring) }
            fill(cg, red) { cg in
                line(cg, (9, 5.7), (9, 9.6), width: 1.7)
                cg.addEllipse(in: circle(9, 12.2, 1))
            }
        case .waiting:
            let o = colored ? c.orange : c.ink
            stroke(cg, o, width: 2) { $0.addEllipse(in: ring) }
            fill(cg, o) { cg in
                cg.addEllipse(in: circle(9, 7.8, 1.6))
            }
            stroke(cg, o, width: 1.7, cap: .round) { line(path: $0, (9, 8.5), (9, 11.8)) }
        case .paused:
            track(0.28)
            arc(fraction, c.ink.withAlphaComponent(0.55))
            bars(cg, c.ink, x1: 6.8, x2: 9.6, y: 6.3, w: 1.6, h: 5.4, r: 0.5)
        case .down:
            stroke(cg, c.ink.withAlphaComponent(0.5), width: 2, dash: [2.2, 2.2]) { $0.addEllipse(in: ring) }
        }
    }

    private static func drawTile(_ cg: CGContext, state: IconState, c: Colors, colored: Bool) {
        if state == .down {
            stroke(cg, c.ink.withAlphaComponent(0.55), width: 1.3, dash: [2.4, 2]) { cg in
                cg.addPath(CGPath(roundedRect: CGRect(x: 1.5, y: 1.5, width: 15, height: 15), cornerWidth: 4, cornerHeight: 4, transform: nil))
            }
            cg.saveGState()
            cg.setAlpha(0.55)
            stroke(cg, c.ink, width: 1.3) { $0.addEllipse(in: circle(9, 9, 4.4)) }
            hands(cg, c.ink, [(9, 6.6), (9, 9), (10.6, 10)], width: 1.3)
            cg.restoreGState()
            return
        }
        let tint: NSColor? = colored ? [IconState.working: c.green, .failed: c.red, .waiting: c.orange][state] : nil
        fill(cg, tint ?? c.ink) { cg in
            cg.addPath(CGPath(roundedRect: CGRect(x: 1, y: 1, width: 16, height: 16), cornerWidth: 4.2, cornerHeight: 4.2, transform: nil))
        }
        mark(cg, cut: tint == nil ? nil : .white) { cg in
            switch state {
            case .idle:
                cg.setLineWidth(1.4)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.addEllipse(in: circle(9, 9, 4.6))
                cg.strokePath()
                cg.move(to: CGPoint(x: 9, y: 6.4))
                cg.addLine(to: CGPoint(x: 9, y: 9))
                cg.addLine(to: CGPoint(x: 10.7, y: 10.1))
                cg.strokePath()
            case .working:
                cg.move(to: CGPoint(x: 7, y: 5.5))
                cg.addLine(to: CGPoint(x: 12.6, y: 9))
                cg.addLine(to: CGPoint(x: 7, y: 12.5))
                cg.closePath()
                cg.setLineWidth(0.8)
                cg.setLineJoin(.round)
                cg.drawPath(using: .fillStroke)
            case .failed:
                line(cg, (9, 5.1), (9, 9.7), width: 1.9)
                cg.fillEllipse(in: circle(9, 12.6, 1.1))
            case .waiting:
                cg.fillEllipse(in: circle(9, 7.6, 1.7))
                line(cg, (9, 8.3), (9, 12.2), width: 1.9)
            case .paused:
                cg.addPath(CGPath(roundedRect: CGRect(x: 6.5, y: 5.5, width: 1.9, height: 7), cornerWidth: 0.6, cornerHeight: 0.6, transform: nil))
                cg.addPath(CGPath(roundedRect: CGRect(x: 9.6, y: 5.5, width: 1.9, height: 7), cornerWidth: 0.6, cornerHeight: 0.6, transform: nil))
                cg.fillPath()
            case .down:
                break
            }
        }
    }

    // MARK: Drawing helpers

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGRect {
        CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
    }

    private static func stroke(_ cg: CGContext, _ color: NSColor, width: CGFloat, cap: CGLineCap = .round, join: CGLineJoin = .round,
                               dash: [CGFloat] = [], _ path: (CGContext) -> Void) {
        cg.saveGState()
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(width)
        cg.setLineCap(cap)
        cg.setLineJoin(join)
        if !dash.isEmpty { cg.setLineDash(phase: 0, lengths: dash) }
        path(cg)
        cg.strokePath()
        cg.restoreGState()
    }

    private static func fill(_ cg: CGContext, _ color: NSColor, _ path: (CGContext) -> Void) {
        cg.saveGState()
        cg.setFillColor(color.cgColor)
        cg.setStrokeColor(color.cgColor)
        path(cg)
        cg.fillPath()
        cg.restoreGState()
    }

    /// Draws with clear pixels: what was there is gone.
    private static func clear(_ cg: CGContext, _ draw: (CGContext) -> Void) {
        cg.saveGState()
        cg.setBlendMode(.clear)
        cg.setFillColor(NSColor.black.cgColor)
        cg.setStrokeColor(NSColor.black.cgColor)
        draw(cg)
        cg.restoreGState()
    }

    /// A sign inside a filled shape: in white on a color, or cut out.
    private static func mark(_ cg: CGContext, cut color: NSColor?, _ draw: (CGContext) -> Void) {
        if let color {
            cg.saveGState()
            cg.setFillColor(color.cgColor)
            cg.setStrokeColor(color.cgColor)
            draw(cg)
            cg.restoreGState()
        } else {
            clear(cg, draw)
        }
    }

    /// A stroked line with round caps, drawn at once.
    private static func line(_ cg: CGContext, _ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat), width: CGFloat) {
        cg.saveGState()
        cg.setLineWidth(width)
        cg.setLineCap(.round)
        cg.move(to: CGPoint(x: a.0, y: a.1))
        cg.addLine(to: CGPoint(x: b.0, y: b.1))
        cg.strokePath()
        cg.restoreGState()
    }

    /// A line added to the path, for `stroke`.
    private static func line(path cg: CGContext, _ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) {
        cg.move(to: CGPoint(x: a.0, y: a.1))
        cg.addLine(to: CGPoint(x: b.0, y: b.1))
    }

    private static func hands(_ cg: CGContext, _ color: NSColor, _ points: [(CGFloat, CGFloat)], width: CGFloat) {
        stroke(cg, color, width: width) { cg in
            cg.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for p in points.dropFirst() { cg.addLine(to: CGPoint(x: p.0, y: p.1)) }
        }
    }

    private static func bars(_ cg: CGContext, _ color: NSColor, x1: CGFloat, x2: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat) {
        fill(cg, color) { cg in
            cg.addPath(CGPath(roundedRect: CGRect(x: x1, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
            cg.addPath(CGPath(roundedRect: CGRect(x: x2, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
        }
    }
}
