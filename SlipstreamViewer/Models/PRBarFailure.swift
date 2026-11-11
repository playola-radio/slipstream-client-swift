import Foundation

/// A failure the PR bar shows in red, with its full Details text.
struct PRBarFailure: Error, Equatable, Sendable {
  var title: String
  var details: String

  init(title: String, details: String) {
    self.title = title
    self.details = details
  }

  /// The folder, command line, how it ended and both outputs in full. Never the environment.
  init(title: String, result: CommandResult, note: String? = nil) {
    let lines = [
      "Folder: \(result.folder.path)",
      "Command: \(result.commandLine)",
      "Ended: \(Self.text(for: result.ending))",
      note,
      "",
      "stdout:",
      result.stdout.isEmpty ? "(empty)" : result.stdout,
      "",
      "stderr:",
      result.stderr.isEmpty ? "(empty)" : result.stderr,
    ]
    self.init(title: title, details: lines.compactMap(\.self).joined(separator: "\n"))
  }

  private static func text(for ending: CommandResult.Ending) -> String {
    switch ending {
    case .exit(let status): "exit status \(status)"
    case .timedOut(let timeout): "timed out after \(timeout.components.seconds) s"
    case .launchFailed(let reason): "couldn't start: \(reason)"
    }
  }
}
