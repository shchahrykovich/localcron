// The terminal app a run's console opens in: kitty when it is installed and
// chosen, else Terminal (from a .command file, see ConsoleScript).

import Foundation

public enum ConsoleTerminal: String, CaseIterable, Sendable, Identifiable {
    case kitty
    case terminal

    public static let kittyBundleID = "net.kovidgoyal.kitty"
    public static let defaultsKey = "consoleTerminal"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .kitty: "kitty"
        case .terminal: "Terminal"
        }
    }

    /// The saved choice; kitty when it is installed and nothing is saved.
    public static func chosen(saved: String?, kittyInstalled: Bool) -> ConsoleTerminal {
        switch saved.flatMap(ConsoleTerminal.init(rawValue:)) {
        case .kitty where kittyInstalled: .kitty
        case .terminal: .terminal
        default: kittyInstalled ? .kitty : .terminal
        }
    }

    /// kitty's arguments: a new window that runs the console command.
    public static func kittyArguments(command: String, runID: String) -> [String] {
        ["--title", "\(runID) console", "/bin/sh", "-c", "exec \(command)"]
    }
}
