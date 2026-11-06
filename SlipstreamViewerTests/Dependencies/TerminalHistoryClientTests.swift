import CustomDump
import Foundation
import SlipstreamCore
import Testing
@testable import SlipstreamViewer

@Suite(.serialized)
struct TerminalHistoryClientTests {
  private let smallCompaction = HistoryCompaction(
    triggerLines: 5, triggerBytes: 1_000_000, keepLines: 2, keepBytes: 1_000_000)

  private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
  }

  private func line(_ text: String) -> [UInt8] {
    Array("\(text)\n".utf8)
  }

  private func logFile(_ tab: UUID, in directory: URL) -> URL {
    directory.appending(component: "\(tab.uuidString).log")
  }

  @Test func appendThenReadReturnsBytesInOrder() async {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = TerminalHistoryClient.live(directory: directory)
    let tab = UUID()

    for number in 0..<100 { client.append(tab, line("\(number)")) }

    let saved = await client.read(tab)

    expectNoDifference(saved, (0..<100).flatMap { line("\($0)") })
  }

  @Test func compactsWhenOverTrigger() async {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = TerminalHistoryClient.live(directory: directory, compaction: smallCompaction)
    let tab = UUID()

    for number in 1...5 { client.append(tab, line("\(number)")) }
    await client.flush(tab)
    let saved = await client.read(tab)
    expectNoDifference(saved, line("4") + line("5"))

    client.append(tab, line("6"))
    let afterSixth = await client.read(tab)
    expectNoDifference(afterSixth, line("4") + line("5") + line("6"))
  }

  @Test func appendAfterFlushReopensTheLog() async {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = TerminalHistoryClient.live(directory: directory, compaction: smallCompaction)
    let tab = UUID()

    for number in 1...3 { client.append(tab, line("\(number)")) }
    await client.flush(tab)
    for number in 4...5 { client.append(tab, line("\(number)")) }

    let saved = await client.read(tab)

    expectNoDifference(saved, line("4") + line("5"))
  }

  @Test func compactsAnExistingLogOnFirstAppend() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tab = UUID()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data((1...5).flatMap { line("\($0)") }).write(to: logFile(tab, in: directory))
    let client = TerminalHistoryClient.live(directory: directory, compaction: smallCompaction)

    client.append(tab, line("6"))

    let saved = await client.read(tab)

    expectNoDifference(saved, line("5") + line("6"))
  }

  @Test func deleteAfterPendingAppendsLeavesNoFile() async {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = TerminalHistoryClient.live(directory: directory)
    let tab = UUID()

    client.append(tab, line("hello"))
    await client.delete(tab)

    #expect(!FileManager.default.fileExists(atPath: logFile(tab, in: directory).path))
    let saved = await client.read(tab)
    expectNoDifference(saved, [])
  }

  @Test func appendAfterDeleteDoesNotRecreate() async {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = TerminalHistoryClient.live(directory: directory)
    let tab = UUID()

    client.append(tab, line("hello"))
    await client.delete(tab)
    client.append(tab, line("late"))
    await client.flush(tab)

    #expect(!FileManager.default.fileExists(atPath: logFile(tab, in: directory).path))
  }

  @Test func writeErrorStopsSavingForThatTabOnly() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let brokenTab = UUID()
    let healthyTab = UUID()
    try FileManager.default.createDirectory(
      at: logFile(brokenTab, in: directory), withIntermediateDirectories: true)
    let client = TerminalHistoryClient.live(directory: directory)

    // The writer reports on its own queue, outside this test's task, so the issue can't be
    // attributed to the test and `withKnownIssue` never sees it.
    await withKnownIssue(isIntermittent: true) {
      client.append(brokenTab, line("lost"))
      client.append(brokenTab, line("also lost"))
      await client.flush(brokenTab)
    }
    client.append(healthyTab, line("kept"))

    let saved = await client.read(healthyTab)

    expectNoDifference(saved, line("kept"))
  }

  @Test func noTempFileLeftAfterCompaction() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = TerminalHistoryClient.live(directory: directory, compaction: smallCompaction)
    let tab = UUID()

    for number in 1...5 { client.append(tab, line("\(number)")) }
    await client.flush(tab)

    expectNoDifference(
      try FileManager.default.contentsOfDirectory(atPath: directory.path),
      ["\(tab.uuidString).log"])
  }
}
