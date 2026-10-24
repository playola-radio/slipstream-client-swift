import Dependencies
import Foundation
import SlipstreamCore

/// Links a chat tab to its workspace's stream. Each closure is one whole operation (re-read the
/// binding, check it, unlink, attach), and no two operations in the app interleave.
struct ChatLinkClient: Sendable {
  /// `replacing` is the generation the caller saw; `nil` links only while nothing is linked.
  var link: @Sendable (_ folder: String, _ tabID: UUID, _ replacing: String?) async -> LinkOutcome
  var unlink: @Sendable (_ folder: String, _ replacing: String) async -> LinkOutcome
}

extension ChatLinkClient: DependencyKey {
  static var liveValue: Self {
    @Dependency(\.daemon) var daemon
    @Dependency(\.agentEnvironment) var agentEnvironment
    let operations = ChatLinkOperations(
      store: daemon.storeID,
      environment: { try await agentEnvironment.resolve() },
      captures: { try await daemon.listCaptures(daemon.discover())?.captures ?? [] },
      run: { arguments, environment in
        guard let slipstream = WorkspaceClient.slipstreamExecutable(in: environment) else {
          throw SlipstreamNotFound()
        }
        let (output, status) = try await WorkspaceClient.runInBackground(
          slipstream, arguments, environment: environment)
        return (status, output)
      }
    )
    return Self(
      link: { await operations.link(folder: $0, tabID: $1, replacing: $2) },
      unlink: { await operations.unlink(folder: $0, replacing: $1) }
    )
  }

  static var testValue: Self {
    Self(
      link: unimplemented("ChatLinkClient.link", placeholder: .skipped),
      unlink: unimplemented("ChatLinkClient.unlink", placeholder: .skipped)
    )
  }
}

extension DependencyValues {
  var chatLink: ChatLinkClient {
    get { self[ChatLinkClient.self] }
    set { self[ChatLinkClient.self] = newValue }
  }
}

private struct SlipstreamNotFound: LocalizedError {
  var errorDescription: String? { WorkspaceClient.slipstreamNotFoundText }
}

actor ChatLinkOperations {
  typealias Run = @Sendable (_ arguments: [String], _ environment: [String: String]) async throws -> (
    status: Int32, output: String
  )

  private let store: String
  private let environment: @Sendable () async throws -> AgentEnvironment
  private let captures: @Sendable () async throws -> [CaptureSummary]
  private let run: Run
  private var previous: Task<Void, Never>?

  init(
    store: String,
    environment: @escaping @Sendable () async throws -> AgentEnvironment,
    captures: @escaping @Sendable () async throws -> [CaptureSummary],
    run: @escaping Run
  ) {
    self.store = store
    self.environment = environment
    self.captures = captures
    self.run = run
  }

  func link(folder: String, tabID: UUID, replacing: String?) async -> LinkOutcome {
    await oneAtATime { [self] in await performLink(folder: folder, tabID: tabID, replacing: replacing) }
  }

  func unlink(folder: String, replacing: String) async -> LinkOutcome {
    await oneAtATime { [self] in await performUnlink(folder: folder, replacing: replacing) }
  }

  /// An actor lets another call in at every `await`, so each operation waits for the one before.
  private func oneAtATime(_ operation: @escaping @Sendable () async -> LinkOutcome) async -> LinkOutcome {
    let waitFor = previous
    let current = Task {
      await waitFor?.value
      return await operation()
    }
    previous = Task { _ = await current.value }
    return await current.value
  }

  private nonisolated func performLink(folder: String, tabID: UUID, replacing: String?) async -> LinkOutcome {
    do {
      let capture = try await capture(in: folder)
      if let replacing {
        guard let capture, let binding = capture.binding, binding.generation == replacing else { return .skipped }
        if binding.isLive {
          let unlinked = try await unlink(capture)
          guard unlinked == .unlinked else { return unlinked }
        } else if binding.state != .unlinked {
          return .skipped
        }
      } else if let binding = capture?.binding, binding.state != .unlinked {
        return .skipped
      }
      return try await attach(folder: folder, tabID: tabID)
    } catch {
      return .refused(.other(Self.message(for: error)))
    }
  }

  private nonisolated func performUnlink(folder: String, replacing: String) async -> LinkOutcome {
    do {
      guard let capture = try await capture(in: folder), let binding = capture.binding,
        binding.generation == replacing, binding.isLive
      else { return .skipped }
      return try await unlink(capture)
    } catch {
      return .refused(.other(Self.message(for: error)))
    }
  }

  private nonisolated func capture(in folder: String) async throws -> CaptureSummary? {
    try await captures().first { ChangeStreamPageModel.normalizedFolder($0.root) == folder }
  }

  private nonisolated func unlink(_ capture: CaptureSummary) async throws -> LinkOutcome {
    let variables = try await environment().variables
    let result = try await run(["unlink", "--session", capture.sessionID, "--store", store], variables)
    return LinkOutcome.unlink(exitCode: result.status, output: result.output)
  }

  private nonisolated func attach(folder: String, tabID: UUID) async throws -> LinkOutcome {
    let agent = try await environment()
    var variables = agent.variables
    variables["CODEX_THREAD_ID"] = nil
    variables["CONDUCTOR_SESSION_ID"] = nil
    variables["CLAUDE_CODE_SESSION_ID"] = tabID.uuidString.lowercased()
    variables["CLAUDE_CODE_EXECPATH"] = agent.claudePath
    let result = try await run(["attach", folder, "--store", store], variables)
    return LinkOutcome.attach(exitCode: result.status, output: result.output)
  }

  private static func message(for error: any Error) -> String {
    (error as? AgentEnvironmentError)?.message ?? error.localizedDescription
  }
}
