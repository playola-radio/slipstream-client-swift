import Darwin
import Foundation
import Synchronization

public struct ControlTransport: Sendable {
  public static let maximumMessageBytes = 1 << 20
  private let store: URL
  private let responseTimeout: Duration

  public init(store: URL, responseTimeout: Duration = .seconds(15)) {
    self.store = store
    self.responseTimeout = responseTimeout
  }

  public func ask(_ request: QuestionRequest) async throws -> QuestionAcknowledgment {
    try await send(request.encoded()) { try QuestionAcknowledgment.decode($0, for: request) }
  }

  public func recordExchange(_ request: QuestionRequest) async throws -> ExchangeAcknowledgment {
    try await send(request.encoded()) { try ExchangeAcknowledgment.decode($0, for: request) }
  }

  public func updateRelay(_ request: QuestionRelayUpdateRequest) async throws -> RelayAcknowledgment {
    try await send(request.encoded()) { try RelayAcknowledgment.decode($0, for: request) }
  }

  public func supportsRelays(sessionID: String) async throws -> Bool {
    try await send(ControlLine.encode(RelayCapabilityRequest(sessionID: sessionID))) {
      try RelayCapabilityRequest.supportsRelays($0)
    }
  }

  public func record(folder: String) async throws {
    try await send(ControlLine.encode(RecordRequest(worktree: folder))) { try ControlReply.check($0) }
  }

  /// `origin` names what asked, so the daemon's log can say who paused the capture.
  public func pause(folder: String, origin: String) async throws {
    try await send(ControlLine.encode(PauseRequest(target: folder, origin: origin))) { try ControlReply.check($0) }
  }

  public func renameSession(sessionID: String, name: String?) async throws {
    try await send(ControlLine.encode(RenameSessionRequest(sessionID: sessionID, name: name))) {
      try ControlReply.check($0)
    }
  }

  /// Whether the daemon stored the name: false when the session already had an agent name.
  public func nameSession(sessionID: String, name: String) async throws -> Bool {
    try await send(ControlLine.encode(NameSessionRequest(sessionID: sessionID, name: name))) {
      try NameSessionRequest.changed($0)
    }
  }

  public func status() async throws -> DaemonBuild {
    try await send(ControlLine.encode(StatusRequest())) { try DaemonBuild.decode($0) }
  }

  private func send<Reply: Sendable>(
    _ line: Data, decode: @escaping @Sendable (Data) throws -> Reply
  ) async throws -> Reply {
    let bytes = line + Data([10])
    let cancellation = Mutex(false)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: Result {
            try decode(exchange(bytes, cancelled: { cancellation.withLock { $0 } }))
          })
        }
      }
    } onCancel: {
      cancellation.withLock { $0 = true }
    }
  }

  private func exchange(_ bytes: Data, cancelled: () -> Bool) throws -> Data {
    let path = store.appendingPathComponent("control.sock").path
    var address = sockaddr_un()
    let pathBytes = Array(path.utf8) + [0]
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path), !path.utf8.contains(0) else {
      throw QuestionError.unavailable
    }
    var metadata = stat()
    guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK,
      metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0, !cancelled()
    else { throw QuestionError.unavailable }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw QuestionError.unavailable }
    defer { close(fd) }
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
      throw QuestionError.unavailable
    }
    var enabled: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
      throw QuestionError.unavailable
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
    let clock = ContinuousClock()
    var deadline = clock.now.advanced(by: .seconds(2))
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connected != 0 {
      guard errno == EINPROGRESS else { throw QuestionError.unavailable }
      try wait(fd, events: Int16(POLLOUT), deadline: deadline, cancelled: cancelled, failure: .unavailable)
      var socketError: Int32 = 0
      var length = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
        throw QuestionError.unavailable
      }
    }
    guard !cancelled() else { throw QuestionError.unavailable }
    deadline = clock.now.advanced(by: responseTimeout)
    var sent = 0
    while sent < bytes.count {
      try wait(fd, events: Int16(POLLOUT), deadline: deadline, cancelled: cancelled, failure: .outcomeUnknown)
      let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), bytes.count - sent) }
      if count < 0, errno == EAGAIN || errno == EINTR { continue }
      guard count > 0 else { throw QuestionError.outcomeUnknown }
      sent += count
    }
    var decoder = ControlResponseBuffer()
    var chunk = [UInt8](repeating: 0, count: 8192)
    while true {
      try wait(fd, events: Int16(POLLIN), deadline: deadline, cancelled: cancelled, failure: .outcomeUnknown)
      let count = Darwin.read(fd, &chunk, chunk.count)
      if count < 0, errno == EAGAIN || errno == EINTR { continue }
      guard count > 0 else { throw QuestionError.outcomeUnknown }
      if let response = try decoder.append(Data(chunk.prefix(count))) { return response }
    }
  }

  private func wait(
    _ fd: Int32, events: Int16, deadline: ContinuousClock.Instant,
    cancelled: () -> Bool, failure: QuestionError
  ) throws {
    while true {
      guard !cancelled(), ContinuousClock.now < deadline else { throw failure }
      var descriptor = pollfd(fd: fd, events: events, revents: 0)
      let result = poll(&descriptor, 1, 20)
      if result < 0, errno == EINTR { continue }
      guard result >= 0 else { throw failure }
      if result > 0 { return }
    }
  }
}

public struct DaemonBuild: Equatable, Sendable {
  public let version: String
  public let build: String?

  public init(version: String, build: String?) {
    self.version = version
    self.build = build
  }

  public func isNewer(than bundled: RuntimeIdentity) -> Bool {
    RuntimeInstall.isVersion(version, newerThan: bundled.version)
  }

  static func decode(_ data: Data) throws -> Self {
    try ControlReply.check(data)
    guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw QuestionError.outcomeUnknown
    }
    // Daemons before 0.3.0 report neither field but still answer, so they still count as running.
    return DaemonBuild(
      version: fields["daemon_version"] as? String ?? "unknown",
      build: fields["daemon_build"] as? String
    )
  }
}

private struct StatusRequest: Encodable {
  let v = 1
  let verb = "status"
}

private struct RecordRequest: Encodable {
  let v = 1
  let verb = "attach"
  let mode = "watch-only"
  let worktree: String
}

private struct PauseRequest: Encodable {
  let v = 1
  let verb = "detach"
  let target: String
  let origin: String
}

private struct RenameSessionRequest: Encodable {
  let sessionID: String
  let name: String?

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(1, forKey: .v)
    try container.encode("rename_session", forKey: .verb)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(name, forKey: .name)
  }

  private enum CodingKeys: String, CodingKey {
    case v, verb, name
    case sessionID = "session_id"
  }
}

private struct NameSessionRequest: Encodable {
  let v = 1
  let verb = "name_session"
  let sessionID: String
  let name: String

  static func changed(_ data: Data) throws -> Bool {
    try ControlReply.check(data)
    guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let changed = fields["changed"] as? Bool
    else { throw QuestionError.outcomeUnknown }
    return changed
  }

  private enum CodingKeys: String, CodingKey {
    case v, verb, name
    case sessionID = "session_id"
  }
}

struct ControlResponseBuffer {
  private var bytes = Data()

  mutating func append(_ chunk: Data) throws -> Data? {
    for byte in chunk {
      if byte == 10 {
        if bytes.isEmpty { continue }
        return bytes
      }
      guard bytes.count < ControlTransport.maximumMessageBytes else { throw QuestionError.outcomeUnknown }
      bytes.append(byte)
    }
    return nil
  }
}
