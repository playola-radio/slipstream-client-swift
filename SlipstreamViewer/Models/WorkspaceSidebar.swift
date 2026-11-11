import Foundation
import Sharing
import SlipstreamCore

/// Where `slipstream workspace create` and Conductor put workspaces, as normalized paths.
struct WorkspaceRoots: Equatable, Sendable {
  var managed: String
  var conductor: String

  init(managed: URL, conductor: URL) {
    self.managed = ChangeStreamPageModel.normalizedFolder(managed.path)
    self.conductor = ChangeStreamPageModel.normalizedFolder(conductor.path)
  }

  /// `<repo>` when `folder` is exactly `<root>/<repo>/<name>` under either root.
  func repository(of folder: String) -> String? {
    guard let root = [managed, conductor].first(where: { ManagedWorkspacePath.contains(folder, root: $0) })
    else { return nil }
    return URL(filePath: folder).pathComponents[URL(filePath: root).pathComponents.count]
  }

  func isArchivable(_ folder: String) -> Bool {
    ManagedWorkspacePath.contains(folder, root: managed)
  }
}

struct SidebarGroup: Identifiable, Equatable, Sendable {
  var repository: String?
  var rows: [SessionOption]

  var id: String { repository ?? rows[0].id }
  var name: String { repository ?? Self.rowName(rows[0]) }
  var newWorkspaceFolder: String? { rows.first?.root }

  static func groups(_ sessions: some Sequence<SessionOption>, roots: WorkspaceRoots?) -> [SidebarGroup] {
    var groups: [SidebarGroup] = []
    for session in sessions {
      let repository = session.root.flatMap { roots?.repository(of: $0) }
      if let repository, let index = groups.firstIndex(where: { $0.repository == repository }) {
        groups[index].rows.append(session)
      } else {
        groups.append(SidebarGroup(repository: repository, rows: [session]))
      }
    }
    return groups
  }

  static func rowName(_ session: SessionOption) -> String {
    session.naming?.userName ?? session.naming?.agentName
      ?? session.root.map { URL(filePath: $0).lastPathComponent } ?? session.label
  }
}

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  static var isSidebarHidden: Self {
    Self[.appStorage("isSidebarHidden"), default: false]
  }

  static var isRightPaneHidden: Self {
    Self[.appStorage("isRightPaneHidden"), default: false]
  }
}

extension SharedKey where Self == AppStorageKey<Double>.Default {
  static var sidebarWidth: Self {
    Self[.appStorage("sidebarWidth"), default: DesignTokens.Workspace.sidebarWidth]
  }

  static var chatWidth: Self {
    Self[.appStorage("chatWidth"), default: DesignTokens.Workspace.chatWidth]
  }
}
