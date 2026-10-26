import Foundation
import IdentifiedCollections
import Sharing

struct TerminalState: Codable, Equatable, Sendable {
  var tabs: IdentifiedArrayOf<TerminalTabRecord> = []
  var selectedTabIDs: [String: TerminalTabRecord.ID] = [:]
}

struct TerminalTabRecord: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var folder: String?
  var kind: Kind

  enum Kind: Codable, Equatable, Sendable {
    case setup(SetupStatus)
    case terminal(number: Int)
  }
}

enum SetupStatus: Codable, Equatable, Sendable {
  case running
  case finished(seconds: Int)
  case failed(exitStatus: Int32?)
  case interrupted
}

extension TerminalState {
  func tabs(shownIn folder: String?, listed: Set<String>) -> [TerminalTabRecord] {
    let orphans = tabs.elements.filter { $0.isOrphanSetup(listed: listed) }
    guard let folder else { return orphans }
    return orphans + tabs.elements.filter { $0.folder == folder && !$0.isOrphanSetup(listed: listed) }
  }

  func nextTerminalNumber(in folder: String) -> Int {
    let numbers = tabs.compactMap { tab -> Int? in
      guard tab.folder == folder, case .terminal(let number) = tab.kind else { return nil }
      return number
    }
    return (numbers.max() ?? 0) + 1
  }

  mutating func moveSetup(_ id: TerminalTabRecord.ID, to folder: String) {
    tabs[id: id]?.folder = folder
    selectedTabIDs[folder] = id
  }
}

extension TerminalTabRecord {
  fileprivate func isOrphanSetup(listed: Set<String>) -> Bool {
    guard case .setup = kind else { return false }
    guard let folder else { return true }
    return !listed.contains(folder)
  }
}

extension SharedKey where Self == FileStorageKey<TerminalState>.Default {
  static var terminalState: Self {
    Self[
      .fileStorage(
        .applicationSupportDirectory
          .appending(component: Bundle.main.bundleIdentifier ?? "com.playola.SlipstreamViewer")
          .appending(component: "terminals.json")),
      default: TerminalState()
    ]
  }
}
