import Foundation
import IdentifiedCollections
import Sharing

struct ChatTabRecord: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var folder: String
  var model: String
  var effort: ChatEffort
  var isWaiting: Bool
}

enum ChatEffort: String, Codable, CaseIterable, Sendable {
  case low, medium, high, xhigh, max

  var name: String {
    switch self {
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra high"
    case .max: "Max"
    }
  }
}

struct ChatModelChoice: Equatable, Sendable {
  let id: String
  let name: String

  static let all = [
    ChatModelChoice(id: "claude-opus-5-5", name: "Opus 5.5"),
    ChatModelChoice(id: "claude-sonnet-5-5", name: "Sonnet 5.5"),
    ChatModelChoice(id: "claude-haiku-5-5", name: "Haiku 5.5"),
  ]
  static let defaultModel = "claude-opus-5-5"
  static let defaultEffort = ChatEffort.high
}

extension SharedKey where Self == FileStorageKey<IdentifiedArrayOf<ChatTabRecord>>.Default {
  static var chatTabs: Self {
    Self[
      .fileStorage(
        .applicationSupportDirectory
          .appending(component: Bundle.main.bundleIdentifier ?? "com.playola.SlipstreamViewer")
          .appending(component: "chatTabs.json")),
      default: []
    ]
  }
}
