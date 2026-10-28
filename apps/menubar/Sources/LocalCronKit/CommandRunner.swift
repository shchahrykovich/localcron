// Runs a program the way a terminal would find it. The app starts with
// launchd's short PATH, where `claude` is missing, so the command goes
// through the user's interactive login shell, which reads ~/.zprofile and
// ~/.zshrc. Tests use a fake runner and never start a real program.

import Foundation

public struct CommandOutput: Equatable, Sendable {
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }

    /// The shell's code for "command not found".
    public var notFound: Bool { status == 127 }
}

public protocol CommandRunner {
    func run(_ argv: [String]) -> CommandOutput
}

/// Quotes one argument for a POSIX shell: `it's` becomes `'it'\''s'`.
public func shellQuote(_ s: String) -> String {
    if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@".contains($0) }), s.allSatisfy(\.isASCII) {
        return s
    }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// One line to paste into a terminal.
public func commandLine(_ argv: [String]) -> String {
    argv.map(shellQuote).joined(separator: " ")
}

public struct LoginShellRunner: CommandRunner {
    public var shell: String
    public var timeout: TimeInterval

    public init(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", timeout: TimeInterval = 60) {
        self.shell = shell.isEmpty ? "/bin/zsh" : shell
        self.timeout = timeout
    }

    public func run(_ argv: [String]) -> CommandOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", commandLine(argv)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return CommandOutput(status: -1, output: "cannot start \(shell): \(error.localizedDescription)")
        }
        // Read while it runs, so a full pipe cannot block the program.
        let reader = DispatchQueue(label: "localcron.command-output")
        nonisolated(unsafe) var data = Data()
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            p.terminate()
            p.waitUntilExit()
            done.wait()
            return CommandOutput(status: -1, output: "\(commandLine(argv)) did not finish in \(Int(timeout)) s")
        }
        p.waitUntilExit()
        done.wait()
        return CommandOutput(status: p.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }
}
