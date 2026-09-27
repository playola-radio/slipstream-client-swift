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
