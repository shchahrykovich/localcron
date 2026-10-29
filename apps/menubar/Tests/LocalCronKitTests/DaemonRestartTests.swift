import Foundation
import XCTest
@testable import LocalCronKit

/// macOS refuses a rebuilt ad-hoc daemon for 10 to 30 s after it is
/// replaced (the old launch constraint); a registration after that works.
final class DaemonRestartTests: XCTestCase {
    private final class Fake: @unchecked Sendable {
        /// The daemon answers after this many registrations.
        var answersAfter: Int
        var registrations = 0
        var waits: [Int] = []
        init(answersAfter: Int) { self.answersAfter = answersAfter }
    }

    private func run(_ fake: Fake) async throws -> Bool {
        try await DaemonRestart.run(answers: { fake.registrations >= fake.answersAfter },
                                    registerAgain: { fake.registrations += 1 },
                                    sleep: { fake.waits.append($0) })
    }

    func testARunningDaemonIsLeftAlone() async throws {
        let fake = Fake(answersAfter: 0)
        let ok = try await run(fake)
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.registrations, 0)
    }

    func testItRegistersAgainUntilTheDaemonAnswers() async throws {
        let fake = Fake(answersAfter: 4)
        let ok = try await run(fake)
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.registrations, 4)
        XCTAssertEqual(fake.waits, [2, 4, 8, 16])
    }

    func testTheWaitsCoverAboutAMinuteThenItGivesUp() async throws {
        let fake = Fake(answersAfter: 99)
        let ok = try await run(fake)
        XCTAssertFalse(ok)
        XCTAssertEqual(fake.waits, [2, 4, 8, 16, 32])
        XCTAssertGreaterThan(fake.waits.reduce(0, +), 30, "longer than the 10 to 30 s macOS refuses the daemon")
    }
}
