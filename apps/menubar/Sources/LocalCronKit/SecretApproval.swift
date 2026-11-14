import Foundation

/// What the Allow Secrets window shows: the job as it is now and, for a job
/// that changed since the user allowed it, each field that changed.
public struct SecretApproval: Equatable, Sendable {
    public var job: Job
    /// What the user allowed the last time; nil for a job never allowed.
    public var before: PastApproval?

    public init(job: Job, before: PastApproval? = nil) {
        self.job = job
        self.before = before
    }

    public init(_ view: JobView) {
        self.init(job: view.job, before: view.allowedBefore)
    }

    public var title: String { "Allow \(job.id) to read its secrets?" }

    /// "Changed since you allowed it yesterday 14:03." or "Not allowed before."
    public func subtitle(now: Date = Date()) -> String {
        guard let before else { return "This job was never allowed. Read what it runs before you allow it." }
        let when = ApiDate.parse(before.allowedAt).map { " " + Formatting.when($0, now: now) } ?? ""
        let n = changes.count
        return "You allowed it\(when). Since then \(n == 1 ? "1 thing" : "\(n) things") changed in what it runs."
    }

    /// Variable and secret name, sorted by variable.
    public var secrets: [(variable: String, secret: String)] {
        job.secretEnv.sorted { $0.key < $1.key }.map { (variable: $0.key, secret: $0.value) }
    }

    public var summary: String {
        """
        Secrets: \(secretList)
        Folder: \((job.dir as NSString).abbreviatingWithTildeInPath)

        The job can do anything with these values, also send them elsewhere. \
        Allow it only if you wrote it or read it below. A change to what it runs needs a new OK.
        """
    }

    /// Everything the approval covers, as text.
    public var details: String {
        var parts: [String] = []
        if job.kind == .shell {
            parts.append("Command:\n\(job.command ?? "")")
        } else {
            parts.append("\(job.kind.title) prompt:\n\(job.prompt ?? "")")
        }
        if let model = job.model { parts.append("Model: \(model)") }
        if let mode = job.permissionMode { parts.append("Permission mode: \(mode)") }
        if !job.args.isEmpty { parts.append("Arguments: \(Formatting.joinArgs(job.args))") }
        if !job.env.isEmpty {
            parts.append("Environment:\n" + job.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        }
        parts.append("Secrets: \(secretList)")
        parts.append("Folder: \(job.dir)")
        return parts.joined(separator: "\n\n")
    }

    /// Each field that differs from what the user allowed, in the order the
    /// window lists them. Empty for a job never allowed.
    public var changes: [SecretChange] {
        guard let old = before?.job else { return [] }
        let new = SecretScope(job)
        var out: [SecretChange] = []
        func add(_ field: String, _ a: String?, _ b: String?, long: Bool = false) {
            if (a ?? "") != (b ?? "") { out.append(SecretChange(field: field, old: a ?? "", new: b ?? "", long: long)) }
        }
        add("Kind", old.kind.title, new.kind.title)
        add("Command", old.command, new.command, long: true)
        add("Prompt", old.prompt, new.prompt, long: true)
        add("Model", old.model, new.model)
        add("Permission mode", old.permissionMode, new.permissionMode)
        add("Arguments", Formatting.joinArgs(old.args), Formatting.joinArgs(new.args))
        add("Folder", old.dir, new.dir)
        for key in Set(old.secretEnv.keys).union(new.secretEnv.keys).sorted() {
            add("Secret \(key)", old.secretEnv[key], new.secretEnv[key])
        }
        for key in Set(old.env.keys).union(new.env.keys).sorted() {
            add("Variable \(key)", old.env[key], new.env[key])
        }
        return out
    }

    private var secretList: String {
        secrets.map { "\($0.variable) from \($0.secret)" }.joined(separator: ", ")
    }
}

/// One field that changed since the user allowed the job. An empty side
/// means the field was not set.
public struct SecretChange: Equatable, Sendable, Identifiable {
    public var field: String
    public var old: String
    public var new: String
    /// A command or a prompt: shown as a word diff, not as two values.
    public var long: Bool

    public var id: String { field }

    public var diff: [DiffPiece] { TextDiff.words(old, new) }
}

public enum DiffPiece: Equatable, Sendable {
    case same(String)
    case removed(String)
    case added(String)

    public var text: String {
        switch self {
        case .same(let t), .removed(let t), .added(let t): t
        }
    }
}

/// A word diff, for a prompt or a command that changed. Joined, the
/// `same` and `removed` pieces give the old text, and the `same` and
/// `added` pieces give the new one.
public enum TextDiff {
    /// Above this many token pairs the middle is shown as removed and
    /// added whole, so a huge prompt cannot stall the window.
    static let maxCells = 2_000_000

    public static func words(_ old: String, _ new: String) -> [DiffPiece] {
        let a = tokens(old), b = tokens(new)
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1
            endB -= 1
        }
        var pieces: [DiffPiece] = []
        if start > 0 { pieces.append(.same(a[0..<start].joined())) }
        pieces += middle(Array(a[start..<endA]), Array(b[start..<endB]))
        if endA < a.count { pieces.append(.same(a[endA...].joined())) }
        return tidy(pieces)
    }

    /// Words and the space between them, so the tokens join back to the text.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSpace: Bool?
        for ch in s {
            let space = ch.isWhitespace
            if space != inSpace, !current.isEmpty {
                out.append(current)
                current = ""
            }
            current.append(ch)
            inSpace = space
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func middle(_ a: [String], _ b: [String]) -> [DiffPiece] {
        if a.isEmpty && b.isEmpty { return [] }
        if a.isEmpty { return [.added(b.joined())] }
        if b.isEmpty { return [.removed(a.joined())] }
        if a.count * b.count > maxCells { return [.removed(a.joined()), .added(b.joined())] }
        // Longest common subsequence, from the end, so the walk goes forward.
        let n = a.count, m = b.count
        var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * (m + 1) + j] = a[i] == b[j]
                    ? table[(i + 1) * (m + 1) + j + 1] + 1
                    : max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1])
            }
        }
        var out: [DiffPiece] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                out.append(.same(a[i]))
                i += 1
                j += 1
            } else if table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1] {
                out.append(.removed(a[i]))
                i += 1
            } else {
                out.append(.added(b[j]))
                j += 1
            }
        }
        while i < n { out.append(.removed(a[i])); i += 1 }
        while j < m { out.append(.added(b[j])); j += 1 }
        return out
    }

    /// A space kept between two changes belongs to the change, so "a b" to
    /// "c d" reads as one removed and one added piece, not four. Then the
    /// pieces of one change go removed first, added second.
    private static func tidy(_ pieces: [DiffPiece]) -> [DiffPiece] {
        var flat = pieces
        for k in flat.indices {
            guard case .same(let t) = flat[k], t.allSatisfy(\.isWhitespace),
                  k > 0, k < flat.count - 1, !isSame(flat[k - 1]), !isSame(flat[k + 1]) else { continue }
            flat[k] = .removed(t)
            flat.insert(.added(t), at: k + 1)
        }
        var out: [DiffPiece] = []
        var removed = "", added = ""
        func flush() {
            if !removed.isEmpty { out.append(.removed(removed)) }
            if !added.isEmpty { out.append(.added(added)) }
            removed = ""
            added = ""
        }
        for piece in flat {
            switch piece {
            case .removed(let t): removed += t
            case .added(let t): added += t
            case .same(let t):
                flush()
                if case .same(let last) = out.last {
                    out[out.count - 1] = .same(last + t)
                } else {
                    out.append(.same(t))
                }
            }
        }
        flush()
        return out
    }

    private static func isSame(_ p: DiffPiece) -> Bool {
        if case .same = p { return true }
        return false
    }

    /// A long unchanged stretch keeps only its ends, so the change stays in view.
    public static func shortened(_ pieces: [DiffPiece], keep: Int = 160) -> [DiffPiece] {
        pieces.enumerated().map { index, piece in
            guard case .same(let t) = piece, t.count > keep * 2 + 20 else { return piece }
            if index == pieces.count - 1 { return .same(t.prefix(keep) + " …") }
            if index == 0 { return .same("… " + t.suffix(keep)) }
            return .same(t.prefix(keep) + " … " + t.suffix(keep))
        }
    }
}
