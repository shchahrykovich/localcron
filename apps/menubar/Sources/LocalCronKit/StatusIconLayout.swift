// Where the parts of the menu bar icon go: the clock, the play badge on the
// clock's bottom right corner while runs are going, and a column to the right
// with the warning (top) and pause (bottom) badges.

import CoreGraphics

public struct StatusIconLayout: Equatable, Sendable {
    public var size: CGSize
    public var clock: CGRect
    /// On the clock's bottom right corner, a little past its edge.
    public var play: CGRect?
    /// The clear ring around the play badge, so it reads on the clock.
    public var playHalo: CGRect?
    /// Left edge of the warning and pause column.
    public var columnX: CGFloat

    /// How far the play badge reaches past the clock's right edge.
    public static let overhang: CGFloat = 2
    /// Width of the clear ring around the play badge.
    public static let halo: CGFloat = 1

    public init(clock: CGSize, play: CGSize?, column: CGFloat, minHeight: CGFloat = 16) {
        let height = max(clock.height, minHeight)
        self.clock = CGRect(x: 0, y: (height - clock.height) / 2, width: clock.width, height: clock.height)
        let reach = play == nil ? 0 : Self.overhang
        if let play {
            let rect = CGRect(x: clock.width + reach - play.width, y: 0, width: play.width, height: play.height)
            self.play = rect
            playHalo = rect.insetBy(dx: -Self.halo, dy: -Self.halo)
        } else {
            self.play = nil
            playHalo = nil
        }
        columnX = clock.width + reach + (column > 0 ? 1 : 0)
        size = CGSize(width: (columnX + column).rounded(.up), height: height)
    }
}
