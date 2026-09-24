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

  private struct State {
    var tokens: [String] = ["token-1"]
    var discoverError: (any Error)?
    var sessions: [SessionSummary] = []
    var roots: [String: String] = [:]
    var follows: [FollowRequest] = []
    var connections: [Connection] = []
    var clips: [Seq: ClipsResponse] = [:]
    var clipsError: (any Error)?
    var blobs: [String: Data] = [:]
  }

  private let state = Mutex(State())
  private let clipsGate: AsyncStream<Void>?

  init(clipsGate: AsyncStream<Void>? = nil) {
    self.clipsGate = clipsGate
  }

  var follows: [FollowRequest] { state.withLock { $0.follows } }

  func setTokens(_ tokens: [String]) { state.withLock { $0.tokens = tokens } }
  func setDiscoverError(_ error: (any Error)?) { state.withLock { $0.discoverError = error } }
  func setSessions(_ sessions: [SessionSummary], roots: [String: String] = [:]) {
    state.withLock {
      $0.sessions = sessions
      $0.roots = roots
    }
  }
  func setClips(_ response: ClipsResponse) { state.withLock { $0.clips[response.changeSeq] = response } }
  func setClipsError(_ error: any Error) { state.withLock { $0.clipsError = error } }
  func setBlob(_ sha: String, _ text: String) { setBlob(sha, data: Data(text.utf8)) }
  func setBlob(_ sha: String, data: Data) { state.withLock { $0.blobs[sha] = data } }

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
      discover: { [self] in
        try state.withLock { state in
          if let error = state.discoverError { throw error }
          let token = state.tokens.count > 1 ? state.tokens.removeFirst() : state.tokens[0]
          return DaemonDescriptor(baseURL: URL(string: "http://127.0.0.1:4100")!, token: token)
        }
      },
      sessions: { [self] _ in state.withLock { $0.sessions } },
      sessionRoot: { [self] _, id in state.withLock { $0.roots[id] } },
      follow: { [self] descriptor, sessionID, cursor in
        let (stream, continuation) = AsyncThrowingStream<StreamItem, any Error>.makeStream()
        state.withLock {
          $0.follows.append(FollowRequest(token: descriptor.token, sessionID: sessionID, cursor: cursor))
          $0.connections.append(continuation)
        }
        return stream
      },
      clips: { [self] _, _, seq in
        if let clipsGate {
          for await _ in clipsGate { break }
        }
        return try state.withLock { state in
          if let error = state.clipsError { throw error }
          guard let response = state.clips[seq] else { throw DaemonHTTPError.status(404, durableSeq: nil) }
          return response
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
    return .frame(SSEEvent(id: String(value), event: nil, data: String(decoding: json, as: UTF8.self)))
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
    frame(value, type: "slipstream.session.started.v1", data: ["session_id": session, "root": "/tmp/project"])
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
