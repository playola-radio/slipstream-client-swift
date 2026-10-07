import ConcurrencyExtras
import Foundation
import SlipstreamCore
import Synchronization
import Testing

@testable import SlipstreamViewer

struct FollowRequest: Equatable {
  var token: String
  var sessionID: String
  var cursor: Seq
}

final class DaemonFake: Sendable {
  typealias Connection = AsyncThrowingStream<StreamItem, any Error>.Continuation

  enum InterfaceReply: Sendable {
    case page(InterfaceComparison)
    case failure(DaemonHTTPError)
  }

  private struct State {
    var tokens: [String] = ["token-1"]
    var discoverError: (any Error)?
    var sessions: [SessionSummary] = []
    var starts: [String: SessionStarted] = [:]
    var sessionStartCallCount = 0
    var follows: [FollowRequest] = []
    var connections: [Connection] = []
    var clips: [Seq: ClipsResponse] = [:]
    var interfaceReplies: [InterfaceReply] = []
    var interfaceRequests: [(String, String, Seq, Seq, String?, String?, Bool)] = []
    var interfaceCallGates: [Int: AsyncStream<Void>.Continuation] = [:]
    var clipsFailures = 0
    var blobs: [String: Data] = [:]
    var clipsCallCount = 0
    var clipsCallGates: [Int: AsyncStream<Void>.Continuation] = [:]
  }

  private let state = Mutex(State())
  private let clipsGate: AsyncStream<Void>?
  private let sessionsGate: AsyncStream<Void>?
  private let sessionStartGates: [String: AsyncStream<Void>]
  private let gatesEachClipsCall: Bool
  private let gatesEachInterfaceCall: Bool
  private let storeID: String

  init(
    storeID: String = "store-a",
    clipsGate: AsyncStream<Void>? = nil,
    sessionsGate: AsyncStream<Void>? = nil,
    sessionStartGates: [String: AsyncStream<Void>] = [:],
    gatesEachClipsCall: Bool = false,
    gatesEachInterfaceCall: Bool = false
  ) {
    self.storeID = storeID
    self.clipsGate = clipsGate
    self.sessionsGate = sessionsGate
    self.sessionStartGates = sessionStartGates
    self.gatesEachClipsCall = gatesEachClipsCall
    self.gatesEachInterfaceCall = gatesEachInterfaceCall
  }

  var follows: [FollowRequest] { state.withLock { $0.follows } }
  var interfaceRequests: [(String, String, Seq, Seq, String?, String?, Bool)] { state.withLock { $0.interfaceRequests } }
  func setInterfacePages(_ pages: [InterfaceComparison]) {
    setInterfaceReplies(pages.map { .page($0) })
  }
  func setInterfaceReplies(_ replies: [InterfaceReply]) { state.withLock { $0.interfaceReplies = replies } }
  func waitForInterfaceCall(_ number: Int) async {
    while state.withLock({ $0.interfaceRequests.count }) < number { await Task.yield() }
  }
  func releaseInterfaceCall(_ number: Int) {
    state.withLock { $0.interfaceCallGates[number] }?.yield()
  }

  func setTokens(_ tokens: [String]) { state.withLock { $0.tokens = tokens } }
  func setDiscoverError(_ error: (any Error)?) { state.withLock { $0.discoverError = error } }
  func setSessions(_ sessions: [SessionSummary], starts: [String: SessionStarted] = [:]) {
    state.withLock {
      $0.sessions = sessions
      $0.starts = starts
    }
  }
  func setClips(_ response: ClipsResponse, for seq: Seq) { state.withLock { $0.clips[seq] = response } }
  func failClips(times: Int) { state.withLock { $0.clipsFailures = times } }
  func setBlob(_ sha: String, _ text: String) { setBlob(sha, data: Data(text.utf8)) }
  func setBlob(_ sha: String, data: Data) { state.withLock { $0.blobs[sha] = data } }

  func waitForClipsCall(_ number: Int) async {
    while state.withLock({ $0.clipsCallCount }) < number { await Task.yield() }
  }

  func waitForSessionStartCall(_ number: Int) async {
    while state.withLock({ $0.sessionStartCallCount }) < number { await Task.yield() }
  }

  func releaseClipsCall(_ number: Int) {
    state.withLock { $0.clipsCallGates[number] }?.yield()
  }

  func send(_ items: StreamItem...) {
    guard let connection = state.withLock({ $0.connections.last }) else {
      Issue.record("No open follow connection")
      return
    }
    for item in items { connection.yield(item) }
  }

  func send(to index: Int, _ items: StreamItem...) {
    let connection = state.withLock { $0.connections[index] }
    for item in items { connection.yield(item) }
  }

  func close(throwing error: (any Error)? = nil) {
    state.withLock { $0.connections.last }?.finish(throwing: error)
  }

  var client: DaemonClient {
    DaemonClient(
      storeID: storeID,
      discover: { [self] in
        try state.withLock { state in
          if let error = state.discoverError { throw error }
          let token = state.tokens.count > 1 ? state.tokens.removeFirst() : state.tokens[0]
          return DaemonDescriptor(baseURL: URL(string: "http://127.0.0.1:4100")!, token: token)
        }
      },
      sessions: { [self] _ in
        if let sessionsGate {
          for await _ in sessionsGate { break }
        }
        return state.withLock { $0.sessions }
      },
      sessionStart: { [self] _, id in
        state.withLock { $0.sessionStartCallCount += 1 }
        if let gate = sessionStartGates[id] {
          for await _ in gate { break }
        }
        return state.withLock { $0.starts[id] }
      },
      follow: { [self] descriptor, sessionID, cursor in
        let (stream, continuation) = AsyncThrowingStream<StreamItem, any Error>.makeStream()
        state.withLock {
          $0.follows.append(FollowRequest(token: descriptor.token, sessionID: sessionID, cursor: cursor))
          $0.connections.append(continuation)
        }
        return stream
      },
      clips: { [self] _, _, seq in
        let callGate: AsyncStream<Void>? = state.withLock { state in
          state.clipsCallCount += 1
          guard gatesEachClipsCall else { return nil }
          let (gate, open) = AsyncStream<Void>.makeStream()
          state.clipsCallGates[state.clipsCallCount] = open
          return gate
        }
        if let callGate {
          for await _ in callGate { break }
        }
        if let clipsGate {
          for await _ in clipsGate { break }
        }
        return try state.withLock { state in
          if state.clipsFailures > 0 {
            state.clipsFailures -= 1
            throw URLError(.networkConnectionLost)
          }
          guard let response = state.clips[seq] else { throw DaemonHTTPError.status(404, durableSeq: nil) }
          return response
        }
      },
      interfaces: { [self] descriptor, sessionID, before, after, prefix, cursor, identical in
        let gate: AsyncStream<Void>? = state.withLock { state in
          state.interfaceRequests.append((descriptor.token, sessionID, before, after, prefix, cursor, identical))
          guard gatesEachInterfaceCall else { return nil }
          let (stream, open) = AsyncStream<Void>.makeStream()
          state.interfaceCallGates[state.interfaceRequests.count] = open
          return stream
        }
        if let gate { for await _ in gate { break } }
        return try state.withLock { state in
          guard !state.interfaceReplies.isEmpty else { throw DaemonHTTPError.status(500, durableSeq: nil) }
          switch state.interfaceReplies.removeFirst() {
          case .page(let page): return page
          case .failure(let error): throw error
          }
        }
      },
      blob: { [self] _, sha in
        try state.withLock { state in
          guard let data = state.blobs[sha] else { throw DaemonHTTPError.status(404, durableSeq: nil) }
          return data
        }
      }
    )
  }
}

enum Fixture {
  static let session = "6f1c2b1e-8d3a-4c55-9a7e-2f4b8c9d0e1a"
  static let otherSession = "0d7e1f2a-1111-4c55-9a7e-2f4b8c9d0e1a"
  static let shaA = String(repeating: "a", count: 64)
  static let shaB = String(repeating: "b", count: 64)
  static let observedAtMs: Int64 = 1_790_246_538_000

  static func seq(_ value: Int) -> Seq {
    Seq(String(value))!
  }

  static func frame(_ value: Int, type: String, data: [String: Any]) -> StreamItem {
    let envelope: [String: Any] = [
      "specversion": "1.0",
      "id": String(value),
      "seq": String(value),
      "type": type,
      "source": "urn:slipstream:session:\(session)",
      "data": data,
    ]
    let json = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    return .frame(SSEEvent(id: String(value), data: String(decoding: json, as: UTF8.self)))
  }

  static func taskStarted(_ value: Int, _ title: String) -> StreamItem {
    frame(value, type: "slipstream.task.started.v1", data: ["session_id": session, "task_id": "t-\(value)", "title": title])
  }

  static func fileChanged(_ value: Int, _ path: String, before: [String: Any], after: [String: Any]) -> StreamItem {
    frame(
      value,
      type: "slipstream.file.changed.v1",
      data: ["session_id": session, "path": path, "before": before, "after": after, "observed_at_ms": observedAtMs]
    )
  }

  static func content(_ sha: String, size: Int = 10) -> [String: Any] {
    ["kind": "content", "sha256": sha, "size": size]
  }

  static var absent: [String: Any] { ["kind": "absent"] }

  static func unavailable(_ reason: String) -> [String: Any] {
    ["kind": "unavailable", "reason": reason]
  }

  static func edited(_ value: Int, _ path: String = "src/user.ts") -> StreamItem {
    fileChanged(value, path, before: content(shaA), after: content(shaB))
  }

  static func sessionStarted(_ value: Int) -> StreamItem {
    frame(value, type: "slipstream.session.started.v1", data: ["session_id": session, "root": "/tmp/project", "started_at_ms": 0])
  }

  static func unknown(_ value: Int) -> StreamItem {
    frame(value, type: "slipstream.future.thing.v1", data: [:])
  }

  static func captureGap(_ value: Int) -> StreamItem {
    frame(
      value,
      type: "slipstream.capture.gap.v1",
      data: ["session_id": session, "reason": "watcher-error", "scope": ["kind": "directory", "path": "src"]]
    )
  }

  static func sessionResumed(_ value: Int) -> StreamItem {
    frame(value, type: "slipstream.session.resumed.v1", data: ["session_id": session])
  }

  static func agentConnection(_ value: Int, state: String, sessionID: String = session) -> StreamItem {
    frame(
      value,
      type: "slipstream.agent.connection.v1",
      data: [
        "state": state,
        "target": ["harness": "claude-code", "harness_session_id": "h-1", "worktree": "/tmp/project"],
        "session_id": sessionID,
      ]
    )
  }

  static func questionQueued(
    _ value: Int,
    id: String,
    text: String = "Why did this change?",
    changeSeq: Int = 1,
    path: String = "src/user.ts",
    replyTo parentID: String? = nil
  ) -> StreamItem {
    var data: [String: Any] = [
      "question_id": id,
      "text": text,
      "queued_at_ms": observedAtMs,
      "context": [
        "change_seq": String(changeSeq), "path": path, "snapshot_sha256": shaB,
        "line_start": 7, "line_end": 9, "selected_text": "a",
      ],
    ]
    if let parentID { data["reply_to_question_id"] = parentID }
    return frame(value, type: "slipstream.question.queued.v1", data: data)
  }

  static func questionAnswered(_ value: Int, id: String, text: String = "Because.") -> StreamItem {
    frame(value, type: "slipstream.question.answered.v1", data: [
      "question_id": id, "attempt_seq": String(value - 1), "text": text, "answered_at_ms": observedAtMs,
    ])
  }
}

struct ConstantGenerator: RandomNumberGenerator {
  mutating func next() -> UInt64 { .max }
}

struct MainSerialExecutorTrait: TestTrait, SuiteTrait, TestScoping {
  var isRecursive: Bool { true }

  func provideScope(
    for test: Test,
    testCase: Test.Case?,
    performing function: @Sendable () async throws -> Void
  ) async throws {
    try await withMainSerialExecutor { try await function() }
  }
}

extension Trait where Self == MainSerialExecutorTrait {
  static var mainSerialExecutor: Self { Self() }
}
