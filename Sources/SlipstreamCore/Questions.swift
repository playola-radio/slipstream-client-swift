import Foundation

public struct QuestionContext: Codable, Equatable, Sendable {
  public let changeSeq: String
  public let path: String
  public let snapshotSHA256: String
  public let lineStart: Int
  public let lineEnd: Int

  public init(changeSeq: String, path: String, snapshotSHA256: String, lineStart: Int, lineEnd: Int) {
    self.changeSeq = changeSeq
    self.path = path
    self.snapshotSHA256 = snapshotSHA256
    self.lineStart = lineStart
    self.lineEnd = lineEnd
  }

  public var isValid: Bool {
    guard let seq = Seq(changeSeq), seq > .zero else { return false }
    return !path.isEmpty && path.utf8.count <= 4096
      && snapshotSHA256.utf8.count == 64 && snapshotSHA256.utf8.allSatisfy(\.isLowercaseHexDigit)
      && lineStart >= 1 && lineEnd >= lineStart && lineEnd - lineStart < 200
      && lineEnd <= 9_007_199_254_740_991
  }

  enum CodingKeys: String, CodingKey {
    case changeSeq = "change_seq", path, snapshotSHA256 = "snapshot_sha256"
    case lineStart = "line_start", lineEnd = "line_end"
  }
}

public struct QuestionRequest: Encodable, Equatable, Sendable {
  public let sessionID: String
  public let requestID: String
  public let text: String
  public let context: QuestionContext
  let v = 1
  let verb = "ask"

  public init(sessionID: String, requestID: String, text: String, context: QuestionContext) {
    self.sessionID = sessionID
    self.requestID = requestID
    self.text = text
    self.context = context
  }

  public func encoded() throws -> Data {
    guard Self.isCanonicalUUID(sessionID), Self.isCanonicalUUID(requestID) else {
      throw QuestionError.rejected(code: "PROTOCOL", message: "Invalid capture or request identity.")
    }
    guard context.isValid else {
      throw QuestionError.rejected(code: "INVALID_CONTEXT", message: "Select 1–200 source lines from one change.")
    }
    let normalized = Self.trim(text)
    guard !normalized.isEmpty, normalized.utf8.count <= 8192 else {
      throw QuestionError.rejected(code: "INVALID_QUESTION", message: "Use a question of 1–8192 UTF-8 bytes.")
    }
    let bytes = try JSONEncoder().encode(self)
    guard bytes.count <= ControlTransport.maximumMessageBytes else {
      throw QuestionError.rejected(code: "PROTOCOL", message: "The request is too large.")
    }
    return bytes
  }

  public static func trim(_ text: String) -> String {
    let whitespace = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
    return text.trimmingCharacters(in: whitespace)
  }

  static func isCanonicalUUID(_ value: String) -> Bool {
    value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil
  }

  enum CodingKeys: String, CodingKey {
    case v, verb, sessionID = "session_id", requestID = "request_id", text, context
  }
}

public enum QuestionError: Error, Equatable, Sendable {
  case unavailable
  case outcomeUnknown
  case rejected(code: String, message: String)
}

public struct QuestionAcknowledgment: Decodable, Equatable, Sendable {
  public let sessionID: String
  public let requestID: String
  public let questionID: String
  public let seq: Seq
  public let queuedAtMs: Int64
  public let expiresAtMs: Int64
  public let duplicate: Bool

  public static func decode(_ data: Data, for request: QuestionRequest) throws -> Self {
    let decoder = JSONDecoder()
    guard let envelope = try? decoder.decode(Envelope.self, from: data), envelope.v == 1 else {
      throw QuestionError.outcomeUnknown
    }
    if !envelope.ok {
      guard let error = try? decoder.decode(Rejection.self, from: data) else { throw QuestionError.outcomeUnknown }
      throw QuestionError.rejected(code: error.code, message: error.message)
    }
    guard let result = try? decoder.decode(Self.self, from: data),
      result.sessionID == request.sessionID, result.requestID == request.requestID,
      QuestionRequest.isCanonicalUUID(result.questionID), result.seq > .zero,
      result.queuedAtMs >= 0, result.expiresAtMs > result.queuedAtMs,
      result.expiresAtMs <= 9_007_199_254_740_991
    else { throw QuestionError.outcomeUnknown }
    return result
  }

  private struct Envelope: Decodable { let v: Int; let ok: Bool }
  private struct Rejection: Decodable { let code: String; let message: String }
  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id", requestID = "request_id", questionID = "question_id", seq
    case queuedAtMs = "queued_at_ms", expiresAtMs = "expires_at_ms", duplicate
  }
}
