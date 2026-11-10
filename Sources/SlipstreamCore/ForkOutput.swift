import Foundation

public enum AskForkKind: Equatable, Sendable {
  case answer(allowsChangeRequests: Bool)
  case report
}

public enum AskForkResult: Equatable, Sendable {
  case answer(forkSessionID: String, reply: String, isChangeRequest: Bool)
  case report(reply: String, outcome: ReportOutcome)
}

public enum AskForkError: Error, Equatable, Sendable {
  case timedOut
  case unavailable(String)
  case badReply(String)
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
      guard case .array(let tools)? = object["tools"], case .array(let servers)? = object["mcp_servers"]
      else { throw .unavailable("The read-only copy of the chat didn't report its tools or MCP servers.") }
      let names = tools.compactMap { tool -> String? in
        guard case .string(let name) = tool else { return nil }
        return name
      }
      guard servers.isEmpty, names.count == tools.count, Set(names) == Self.allowedTools, names.count == Self.allowedTools.count
      else { throw .unavailable(Self.isolationDetail(tools: names, servers: servers)) }
      isIsolated = true
      return nil
    case (.string("result"), _):
      guard object["is_error"] != .bool(true) else { throw .unavailable(Self.errorDetail(object)) }
      guard isIsolated else { throw .badReply("Claude Code answered before reporting its setup.") }
      guard case .string(let sessionID)? = object["session_id"], !sessionID.isEmpty else {
        throw .badReply("The reply had no session id.")
      }
      guard case .object(let output)? = object["structured_output"] else {
        throw .badReply("The reply had no structured answer.")
      }
      return try answer(output, forkSessionID: sessionID)
    default:
      return nil
    }
  }

  private static func isolationDetail(tools: [String], servers: [JSONValue]) -> String {
    let serverNames = servers.compactMap { server -> String? in
      guard case .object(let fields) = server, case .string(let name)? = fields["name"] else { return nil }
      return name
    }
    let toolText = tools.isEmpty ? "none" : tools.sorted().joined(separator: ", ")
    let serverText =
      servers.isEmpty ? "none" : serverNames.count == servers.count ? serverNames.joined(separator: ", ") : "\(servers.count)"
    return DiagnosticText.line(
      "The read-only copy of the chat wasn't isolated. It had tools \(toolText) and MCP servers \(serverText).")
  }

  private static func errorDetail(_ object: [String: JSONValue]) -> String {
    DiagnosticText.line("Claude Code reported an error: \(errorText(object) ?? "no details")")
  }

  private static func errorText(_ object: [String: JSONValue]) -> String? {
    if case .string(let text)? = object["result"], !DiagnosticText.line(text).isEmpty {
      return DiagnosticText.line(text)
    }
    if case .array(let errors)? = object["errors"] {
      let texts = errors.compactMap { error -> String? in
        guard case .string(let text) = error, !DiagnosticText.line(text).isEmpty else { return nil }
        return DiagnosticText.line(text)
      }
      if !texts.isEmpty { return DiagnosticText.line(texts.joined(separator: " · ")) }
    }
    if case .string(let text)? = object["subtype"], text != "success", !DiagnosticText.line(text).isEmpty {
      return DiagnosticText.line(text)
    }
    return nil
  }

  private func answer(_ output: [String: JSONValue], forkSessionID: String) throws(AskForkError) -> AskForkResult {
    guard case .string(let reply)? = output["reply"] else { throw .badReply("The reply had no text.") }
    guard !QuestionRequest.trim(reply).isEmpty else { throw .badReply("The reply was empty.") }
    switch kind {
    case .answer(let allowsChangeRequests):
      return try answer(output, reply: reply, forkSessionID: forkSessionID, allowsChangeRequests: allowsChangeRequests)
    case .report:
      guard case .string(let raw)? = output["outcome"], let outcome = ReportOutcome(rawValue: raw)
      else { throw .badReply("The report had no recognized outcome.") }
      guard output.count == 2 else { throw .badReply("The report had fields other than its reply and outcome.") }
      return .report(reply: reply, outcome: outcome)
    }
  }

  private func answer(
    _ output: [String: JSONValue], reply: String, forkSessionID: String, allowsChangeRequests: Bool
  ) throws(AskForkError) -> AskForkResult {
    guard allowsChangeRequests else {
      guard output.count == 1 else { throw .badReply("The reply had fields other than its text.") }
      return .answer(forkSessionID: forkSessionID, reply: reply, isChangeRequest: false)
    }
    guard case .bool(let isChangeRequest)? = output["is_change_request"] else {
      throw .badReply("The reply had no change-request flag.")
    }
    guard output.count == 2 else { throw .badReply("The reply had fields other than its text and change-request flag.") }
    return .answer(forkSessionID: forkSessionID, reply: reply, isChangeRequest: isChangeRequest)
  }
}
