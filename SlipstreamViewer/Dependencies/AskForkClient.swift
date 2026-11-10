import Dependencies
import Foundation
import SlipstreamCore

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
      let handle: AgentProcessHandle
      do {
        handle = try await agentProcess.launch(
          AgentLaunch(
            executable: request.environment.claudePath,
            arguments: ClaudeInvocation.forkArguments(
              parentSessionID: request.parentSessionID, model: request.model,
              effort: request.effort.rawValue, schema: schema),
            environment: request.environment.variables,
            directory: request.folder
          )
        )
      } catch {
        throw .unavailable("Claude Code couldn't start: \(reason(error))")
      }

      let outcome = await withTaskGroup(of: Result<AskForkResult, AskForkError>.self) { group in
        group.addTask { await converse(handle, request) }
        group.addTask { [clock] in
          do {
            try await clock.sleep(for: timeLimit)
            return .failure(.timedOut)
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

  private static func converse(
    _ handle: AgentProcessHandle, _ request: AskForkRequest
  ) async -> Result<AskForkResult, AskForkError> {
    do {
      try await handle.write(Data(request.prompt.utf8))
    } catch {
      return .failure(.unavailable("The question couldn't be sent to Claude Code: \(reason(error))"))
    }
    await handle.closeInput()
    var output = ForkOutput(kind: request.kind)
    for await event in handle.events {
      switch event {
      case .line(let line):
        do throws(AskForkError) {
          if let result = try output.read(line) { return .success(result) }
        } catch {
          return .failure(error)
        }
      case .overflow:
        return .failure(.badReply("Claude Code's reply was too long to read."))
      case .exited(let status, let stderrTail):
        guard status != 0 else { return .failure(.badReply("Claude Code exited without an answer.")) }
        let summary = stderrSummary(stderrTail)
        return .failure(.unavailable("Claude Code exited with status \(status)" + (summary.isEmpty ? "." : ": \(summary)")))
      }
    }
    return .failure(.unavailable("Claude Code stopped unexpectedly."))
  }

  static func stderrSummary(_ tail: String) -> String {
    let lines = tail.components(separatedBy: .newlines).map(DiagnosticText.unwrapped).filter { !$0.isEmpty }
    let summary = lines.suffix(3).joined(separator: " · ")
    return summary.count > DiagnosticText.limit ? "…" + summary.suffix(DiagnosticText.limit - 1) : summary
  }

  private static let cancelledDetail = "The question was cancelled."

  private static func reason(_ error: any Error) -> String {
    switch error {
    case AgentProcessError.launchFailed(let code), AgentProcessError.writeFailed(let code):
      String(cString: strerror(code))
    default:
      error.localizedDescription
    }
  }
}

extension DependencyValues {
  var askFork: AskForkClient {
    get { self[AskForkClient.self] }
    set { self[AskForkClient.self] = newValue }
  }
}
