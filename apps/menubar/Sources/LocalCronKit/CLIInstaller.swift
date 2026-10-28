// "Install Command Line Tool": a symlink ~/.local/bin/localcron pointing
// into the app bundle, so the terminal and `claude mcp add` can find it.
// No admin password is needed for ~/.local/bin. Each instance has
// its own link: localcron-dev for -dev.

import Foundation

/// Where the bundled programs live inside LocalCron.app. The daemon and
/// the CLI carry the instance's suffix in their names; they read their
/// instance from it.
public enum BundleLayout {
    /// The Swift app's own executable (CFBundleExecutable).
    public static let appExecutable = "Contents/MacOS/LocalCron"
    /// The daemon, started by the LaunchAgent (BundleProgram).
    public static func daemon(for instance: Instance) -> String { "Contents/MacOS/\(instance.daemonProgram)" }
    /// The command-line tool and MCP server.
    public static func cli(for instance: Instance) -> String { "Contents/Helpers/\(instance.cli)" }
    public static var daemon: String { daemon(for: .current) }
    public static var cli: String { cli(for: .current) }
    /// The note for Claude Code and Codex, linked into ~/.claude and ~/.codex.
    public static let claudeNote = "Contents/Resources/LocalCron.md"
}

public struct CLIInstaller {
    public enum Outcome: Equatable {
        /// The link was made or already pointed at this app.
        case installed(link: URL, onPath: Bool)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case toolMissing(URL)
        case occupied(URL)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case let .toolMissing(url): "The command-line tool is missing from the app: \(url.path)"
            case let .occupied(url): "\(url.path) already exists and is not a LocalCron link. Remove it first."
            case let .io(text): text
            }
        }
    }

    public var tool: URL
    public var binDir: URL
    public var pathVariable: String
    public var instance: Instance

    /// The bundled tool of the running app and ~/.local/bin.
    public init(bundle: Bundle = .main, instance: Instance = .current,
                binDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin"),
                pathVariable: String = ProcessInfo.processInfo.environment["PATH"] ?? "") {
        self.tool = bundle.bundleURL.appendingPathComponent(BundleLayout.cli(for: instance))
        self.binDir = binDir
        self.pathVariable = pathVariable
        self.instance = instance
    }

    public init(tool: URL, binDir: URL, pathVariable: String, instance: Instance = .current) {
        self.tool = tool
        self.binDir = binDir
        self.pathVariable = pathVariable
        self.instance = instance
    }

    /// `localcron` for the release, `localcron-dev` for -dev.
    public var link: URL { binDir.appendingPathComponent(instance.cli) }

    /// The program agents start for the MCP server: the link when it points
    /// to this app, else the tool inside the bundle.
    public var commandPath: String {
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), dest == tool.path {
            return link.path
        }
        return tool.path
    }

    /// A link into any bundle's CLI of this instance, wherever the bundle is.
    func isOurs(_ destination: String) -> Bool {
        destination.hasSuffix("/" + BundleLayout.cli(for: instance))
    }

    /// Remove the link if it is ours (uninstall).
    public func uninstall() {
        let fm = FileManager.default
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path), isOurs(dest) {
            try? fm.removeItem(at: link)
        }
    }

    /// Make or refresh the link. Never replaces anything that is not a link
    /// into a LocalCron bundle.
    public func install() throws -> Outcome {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: tool.path) else { throw Failure.toolMissing(tool) }
        do {
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        } catch {
            throw Failure.io("cannot create \(binDir.path): \(error.localizedDescription)")
        }
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if existing == tool.path { return .installed(link: link, onPath: onPath) }
            guard isOurs(existing) else { throw Failure.occupied(link) }
            try? fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            throw Failure.occupied(link)
        }
        do {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: tool.path)
        } catch {
            throw Failure.io("cannot link \(link.path): \(error.localizedDescription)")
        }
        return .installed(link: link, onPath: onPath)
    }

    /// Is the link folder on PATH (the app's PATH, /etc/paths or /etc/paths.d)?
    public var onPath: Bool {
        var dirs = pathVariable.split(separator: ":").map(String.init)
        if let paths = try? String(contentsOfFile: "/etc/paths", encoding: .utf8) {
            dirs += paths.split(separator: "\n").map(String.init)
        }
        if let extra = try? FileManager.default.contentsOfDirectory(atPath: "/etc/paths.d") {
            for file in extra {
                if let text = try? String(contentsOfFile: "/etc/paths.d/\(file)", encoding: .utf8) {
                    dirs += text.split(separator: "\n").map(String.init)
                }
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let target = binDir.standardizedFileURL.path
        return dirs.contains { dir in
            let expanded = dir.replacingOccurrences(of: "$HOME", with: home).replacingOccurrences(of: "~", with: home)
            return URL(fileURLWithPath: expanded).standardizedFileURL.path == target
        }
    }

    /// One line to paste into ~/.zshrc when the folder is not on PATH.
    public var pathHint: String { "echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc" }
}
