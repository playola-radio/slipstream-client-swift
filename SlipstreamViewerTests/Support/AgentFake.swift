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
    var inputClosed: [Bool] = []
    var launchError: (any Error)?
    var shutdowns: [Int] = []
    var writeError: (any Error)?
    var holding: Set<Hold> = []
    var held: [Hold: [CheckedContinuation<Void, Never>]] = [:]
  }

  enum Hold { case environment, launches, writes, shutdowns }

  private let state = Mutex(State())

  var launches: [AgentLaunch] { state.withLock { $0.launches } }
  var loads: [UUID] { state.withLock { $0.loads } }
  var shutdownCount: Int { state.withLock { $0.shutdowns.reduce(0, +) } }
  /// Decoded, because the encoder orders object keys differently from call to call.
  func writes(_ launch: Int) -> [JSONValue] { state.withLock { $0.writes[launch] }.map(json) }
  func rawWrites(_ launch: Int) -> [Data] { state.withLock { $0.writes[launch] } }
  func isInputClosed(_ launch: Int) -> Bool { state.withLock { $0.inputClosed[launch] } }
  func shutdowns(_ launch: Int) -> Int { state.withLock { $0.shutdowns[launch] } }

  func setEnvironmentError(_ error: AgentEnvironmentError?) { state.withLock { $0.environmentError = error } }
  func setTranscript(_ id: UUID, _ lookup: TranscriptLookup) { state.withLock { $0.transcripts[id] = lookup } }
  func setUnreadable(_ id: UUID) { state.withLock { _ = $0.unreadable.insert(id) } }
  func setWriteError(_ error: (any Error)?) { state.withLock { $0.writeError = error } }
  func setLaunchError(_ error: (any Error)?) { state.withLock { $0.launchError = error } }

  /// Makes those calls wait until `release(_:)`, like a slow login shell or a full pipe.
  func hold(_ hold: Hold) { state.withLock { _ = $0.holding.insert(hold) } }

  func release(_ hold: Hold) {
    let held = state.withLock { state in
      state.holding.remove(hold)
      return state.held.removeValue(forKey: hold) ?? []
    }
    for continuation in held { continuation.resume() }
  }

  /// Lets only the most recent held call through.
  func releaseLast(_ hold: Hold) {
    let continuation = state.withLock { $0.held[hold]?.popLast() }
    continuation?.resume()
  }

  private func wait(_ hold: Hold) async {
    await withCheckedContinuation { continuation in
      let isHeld = state.withLock { state in
        if state.holding.contains(hold) { state.held[hold, default: []].append(continuation) }
        return state.holding.contains(hold)
      }
      if !isHeld { continuation.resume() }
    }
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

  func finishEvents() {
    state.withLock { $0.continuations[$0.continuations.count - 1] }.finish()
  }

  var environmentClient: AgentEnvironmentClient {
    AgentEnvironmentClient(resolve: {
      await self.wait(.environment)
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
      await self.wait(.launches)
      if let error = self.state.withLock({ $0.launchError }) { throw error }
      let (events, continuation) = AsyncStream<AgentProcessEvent>.makeStream()
      let index = self.state.withLock { state in
        state.launches.append(launch)
        state.continuations.append(continuation)
        state.writes.append([])
        state.inputClosed.append(false)
        state.shutdowns.append(0)
        return state.launches.count - 1
      }
      return AgentProcessHandle(
        events: events,
        write: { data in
          await self.wait(.writes)
          try self.state.withLock { state in
            if let error = state.writeError { throw error }
            if state.inputClosed[index] { throw WriteFailed() }
            state.writes[index].append(data)
          }
        },
        closeInput: { self.state.withLock { $0.inputClosed[index] = true } },
        shutdown: {
          self.state.withLock { $0.shutdowns[index] += 1 }
          await self.wait(.shutdowns)
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

  static func echo(_ uuid: String, _ text: String = "hi") -> String {
    #"{"type":"user","uuid":"\#(uuid)","isReplay":true,"session_id":"s","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"text","text":"\#(text)"}]}}"#
  }

  static let idle = #"{"type":"system","subtype":"session_state_changed","state":"idle"}"#

  static func canUseTool(_ requestID: String) -> String {
    #"{"type":"control_request","request_id":"\#(requestID)","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#
  }
}
