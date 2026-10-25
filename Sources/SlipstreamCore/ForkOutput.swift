import Foundation

public enum AskForkKind: Equatable, Sendable {
  case answer(allowsChangeRequests: Bool)
}

public enum AskForkResult: Equatable, Sendable {
  case answer(forkSessionID: String, reply: String, isChangeRequest: Bool)
}

public enum AskForkError: Error, Equatable, Sendable {
  case timedOut
  case unavailable
  case badReply
}

public struct ForkOutput: Sendable {
  static let allowedTools: Set<String> = ["Read", "Grep", "Glob", "StructuredOutput"]

  private let kind: AskForkKind
  private var isIsolated = false

  public init(kind: AskForkKind) {
    self.kind = kind
  }

  public mutating func read(_ line: Data) throws(AskForkError) -> AskForkResult? {
    guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: line) else { return nil }
    switch (object["type"], object["subtype"]) {
    case (.string("system"), .string("init")):
      guard case .array(let tools)? = object["tools"], case .array(let servers)? = object["mcp_servers"],
        servers.isEmpty
      else { throw .unavailable }
      let names = tools.compactMap { tool -> String? in
        guard case .string(let name) = tool else { return nil }
        return name
      }
      guard names.count == tools.count, names.count == Self.allowedTools.count, Set(names) == Self.allowedTools
      else { throw .unavailable }
      isIsolated = true
      return nil
    case (.string("result"), _):
      guard isIsolated, object["is_error"] != .bool(true) else { throw .unavailable }
      guard case .string(let sessionID)? = object["session_id"], !sessionID.isEmpty,
        case .object(let output)? = object["structured_output"]
      else { throw .badReply }
      return try answer(output, forkSessionID: sessionID)
    default:
      return nil
    }
  }

  private func answer(_ output: [String: JSONValue], forkSessionID: String) throws(AskForkError) -> AskForkResult {
    guard case .string(let reply)? = output["reply"], !QuestionRequest.trim(reply).isEmpty else { throw .badReply }
    switch kind {
    case .answer(let allowsChangeRequests):
      return try answer(output, reply: reply, forkSessionID: forkSessionID, allowsChangeRequests: allowsChangeRequests)
    }
  }

  private func answer(
    _ output: [String: JSONValue], reply: String, forkSessionID: String, allowsChangeRequests: Bool
  ) throws(AskForkError) -> AskForkResult {
    guard allowsChangeRequests else {
      guard output.count == 1 else { throw .badReply }
      return .answer(forkSessionID: forkSessionID, reply: reply, isChangeRequest: false)
    }
    guard output.count == 2, case .bool(let isChangeRequest)? = output["is_change_request"] else { throw .badReply }
    return .answer(forkSessionID: forkSessionID, reply: reply, isChangeRequest: isChangeRequest)
  }
}
