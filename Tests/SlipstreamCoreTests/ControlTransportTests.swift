import CustomDump
import Darwin
import Foundation
import Testing
@testable import SlipstreamCore

struct ControlTransportTests {
  @Test func missingSocketIsUnavailable() async {
    let transport = ControlTransport(store: URL(fileURLWithPath: "/tmp/absent-\(UUID())"))
    await #expect(throws: QuestionError.unavailable) { try await transport.ask(QuestionsTests.request) }
  }

  @Test func splitFramesAndUTF8AreBufferedUntilNewline() throws {
    var decoder = ControlResponseBuffer()
    let bytes = Array("\n{\"text\":\"😀\"}\n".utf8)
    for byte in bytes.dropLast() { #expect(try decoder.append(Data([byte])) == nil) }
    expectNoDifference(try decoder.append(Data([10])), Data("{\"text\":\"😀\"}".utf8))
  }

  @Test func completeAndUnterminatedResponsesAreBounded() {
    for suffix in [Data(), Data([10])] {
      var decoder = ControlResponseBuffer()
      #expect(throws: QuestionError.outcomeUnknown) {
        try decoder.append(Data(repeating: 65, count: ControlTransport.maximumMessageBytes + 1) + suffix)
      }
    }
  }

  @Test func realSocketReceivesOneRequestAndReturnsSplitReply() async throws {
    let server = try SocketFixture()
    let serving = server.serve { fd in
      var request = Data()
      var byte: UInt8 = 0
      while Darwin.read(fd, &byte, 1) == 1, byte != 10 { request.append(byte) }
      let json = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
      expectNoDifference(json["request_id"] as? String, QuestionsTests.requestID)
      for byte in (QuestionsTests.acknowledgment + "\n").utf8 {
        var value = byte
        _ = Darwin.write(fd, &value, 1)
      }
    }
    let reply = try await ControlTransport(store: server.store).ask(QuestionsTests.request)
    expectNoDifference(reply.questionID, QuestionsTests.questionID)
    try await serving.value
  }

  @Test func recordExchangeSendsOneLineAndDecodesTheReply() async throws {
    let server = try SocketFixture()
    let serving = server.serve { fd in
      var request = Data()
      var byte: UInt8 = 0
      while Darwin.read(fd, &byte, 1) == 1, byte != 10 { request.append(byte) }
      let json = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
      expectNoDifference(json["verb"] as? String, "record_question_exchange")
      let reply = Array((QuestionsTests.exchangeAcknowledgment + "\n").utf8)
      _ = reply.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
    let reply = try await ControlTransport(store: server.store).recordExchange(QuestionsTests.exchange())
    expectNoDifference(reply.questionID, QuestionsTests.questionID)
    try await serving.value
  }

  @Test func postSendDisconnectIsUnknown() async throws {
    let server = try SocketFixture()
    let serving = server.serve { fd in
      var byte: UInt8 = 0
      while Darwin.read(fd, &byte, 1) == 1, byte != 10 {}
    }
    await #expect(throws: QuestionError.outcomeUnknown) {
      try await ControlTransport(store: server.store).ask(QuestionsTests.request)
    }
    try await serving.value
  }

  @Test func cancellationClosesRequestAndKeepsPostSendUncertainty() async throws {
    let server = try SocketFixture()
    let (received, continuation) = AsyncStream<Void>.makeStream()
    let serving = server.serve { fd in
      var byte: UInt8 = 0
      while Darwin.read(fd, &byte, 1) == 1, byte != 10 {}
      continuation.yield()
      expectNoDifference(Darwin.read(fd, &byte, 1), 0)
    }
    let task = Task { try await ControlTransport(store: server.store).ask(QuestionsTests.request) }
    for await _ in received { break }
    task.cancel()
    await #expect(throws: QuestionError.outcomeUnknown) { try await task.value }
    try await serving.value
  }

  @Test func responseDeadlineIsUnknown() async throws {
    let server = try SocketFixture()
    let serving = server.serve { fd in
      var byte: UInt8 = 0
      while Darwin.read(fd, &byte, 1) == 1 {}
    }
    await #expect(throws: QuestionError.outcomeUnknown) {
      try await ControlTransport(store: server.store, responseTimeout: .milliseconds(20)).ask(QuestionsTests.request)
    }
    try await serving.value
  }
}

private final class SocketFixture: Sendable {
  let store: URL
  let fd: Int32
  init() throws {
    store = URL(fileURLWithPath: "/tmp/ss-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(store.appendingPathComponent("control.sock").path.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    #expect(result == 0)
    #expect(chmod(store.appendingPathComponent("control.sock").path, 0o600) == 0)
    #expect(listen(fd, 1) == 0)
  }
  deinit {
    close(fd)
    try? FileManager.default.removeItem(at: store)
  }
  func serve(_ body: @escaping @Sendable (Int32) throws -> Void) -> Task<Void, any Error> {
    // Blocking accept runs on GCD so EventFollowerTests' process-wide main serial executor can't park it on main.
    Task {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
          continuation.resume(with: Result {
            let client = accept(self.fd, nil, nil)
            guard client >= 0 else { throw POSIXError(.EBADF) }
            defer { close(client) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var enabled: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            try body(client)
          })
        }
      }
    }
  }
}

extension ControlTransportTests {
  @Test func malformedReplyIsUnknown() async throws {
    let server = try SocketFixture()
    let serving = server.serve { fd in
      var byte: UInt8 = 0
      while Darwin.read(fd, &byte, 1) == 1, byte != 10 {}
      let reply = Data("{\"v\":1,\"ok\":true}\n".utf8)
      _ = reply.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
    await #expect(throws: QuestionError.outcomeUnknown) {
      try await ControlTransport(store: server.store).ask(QuestionsTests.request)
    }
    try await serving.value
  }

  @Test func cancelledBeforeConnectingIsUnavailable() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await ControlTransport(store: URL(fileURLWithPath: "/tmp/unused-\(UUID())")).ask(QuestionsTests.request)
    }
    await #expect(throws: QuestionError.unavailable) { try await task.value }
  }

  @Test func worldReadableSocketIsRefused() async throws {
    let server = try SocketFixture()
    chmod(server.store.appendingPathComponent("control.sock").path, 0o666)
    await #expect(throws: QuestionError.unavailable) {
      try await ControlTransport(store: server.store).ask(QuestionsTests.request)
    }
  }
}

extension ControlTransportTests {
  func capability(reply: String) async throws -> Bool {
    let server = try SocketFixture()
    let serving = server.serve { fd in
      var request = Data()
      var byte: UInt8 = 0
      while Darwin.read(fd, &byte, 1) == 1, byte != 10 { request.append(byte) }
      expectNoDifference(
        try QuestionsTests.json(request),
        try QuestionsTests.json(
          Data(#"{"v":1,"verb":"record_question_relay_update","session_id":"\#(QuestionsTests.session)"}"#.utf8)))
      let bytes = Array((reply + "\n").utf8)
      _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
    let supports = try await ControlTransport(store: server.store).supportsRelays(sessionID: QuestionsTests.session)
    try await serving.value
    return supports
  }

  @Test func supportsRelaysTrueOnProtocol() async throws {
    #expect(
      try await capability(
        reply: #"{"v":1,"ok":false,"code":"PROTOCOL","message":"request_id must be a canonical lowercase UUID"}"#))
  }

  @Test func supportsRelaysFalseOnUnknownVerb() async throws {
    #expect(
      try await !capability(
        reply: #"{"v":1,"ok":false,"code":"PROTOCOL","message":"unknown verb: record_question_relay_update"}"#))
  }
}

extension ControlTransportTests {
  static let folder = "/Users/brian/conductor/workspaces/playola/farmerville"

  func exchange(
    reply: String, expecting expected: String, _ body: @Sendable (ControlTransport) async throws -> Void
  ) async throws {
    let server = try SocketFixture()
    let serving = server.serve { fd in
      var request = Data()
      var byte: UInt8 = 0
      while Darwin.read(fd, &byte, 1) == 1, byte != 10 { request.append(byte) }
      expectNoDifference(try QuestionsTests.json(request), try QuestionsTests.json(Data(expected.utf8)))
      let bytes = Array((reply + "\n").utf8)
      _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
    try await body(ControlTransport(store: server.store))
    try await serving.value
  }

  static let recordLine = #"{ "v": 1, "verb": "attach", "mode": "watch-only", "worktree": "/Users/brian/conductor/workspaces/playola/farmerville" }"#
  static let pauseLine =
    #"{ "v": 1, "verb": "detach", "target": "/Users/brian/conductor/workspaces/playola/farmerville", "origin": "app:pause" }"#

  @Test func recordSendsWatchOnlyAttachAndIgnoresTheReply() async throws {
    try await exchange(
      reply: #"{"v":1,"ok":true,"session_id":"6f1c","state":"queued","reason":null,"created":true}"#,
      expecting: Self.recordLine
    ) { try await $0.record(folder: Self.folder) }
  }

  @Test func pauseSendsDetachAndIgnoresTheReply() async throws {
    try await exchange(
      reply: #"{"v":1,"ok":true,"session_id":"6f1c","state":"stopped","reason":"detached","already_stopped":true}"#,
      expecting: Self.pauseLine
    ) { try await $0.pause(folder: Self.folder, origin: "app:pause") }
  }

  @Test func recordRefusalCarriesTheDaemonsCodeAndMessage() async throws {
    let message = "32/32 capture slots in use. This workspace is NOT recording. Pause one first."
    try await exchange(
      reply: #"{"v":1,"ok":false,"code":"CAPTURE_LIMIT_REACHED","message":"\#(message)"}"#,
      expecting: Self.recordLine
    ) { transport in
      await #expect(throws: QuestionError.rejected(code: "CAPTURE_LIMIT_REACHED", message: message)) {
        try await transport.record(folder: Self.folder)
      }
    }
  }

  @Test func pauseRefusalCarriesTheDaemonsCodeAndMessage() async throws {
    try await exchange(
      reply: #"{"v":1,"ok":false,"code":"TARGET_NOT_FOUND","message":"no capture"}"#,
      expecting: Self.pauseLine
    ) { transport in
      await #expect(throws: QuestionError.rejected(code: "TARGET_NOT_FOUND", message: "no capture")) {
        try await transport.pause(folder: Self.folder, origin: "app:pause")
      }
    }
  }
}

extension ControlTransportTests {
  static func renameLine(_ name: String) -> String {
    #"{"v":1,"verb":"rename_session","session_id":"\#(QuestionsTests.session)","name":\#(name)}"#
  }

  @Test func renameSendsNameAndSessionID() async throws {
    try await exchange(reply: #"{"v":1,"ok":true}"#, expecting: Self.renameLine(#""Fix login""#)) {
      try await $0.renameSession(sessionID: QuestionsTests.session, name: "Fix login")
    }
  }

  @Test func clearSendsExplicitNull() async throws {
    try await exchange(reply: #"{"v":1,"ok":true}"#, expecting: Self.renameLine("null")) {
      try await $0.renameSession(sessionID: QuestionsTests.session, name: nil)
    }
  }

  @Test func sessionNotFoundIsRejected() async throws {
    try await exchange(
      reply: #"{"v":1,"ok":false,"code":"SESSION_NOT_FOUND","message":"session was deleted"}"#,
      expecting: Self.renameLine(#""Fix login""#)
    ) { transport in
      await #expect(throws: QuestionError.rejected(code: "SESSION_NOT_FOUND", message: "session was deleted")) {
        try await transport.renameSession(sessionID: QuestionsTests.session, name: "Fix login")
      }
    }
  }
}

extension ControlTransportTests {
  static func nameLine(_ name: String) -> String {
    #"{"v":1,"verb":"name_session","session_id":"\#(QuestionsTests.session)","name":"\#(name)"}"#
  }

  @Test(arguments: [true, false])
  func nameSessionSendsNameAndReturnsChanged(changed: Bool) async throws {
    try await exchange(reply: #"{"v":1,"ok":true,"changed":\#(changed)}"#, expecting: Self.nameLine("Fix login")) {
      let result = try await $0.nameSession(sessionID: QuestionsTests.session, name: "Fix login")
      expectNoDifference(result, changed)
    }
  }

  @Test func nameSessionWithoutChangedIsOutcomeUnknown() async throws {
    try await exchange(reply: #"{"v":1,"ok":true}"#, expecting: Self.nameLine("Fix login")) { transport in
      await #expect(throws: QuestionError.outcomeUnknown) {
        try await transport.nameSession(sessionID: QuestionsTests.session, name: "Fix login")
      }
    }
  }

  @Test(arguments: [
    ("SESSION_NOT_FOUND", "session was deleted"), ("INVALID_NAME", "name is too long"),
    ("STORAGE_UNAVAILABLE", "store unreadable"), ("PROTOCOL", "unknown verb: name_session"),
  ])
  func nameSessionRefusalCarriesTheDaemonsCodeAndMessage(code: String, message: String) async throws {
    try await exchange(
      reply: #"{"v":1,"ok":false,"code":"\#(code)","message":"\#(message)"}"#, expecting: Self.nameLine("Fix login")
    ) { transport in
      await #expect(throws: QuestionError.rejected(code: code, message: message)) {
        try await transport.nameSession(sessionID: QuestionsTests.session, name: "Fix login")
      }
    }
  }
}

extension ControlTransportTests {
  func status(reply: String) async throws -> DaemonBuild {
    let server = try SocketFixture()
    let serving = server.serve { fd in
      var request = Data()
      var byte: UInt8 = 0
      while Darwin.read(fd, &byte, 1) == 1, byte != 10 { request.append(byte) }
      expectNoDifference(try QuestionsTests.json(request), try QuestionsTests.json(Data(#"{"v":1,"verb":"status"}"#.utf8)))
      let bytes = Array((reply + "\n").utf8)
      _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
    let build = try await ControlTransport(store: server.store).status()
    try await serving.value
    return build
  }

  @Test func statusReportsDaemonBuild() async throws {
    let current = try await status(reply: #"{"v":1,"ok":true,"daemon_version":"0.3.2","daemon_build":"7f3c9a1e-1","captures":[]}"#)
    let older = try await status(reply: #"{"v":1,"ok":true,"daemon_version":"0.3.0","daemon_build":null}"#)
    expectNoDifference(current, DaemonBuild(version: "0.3.2", build: "7f3c9a1e-1"))
    expectNoDifference(older, DaemonBuild(version: "0.3.0", build: nil))
  }
}
