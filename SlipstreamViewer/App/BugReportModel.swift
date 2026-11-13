import Dependencies
import Foundation

@MainActor
@Observable
final class BugReportModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.appLog) var appLog
  @ObservationIgnored @Dependency(\.date.now) var now
  @ObservationIgnored @Dependency(\.logFiles) var logFiles
  @ObservationIgnored @Dependency(\.pasteboard) var pasteboard

  // MARK: - Initialization

  /// `version` is the app's version and build, for example `0.4.20 (24)`.
  init(version: String) {
    self.version = version
    super.init()
  }

  // MARK: - Properties

  private let version: String

  // MARK: - User Actions

  func copyLogsTapped() {
    appLog.drain()
    let header = "Slipstream \(version), logs copied \(now.formatted(.iso8601))\n"
    let sections = LogFile.allCases.map { file in
      let text: String
      do {
        text = try logFiles.tail(file)
      } catch {
        text = "Couldn't read \(file.name): \(error)\n"
      }
      return "== \(file.name) (last \(LogFilesClient.tailBytes / 1024) KB) ==\n\(text)"
    }
    pasteboard.copy(([header] + sections).joined(separator: "\n"))
  }
}
