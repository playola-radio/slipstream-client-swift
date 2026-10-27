import CustomDump
import Foundation
import Testing
@testable import SlipstreamViewer

struct WorkspaceSidebarTests {
  static let roots = WorkspaceRoots(
    managed: URL(filePath: "/u/slipstream/workspaces"), conductor: URL(filePath: "/u/conductor/workspaces"))

  static func session(_ root: String) -> SessionOption {
    SessionOption(id: root, label: "Session at \(root)", root: root)
  }

  static func names(_ groups: [SidebarGroup]) -> [[String]] {
    groups.map { [$0.name] + $0.rows.map(SidebarGroup.rowName) }
  }

  @Test func sameRepoUnderBothRootsSharesOneGroup() {
    let groups = SidebarGroup.groups(
      [Self.session("/u/slipstream/workspaces/playola/workspace-9"), Self.session("/u/conductor/workspaces/playola/lisbon-v2")],
      roots: Self.roots)

    expectNoDifference(Self.names(groups), [["playola", "workspace-9", "lisbon-v2"]])
    expectNoDifference(groups.first?.newWorkspaceFolder, "/u/slipstream/workspaces/playola/workspace-9")
  }

  @Test func aFolderOutsideTheRootsIsItsOwnGroup() {
    let groups = SidebarGroup.groups([Self.session("/a/b/c")], roots: Self.roots)

    expectNoDifference(Self.names(groups), [["c", "c"]])
    #expect(groups.first?.repository == nil)
  }

  @Test func onlyExactlyRepoSlashNameGroups() {
    let groups = SidebarGroup.groups(
      [
        Self.session("/u/slipstream/workspaces/r"),
        Self.session("/u/conductor/workspaces/r/w/deeper"),
        Self.session("/u/slipstream/workspaces-old/r/w"),
      ],
      roots: Self.roots)

    expectNoDifference(Self.names(groups), [["r", "r"], ["deeper", "deeper"], ["w", "w"]])
    expectNoDifference(groups.map(\.repository), [nil, nil, nil])
  }

  @Test func aSessionWithoutARootShowsItsLabel() {
    let groups = SidebarGroup.groups([SessionOption(id: "s1", label: "Today 10:02")], roots: Self.roots)

    expectNoDifference(Self.names(groups), [["Today 10:02", "Today 10:02"]])
    #expect(groups.first?.newWorkspaceFolder == nil)
  }

  @Test func withoutRootsEverySessionIsItsOwnGroup() {
    let groups = SidebarGroup.groups(
      [Self.session("/u/slipstream/workspaces/playola/workspace-9"), Self.session("/u/conductor/workspaces/playola/lisbon-v2")],
      roots: nil)

    expectNoDifference(Self.names(groups), [["workspace-9", "workspace-9"], ["lisbon-v2", "lisbon-v2"]])
  }

  @Test func onlyManagedWorkspacesAreArchivable() {
    expectNoDifference(
      [
        "/u/slipstream/workspaces/r/w",
        "/u/conductor/workspaces/r/w",
        "/u/slipstream/workspaces/r",
        "/u/slipstream/workspaces-old/r/w",
      ].map(Self.roots.isArchivable),
      [true, false, false, false])
  }
}
