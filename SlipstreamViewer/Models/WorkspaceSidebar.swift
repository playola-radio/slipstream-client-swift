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
  /// The repo's main checkout, remembered so the group outlives its last workspace.
  var repositoryFolder: String?
  var isCreatingWorkspace = false

  var id: String { repository ?? rows[0].id }
  /// The group names a folder, so it never takes a workspace's name.
  var name: String { repository ?? Self.folderName(rows[0]) }
  var newWorkspaceFolder: String? { rows.first?.root ?? repositoryFolder }

  /// Repos A→Z, including remembered repos with no workspaces, then folders outside the
  /// workspace roots. A repo's rows come newest first, in reverse natural folder order
  /// (`workspace-10` above `workspace-9`). The order never depends on input order or on a
  /// workspace's name, so rows never jump. The repo `creatingIn` names gets a group even before
  /// it has a row.
  static func groups(
    _ sessions: some Sequence<SessionOption>, roots: WorkspaceRoots?, repositories: [String: String] = [:],
    creatingIn creatingRepository: String? = nil
  ) -> [SidebarGroup] {
    var rowsByRepository: [String: [SessionOption]] = roots == nil ? [:] : repositories.mapValues { _ in [] }
    var folders: [SidebarGroup] = []
    for session in sessions {
      if let repository = session.root.flatMap({ roots?.repository(of: $0) }) {
        rowsByRepository[repository, default: []].append(session)
      } else {
        folders.append(SidebarGroup(repository: nil, rows: [session]))
      }
    }
    if let creatingRepository { rowsByRepository[creatingRepository, default: []] += [] }
    let repositories = rowsByRepository
      .map { repository, rows in
        SidebarGroup(
          repository: repository, rows: rows.sorted { isInFolderOrder($1, $0) },
          repositoryFolder: repositories[repository], isCreatingWorkspace: repository == creatingRepository)
      }
      .sorted { precedes(($0.name, $0.id), ($1.name, $1.id)) }
    return repositories + folders.sorted { isInFolderOrder($0.rows[0], $1.rows[0]) }
  }

  static func rowName(_ session: SessionOption) -> String {
    session.naming?.userName ?? session.naming?.agentName ?? folderName(session)
  }

  private static func folderName(_ session: SessionOption) -> String {
    session.root.map { URL(filePath: $0).lastPathComponent } ?? session.label
  }

  private static func isInFolderOrder(_ lhs: SessionOption, _ rhs: SessionOption) -> Bool {
    precedes((folderName(lhs), lhs.id), (folderName(rhs), rhs.id))
  }

  private static func precedes(_ lhs: (name: String, id: String), _ rhs: (name: String, id: String)) -> Bool {
    switch lhs.name.localizedStandardCompare(rhs.name) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: lhs.id < rhs.id
    }
  }
}

/// Each sidebar repo group's name and its main checkout.
extension SharedKey where Self == FileStorageKey<[String: String]>.Default {
  static var sidebarRepositories: Self {
    Self[
      .fileStorage(
        .applicationSupportDirectory
          .appending(component: Bundle.main.bundleIdentifier ?? "com.playola.SlipstreamViewer")
          .appending(component: "sidebarRepositories.json")),
      default: [:]
    ]
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
