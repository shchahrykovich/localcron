// Every file in api/examples decodes into its Swift type. Replies, which the
// daemon wrote, also encode back to the same JSON.

import Foundation
import XCTest
@testable import LocalCronKit

final class ApiContractTests: XCTestCase {
    private var examples: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LocalCronKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // menubar
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repo
            .appendingPathComponent("api/examples")
    }

    private static let methods = [
        "hello", "status", "list_jobs", "get_job", "set_job", "remove_job", "set_job_enabled", "run_job",
        "cancel_run", "list_runs", "get_run_log", "preview_schedule", "get_config", "set_config",
        "list_secrets", "set_secret", "remove_secret",
    ]

    /// `set_job_shell` → `set_job`, `run_job_second` → `run_job`,
    /// `get_job_error` → `get_job`.
    private func method(of name: String) -> String? {
        Self.methods.filter { name == $0 || name.hasPrefix($0 + "_") }.max(by: { $0.count < $1.count })
    }

    /// Decode; for replies also encode again and compare with the file.
    private func check<T: Codable & Equatable>(_ type: T.Type, _ json: Any, _ file: String, exact: Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        let value: T
        do {
            value = try Api.decoder.decode(T.self, from: data)
        } catch {
            XCTFail("\(file): \(error)")
            return
        }
        let encoded = try Api.encoder.encode(value)
        XCTAssertEqual(try Api.decoder.decode(T.self, from: encoded), value, "\(file): decode after encode differs")
        if exact {
            let back = try JSONSerialization.jsonObject(with: encoded)
            XCTAssertEqual(json as? NSObject, back as? NSObject, "\(file): round trip differs")
        }
    }

    private func params(_ method: String, _ json: Any, _ file: String) throws {
        switch method {
        case "hello": try check(HelloParams.self, json, file, exact: true)
        case "get_job", "remove_job", "run_job": try check(IdParams.self, json, file, exact: true)
        case "set_job": try check(SetJobParams.self, json, file, exact: false)
        case "set_job_enabled": try check(SetJobEnabledParams.self, json, file, exact: true)
        case "cancel_run": try check(CancelRunParams.self, json, file, exact: true)
        case "list_runs": try check(ListRunsParams.self, json, file, exact: true)
        case "get_run_log": try check(GetRunLogParams.self, json, file, exact: true)
        case "preview_schedule": try check(PreviewScheduleParams.self, json, file, exact: true)
        case "set_config": try check(SetConfigParams.self, json, file, exact: true)
        case "status", "list_jobs", "get_config", "list_secrets": try check(Empty.self, json, file, exact: true)
        case "set_secret": try check(SetSecretParams.self, json, file, exact: true)
        case "remove_secret": try check(NameParams.self, json, file, exact: true)
        default: XCTFail("\(file): no params type for \(method)")
        }
    }

    private func result(_ method: String, _ json: Any, _ file: String) throws {
        switch method {
        case "hello": try check(HelloResult.self, json, file, exact: true)
        case "status": try check(StatusResult.self, json, file, exact: true)
        case "list_jobs": try check(ListJobsResult.self, json, file, exact: true)
        case "get_job", "set_job_enabled": try check(JobResult.self, json, file, exact: true)
        case "set_job": try check(SetJobResult.self, json, file, exact: true)
        case "remove_job": try check(RemoveJobResult.self, json, file, exact: true)
        case "run_job": try check(RunResult.self, json, file, exact: true)
        case "cancel_run": try check(CancelRunResult.self, json, file, exact: true)
        case "list_runs": try check(ListRunsResult.self, json, file, exact: true)
        case "get_run_log": try check(GetRunLogResult.self, json, file, exact: true)
        case "preview_schedule": try check(PreviewScheduleResult.self, json, file, exact: true)
        case "get_config", "set_config": try check(Config.self, json, file, exact: true)
        case "list_secrets": try check(ListSecretsResult.self, json, file, exact: true)
        case "set_secret": try check(SetSecretResult.self, json, file, exact: true)
        case "remove_secret": try check(RemoveSecretResult.self, json, file, exact: true)
        default: XCTFail("\(file): no result type for \(method)")
        }
    }

    func testEveryExampleDecodes() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: examples.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertGreaterThan(files.count, 20, "examples missing at \(examples.path)")
        var seen = Set<String>()
        for file in files {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: examples.appendingPathComponent(file)))
            guard let dict = object as? [String: Any] else { XCTFail("\(file): not an object"); continue }
            let name = file.replacingOccurrences(of: ".request.json", with: "").replacingOccurrences(of: ".reply.json", with: "")
            if let error = dict["error"] {
                // `error.reply.json` and `<method>_error.reply.json`.
                try check(ApiError.self, error, file, exact: true)
                continue
            }
            if name == "error" {
                // The request that caused error.reply.json.
                XCTAssertNotNil(dict["method"], file)
                continue
            }
            guard let method = method(of: name) else {
                XCTFail("\(file): no method \(name) in the Swift list")
                continue
            }
            seen.insert(method)
            if file.hasSuffix(".request.json") {
                XCTAssertEqual(dict["method"] as? String, method, file)
                try params(method, dict["params"] ?? [:], file)
            } else {
                guard let r = dict["result"] else { XCTFail("\(file): no result"); continue }
                try result(method, r, file)
            }
        }
        XCTAssertEqual(seen, Set(Self.methods), "every method needs an example")
    }

    func testDatesWithAndWithoutFractions() {
        XCTAssertEqual(ApiDate.parse("2026-10-28T11:02:55Z")?.timeIntervalSince1970, 1_793_185_375)
        XCTAssertEqual(ApiDate.parse("2026-10-28T12:02:55+01:00")?.timeIntervalSince1970, 1_793_185_375)
        XCTAssertEqual(ApiDate.parse("2026-10-28T11:02:55.5Z")?.timeIntervalSince1970, 1_793_185_375.5)
        XCTAssertNil(ApiDate.parse("yesterday"))
    }

    func testEnvKeysAreNotChanged() throws {
        let json = #"{"id":"a","schedule":"@daily","kind":"shell","command":"ls","dir":"/tmp","env":{"REVIEW_LIMIT":"10"}}"#
        let job = try Api.decoder.decode(Job.self, from: Data(json.utf8))
        XCTAssertEqual(job.env, ["REVIEW_LIMIT": "10"])
        XCTAssertTrue(job.enabled && job.catchUp)
        XCTAssertEqual(job.timeoutSecs, 3600)
        let text = String(decoding: try Api.encoder.encode(job), as: UTF8.self)
        XCTAssertTrue(text.contains("\"REVIEW_LIMIT\""), text)
        XCTAssertFalse(text.contains("\"args\""), text)
    }

    func testPrintingSetSecretParamsHidesTheValue() {
        let p = SetSecretParams(name: "github-token", value: "ghp_secret", description: "x")
        XCTAssertFalse("\(p)".contains("ghp_secret"))
        XCTAssertTrue("\(p)".contains("<hidden>"))
    }
}
