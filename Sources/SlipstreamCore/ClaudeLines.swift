import Foundation

public enum AssistantBlock: Equatable, Sendable {
  case text(String)
  case thinking(String)
  case toolUse(id: String, name: String, input: JSONValue)
}

public enum UserBlock: Equatable, Sendable {
  case text(String)
  case toolResult(toolUseID: String, text: String, isError: Bool)
}

public enum AgentLine: Equatable, Sendable {
  case assistant(uuid: String, timestamp: Date?, blocks: [AssistantBlock])
  case user(uuid: String, timestamp: Date?, isPrompt: Bool, blocks: [UserBlock])
  case result(durationMs: Int, isError: Bool, text: String?)
  case controlRequest(requestID: String, subtype: String, input: JSONValue?)
  case title(String)
  case gap
  case ignored
}

extension AgentLine {
  public static func decode(_ line: Data) -> AgentLine {
    let decoder = JSONDecoder()
    guard let envelope = try? decoder.decode(Envelope.self, from: line) else { return .gap }
    if envelope.isSidechain == true { return .ignored }
    do {
      switch envelope.type {
      case "assistant":
        let wire = try decoder.decode(AssistantWire.self, from: line)
        return .assistant(
          uuid: wire.uuid, timestamp: parseTimestamp(wire.timestamp),
          blocks: try wire.message.content.blocks.compactMap(assistantBlock))
      case "user":
        let wire = try decoder.decode(UserWire.self, from: line)
        let blocks = try wire.message.content.blocks.compactMap(userBlock)
        let hasText = blocks.contains { if case .text = $0 { true } else { false } }
        return .user(
          uuid: wire.uuid, timestamp: parseTimestamp(wire.timestamp),
          isPrompt: wire.promptId != nil && hasText, blocks: blocks)
      case "result":
        let wire = try decoder.decode(ResultWire.self, from: line)
        return .result(durationMs: wire.durationMs, isError: wire.isError, text: wire.result)
      case "control_request":
        let wire = try decoder.decode(ControlRequestWire.self, from: line)
        return .controlRequest(requestID: wire.requestID, subtype: wire.request.subtype, input: wire.request.input)
      case "ai-title":
        return .title(try decoder.decode(TitleWire.self, from: line).aiTitle)
      default:
        return .ignored
      }
    } catch {
      return .gap
    }
  }
}

private struct MalformedBlock: Error {}

private func parseTimestamp(_ string: String?) -> Date? {
  guard let string else { return nil }
  return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
    ?? (try? Date.ISO8601FormatStyle().parse(string))
}

private func assistantBlock(_ block: BlockWire) throws -> AssistantBlock? {
  switch block.type {
  case "text":
    guard let text = block.text else { throw MalformedBlock() }
    return .text(text)
  case "thinking":
    guard let thinking = block.thinking else { throw MalformedBlock() }
    return .thinking(thinking)
  case "tool_use":
    guard let id = block.id, let name = block.name else { throw MalformedBlock() }
    return .toolUse(id: id, name: name, input: block.input ?? .object([:]))
  default:
    return nil
  }
}

private func userBlock(_ block: BlockWire) throws -> UserBlock? {
  switch block.type {
  case "text":
    guard let text = block.text else { throw MalformedBlock() }
    return .text(text)
  case "tool_result":
    guard let toolUseID = block.toolUseID else { throw MalformedBlock() }
    return .toolResult(toolUseID: toolUseID, text: block.content?.joinedText ?? "", isError: block.isError ?? false)
  default:
    return nil
  }
}

private struct Envelope: Decodable {
  var type: String?
  var isSidechain: Bool?
}

private struct AssistantWire: Decodable {
  var uuid: String
  var timestamp: String?
  var message: MessageWire
}

private struct UserWire: Decodable {
  var uuid: String
  var timestamp: String?
  var promptId: String?
  var message: MessageWire
}

private struct MessageWire: Decodable {
  var content: ContentWire
}

private enum ContentWire: Decodable {
  case text(String)
  case blocks([BlockWire])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self = .text(text)
    } else {
      self = .blocks(try container.decode([BlockWire].self))
    }
  }

  var blocks: [BlockWire] {
    switch self {
    case .text(let text): [BlockWire(type: "text", text: text)]
    case .blocks(let blocks): blocks
    }
  }
}

private struct BlockWire: Decodable {
  var type: String
  var text: String?
  var thinking: String?
  var id: String?
  var name: String?
  var input: JSONValue?
  var toolUseID: String?
  var content: ToolResultContentWire?
  var isError: Bool?

  init(type: String, text: String) {
    self.type = type
    self.text = text
  }

  enum CodingKeys: String, CodingKey {
    case type, text, thinking, id, name, input, content
    case toolUseID = "tool_use_id"
    case isError = "is_error"
  }
}

private enum ToolResultContentWire: Decodable {
  case text(String)
  case blocks([ResultBlockWire])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self = .text(text)
    } else {
      self = .blocks(try container.decode([ResultBlockWire].self))
    }
  }

  var joinedText: String {
    switch self {
    case .text(let text):
      text
    case .blocks(let blocks):
      blocks.map { $0.type == "text" ? ($0.text ?? "") : "[\($0.type)]" }.joined(separator: "\n")
    }
  }
}

private struct ResultBlockWire: Decodable {
  var type: String
  var text: String?
}

private struct ResultWire: Decodable {
  var durationMs: Int
  var isError: Bool
  var result: String?

  enum CodingKeys: String, CodingKey {
    case durationMs = "duration_ms"
    case isError = "is_error"
    case result
  }
}

private struct ControlRequestWire: Decodable {
  struct Request: Decodable {
    var subtype: String
    var input: JSONValue?
  }

  var requestID: String
  var request: Request

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case request
  }
}

private struct TitleWire: Decodable {
  var aiTitle: String
}
