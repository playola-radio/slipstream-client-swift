import CustomDump
import Foundation
import Testing

@testable import SlipstreamViewer

struct WorkspaceClientTests {
  @Test func managedRootFollowsHome() {
    expectNoDifference(
      WorkspaceClient.managedRoot(environment: ["HOME": "/nonexistent-home/x"]).path,
      "/nonexistent-home/x/slipstream/workspaces")
  }

  @Test func successHasNoFailureText() {
    #expect(WorkspaceClient.failureText(output: "archived /w/workspace-1\n", status: 0) == nil)
  }

  @Test func failureReturnsTheTailWithoutBlankLines() {
    let output = "\nslipstream: the workspace has uncommitted or untracked changes.\n"

    expectNoDifference(
      WorkspaceClient.failureText(output: output, status: 1),
      "slipstream: the workspace has uncommitted or untracked changes.\nslipstream exited with status 1."
    )
  }

  @Test func failureWithoutOutputNamesTheExitStatus() {
    expectNoDifference(WorkspaceClient.failureText(output: "", status: 9), "slipstream exited with status 9.")
  }

  @Test func failureTailIsCappedAtTwelveLines() {
    let output = (1...20).map { "line \($0)" }.joined(separator: "\n")

    expectNoDifference(
      WorkspaceClient.failureText(output: output, status: 1),
      ((9...20).map { "line \($0)" } + ["slipstream exited with status 1."]).joined(separator: "\n")
    )
  }

  @Test func archiveRunsShim() async throws {
    let shim = try makeShim(#"echo "ran $0 $*"; exit 3"#)
    defer { try? FileManager.default.removeItem(at: shim.deletingLastPathComponent()) }

    let failure = await WorkspaceClient.runShim(
      shim.path, ["workspace", "archive", "/w/one", "--store", "/s"], environment: [:])

    expectNoDifference(
      failure, "ran \(shim.path) workspace archive /w/one --store /s\nslipstream exited with status 3.")
  }

  @Test func missingShimReportsShimError() async throws {
    let shim = try makeShim(
      #"echo "slipstream: no runtime at /rt/current; open Slipstream once." >&2; exit 127"#)
    defer { try? FileManager.default.removeItem(at: shim.deletingLastPathComponent()) }

    let failure = await WorkspaceClient.runShim(shim.path, ["workspace", "archive", "/w/one"], environment: [:])

    expectNoDifference(
      failure,
      "slipstream: no runtime at /rt/current; open Slipstream once.\nslipstream exited with status 127.")
  }

  @Test func absentShimNamesItsPath() async {
    let failure = await WorkspaceClient.runShim("/nonexistent-runtime/bin/slipstream", [], environment: [:])

    #expect(failure?.hasPrefix("Couldn't run /nonexistent-runtime/bin/slipstream: ") == true)
  }

  @Test func repositoryOfAWorktreeIsItsMainCheckout() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "repo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = folder.appending(path: "r")
    let worktree = folder.appending(path: "lisbon")
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    for arguments in [
      ["init", "-q"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"],
      ["worktree", "add", "-q", worktree.path],
    ] {
      let (output, status) = try WorkspaceClient.run(
        "/usr/bin/git", ["-C", main.path] + arguments, environment: ProcessInfo.processInfo.environment)
      try #require(status == 0, Comment(rawValue: output))
    }

    let mainOfWorktree = await WorkspaceClient.repository(of: worktree)
    let mainOfMain = await WorkspaceClient.repository(of: main)
    let outside = await WorkspaceClient.repository(of: folder)

    expectNoDifference(mainOfWorktree?.resolvingSymlinksInPath().path, main.resolvingSymlinksInPath().path)
    expectNoDifference(mainOfMain?.resolvingSymlinksInPath().path, main.resolvingSymlinksInPath().path)
    #expect(outside == nil)
  }

  private func makeShim(_ body: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "shim-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let shim = folder.appending(path: "slipstream")
    FileManager.default.createFile(
      atPath: shim.path, contents: Data("#!/bin/sh\n\(body)\n".utf8), attributes: [.posixPermissions: 0o755])
    return shim
  }

  @Test func commandReturnsWhenItsBackgroundSetupKeepsTheOutputPipeOpen() throws {
    let result = try WorkspaceClient.run(
      "/bin/sh", ["-c", "yes setup-output &"], environment: ProcessInfo.processInfo.environment)

    #expect(result.status == 0)
    #expect(result.output.utf8.count <= 65_536)
  }
}
