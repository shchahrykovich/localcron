// Open Terminal: a run's console opens in Terminal from a small .command
// file, the way macOS opens shell scripts by a double click. Any other
// terminal (kitty, iTerm) takes the same command from Copy Terminal Command.

import Foundation

public enum ConsoleScript {
    /// The script for `command` (the run's `console`): it replaces itself
    /// with tmux, so leaving tmux closes the window's shell too.
    /// With `dir`, it goes to that folder first; `note` is its comment line.
    public static func text(runID: String, command: String, dir: String? = nil, note: String? = nil) -> String {
        let note = note ?? "The console of \(runID). Leave it with Ctrl-B, then D: the run goes on."
        let cd = dir.map { "cd -- \(quoted($0)) || exit 1\n" } ?? ""
        return "#!/bin/sh\n# \(note)\n\(cd)exec \(command)\n"
    }

    /// `claude --resume <session>` in the user's login shell, so `claude` is
    /// found as in their own terminal; nil when `session` is not a session id.
    public static func resumeCommand(session: String, shell: String) -> String? {
        guard let id = UUID(uuidString: session) else { return nil }
        return "\(quoted(shell)) -lic 'claude --resume \(id.uuidString.lowercased())'"
    }

    /// `s` in single quotes for /bin/sh.
    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Write it, executable, into `dir`; returns its URL.
    public static func write(runID: String, command: String, in dir: URL, workDir: String? = nil, note: String? = nil,
                             suffix: String = "") throws -> URL {
        let safe = runID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" }
        let url = dir.appendingPathComponent("\(String(safe))\(suffix).command")
        try text(runID: runID, command: command, dir: workDir, note: note).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
