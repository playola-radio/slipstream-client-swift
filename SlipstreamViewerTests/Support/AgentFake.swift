import ConcurrencyExtras
import Foundation
import SlipstreamCore
import Synchronization

@testable import SlipstreamViewer

struct TranscriptUnreadable: Error {}
struct WriteFailed: Error {}

final class AgentFake: Sendable {
  static let environment = AgentEnvironment(
    claudePath: "/opt/claude/bin/claude",
    variables: ["PATH": "/opt/claude/bin:/usr/bin"],
    configDirectory: URL(fileURLWithPath: "/fake/claude-config")
  )

  private struct State {
    var environmentError: AgentEnvironmentError?
    var transcripts: [UUID: TranscriptLookup] = [:]
    var unreadable: Set<UUID> = []
    var loads: [UUID] = []
    var launches: [AgentLaunch] = []
    var continuations: [AsyncStream<AgentProcessEvent>.Continuation] = []
    var writes: [[Data]] = []
    var shutdowns: [Int] = []
    var writeError: (any Error)?
    var isHoldingEnvironment = false
    var heldResolves: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  var launches: [AgentLaunch] { state.withLock { $0.launches } }
  var loads: [UUID] { state.withLock { $0.loads } }
  var shutdownCount: Int { state.withLock { $0.shutdowns.reduce(0, +) } }
  /// Decoded, because the encoder orders object keys differently from call to call.
  func writes(_ launch: Int) -> [JSONValue] { state.withLock { $0.writes[launch] }.map(json) }
  func shutdowns(_ launch: Int) -> Int { state.withLock { $0.shutdowns[launch] } }

  func setEnvironmentError(_ error: AgentEnvironmentError?) { state.withLock { $0.environmentError = error } }
  func setTranscript(_ id: UUID, _ lookup: TranscriptLookup) { state.withLock { $0.transcripts[id] = lookup } }
  func setUnreadable(_ id: UUID) { state.withLock { _ = $0.unreadable.insert(id) } }
  func setWriteError(_ error: (any Error)?) { state.withLock { $0.writeError = error } }

  /// Makes environment lookups wait until `releaseEnvironment()`, like a slow login shell.
  func holdEnvironment() { state.withLock { $0.isHoldingEnvironment = true } }

  func releaseEnvironment() {
    let held = state.withLock { state in
      state.isHoldingEnvironment = false
      defer { state.heldResolves = [] }
      return state.heldResolves
    }
    for continuation in held { continuation.resume() }
  }

  /// Sends to the most recent launch unless another is named.
  func send(_ event: AgentProcessEvent, to launch: Int? = nil) {
    state.withLock { $0.continuations[launch ?? $0.continuations.count - 1] }.yield(event)
  }

  func sendLine(_ json: String, to launch: Int? = nil) {
    send(.line(Data(json.utf8)), to: launch)
  }

  func exit(status: Int32 = 1, stderrTail: String = "", launch: Int? = nil) {
    let continuation = state.withLock { $0.continuations[launch ?? $0.continuations.count - 1] }
    continuation.yield(.exited(status: status, stderrTail: stderrTail))
    continuation.finish()
  }

  var environmentClient: AgentEnvironmentClient {
    AgentEnvironmentClient(resolve: {
      await withCheckedContinuation { continuation in
        let isHeld = self.state.withLock { state in
          if state.isHoldingEnvironment { state.heldResolves.append(continuation) }
          return state.isHoldingEnvironment
        }
        if !isHeld { continuation.resume() }
      }
      if let error = self.state.withLock({ $0.environmentError }) { throw error }
      return Self.environment
    })
  }

  var transcriptClient: TranscriptClient {
    TranscriptClient(load: { directory, id in
      precondition(directory == Self.environment.configDirectory)
      return try self.state.withLock { state in
        state.loads.append(id)
        if state.unreadable.contains(id) { throw TranscriptUnreadable() }
        return state.transcripts[id] ?? .notFound
      }
    })
  }

  var processClient: AgentProcessClient {
    AgentProcessClient(launch: { launch in
      let (events, continuation) = AsyncStream<AgentProcessEvent>.makeStream()
      let index = self.state.withLock { state in
        state.launches.append(launch)
        state.continuations.append(continuation)
        state.writes.append([])
        state.shutdowns.append(0)
        return state.launches.count - 1
      }
      return AgentProcessHandle(
        events: events,
        write: { data in
          try self.state.withLock { state in
            if let error = state.writeError { throw error }
            state.writes[index].append(data)
          }
        },
        shutdown: {
          self.state.withLock { $0.shutdowns[index] += 1 }
          continuation.yield(.exited(status: 143, stderrTail: ""))
          continuation.finish()
        }
      )
    })
  }
}

func json(_ line: Data) -> JSONValue {
  (try? JSONDecoder().decode(JSONValue.self, from: line)) ?? .null
}

enum Line {
  static func assistantText(_ uuid: String, _ text: String) -> String {
    #"{"type":"assistant","uuid":"\#(uuid)","message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
  }

  static func result(durationMs: Int = 41_000, isError: Bool = false, text: String = "done") -> String {
    #"{"type":"result","subtype":"success","duration_ms":\#(durationMs),"is_error":\#(isError),"result":"\#(text)"}"#
  }

  static func interruptedResult(durationMs: Int = 41_000) -> String {
    #"{"type":"result","subtype":"error_during_execution","duration_ms":\#(durationMs),"is_error":true,"errors":["interrupted"]}"#
  }

  static let idle = #"{"type":"system","subtype":"session_state_changed","state":"idle"}"#

  static func canUseTool(_ requestID: String) -> String {
    #"{"type":"control_request","request_id":"\#(requestID)","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#
  }
}
