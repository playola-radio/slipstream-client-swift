import Dependencies
import Foundation
import SlipstreamCore

struct CommandResult: Equatable, Sendable {
  enum Ending: Equatable, Sendable {
    case exit(Int32)
    case timedOut(Duration)
    case launchFailed(String)
  }

  var command: [String]
  var folder: URL
  var ending: Ending
  var stdout: String
  var stderr: String

  var succeeded: Bool { ending == .exit(0) }

  var commandLine: String {
    command.map { $0.wholeMatch(of: /[A-Za-z0-9_@%+=:,.\/-]+/) == nil ? RuntimeInstall.shellQuoted($0) : $0 }
      .joined(separator: " ")
  }
}

/// Runs `git` and `gh` in a workspace folder. `arguments[0]` is the tool, found on the user's
/// login `PATH`.
struct RepoCommandClient: Sendable {
  var run: @Sendable (_ arguments: [String], _ folder: URL, _ timeout: Duration) async -> CommandResult
}

extension RepoCommandClient {
  static func live(loginEnvironment: @escaping @Sendable () async throws -> [String: String]) -> Self {
    Self(run: { arguments, folder, timeout in
      let environment = (try? await loginEnvironment()) ?? ProcessInfo.processInfo.environment
      return await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          continuation.resume(returning: runBlocking(arguments, folder, timeout, environment: environment))
        }
      }
    })
  }

  private static func runBlocking(
    _ arguments: [String], _ folder: URL, _ timeout: Duration, environment: [String: String]
  ) -> CommandResult {
    var result = CommandResult(command: arguments, folder: folder, ending: .exit(0), stdout: "", stderr: "")
    do {
      let capture = try AgentEnvironmentClient.runBlocking(
        "/usr/bin/env", arguments, environment: environment, directory: folder, capturesStandardError: true,
        timeout: timeout / .seconds(1))
      result.stdout = String(decoding: capture.standardOutput, as: UTF8.self)
      result.stderr = String(decoding: capture.standardError, as: UTF8.self)
      result.ending = capture.didTimeOut ? .timedOut(timeout) : .exit(capture.status)
    } catch {
      result.ending = .launchFailed(error.localizedDescription)
    }
    return result
  }
}

extension RepoCommandClient: DependencyKey {
  static var liveValue: Self {
    live(loginEnvironment: AgentEnvironmentClient.loginEnvironment)
  }

  static var testValue: Self {
    Self(run: unimplemented("RepoCommandClient.run", placeholder: CommandResult(
      command: [], folder: URL(fileURLWithPath: "/"), ending: .launchFailed("unimplemented"), stdout: "", stderr: "")))
  }
}

extension DependencyValues {
  var repoCommand: RepoCommandClient {
    get { self[RepoCommandClient.self] }
    set { self[RepoCommandClient.self] = newValue }
  }
}
