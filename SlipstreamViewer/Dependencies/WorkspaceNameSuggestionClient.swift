import Darwin
import Dependencies
import Foundation
import SlipstreamCore

/// Asks Claude Haiku, in a one-shot run that is never saved, for a short name for the work a
/// message describes.
struct WorkspaceNameSuggestionClient: Sendable {
  var suggest: @Sendable (_ message: String, _ environment: AgentEnvironment) async throws -> String
}

extension WorkspaceNameSuggestionClient: DependencyKey {
  static let timeLimit = Duration.seconds(20)

  static var liveValue: Self {
    Self(suggest: { message, environment in
      @Dependency(\.agentProcess) var agentProcess
      @Dependency(\.continuousClock) var clock

      let directory = try makeEmptyDirectory()
      defer { try? FileManager.default.removeItem(atPath: directory) }
      let handle = try await agentProcess.launch(
        AgentLaunch(
          executable: environment.claudePath,
          arguments: ClaudeInvocation.workspaceNameArguments(schema: WorkspaceNameSuggestion.schema),
          environment: environment.variables,
          directory: directory
        )
      )
      let outcome = await withTaskGroup(of: Result<String, WorkspaceNameSuggestionError>.self) { group in
        group.addTask { await converse(handle, message) }
        group.addTask { [clock] in
          do {
            try await clock.sleep(for: timeLimit)
            return .failure(.timedOut)
          } catch {
            return .failure(.unavailable("The name suggestion was cancelled."))
          }
        }
        let first = await group.next() ?? .failure(.unavailable("The name suggestion was cancelled."))
        await handle.shutdown()
        group.cancelAll()
        return first
      }
      if Task.isCancelled { throw CancellationError() }
      return try outcome.get()
    })
  }

  static var testValue: Self {
    Self(suggest: unimplemented("WorkspaceNameSuggestionClient.suggest", placeholder: ""))
  }

  private static func converse(
    _ handle: AgentProcessHandle, _ message: String
  ) async -> Result<String, WorkspaceNameSuggestionError> {
    do {
      try await handle.write(Data(WorkspaceNameSuggestion.prompt(for: message).utf8))
    } catch {
      return .failure(.unavailable("The message couldn't be sent to Claude Code: \(error.localizedDescription)"))
    }
    await handle.closeInput()
    for await event in handle.events {
      switch event {
      case .line(let line):
        do throws(WorkspaceNameSuggestionError) {
          if let name = try WorkspaceNameSuggestion.name(fromLine: line) { return .success(name) }
        } catch {
          return .failure(error)
        }
      case .overflow:
        return .failure(.badReply("Claude Code's reply was too long to read."))
      case .exited(let status, let stderrTail):
        guard status != 0 else { return .failure(.badReply("Claude Code exited without a name.")) }
        let summary = AskForkClient.stderrSummary(stderrTail)
        let exited = "Claude Code exited with status \(status)"
        return .failure(.unavailable(summary.isEmpty ? exited + "." : "\(exited): \(summary)"))
      }
    }
    return .failure(.unavailable("Claude Code stopped unexpectedly."))
  }

  private static func makeEmptyDirectory() throws -> String {
    var template = Array((NSTemporaryDirectory() + "/slipstream-name-XXXXXX").utf8CString)
    guard mkdtemp(&template) != nil else { throw AgentProcessError.launchFailed(errno: errno) }
    return String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

extension DependencyValues {
  var workspaceNameSuggestion: WorkspaceNameSuggestionClient {
    get { self[WorkspaceNameSuggestionClient.self] }
    set { self[WorkspaceNameSuggestionClient.self] = newValue }
  }
}
