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

public enum QuestionVerb: Equatable, Sendable {
  case ask(bindingGeneration: String?)
  case recordExchange(answerText: String, conversation: ExchangeConversation, relay: ExchangeRelay? = nil)
}

public struct ExchangeRelay: Codable, Equatable, Sendable {
  public var relayID: String
  public var chatSessionID: String

  public init(relayID: String, chatSessionID: String) {
    self.relayID = relayID
    self.chatSessionID = chatSessionID
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(relayID, forKey: .relayID)
    try container.encode(chatSessionID.lowercased(), forKey: .chatSessionID)
  }

  enum CodingKeys: String, CodingKey {
    case relayID = "relay_id", chatSessionID = "chat_session_id"
  }
}

public struct ExchangeConversation: Encodable, Equatable, Sendable {
  public let parentSessionID: String
  public let forkSessionID: String

  public init(parentSessionID: String, forkSessionID: String) {
    self.parentSessionID = parentSessionID
    self.forkSessionID = forkSessionID
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode("claude-code", forKey: .harness)
    try container.encode(parentSessionID.lowercased(), forKey: .parentSessionID)
    try container.encode(forkSessionID.lowercased(), forKey: .forkSessionID)
  }

  enum CodingKeys: String, CodingKey {
    case harness, parentSessionID = "parent_session_id", forkSessionID = "fork_session_id"
  }
}

public struct QuestionRequest: Encodable, Equatable, Sendable {
  public static let maximumTextBytes = 8192

  public let sessionID: String
  public let requestID: String
  public let text: String
  public let context: QuestionContext
  public let replyToQuestionID: String?
  public let verb: QuestionVerb

  public init(
    sessionID: String, requestID: String, text: String, context: QuestionContext, replyToQuestionID: String? = nil,
    verb: QuestionVerb = .ask(bindingGeneration: nil)
  ) {
    self.sessionID = sessionID
    self.requestID = requestID
    self.text = text
    self.context = context
    self.replyToQuestionID = replyToQuestionID
    self.verb = verb
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(1, forKey: .v)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(requestID, forKey: .requestID)
    try container.encode(text, forKey: .text)
    try container.encode(context, forKey: .context)
    try container.encodeIfPresent(replyToQuestionID, forKey: .replyToQuestionID)
    switch verb {
    case .ask(let bindingGeneration):
      try container.encode("ask", forKey: .verb)
      try container.encodeIfPresent(bindingGeneration, forKey: .bindingGeneration)
    case .recordExchange(let answerText, let conversation, let relay):
      try container.encode("record_question_exchange", forKey: .verb)
      try container.encode(answerText, forKey: .answerText)
      try container.encode(conversation, forKey: .conversation)
      try container.encodeIfPresent(relay, forKey: .relay)
    }
  }

  public func encoded() throws -> Data {
    guard Self.isCanonicalUUID(sessionID), Self.isCanonicalUUID(requestID),
      replyToQuestionID.map(Self.isCanonicalUUID) ?? true, relay.map({ Self.isCanonicalUUID($0.relayID) }) ?? true
    else {
      throw QuestionError.rejected(code: "PROTOCOL", message: "Invalid capture or request identity.")
    }
    guard context.isValid else {
      throw QuestionError.rejected(code: "INVALID_CONTEXT", message: "Select 1–200 source lines from one change.")
    }
    let normalized = Self.trim(text)
    guard !normalized.isEmpty, normalized.utf8.count <= Self.maximumTextBytes else {
      throw QuestionError.rejected(code: "INVALID_QUESTION", message: "Use a question of 1–8192 UTF-8 bytes.")
    }
    return try ControlLine.encode(self)
  }

  private var relay: ExchangeRelay? {
    guard case .recordExchange(_, _, let relay) = verb else { return nil }
    return relay
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
    case replyToQuestionID = "reply_to_question_id"
    case bindingGeneration = "binding_generation"
    case answerText = "answer_text", conversation, relay
  }
}

public enum ReportOutcome: String, Equatable, Sendable {
  case done
  case notDoneYet = "not_done_yet"
}

public enum RelayUpdate: Equatable, Sendable, Encodable {
  case sent(chatSessionID: String)
  case pickedUp
  case notDelivered
  case reported(ReportOutcome, text: String)

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .sent(let chatSessionID):
      try container.encode("sent", forKey: .kind)
      try container.encode(chatSessionID.lowercased(), forKey: .chatSessionID)
    case .pickedUp:
      try container.encode("picked_up", forKey: .kind)
    case .notDelivered:
      try container.encode("not_delivered", forKey: .kind)
    case .reported(let outcome, let text):
      try container.encode("reported", forKey: .kind)
      try container.encode(outcome.rawValue, forKey: .outcome)
      try container.encode(text, forKey: .text)
    }
  }

  enum CodingKeys: String, CodingKey {
    case kind, chatSessionID = "chat_session_id", outcome, text
  }
}

public struct QuestionRelayUpdateRequest: Encodable, Equatable, Sendable {
  public let sessionID: String
  public let requestID: String
  public let questionID: String
  public let relayID: String
  public let update: RelayUpdate

  public init(sessionID: String, requestID: String, questionID: String, relayID: String, update: RelayUpdate) {
    self.sessionID = sessionID
    self.requestID = requestID
    self.questionID = questionID
    self.relayID = relayID
    self.update = update
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(1, forKey: .v)
    try container.encode(RelayCapabilityRequest.verb, forKey: .verb)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(requestID, forKey: .requestID)
    try container.encode(questionID, forKey: .questionID)
    try container.encode(relayID, forKey: .relayID)
    try container.encode(update, forKey: .update)
  }

  public func encoded() throws -> Data {
    guard [sessionID, requestID, questionID, relayID].allSatisfy(QuestionRequest.isCanonicalUUID) else {
      throw QuestionError.rejected(code: "PROTOCOL", message: "Invalid capture or request identity.")
    }
    return try ControlLine.encode(self)
  }

  enum CodingKeys: String, CodingKey {
    case v, verb, sessionID = "session_id", requestID = "request_id", questionID = "question_id"
    case relayID = "relay_id", update
  }
}

/// The relay verb with no body: a daemon that has the verb refuses it as malformed, one that doesn't as unknown.
struct RelayCapabilityRequest: Encodable {
  static let verb = "record_question_relay_update"
  let sessionID: String

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: QuestionRelayUpdateRequest.CodingKeys.self)
    try container.encode(1, forKey: .v)
    try container.encode(Self.verb, forKey: .verb)
    try container.encode(sessionID, forKey: .sessionID)
  }

  static func supportsRelays(_ data: Data) throws -> Bool {
    do {
      try ControlReply.check(data)
    } catch QuestionError.rejected(code: "PROTOCOL", let message) {
      return message != "unknown verb: \(verb)"
    }
    throw QuestionError.outcomeUnknown
  }
}

enum ControlLine {
  static func encode(_ request: some Encodable) throws -> Data {
    let bytes = try JSONEncoder().encode(request)
    guard bytes.count <= ControlTransport.maximumMessageBytes else {
      throw QuestionError.rejected(code: "PROTOCOL", message: "The request is too large.")
    }
    return bytes
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
    try ControlReply.check(data)
    guard let result = try? JSONDecoder().decode(Self.self, from: data),
      result.sessionID == request.sessionID, result.requestID == request.requestID,
      QuestionRequest.isCanonicalUUID(result.questionID), result.seq > .zero,
      result.queuedAtMs >= 0, result.expiresAtMs > result.queuedAtMs,
      result.expiresAtMs <= 9_007_199_254_740_991
    else { throw QuestionError.outcomeUnknown }
    return result
  }

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id", requestID = "request_id", questionID = "question_id", seq
    case queuedAtMs = "queued_at_ms", expiresAtMs = "expires_at_ms", duplicate
  }
}

public struct ExchangeAcknowledgment: Decodable, Equatable, Sendable {
  public let sessionID: String
  public let requestID: String
  public let questionID: String
  public let seq: Seq
  public let duplicate: Bool

  public init(sessionID: String, requestID: String, questionID: String, seq: Seq, duplicate: Bool) {
    self.sessionID = sessionID
    self.requestID = requestID
    self.questionID = questionID
    self.seq = seq
    self.duplicate = duplicate
  }

  public static func decode(_ data: Data, for request: QuestionRequest) throws -> Self {
    try ControlReply.check(data)
    guard let result = try? JSONDecoder().decode(Self.self, from: data),
      result.sessionID == request.sessionID, result.requestID == request.requestID,
      QuestionRequest.isCanonicalUUID(result.questionID), result.seq > .zero
    else { throw QuestionError.outcomeUnknown }
    return result
  }

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id", requestID = "request_id", questionID = "question_id", seq, duplicate
  }
}

public struct RelayAcknowledgment: Decodable, Equatable, Sendable {
  public let sessionID: String
  public let requestID: String
  public let questionID: String
  public let relayID: String
  public let seq: Seq
  public let duplicate: Bool

  public init(sessionID: String, requestID: String, questionID: String, relayID: String, seq: Seq, duplicate: Bool) {
    self.sessionID = sessionID
    self.requestID = requestID
    self.questionID = questionID
    self.relayID = relayID
    self.seq = seq
    self.duplicate = duplicate
  }

  public static func decode(_ data: Data, for request: QuestionRelayUpdateRequest) throws -> Self {
    try ControlReply.check(data)
    guard let result = try? JSONDecoder().decode(Self.self, from: data),
      result.sessionID == request.sessionID, result.requestID == request.requestID,
      result.questionID == request.questionID, result.relayID == request.relayID, result.seq > .zero
    else { throw QuestionError.outcomeUnknown }
    return result
  }

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id", requestID = "request_id", questionID = "question_id", relayID = "relay_id"
    case seq, duplicate
  }
}

enum ControlReply {
  static func check(_ data: Data) throws {
    let decoder = JSONDecoder()
    guard let envelope = try? decoder.decode(Envelope.self, from: data), envelope.v == 1 else {
      throw QuestionError.outcomeUnknown
    }
    if !envelope.ok {
      guard let error = try? decoder.decode(Rejection.self, from: data) else { throw QuestionError.outcomeUnknown }
      throw QuestionError.rejected(code: error.code, message: error.message)
    }
  }

  private struct Envelope: Decodable { let v: Int; let ok: Bool }
  private struct Rejection: Decodable { let code: String; let message: String }
}
