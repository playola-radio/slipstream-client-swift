import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@testable import SlipstreamViewer

@MainActor
struct BugReportModelTests {
  let copied = LockIsolated<[String]>([])
  let drained = LockIsolated(false)

  func makeModel(tail: @escaping @Sendable (LogFile) throws -> String) -> BugReportModel {
    withDependencies {
      $0.appLog.drain = { [drained] in drained.setValue(true) }
      $0.date.now = Date(timeIntervalSince1970: 1_794_530_850)
      $0.logFiles.tail = tail
      $0.pasteboard.copy = { [copied] text in copied.withValue { $0.append(text) } }
    } operation: {
      BugReportModel(version: "0.4.20 (24)")
    }
  }

  @Test func copyLogsCopiesTheVersionAndTheEndOfEachLog() {
    let model = makeModel { file in
      switch file {
      case .app: "app line 1\napp line 2\n"
      case .daemon: "daemon line\n"
      }
    }

    model.copyLogsTapped()

    expectNoDifference(
      copied.value,
      [
        """
        Slipstream 0.4.20 (24), logs copied 2026-11-13T00:47:30Z

        == \(LogFile.app.name) (last 64 KB) ==
        app line 1
        app line 2

        == daemon.log (last 64 KB) ==
        daemon line

        """
      ])
  }

  @Test func copyLogsWritesQueuedAppLogLinesFirst() {
    let model = makeModel { _ in "" }

    model.copyLogsTapped()

    expectNoDifference(drained.value, true)
  }

  @Test func aLogThatCannotBeReadSaysWhy() {
    let model = makeModel { file in
      switch file {
      case .app: "app line\n"
      case .daemon: throw RecorderServiceError(description: "daemon.log: no such file")
      }
    }

    model.copyLogsTapped()

    expectNoDifference(
      copied.value.first?.components(separatedBy: "== daemon.log (last 64 KB) ==\n").last,
      "Couldn't read daemon.log: daemon.log: no such file\n")
  }
}
