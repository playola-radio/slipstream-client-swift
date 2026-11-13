import CustomDump
import Foundation
import Testing

@testable import SlipstreamViewer

struct LogFilesClientTests {
  let folder = FileManager.default.temporaryDirectory.appending(path: "log-files-\(UUID().uuidString)")
  var log: URL { folder.appending(path: "app.log") }
  var rotated: URL { folder.appending(path: "app.log.1") }

  func client(tailBytes: UInt64) throws -> LogFilesClient {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return LogFilesClient.live(url: { [log] _ in log }, tailBytes: tailBytes)
  }

  @Test func aShortLogIsCopiedWhole() throws {
    let logFiles = try client(tailBytes: 64)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "one\ntwo\n".write(to: log, atomically: true, encoding: .utf8)

    expectNoDifference(try logFiles.tail(.app), "one\ntwo\n")
  }

  @Test func aLogExactlyTheBudgetIsCopiedWhole() throws {
    let logFiles = try client(tailBytes: 8)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "one\ntwo\n".write(to: log, atomically: true, encoding: .utf8)

    expectNoDifference(try logFiles.tail(.app), "one\ntwo\n")
  }

  @Test func aLongLogStartsOnTheFirstWholeLineInsideTheBudget() throws {
    let logFiles = try client(tailBytes: 12)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "first line\nsecond\nthird\n".write(to: log, atomically: true, encoding: .utf8)

    expectNoDifference(try logFiles.tail(.app), "third\n")
  }

  @Test func aLineLongerThanTheBudgetKeepsItsEnd() throws {
    let logFiles = try client(tailBytes: 8)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "a very long line\n".write(to: log, atomically: true, encoding: .utf8)

    expectNoDifference(try logFiles.tail(.app), "ng line\n")
  }

  @Test func aJustRotatedLogIsFilledFromTheRotatedFile() throws {
    let logFiles = try client(tailBytes: 16)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "old one\nold two\n".write(to: rotated, atomically: true, encoding: .utf8)
    try "new\n".write(to: log, atomically: true, encoding: .utf8)

    expectNoDifference(try logFiles.tail(.app), "old two\nnew\n")
  }

  @Test func aRotatedAndNewLogThatFillTheBudgetExactlyAreCopiedWhole() throws {
    let logFiles = try client(tailBytes: 8)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "old\n".write(to: rotated, atomically: true, encoding: .utf8)
    try "new\n".write(to: log, atomically: true, encoding: .utf8)

    expectNoDifference(try logFiles.tail(.app), "old\nnew\n")
  }

  @Test func aRotatedLogWithNoNewFileYetIsStillCopied() throws {
    let logFiles = try client(tailBytes: 64)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "old\n".write(to: rotated, atomically: true, encoding: .utf8)

    expectNoDifference(try logFiles.tail(.app), "old\n")
  }

  @Test func aMissingLogThrows() throws {
    let logFiles = try client(tailBytes: 64)
    defer { try? FileManager.default.removeItem(at: folder) }

    #expect(throws: (any Error).self) { try logFiles.tail(.app) }
  }
}
