import Foundation

public enum TurnEnding: Equatable, Sendable { case completed, failed, stopped }

public enum ToolStatus: Equatable, Sendable { case running, done, failed, stopped }

public struct TranscriptItem: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case userMessage(String)
    case reply(String)
    case thinking(String)
    case toolCall(name: String, target: String?, status: ToolStatus, detail: String?)
    case turnFooter(ending: TurnEnding, duration: Duration, time: Date)
    case gap
  }

  public let id: String
  public var kind: Kind

  public init(id: String, kind: Kind) {
    self.id = id
    self.kind = kind
  }
}

public struct TranscriptProjection: Equatable, Sendable {
  public private(set) var items: [TranscriptItem]
  private var gapCount = 0

  public init() {
    items = []
  }

  public static func history(_ lines: [AgentLine]) -> TranscriptProjection {
    var projection = TranscriptProjection()
    var turn: HistoryTurn?
    for line in lines {
      if case .user(_, _, true, _) = line {
        if let turn { projection.closeHistoryTurn(turn) }
        turn = HistoryTurn()
      }
      projection.apply(line)
      switch line {
      case .assistant(let uuid, let timestamp, _):
        turn?.note(uuid: uuid, timestamp: timestamp)
      case .user(let uuid, let timestamp, _, let blocks):
        turn?.note(uuid: uuid, timestamp: timestamp)
        if blocks.contains(where: { if case .text(let text) = $0 { isInterruptMarker(text) } else { false } }) {
          turn?.isInterrupted = true
        }
      default:
        break
      }
    }
    if let turn { projection.closeHistoryTurn(turn) }
    projection.stopRunningTools()
    return projection
  }

  public mutating func userSent(_ text: String, id: String) {
    items.append(TranscriptItem(id: id, kind: .userMessage(text)))
  }

  public mutating func apply(_ line: AgentLine) {
    switch line {
    case .assistant(let uuid, _, let blocks):
      for (index, block) in blocks.enumerated() {
        let id = "\(uuid)#\(index)"
        switch block {
        case .text(let text) where !text.isEmpty:
          items.append(TranscriptItem(id: id, kind: .reply(text)))
        case .thinking(let text) where !text.isEmpty:
          items.append(TranscriptItem(id: id, kind: .thinking(text)))
        case .toolUse(let toolID, let name, let input):
          items.append(
            TranscriptItem(
              id: toolID,
              kind: .toolCall(name: name, target: Self.target(of: name, input: input), status: .running, detail: nil)))
        default:
          break
        }
      }
    case .user(let uuid, _, let isPrompt, let blocks):
      for (index, block) in blocks.enumerated() {
        switch block {
        case .text(let text) where isPrompt && !Self.isInterruptMarker(text):
          items.append(TranscriptItem(id: "\(uuid)#\(index)", kind: .userMessage(text)))
        case .toolResult(let toolUseID, let text, let isError):
          finishTool(toolUseID, text: text, isError: isError)
        default:
          break
        }
      }
    case .gap:
      items.append(TranscriptItem(id: "gap#\(gapCount)", kind: .gap))
      gapCount += 1
    case .result, .controlRequest, .title, .ignored:
      break
    }
  }

  public mutating func endTurn(_ ending: TurnEnding, duration: Duration, at time: Date, id: String) {
    stopRunningTools()
    items.append(TranscriptItem(id: id, kind: .turnFooter(ending: ending, duration: duration, time: time)))
  }

  public func replyText(endingAt footerID: String) -> String {
    guard let footerIndex = items.firstIndex(where: { $0.id == footerID }) else { return "" }
    var replies: [String] = []
    for item in items[..<footerIndex].reversed() {
      switch item.kind {
      case .turnFooter: return replies.reversed().joined(separator: "\n\n")
      case .reply(let text): replies.append(text)
      default: break
      }
    }
    return replies.reversed().joined(separator: "\n\n")
  }

  private struct HistoryTurn {
    var first: Date?
    var last: Date?
    var lastUUID: String?
    var isInterrupted = false

    mutating func note(uuid: String, timestamp: Date?) {
      lastUUID = uuid
      guard let timestamp else { return }
      first = first ?? timestamp
      last = timestamp
    }
  }

  private mutating func closeHistoryTurn(_ turn: HistoryTurn) {
    guard let first = turn.first, let last = turn.last, let lastUUID = turn.lastUUID else { return }
    endTurn(
      turn.isInterrupted ? .stopped : .completed,
      duration: .seconds(last.timeIntervalSince(first)),
      at: last,
      id: "\(lastUUID)#footer")
  }

  private mutating func finishTool(_ toolUseID: String, text: String, isError: Bool) {
    guard
      let index = items.lastIndex(where: { $0.id == toolUseID }),
      case .toolCall(let name, let target, _, _) = items[index].kind
    else { return }
    items[index].kind = .toolCall(
      name: name, target: target, status: isError ? .failed : .done, detail: text)
  }

  private mutating func stopRunningTools() {
    for index in items.indices {
      if case .toolCall(let name, let target, .running, let detail) = items[index].kind {
        items[index].kind = .toolCall(name: name, target: target, status: .stopped, detail: detail)
      }
    }
  }

  private static func isInterruptMarker(_ text: String) -> Bool {
    text.hasPrefix("[Request interrupted by user")
  }

  private static func target(of name: String, input: JSONValue) -> String? {
    guard case .object(let fields) = input else { return nil }
    switch name {
    case "Bash":
      guard case .string(let command)? = fields["command"] else { return nil }
      return command
    case "Read", "Write", "Edit", "MultiEdit":
      guard case .string(let path)? = fields["file_path"] else { return nil }
      return URL(fileURLWithPath: path).lastPathComponent
    default:
      return nil
    }
  }
}
