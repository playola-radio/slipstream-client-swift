import CustomDump
import Foundation
import SlipstreamCore
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

    expectNoDifference(Self.names(groups), [["playola", "lisbon-v2", "workspace-9"]])
    expectNoDifference(groups.first?.newWorkspaceFolder, "/u/conductor/workspaces/playola/lisbon-v2")
  }

  @Test func aFolderOutsideTheRootsIsItsOwnGroup() {
    let groups = SidebarGroup.groups([Self.session("/a/b/c")], roots: Self.roots)

    expectNoDifference(Self.names(groups), [["c", "c"]])
    #expect(groups.first?.repository == nil)
  }

  @Test func aNamedFolderGroupKeepsTheFolderName() {
    var session = Self.session("/a/b/c")
    session.naming = SessionNaming(agentName: "Agent's name", userName: "My name")

    let groups = SidebarGroup.groups([session], roots: Self.roots)

    expectNoDifference(Self.names(groups), [["c", "My name"]])
  }

  @Test func onlyExactlyRepoSlashNameGroups() {
    let groups = SidebarGroup.groups(
      [
        Self.session("/u/slipstream/workspaces/r"),
        Self.session("/u/conductor/workspaces/r/w/deeper"),
        Self.session("/u/slipstream/workspaces-old/r/w"),
      ],
      roots: Self.roots)

    expectNoDifference(Self.names(groups), [["deeper", "deeper"], ["r", "r"], ["w", "w"]])
    expectNoDifference(groups.map(\.repository), [nil, nil, nil])
  }

  @Test(arguments: [
    (SessionNaming(agentName: "Agent's name", userName: "My name"), "My name"),
    (SessionNaming(agentName: "Agent's name", userName: nil), "Agent's name"),
    (SessionNaming(agentName: nil, userName: nil), "w"),
    (nil, "w"),
  ])
  func rowNamePrefersUserThenAgentThenFolder(naming: SessionNaming?, name: String) {
    var session = Self.session("/u/conductor/workspaces/r/w")
    session.naming = naming

    expectNoDifference(SidebarGroup.rowName(session), name)
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

    expectNoDifference(Self.names(groups), [["lisbon-v2", "lisbon-v2"], ["workspace-9", "workspace-9"]])
  }

  @Test func reposComeAToZThenFolderGroups() {
    let groups = SidebarGroup.groups(
      [
        Self.session("/u/slipstream/workspaces/zeta/w"),
        Self.session("/x/standalone-b"),
        Self.session("/u/conductor/workspaces/Beta/w"),
        Self.session("/x/standalone-a"),
        Self.session("/u/slipstream/workspaces/alpha/w"),
      ],
      roots: Self.roots)

    expectNoDifference(groups.map(\.name), ["alpha", "Beta", "zeta", "standalone-a", "standalone-b"])
  }

  @Test func rowsComeInNaturalFolderOrder() {
    let groups = SidebarGroup.groups(
      [
        Self.session("/u/slipstream/workspaces/r/workspace-10"),
        Self.session("/u/slipstream/workspaces/r/workspace-2"),
        Self.session("/u/conductor/workspaces/r/Lisbon"),
        Self.session("/u/slipstream/workspaces/r/workspace-1"),
      ],
      roots: Self.roots)

    expectNoDifference(Self.names(groups), [["r", "Lisbon", "workspace-1", "workspace-2", "workspace-10"]])
  }

  @Test func rowsInTheSameFolderComeInIDOrder() {
    let groups = SidebarGroup.groups(
      [
        SessionOption(id: "b", label: "b", root: "/u/slipstream/workspaces/r/w"),
        SessionOption(id: "a", label: "a", root: "/u/conductor/workspaces/r/w"),
      ],
      roots: Self.roots)

    expectNoDifference(groups.first?.rows.map(\.id), ["a", "b"])
  }

  @Test func inputOrderDoesNotChangeTheOrder() {
    let sessions = [
      Self.session("/u/slipstream/workspaces/r/workspace-2"),
      Self.session("/u/slipstream/workspaces/q/workspace-1"),
      Self.session("/x/solo"),
      Self.session("/u/slipstream/workspaces/r/workspace-1"),
      Self.session("/u/conductor/workspaces/q/lisbon"),
    ]
    let expected = SidebarGroup.groups(sessions, roots: Self.roots)

    for shift in 1..<sessions.count {
      let rotated = Array(sessions[shift...] + sessions[..<shift])
      expectNoDifference(SidebarGroup.groups(rotated, roots: Self.roots), expected)
      expectNoDifference(SidebarGroup.groups(rotated.reversed(), roots: Self.roots), expected)
    }
  }

  @Test func aNameNeverMovesARow() {
    var named = Self.session("/u/slipstream/workspaces/r/workspace-2")
    named.naming = SessionNaming(agentName: "aaa first by name", userName: nil)

    let groups = SidebarGroup.groups(
      [named, Self.session("/u/slipstream/workspaces/r/workspace-1")], roots: Self.roots)

    expectNoDifference(Self.names(groups), [["r", "workspace-1", "aaa first by name"]])
  }

  @Test func aRememberedRepoKeepsItsGroupWithoutWorkspaces() {
    let groups = SidebarGroup.groups(
      [Self.session("/u/slipstream/workspaces/zeta/w")], roots: Self.roots,
      repositories: ["alpha": "/code/alpha", "zeta": "/code/zeta"])

    expectNoDifference(Self.names(groups), [["alpha"], ["zeta", "w"]])
    expectNoDifference(groups.map(\.newWorkspaceFolder), ["/code/alpha", "/u/slipstream/workspaces/zeta/w"])
  }

  @Test func rememberedReposWaitForTheRoots() {
    #expect(SidebarGroup.groups([], roots: nil, repositories: ["alpha": "/code/alpha"]).isEmpty)
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
