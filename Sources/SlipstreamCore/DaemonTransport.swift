import Foundation

public struct SessionSummary: Equatable, Sendable, Decodable, Identifiable {
  public var id: String
  public var durableSeq: Seq
  public var removed: Bool

  public init(id: String, durableSeq: Seq, removed: Bool) {
    self.id = id
    self.durableSeq = durableSeq
    self.removed = removed
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case durableSeq = "durable_seq"
    case removed
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
  private static func check(_ response: URLResponse) throws -> HTTPURLResponse {
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
