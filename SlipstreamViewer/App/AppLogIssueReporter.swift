import IssueReporting

struct AppLogIssueReporter: IssueReporter {
  var log: AppLogClient = .liveValue

  func reportIssue(
    _ message: @autoclosure () -> String?,
    severity: IssueSeverity,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
  ) {
    log.error("issue", "\(fileID):\(line) \(message() ?? "Issue reported")")
  }
}
