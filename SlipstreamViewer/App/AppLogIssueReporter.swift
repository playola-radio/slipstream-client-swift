import Dependencies
import IssueReporting

struct AppLogIssueReporter: IssueReporter {
  func reportIssue(
    _ message: @autoclosure () -> String?,
    severity: IssueSeverity,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) {
    @Dependency(\.appLog) var log
    log.error("issue", "\(fileID):\(line) \(message() ?? "Issue reported")")
  }
}
