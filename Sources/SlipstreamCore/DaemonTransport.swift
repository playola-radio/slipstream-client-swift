import Foundation

public struct SessionSummary: Equatable, Sendable, Decodable, Identifiable {
  public var id: String
  public var durableSeq: Seq
  public var removed: Bool
  public var agentConnection: AgentConnection

  public init(id: String, durableSeq: Seq, removed: Bool, agentConnection: AgentConnection = .unreported) {
    self.id = id
    self.durableSeq = durableSeq
    self.removed = removed
    self.agentConnection = agentConnection
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    durableSeq = try container.decode(Seq.self, forKey: .durableSeq)
    removed = try container.decode(Bool.self, forKey: .removed)
    if container.contains(.agentConnection) {
      let wire = try? container.decode(AgentConnectionWire.self, forKey: .agentConnection)
      agentConnection = wire?.connection ?? .disconnected(reason: nil)
    } else {
      agentConnection = .unreported
    }
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case durableSeq = "durable_seq"
    case removed
    case agentConnection = "agent_connection"
  }
}

public enum StreamItem: Equatable, Sendable {
  case frame(SSEEvent)
  case heartbeat
  case invalid
}

public enum DaemonHTTPError: Error, Equatable, Sendable {
  case status(Int, durableSeq: Seq?)
  case invalidResponse
}

public final class DaemonTransport: Sendable {
  private let session: URLSession

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 120
    session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
  }

  deinit {
    session.invalidateAndCancel()
  }

  public func sessions(_ descriptor: DaemonDescriptor) async throws -> [SessionSummary] {
    let (data, _) = try await get(descriptor, path: "/v1/sessions")
    return try JSONDecoder().decode([SessionSummary].self, from: data)
  }

  public func firstEvent(_ descriptor: DaemonDescriptor, sessionID: String) async throws -> SlipstreamEvent? {
    let request = makeRequest(descriptor, path: "/v1/sessions/\(sessionID)/events", query: [URLQueryItem(name: "after", value: "0")])
    let (bytes, response) = try await session.bytes(for: request)
    defer { bytes.task.cancel() }
    try Self.check(response)
    var line: [UInt8] = []
    for try await byte in bytes {
      if byte == UInt8(ascii: "\n") { break }
      line.append(byte)
      if line.count > SSEParser.maximumLineLength { throw DaemonHTTPError.invalidResponse }
    }
    guard !line.isEmpty else { return nil }
    return try SlipstreamEvent.decode(Data(line))
  }

  public func follow(_ descriptor: DaemonDescriptor, sessionID: String, after cursor: Seq) -> AsyncThrowingStream<StreamItem, any Error> {
    var request = makeRequest(
      descriptor,
      path: "/v1/sessions/\(sessionID)/events",
      query: [URLQueryItem(name: "after", value: cursor.decimal), URLQueryItem(name: "follow", value: "true")]
    )
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    if cursor != .zero {
      request.setValue(cursor.decimal, forHTTPHeaderField: "Last-Event-ID")
    }
    let session = session
    let followRequest = request
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let (bytes, response) = try await session.bytes(for: followRequest)
          try Self.check(response)
          var parser = SSEParser()
          var chunk: [UInt8] = []
          for try await byte in bytes {
            chunk.append(byte)
            let isTerminator = byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
            guard isTerminator || chunk.count > SSEParser.maximumLineLength else { continue }
            for item in parser.consume(chunk) {
              switch item {
              case .event(let event): continuation.yield(.frame(event))
              case .comment: continuation.yield(.heartbeat)
              case .malformedLine: continuation.yield(.invalid)
              }
            }
            chunk.removeAll(keepingCapacity: true)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func clips(_ descriptor: DaemonDescriptor, sessionID: String, seq: Seq) async throws -> ClipsResponse {
    let (data, _) = try await get(descriptor, path: "/v1/sessions/\(sessionID)/changes/\(seq.decimal)/clips")
    return try JSONDecoder().decode(ClipsResponse.self, from: data)
  }

  public func interfaces(
    _ descriptor: DaemonDescriptor, sessionID: String, before: Seq, after: Seq,
    pathPrefix: String?, afterPath: String?, includeIdentical: Bool
  ) async throws -> InterfaceComparison {
    let request = interfaceRequest(
      descriptor, sessionID: sessionID, before: before, after: after,
      pathPrefix: pathPrefix, afterPath: afterPath, includeIdentical: includeIdentical)
    let (data, response) = try await session.data(for: request)
    try Self.check(response)
    try Task.checkCancellation()
    return try InterfaceComparison.decode(data)
  }

  func interfaceRequest(
    _ descriptor: DaemonDescriptor, sessionID: String, before: Seq, after: Seq,
    pathPrefix: String?, afterPath: String?, includeIdentical: Bool
  ) -> URLRequest {
    var components = URLComponents(url: descriptor.baseURL, resolvingAgainstBaseURL: false)!
    components.percentEncodedPath = "/v1/sessions/\(Self.encode(sessionID))/interfaces"
    var query = [
      "before_seq=\(before.decimal)", "after_seq=\(after.decimal)", "limit=16"
    ]
    if let pathPrefix { query.append("path_prefix=\(Self.encode(pathPrefix))") }
    if let afterPath { query.append("after_path=\(Self.encode(afterPath))") }
    if includeIdentical { query.append("include_identical=true") }
    components.percentEncodedQuery = query.joined(separator: "&")
    var request = URLRequest(url: components.url!)
    request.httpMethod = "GET"
    request.setValue("Bearer \(descriptor.token)", forHTTPHeaderField: "Authorization")
    return request
  }

  private static func encode(_ value: String) -> String {
    let hex = Array("0123456789ABCDEF".utf8)
    var result = ""
    for byte in value.utf8 {
      if (65...90).contains(byte) || (97...122).contains(byte)
        || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte)
      {
        result.append(Character(UnicodeScalar(byte)))
      } else {
        result.append("%")
        result.append(Character(UnicodeScalar(hex[Int(byte >> 4)])))
        result.append(Character(UnicodeScalar(hex[Int(byte & 15)])))
      }
    }
    return result
  }

  public func blob(_ descriptor: DaemonDescriptor, sha256: String) async throws -> Data {
    guard sha256.utf8.count == 64, sha256.utf8.allSatisfy(\.isLowercaseHexDigit) else {
      throw DaemonHTTPError.invalidResponse
    }
    return try await get(descriptor, path: "/v1/blobs/sha256/\(sha256)").0
  }

  private func get(_ descriptor: DaemonDescriptor, path: String) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: makeRequest(descriptor, path: path, query: []))
    return (data, try Self.check(response))
  }

  private func makeRequest(_ descriptor: DaemonDescriptor, path: String, query: [URLQueryItem]) -> URLRequest {
    var components = URLComponents(url: descriptor.baseURL, resolvingAgainstBaseURL: false)!
    components.path = path
    components.queryItems = query.isEmpty ? nil : query
    var request = URLRequest(url: components.url!)
    request.httpMethod = "GET"
    request.setValue("Bearer \(descriptor.token)", forHTTPHeaderField: "Authorization")
    return request
  }

  @discardableResult
  static func check(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else { throw DaemonHTTPError.invalidResponse }
    guard http.statusCode == 200 else {
      let durable = http.value(forHTTPHeaderField: "slipstream-durable-seq").flatMap(Seq.init)
      throw DaemonHTTPError.status(http.statusCode, durableSeq: durable)
    }
    return http
  }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}
