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
    if envelope.isSidechain == true || envelope.isMeta == true { return .ignored }
    do {
      switch envelope.type {
      case "assistant":
        let wire = try decoder.decode(AssistantWire.self, from: line)
        return .assistant(
          uuid: wire.uuid, timestamp: parseTimestamp(wire.timestamp),
          blocks: wire.message.content.blocks.compactMap(assistantBlock))
      case "user":
        let wire = try decoder.decode(UserWire.self, from: line)
        let blocks = wire.message.content.blocks.compactMap(userBlock)
        let hasText = blocks.contains { if case .text = $0 { true } else { false } }
        return .user(
          uuid: wire.uuid, timestamp: parseTimestamp(wire.timestamp),
          isPrompt: wire.promptId != nil && hasText, blocks: blocks)
      case "result":
        let wire = try decoder.decode(ResultWire.self, from: line)
        return .result(
          durationMs: wire.durationMs, isError: wire.isError,
          text: wire.result ?? wire.errors?.joined(separator: "\n"))
      case "control_request":
        let wire = try decoder.decode(ControlRequestWire.self, from: line)
        if wire.request.subtype == "can_use_tool" && wire.request.input == nil { return .gap }
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

private func parseTimestamp(_ string: String?) -> Date? {
  guard let string else { return nil }
  return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
    ?? (try? Date.ISO8601FormatStyle().parse(string))
}

private func assistantBlock(_ block: BlockWire) -> AssistantBlock? {
  switch block {
  case .text(let text): .text(text)
  case .thinking(let thinking): .thinking(thinking)
  case .toolUse(let id, let name, let input): .toolUse(id: id, name: name, input: input)
  case .toolResult, .other: nil
  }
}

private func userBlock(_ block: BlockWire) -> UserBlock? {
  switch block {
  case .text(let text): .text(typedCommand(text))
  case .toolResult(let toolUseID, let text, let isError): .toolResult(toolUseID: toolUseID, text: text, isError: isError)
  case .thinking, .toolUse, .other: nil
  }
}

/// A slash command is saved as `<command-name>/x</command-name>` (plus message and args tags);
/// show it as the user typed it.
private func typedCommand(_ text: String) -> String {
  guard text.hasPrefix("<command-"), let name = tagContent("command-name", in: text) else { return text }
  let arguments = tagContent("command-args", in: text) ?? ""
  return arguments.isEmpty ? name : "\(name) \(arguments)"
}

private func tagContent(_ tag: String, in text: String) -> String? {
  guard let open = text.range(of: "<\(tag)>"),
    let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
  else { return nil }
  return String(text[open.upperBound..<close.lowerBound])
}

private struct Envelope: Decodable {
  var type: String?
  var isSidechain: Bool?
  var isMeta: Bool?
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
    case .text(let text): [.text(text)]
    case .blocks(let blocks): blocks
    }
  }
}

private enum BlockWire: Decodable {
  case text(String)
  case thinking(String)
  case toolUse(id: String, name: String, input: JSONValue)
  case toolResult(toolUseID: String, text: String, isError: Bool)
  case other

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "text":
      self = .text(try container.decode(String.self, forKey: .text))
    case "thinking":
      self = .thinking(try container.decode(String.self, forKey: .thinking))
    case "tool_use":
      self = .toolUse(
        id: try container.decode(String.self, forKey: .id),
        name: try container.decode(String.self, forKey: .name),
        input: try container.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:]))
    case "tool_result":
      self = .toolResult(
        toolUseID: try container.decode(String.self, forKey: .toolUseID),
        text: try container.decodeIfPresent(ToolResultContentWire.self, forKey: .content)?.joinedText ?? "",
        isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false)
    default:
      self = .other
    }
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
      blocks.map(\.text).joined(separator: "\n")
    }
  }
}

private struct ResultBlockWire: Decodable {
  var text: String

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    text = type == "text" ? try container.decode(String.self, forKey: .text) : "[\(type)]"
  }

  enum CodingKeys: String, CodingKey {
    case type, text
  }
}

private struct ResultWire: Decodable {
  var durationMs: Int
  var isError: Bool
  var result: String?
  var errors: [String]?

  enum CodingKeys: String, CodingKey {
    case durationMs = "duration_ms"
    case isError = "is_error"
    case result, errors
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
