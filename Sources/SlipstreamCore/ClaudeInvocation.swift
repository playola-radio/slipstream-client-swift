import Foundation

public enum ClaudeSessionStart: Equatable, Sendable {
  case new(UUID)
  case resume(UUID)
}

public enum ClaudeInvocation {
  public static func arguments(model: String, effort: String, session: ClaudeSessionStart) -> [String] {
    let sessionArgument =
      switch session {
      case .new(let id): "--session-id=\(id.uuidString.lowercased())"
      case .resume(let id): "--resume=\(id.uuidString.lowercased())"
      }
    return [
      "--print", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
      "--thinking=adaptive", "--thinking-display=summarized",
      "--effort=\(effort)", "--model=\(model)", "--max-turns=1000",
      "--permission-prompt-tool=stdio", "--permission-mode=bypassPermissions",
      "--disallowedTools=AskUserQuestion", "--setting-sources=user,project,local",
      sessionArgument,
    ]
  }

  public static func userMessage(_ text: String) -> Data {
    line(
      .object([
        "type": .string("user"),
        "message": .object([
          "role": .string("user"),
          "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]),
      ]))
  }

  public static func interrupt(requestID: String) -> Data {
    line(
      .object([
        "type": .string("control_request"),
        "request_id": .string(requestID),
        "request": .object(["subtype": .string("interrupt")]),
      ]))
  }

  public static func reply(requestID: String, subtype: String, input: JSONValue?) -> Data {
    let response: JSONValue =
      if subtype == "can_use_tool" {
        .object([
          "subtype": .string("success"),
          "request_id": .string(requestID),
          "response": .object([
            "behavior": .string("allow"),
            "updatedInput": input ?? .object([:]),
          ]),
        ])
      } else {
        .object([
          "subtype": .string("error"),
          "request_id": .string(requestID),
          "error": .string("unsupported"),
        ])
      }
    return line(.object(["type": .string("control_response"), "response": response]))
  }

  private static func line(_ value: JSONValue) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    var data = (try? encoder.encode(value)) ?? Data("{}".utf8)
    data.append(0x0A)
    return data
  }
}
