import Foundation
import XCTest
@testable import LocalCronKit

/// Today is Friday 30 October 2026, 10:40, in UTC.
let testNow = ApiDate.parse("2026-10-30T10:40:00Z")!

var utcCalendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

func makeRun(_ id: String, _ status: RunStatus, trigger: Trigger = .schedule, start: String?, end: String? = nil,
             exit: Int32? = nil, message: String = "", due: String? = nil) -> Run {
    Run(id: id, jobId: String(id.split(separator: ".")[0]), trigger: trigger, status: status, dueAt: due,
        queuedAt: start ?? end ?? "2026-10-30T00:00:00Z", startedAt: start, endedAt: end, exitCode: exit, message: message)
}

final class RunTextTests: XCTestCase {
    private func line(_ run: Run) -> String { RunText.line(run, now: testNow, calendar: utcCalendar).text }

    func testEachStatusInWords() {
        XCTAssertEqual(line(makeRun("deps.1", .running, trigger: .manual, start: "2026-10-30T10:36:48Z")), "Working for 3 min 12 s")
        XCTAssertEqual(RunText.line(makeRun("deps.1", .running, start: "2026-10-30T10:36:48Z"), now: testNow).tone, .accent)
        XCTAssertEqual(line(makeRun("pr.1", .succeeded, start: "2026-10-30T10:00:00Z", end: "2026-10-30T10:06:40Z", exit: 0)),
                       "Succeeded in 6 min 40 s")
        XCTAssertEqual(line(makeRun("pr.2", .succeeded, trigger: .catchUp, start: "2026-10-30T08:14:00Z", end: "2026-10-30T08:19:02Z",
                                    exit: 0, due: "2026-10-30T08:00:00Z")),
                       "Due at 08:00, the Mac was asleep. Succeeded in 5 min 2 s")
        XCTAssertEqual(line(makeRun("nt.1", .failed, start: "2026-10-30T02:00:00Z", end: "2026-10-30T02:01:48Z", exit: 2)),
                       "Failed with exit code 2 after 1 min 48 s")
        let notStarted = makeRun("digest.1", .failed, start: nil, end: "2026-10-30T08:30:00Z",
                                 message: "you have not allowed its secrets yet")
        XCTAssertEqual(line(notStarted), "Did not start: you have not allowed its secrets yet")
        XCTAssertEqual(RunText.line(notStarted).tone, .danger)
        XCTAssertEqual(line(makeRun("pr.3", .timedOut, start: "2026-10-29T16:00:00Z", end: "2026-10-29T17:00:00Z")),
                       "Stopped after 60 min, its time limit")
        XCTAssertEqual(line(makeRun("b.1", .canceled, start: "2026-10-29T15:30:00Z", end: "2026-10-29T15:30:12Z", message: "canceled")),
                       "Stopped by you after 12 s")
        XCTAssertEqual(line(makeRun("b.2", .canceled, start: nil, end: "2026-10-29T15:30:00Z", message: "LocalCron was paused")),
                       "Stopped: LocalCron was paused")
        XCTAssertEqual(line(makeRun("b.3", .skipped, start: nil, end: "2026-10-29T15:30:00Z", message: "run b.2 was still running")),
                       "Did not start: run b.2 was still running")
    }

    func testTheChipSaysWhoStartedTheRun() {
        XCTAssertEqual(RunText.chip(makeRun("a.1", .running, trigger: .manual, start: nil)), "Run by you")
        XCTAssertEqual(RunText.chip(makeRun("a.1", .running, trigger: .catchUp, start: nil)), "Caught up")
        XCTAssertNil(RunText.chip(makeRun("a.1", .running, start: nil)))
        XCTAssertEqual(RunText.startedBy(makeRun("a.1", .failed, start: nil), scheduleText: "Every day at 02:00"),
                       "The schedule, every day at 02:00")
    }

    func testRunsGroupByDayNewestFirst() {
        let runs = [makeRun("a.3", .running, start: "2026-10-30T10:37:00Z"),
                    makeRun("a.2", .succeeded, start: "2026-10-30T02:00:00Z"),
                    makeRun("a.1", .succeeded, start: "2026-10-29T18:00:00Z"),
                    makeRun("a.0", .failed, start: "2026-10-27T09:00:00Z")]
        let days = RunGroups.byDay(runs, now: testNow, calendar: utcCalendar)
        XCTAssertEqual(days.map(\.title), ["Today, Friday 30 October", "Yesterday", "Tuesday 27 October"])
        XCTAssertEqual(days[0].runs.map(\.id), ["a.3", "a.2"])
        XCTAssertEqual(RunGroups.count(1), "1 run")
        XCTAssertEqual(runs.filter(RunFilter.failed.matches).map(\.id), ["a.0"])
        XCTAssertEqual(runs.filter(RunFilter.working.matches).map(\.id), ["a.3"])
    }

    func testJobsGroupByFolderWithASummary() throws {
        func job(_ id: String, dir: String, enabled: Bool = true, running: Bool = false, next: String? = nil) throws -> JobView {
            let active = running ? #","active_run":{"id":"\#(id).1","job_id":"\#(id)","trigger":"manual","status":"running","queued_at":"2026-10-30T10:00:00Z"}"# : ""
            let nextJSON = next.map { #","next_run":"\#($0)""# } ?? ""
            let json = #"{"id":"\#(id)","schedule":"@daily","kind":"shell","command":"true","dir":"\#(dir)","enabled":\#(enabled),"schedule_text":"Every day"\#(active)\#(nextJSON)}"#
            return try Api.decoder.decode(JobView.self, from: Data(json.utf8))
        }
        let jobs = [try job("pr-review", dir: "/Users/me/Projects/shop", next: "2026-10-30T12:00:00Z"),
                    try job("nightly", dir: "/Users/me/Projects/shop", next: "2026-10-31T02:00:00Z"),
                    try job("deps", dir: "/Users/me/Projects/shop", running: true),
                    try job("notes", dir: "/Users/me/notes", enabled: false)]
        let folders = JobGroups.byFolder(jobs, home: "/Users/me")
        XCTAssertEqual(folders.map(\.title), ["~/Projects/shop", "~/notes"])
        XCTAssertEqual(folders.map(\.summary), ["3 jobs, 1 running", "1 job, off"])
        XCTAssertEqual(folders[0].jobs.map(\.id), ["deps", "pr-review", "nightly"], "running first, then the soonest")
        XCTAssertEqual(JobGroups.tilde("/Users/me", home: "/Users/me"), "~")
        XCTAssertEqual(JobGroups.tilde("/tmp/x", home: "/Users/me"), "/tmp/x")
    }

    func testTextForTimesAndSizes() {
        let cal = utcCalendar
        XCTAssertEqual(Formatting.soon(ApiDate.parse("2026-10-30T12:00:00Z")!, now: testNow, calendar: cal), "12:00, in 1 h 20 min")
        XCTAssertEqual(Formatting.soon(ApiDate.parse("2026-10-31T02:00:00Z")!, now: testNow, calendar: cal), "tomorrow 02:00")
        XCTAssertEqual(Formatting.soon(ApiDate.parse("2026-11-02T09:00:00Z")!, now: testNow, calendar: cal), "Monday 09:00")
        XCTAssertEqual(Formatting.soon(ApiDate.parse("2026-11-12T09:00:00Z")!, now: testNow, calendar: cal), "12 Nov 09:00")
        XCTAssertEqual(Formatting.left(20 * 60), "in 20 min")
        XCTAssertEqual(Formatting.left(3 * 3600), "in 3 h")
        XCTAssertEqual(Formatting.left(10), "in 1 min")
        XCTAssertEqual(Formatting.when(ApiDate.parse("2026-10-30T02:00:00Z")!, now: testNow, calendar: cal), "02:00")
        XCTAssertEqual(Formatting.when(ApiDate.parse("2026-10-29T18:00:00Z")!, now: testNow, calendar: cal), "yesterday 18:00")
        XCTAssertEqual(Formatting.bytes(820), "820 bytes")
        XCTAssertEqual(Formatting.bytes(38 * 1024 * 1024 + 1000), "38 MB")
        XCTAssertEqual(Formatting.bytes(1024 * 1024 * 1024), "1 GB")
        XCTAssertEqual(Formatting.bytes(1536 * 1024 * 1024), "1.5 GB")
    }
}

final class CalendarLayoutTests: XCTestCase {
    func testTheStripShowsTwelveHoursWithNowAThirdIn() {
        let strip = DayStrip(now: testNow, calendar: utcCalendar)
        XCTAssertEqual(strip.start, ApiDate.parse("2026-10-30T06:00:00Z"))
        XCTAssertEqual(strip.end, ApiDate.parse("2026-10-30T18:00:00Z"))
        XCTAssertEqual(strip.fraction(testNow), 280.0 / 720, accuracy: 0.0001)
        XCTAssertEqual(strip.labels.map { Formatting.clock($0, calendar: utcCalendar) }, ["06:00", "09:00", "12:00", "15:00", "18:00"])
        let marks = [TimeMark(id: "a", jobID: "a", mark: .planned, start: ApiDate.parse("2026-10-30T19:00:00Z")!),
                     TimeMark(id: "b", jobID: "b", mark: .succeeded, start: ApiDate.parse("2026-10-30T08:00:00Z")!)]
        XCTAssertEqual(strip.marks(marks).map(\.id), ["b"], "19:00 is past the end")
    }

    func testTheMonthStartsOnMondayAndFillsWholeWeeks() {
        let days = MonthGrid.days(of: testNow, calendar: utcCalendar)
        XCTAssertEqual(days.count, 35)
        XCTAssertEqual(days.first?.number, 28, "Monday 28 September")
        XCTAssertTrue(days.first!.outside)
        XCTAssertEqual(days[3].number, 1, "1 October 2026 is a Thursday")
        XCTAssertFalse(days[3].outside)
        XCTAssertEqual(days.last?.number, 1, "Sunday 1 November")
        let marks = [TimeMark(id: "1", jobID: "a", mark: .succeeded, start: testNow),
                     TimeMark(id: "2", jobID: "a", mark: .failed, start: testNow),
                     TimeMark(id: "3", jobID: "a", mark: .planned, start: testNow)]
        XCTAssertEqual(MonthGrid.summary(marks), "2 runs, 1 failed, 1 planned")
        XCTAssertEqual(MonthGrid.counts(marks).map(\.mark), [.succeeded, .failed, .planned])
    }

    func testOverlappingBlocksShareTheColumnAndShortRunsGetAMinimumHeight() {
        let day = ApiDate.parse("2026-10-30T00:00:00Z")!
        func mark(_ start: String, _ end: String?) -> TimeMark {
            TimeMark(id: start, jobID: "a", mark: .succeeded, start: ApiDate.parse(start)!, end: end.flatMap(ApiDate.parse))
        }
        let blocks = WeekLayout.blocks([mark("2026-10-30T08:00:00Z", "2026-10-30T08:05:00Z"),
                                        mark("2026-10-30T08:20:00Z", "2026-10-30T09:00:00Z"),
                                        mark("2026-10-30T12:00:00Z", "2026-10-30T13:30:00Z")], day: day)
        XCTAssertEqual(blocks[0].top, 480)
        XCTAssertEqual(blocks[0].bottom, 520, "5 minutes, shown as 40")
        XCTAssertEqual(blocks[0].columns, 2)
        XCTAssertEqual(blocks[1].column, 1)
        XCTAssertEqual(blocks[2].columns, 1)
        XCTAssertEqual(blocks[2].bottom, 810)
    }
}

final class SchedulePresetTests: XCTestCase {
    func testEachButtonKeepsTheTimeOfDay() {
        let now = testNow
        XCTAssertEqual(SchedulePreset.everyDay.schedule(from: "30 8 * * mon-fri", now: now), "30 8 * * *")
        XCTAssertEqual(SchedulePreset.weekdays.schedule(from: "0 2 * * *", now: now), "0 2 * * mon-fri")
        XCTAssertEqual(SchedulePreset.everyWeek.schedule(from: "0 9 * * wed", now: now), "0 9 * * wed")
        XCTAssertEqual(SchedulePreset.everyWeek.schedule(from: "0 9 * * *", now: now), "0 9 * * mon")
        XCTAssertEqual(SchedulePreset.everyHour.schedule(from: "15 9 * * *", now: now), "15 * * * *")
        XCTAssertEqual(SchedulePreset.once.schedule(from: "0 9 * * *", now: now, calendar: utcCalendar), "@at 2026-10-31 09:00")
        XCTAssertEqual(SchedulePreset.in20Minutes.schedule(from: "", now: now), "@in 20m")
        XCTAssertEqual(SchedulePreset.everyDay.schedule(from: "*/30 * * * *", now: now), "0 9 * * *", "no fixed time: 09:00")
    }

    func testTheButtonOfASchedule() {
        XCTAssertEqual(SchedulePreset.matching("0 9 * * *"), .everyDay)
        XCTAssertEqual(SchedulePreset.matching("0 9 * * mon-fri"), .weekdays)
        XCTAssertEqual(SchedulePreset.matching("0 9 * * 3"), .everyWeek)
        XCTAssertEqual(SchedulePreset.matching("0 * * * *"), .everyHour)
        XCTAssertEqual(SchedulePreset.matching("@at 2026-11-05 09:00"), .once)
        XCTAssertNil(SchedulePreset.matching("0 8-18/2 * * mon-fri"))
        XCTAssertNil(SchedulePreset.matching("@daily"))
    }
}

final class JobIconDraftTests: XCTestCase {
    private let flag = #"<svg viewBox="0 0 16 16"><path d="M0 0h9"/></svg>"#

    func testUseDefaultRemovesASavedIconAndANewJobSendsNone() throws {
        var saved = Job(id: "flag", schedule: "@daily", kind: .shell, command: "true", dir: "/tmp", icon: flag, iconColors: true)
        var draft = JobDraft(job: saved)
        XCTAssertEqual(try draft.job().get(), saved, "unchanged")
        draft.icon = ""
        let cleared = try draft.job().get()
        XCTAssertEqual(cleared.icon, "", "\"\" removes it; nil would keep it")
        XCTAssertFalse(cleared.iconColors, "no icon, no colors")

        saved.icon = nil
        saved.iconColors = false
        XCTAssertNil(try JobDraft(job: saved).job().get().icon, "it had none: none is sent")
        var new = JobDraft(home: URL(fileURLWithPath: "/tmp"))
        new.id = "x"
        new.prompt = "Do it"
        XCTAssertNil(try new.job().get().icon)
        new.icon = flag
        XCTAssertEqual(try new.job().get().icon, flag)
    }
}
