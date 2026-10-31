import Foundation
import XCTest
@testable import LocalCronKit

final class TokenStatsTests: XCTestCase {
    private func run(_ id: String, _ start: String, input: UInt64 = 0, read: UInt64 = 0, output: UInt64) -> Run {
        var r = makeRun(id, .succeeded, start: start, end: start)
        r.usage = TokenUsage(inputTokens: input, cacheReadTokens: read, outputTokens: output, requests: 1)
        return r
    }

    private var runs: [Run] {
        [
            run("review.3", "2026-10-30T09:00:00Z", input: 10, read: 1000, output: 50),
            run("review.2", "2026-10-29T09:00:00Z", input: 10, read: 800, output: 40),
            run("blog.1", "2026-10-30T07:00:00Z", input: 5, read: 100, output: 300),
            run("deps.1", "2026-10-28T07:00:00Z", output: 7),
            // Before the period: not counted.
            run("review.1", "2026-10-20T09:00:00Z", output: 999),
            // A shell run has no tokens.
            makeRun("backup.1", .succeeded, start: "2026-10-30T08:00:00Z", end: "2026-10-30T08:01:00Z"),
        ]
    }

    func testAllJobsSplitTheBarsByJobWithTheSmallOnesTogether() {
        let stats = TokenStats(runs: runs, now: testNow, period: .week, metric: .all, top: 2, calendar: utcCalendar)
        XCTAssertEqual(stats.days.count, 7)
        XCTAssertEqual(stats.days.last, ApiDate.parse("2026-10-30T00:00:00Z"))
        XCTAssertEqual(stats.runs, 4)
        XCTAssertEqual(stats.total.total, 2322)
        XCTAssertEqual(stats.jobs.map(\.jobID), ["review", "blog", "deps"])
        XCTAssertEqual(stats.jobs.first?.runs, 2)
        XCTAssertEqual(stats.series, ["review", "blog", TokenStats.other])
        let day = ApiDate.parse("2026-10-30T00:00:00Z")!
        XCTAssertEqual(stats.bars.filter { $0.day == day }.map(\.series), ["review", "blog"], "in the order of the series")
        XCTAssertEqual(stats.bars.first { $0.series == TokenStats.other }?.tokens, 7)
        XCTAssertEqual(stats.peak, 1060 + 405)
    }

    func testOutputOrdersTheJobsByWhatTheModelWrote() {
        let stats = TokenStats(runs: runs, now: testNow, period: .week, metric: .output, calendar: utcCalendar)
        XCTAssertEqual(stats.jobs.map(\.jobID), ["blog", "review", "deps"])
        XCTAssertEqual(stats.peak, 350)
    }

    func testOneJobSplitsItsBarsByKindOfTokens() {
        let stats = TokenStats(runs: runs, now: testNow, period: .month, metric: .all, job: "review", calendar: utcCalendar)
        XCTAssertEqual(stats.runs, 3, "the run of 20 October is in the 30 days")
        XCTAssertEqual(stats.series, ["New input", "Cache write", "Cache read", "Output"])
        let day = ApiDate.parse("2026-10-30T00:00:00Z")!
        XCTAssertEqual(stats.bars.filter { $0.day == day }.map(\.series), ["New input", "Cache read", "Output"], "no empty parts")
        let output = TokenStats(runs: runs, now: testNow, period: .month, metric: .output, job: "review", calendar: utcCalendar)
        XCTAssertEqual(output.series, ["Output"])
    }

    func testNoTokensNoBars() {
        let stats = TokenStats(runs: [], now: testNow, period: .week, metric: .all, calendar: utcCalendar)
        XCTAssertEqual(stats.bars, [])
        XCTAssertEqual(stats.peak, 0)
        XCTAssertEqual(stats.total, TokenUsage())
    }

    func testTokensInAFewCharacters() {
        XCTAssertEqual([812, 46_355, 999_499, 999_600, 9_311_043, 46_000_000].map { Formatting.tokens(UInt64($0)) },
                       ["812", "46K", "999K", "1.0M", "9.3M", "46M"])
        XCTAssertEqual(Formatting.tokens(TokenUsage(cacheReadTokens: 9_000_000, outputTokens: 46_355)), "9.0M tokens, 46K out")
    }

    func testTheTokensOfARunInWords() {
        let u = TokenUsage(inputTokens: 138, cacheWriteTokens: 206_115, cacheReadTokens: 9_104_790, outputTokens: 46_355, requests: 69,
                           models: ["claude-opus-5-5"])
        XCTAssertEqual(RunText.tokens(u),
                       "9.4M: 138 new input, 206K cache write, 9.1M cache read, 46K output. 69 requests to claude-opus-5-5")
        XCTAssertEqual(RunText.tokens(TokenUsage(outputTokens: 5, requests: 1)),
                       "5: 0 new input, 0 cache write, 0 cache read, 5 output. 1 request")
    }

    func testARunDecodesItsSessionAndTokens() throws {
        let json = #"{"id":"a.1","job_id":"a","trigger":"manual","status":"succeeded","queued_at":"2026-10-30T10:00:00Z","session_id":"s","usage":{"input_tokens":1,"output_tokens":2}}"#
        let run = try Api.decoder.decode(Run.self, from: Data(json.utf8))
        XCTAssertEqual(run.sessionId, "s")
        XCTAssertEqual(run.usage, TokenUsage(inputTokens: 1, outputTokens: 2))
    }
}
