import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@testable import SlipstreamViewer

struct AppLogFileTests {
  func makeURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "app-log-\(UUID().uuidString)")
      .appending(path: "app.log")
  }

  func messages(in url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n")
      .map { String($0.split(separator: " ").last ?? "") }
  }

  @Test func appendsAcrossInstances() throws {
    let url = makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let first = AppLogFile(url: url)
    first.write(.info, category: "app", message: "one")
    first.drain()
    let second = AppLogFile(url: url)
    second.write(.error, category: "app", message: "two")
    second.drain()

    expectNoDifference(try messages(in: url), ["one", "two"])
  }

  @Test func writesTheFormattedLine() throws {
    let url = makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let file = AppLogFile(url: url)
    file.write(.error, category: "daemon", message: "sessions failed")
    file.drain()

    let line = try String(contentsOf: url, encoding: .utf8)
    #expect(line.hasSuffix(" ERROR [daemon] sessions failed\n"))
  }

  @Test func rotatesOnceTheLimitIsExceeded() throws {
    let url = makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let file = AppLogFile(url: url, maxBytes: 100)
    for message in ["m1", "m2", "m3", "m4", "m5"] {
      file.write(.info, category: "app", message: message)
    }
    file.drain()

    expectNoDifference(try messages(in: url.appendingPathExtension("1")), ["m1", "m2", "m3"])
    expectNoDifference(try messages(in: url), ["m4", "m5"])
  }

  @Test func writersReopenAfterAnotherWriterRotates() throws {
    let url = makeURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let first = AppLogFile(url: url, maxBytes: 100)
    let second = AppLogFile(url: url, maxBytes: 100)
    first.write(.info, category: "app", message: "m1")
    first.drain()
    second.write(.info, category: "app", message: "m2")
    second.drain()
    first.write(.info, category: "app", message: "m3")
    first.drain()
    second.write(.info, category: "app", message: "m4")
    second.drain()

    expectNoDifference(try messages(in: url.appendingPathExtension("1")), ["m1", "m2", "m3"])
    expectNoDifference(try messages(in: url), ["m4"])
  }

  @Test func issueReporterUsesTheCurrentAppLogDependency() {
    let logged = LockIsolated<[String]>([])

    withDependencies {
      $0.appLog.write = { _, _, message in logged.withValue { $0.append(message) } }
    } operation: {
      AppLogIssueReporter().reportIssue("reported", severity: .error, fileID: "Test", filePath: "", line: 1, column: 1)
    }

    expectNoDifference(logged.value, ["Test:1 reported"])
  }
}
