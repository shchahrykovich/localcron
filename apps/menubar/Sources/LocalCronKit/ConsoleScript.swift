// Open Terminal: a run's console opens in Terminal from a small .command
// file, the way macOS opens shell scripts by a double click. Any other
// terminal (kitty, iTerm) takes the same command from Copy Terminal Command.

import Foundation

public enum ConsoleScript {
    /// The script for `command` (the run's `console`): it replaces itself
    /// with tmux, so leaving tmux closes the window's shell too.
    public static func text(runID: String, command: String) -> String {
        """
        #!/bin/sh
        # The console of \(runID). Leave it with Ctrl-B, then D: the run goes on.
        exec \(command)

        """
    }

    /// Write it, executable, into `dir`; returns its URL.
    public static func write(runID: String, command: String, in dir: URL) throws -> URL {
        let safe = runID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" }
        let url = dir.appendingPathComponent("\(String(safe)).command")
        try text(runID: runID, command: command).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
