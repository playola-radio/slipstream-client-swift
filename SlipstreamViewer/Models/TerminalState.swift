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
  /// A workspace shows only its own tabs, after any Setup still waiting for a workspace.
  func tabs(shownIn folder: String?) -> [TerminalTabRecord] {
    let folderless = tabs.elements.filter { $0.folder == nil }
    guard let folder else { return folderless }
    return folderless + tabs.elements.filter { $0.folder == folder }
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
    selectedTabIDs = selectedTabIDs.filter { $0.value != id }
    selectedTabIDs[folder] = id
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
