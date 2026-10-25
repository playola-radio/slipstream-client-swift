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
        throw .unavailable
      }

      let outcome = await withTaskGroup(of: Result<AskForkResult, AskForkError>.self) { group in
        group.addTask { await converse(handle, request) }
        group.addTask { [clock] in
          do {
            try await clock.sleep(for: timeLimit)
            return .failure(.timedOut)
          } catch {
            return .failure(.unavailable)
          }
        }
        let first = await group.next() ?? .failure(.unavailable)
        group.cancelAll()
        return first
      }
      await handle.shutdown()
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
      return .failure(.unavailable)
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
        return .failure(.badReply)
      case .exited(let status, _):
        return .failure(status == 0 ? .badReply : .unavailable)
      }
    }
    return .failure(.unavailable)
  }
}

extension DependencyValues {
  var askFork: AskForkClient {
    get { self[AskForkClient.self] }
    set { self[AskForkClient.self] = newValue }
  }
}
