import Dependencies
import Foundation
import SlipstreamCore
import Synchronization

struct AskForkRequest: Equatable, Sendable {
  let parentSessionID: UUID
  let folder: String
  let environment: AgentEnvironment
  let model: String
  let effort: ChatEffort
  let prompt: String
  let kind: AskForkKind
}

/// Runs a one-shot, read-only copy of a chat and returns its reply. The copy is never saved, so
/// the chat it was copied from is left exactly as it was.
struct AskForkClient: Sendable {
  var run: @Sendable (AskForkRequest) async throws(AskForkError) -> AskForkResult
}

extension AskForkClient: DependencyKey {
  static let timeLimit = Duration.seconds(120)

  static var liveValue: Self {
    Self(run: { request throws(AskForkError) in
      @Dependency(\.agentProcess) var agentProcess
      @Dependency(\.continuousClock) var clock

      let schema: String
      switch request.kind {
      case .answer(let allowsChangeRequests):
        schema = AskPrompt.answerSchema(allowsChangeRequests: allowsChangeRequests)
      case .report:
        schema = AskPrompt.reportSchema
      }
      let credentials = try userCredentials(request.environment.configDirectory)
      let handle: AgentProcessHandle
      do {
        handle = try await agentProcess.launch(
          AgentLaunch(
            executable: request.environment.claudePath,
            arguments: ClaudeInvocation.forkArguments(
              parentSessionID: request.parentSessionID, model: request.model,
              effort: request.effort.rawValue, schema: schema, settings: credentials.settings),
            environment: request.environment.variables.merging(credentials.environment) { $1 },
            directory: request.folder
          )
        )
      } catch {
        throw .unavailable(DiagnosticText.line("Claude Code couldn't start: \(reason(error))"))
      }

      let lastAPIError = LastAPIError()
      let outcome = await withTaskGroup(of: Result<AskForkResult, AskForkError>.self) { group in
        group.addTask { await converse(handle, request, lastAPIError) }
        group.addTask { [clock] in
          do {
            try await clock.sleep(for: timeLimit)
            return .failure(lastAPIError.timedOut)
          } catch {
            return .failure(.unavailable(cancelledDetail))
          }
        }
        let first = await group.next() ?? .failure(.unavailable(cancelledDetail))
        // Before the group waits for the other task: a prompt write blocked on a full pipe only
        // returns once the process is gone.
        await handle.shutdown()
        group.cancelAll()
        return first
      }
      // Cancelling also ends the event stream, so the reader can win the race with a misleading reason.
      if Task.isCancelled { throw .unavailable(cancelledDetail) }
      return try outcome.get()
    })
  }

  static var testValue: Self {
    Self(run: unimplemented("AskForkClient.run", placeholder: .answer(forkSessionID: "", reply: "", isChangeRequest: false)))
  }

  /// `--restricted` keeps the copy from reading the user's settings file, which is where gateway
  /// and helper-based sign-ins live.
  private static func userCredentials(_ configDirectory: URL) throws(AskForkError) -> ForkCredentials {
    let file = configDirectory.appending(path: "settings.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return .none }
    do {
      return try ForkCredentials(userSettings: try Data(contentsOf: file))
    } catch let error as ForkCredentialsError {
      throw .unavailable(DiagnosticText.line("Claude Code's settings file \(file.path) couldn't be used: \(error.reason)."))
    } catch {
      throw .unavailable(DiagnosticText.line("Claude Code's settings file \(file.path) couldn't be read: \(error)"))
    }
  }

  private static func converse(
    _ handle: AgentProcessHandle, _ request: AskForkRequest, _ lastAPIError: LastAPIError
  ) async -> Result<AskForkResult, AskForkError> {
    do {
      try await handle.write(Data(request.prompt.utf8))
    } catch {
      return .failure(.unavailable(DiagnosticText.line("The question couldn't be sent to Claude Code: \(reason(error))")))
    }
    await handle.closeInput()
    var output = ForkOutput(kind: request.kind)
    for await event in handle.events {
      switch event {
      case .line(let line):
        do throws(AskForkError) {
          let result = try output.read(line)
          lastAPIError.record(output.lastAPIError)
          if let result { return .success(result) }
        } catch {
          return .failure(error)
        }
      case .overflow:
        return .failure(.badReply("Claude Code's reply was too long to read."))
      case .exited(let status, let stderrTail):
        guard status != 0 else { return .failure(.badReply("Claude Code exited without an answer.")) }
        let exited = "Claude Code exited with status \(status)"
        let summary = stderrSummary(stderrTail, limit: DiagnosticText.limit - exited.count - 2)
        return .failure(.unavailable(exited + (summary.isEmpty ? "." : ": \(summary)")))
      }
    }
    return .failure(.unavailable("Claude Code stopped unexpectedly."))
  }

  static func stderrSummary(_ tail: String, limit: Int = DiagnosticText.limit) -> String {
    let lines = tail.components(separatedBy: .newlines).map(DiagnosticText.unwrapped).filter { !$0.isEmpty }
    let summary = lines.suffix(3).joined(separator: " · ")
    return summary.count > limit ? "…" + summary.suffix(limit - 1) : summary
  }

  private static let cancelledDetail = "The question was cancelled."

  private static func reason(_ error: any Error) -> String {
    switch error {
    case let error as AgentProcessError:
      error.message
    default:
      error.localizedDescription
    }
  }
}

private final class LastAPIError: Sendable {
  private let value = Mutex<String?>(nil)

  func record(_ error: String?) {
    value.withLock { $0 = error }
  }

  var timedOut: AskForkError {
    guard let error = value.withLock({ $0 }) else { return .timedOut }
    return .unavailable(
      DiagnosticText.line("Claude Code didn't answer within 120 seconds. Its last API call failed: \(error)."))
  }
}

extension DependencyValues {
  var askFork: AskForkClient {
    get { self[AskForkClient.self] }
    set { self[AskForkClient.self] = newValue }
  }
}
