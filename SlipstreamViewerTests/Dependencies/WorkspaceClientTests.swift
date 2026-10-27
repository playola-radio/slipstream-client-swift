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
      "slipstream: the workspace has uncommitted or untracked changes."
    )
  }

  @Test func failureWithoutOutputNamesTheExitStatus() {
    expectNoDifference(WorkspaceClient.failureText(output: "", status: 9), "slipstream exited with status 9.")
  }

  @Test func failureTailIsCappedAtTwelveLines() {
    let output = (1...20).map { "line \($0)" }.joined(separator: "\n")

    expectNoDifference(
      WorkspaceClient.failureText(output: output, status: 1),
      (9...20).map { "line \($0)" }.joined(separator: "\n")
    )
  }

  @Test func commandReturnsWhenItsBackgroundSetupKeepsTheOutputPipeOpen() throws {
    let result = try WorkspaceClient.run(
      "/bin/sh", ["-c", "yes setup-output &"], environment: ProcessInfo.processInfo.environment)

    #expect(result.status == 0)
    #expect(result.output.utf8.count <= 65_536)
  }
}
