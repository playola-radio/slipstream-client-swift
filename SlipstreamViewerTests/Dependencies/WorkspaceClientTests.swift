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

  @Test func successReturnsThePathAndNoFailure() {
    let output = "created /w/workspace-1 on slipstream/workspace-1 from origin/develop\nSETUP-DONE\nworkspace_path: /w/workspace-1\n"

    expectNoDifference(
      WorkspaceClient.outcome(output: output, status: 0),
      WorkspaceOutcome(workspacePath: "/w/workspace-1", failureText: nil)
    )
  }

  @Test func failedSetupReturnsThePathAndTheTail() {
    let output = "docker: no space left\nslipstream: the setup script exited 2.\nworkspace_path: /w/workspace-1\n"

    expectNoDifference(
      WorkspaceClient.outcome(output: output, status: 1),
      WorkspaceOutcome(
        workspacePath: "/w/workspace-1",
        failureText: "docker: no space left\nslipstream: the setup script exited 2."
      )
    )
  }

  @Test func failureWithoutAPathReturnsOnlyTheTail() {
    let output = "\nslipstream: /r has no \"origin\" remote to branch from.\n"

    expectNoDifference(
      WorkspaceClient.outcome(output: output, status: 1),
      WorkspaceOutcome(workspacePath: nil, failureText: "slipstream: /r has no \"origin\" remote to branch from.")
    )
  }

  @Test func failureTailIsCappedAtTwelveLines() {
    let output = (1...20).map { "line \($0)" }.joined(separator: "\n")

    expectNoDifference(
      WorkspaceClient.outcome(output: output, status: 1).failureText,
      (9...20).map { "line \($0)" }.joined(separator: "\n")
    )
  }
}
