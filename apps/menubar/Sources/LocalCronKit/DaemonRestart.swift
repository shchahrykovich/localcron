// The app registers the daemon again when it does not answer at start:
// scripts/install.sh removes the old LaunchAgent job before it replaces the
// app. A Developer ID build starts at the first registration. An ad-hoc build
// gets a new signature each time, and macOS keeps the launch constraint of
// the old one for 10 to 30 s ("Launch Constraint Violation", job state
// "spawn failed"); a registration after that works. So register again, with
// longer and longer waits, about a minute in all.

import Foundation

public enum DaemonRestart {
    /// Seconds to wait after each registration.
    public static let waits = [2, 4, 8, 16, 32]

    /// True when the daemon answers, at once or after a registration.
    /// `answers` asks the daemon; `registerAgain` unregisters and registers
    /// the LaunchAgent; `sleep` waits that many seconds. It runs on the
    /// caller's actor, so the closures may use its state.
    public static func run(isolation: isolated (any Actor)? = #isolation,
                           answers: () async -> Bool,
                           registerAgain: () async throws -> Void,
                           sleep: (Int) async -> Void) async throws -> Bool {
        if await answers() { return true }
        for seconds in waits {
            try await registerAgain()
            await sleep(seconds)
            if await answers() { return true }
        }
        return false
    }
}
