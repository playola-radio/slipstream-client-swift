import ConcurrencyExtras
import CustomDump
import Foundation
import Testing

@testable import SlipstreamViewer

struct AgentEnvironmentClientTests {
  @Test func parsesEnvAfterMarkerIgnoringChatter() {
    let marker = "SLIPSTREAM-ENV-1"
    let output = Data("motd\n\0\(marker)\0PATH=/a\0CLAUDE_CONFIG_DIR=/c\0".utf8)

    expectNoDifference(
      AgentEnvironmentClient.parseEnvironment(output, marker: marker),
      ["PATH": "/a", "CLAUDE_CONFIG_DIR": "/c"]
    )
  }

  @Test func parseKeepsEqualsSignsAndNewlinesInValues() {
    let output = Data("\0M\0A=x=y\0B=line1\nline2\0".utf8)

    expectNoDifference(
      AgentEnvironmentClient.parseEnvironment(output, marker: "M"),
      ["A": "x=y", "B": "line1\nline2"]
    )
  }

  @Test func parseWithoutMarkerIsNil() {
    expectNoDifference(AgentEnvironmentClient.parseEnvironment(Data("PATH=/a\0".utf8), marker: "M"), nil)
  }

  @Test func versionFloor() {
    expectNoDifference(
      [
        AgentEnvironmentClient.isSupported(version: "2.1.293 (Claude Code)"),
        AgentEnvironmentClient.isSupported(version: "2.1.292 (Claude Code)"),
        AgentEnvironmentClient.isSupported(version: "2.2.0"),
        AgentEnvironmentClient.isSupported(version: "10.0.0"),
        AgentEnvironmentClient.isSupported(version: "garbage"),
      ],
      [true, false, true, true, false]
    )
  }

  @Test func messagesNameTheProblem() {
    expectNoDifference(
      AgentEnvironmentError.tooOld(found: "2.1.100").message,
      "Slipstream needs Claude Code 2.1.293 or newer (found 2.1.100)"
    )
    expectNoDifference(
      AgentEnvironmentError.claudeNotFound.message,
      "Couldn't find claude on your login shell's PATH"
    )
  }

  @Test func configDirectoryPrefersClaudeConfigDir() {
    let home = URL(fileURLWithPath: "/Users/someone")
    expectNoDifference(
      [
        AgentEnvironmentClient.configDirectory(["CLAUDE_CONFIG_DIR": "/c"], home: home),
        AgentEnvironmentClient.configDirectory(["CLAUDE_CONFIG_DIR": ""], home: home),
        AgentEnvironmentClient.configDirectory([:], home: home),
      ],
      [
        URL(fileURLWithPath: "/c"),
        URL(fileURLWithPath: "/Users/someone/.claude"),
        URL(fileURLWithPath: "/Users/someone/.claude"),
      ]
    )
  }

  @Test func usesPasswordDatabaseShellWhenEnvironmentShellIsMissing() {
    expectNoDifference(
      AgentEnvironmentClient.loginShell(environment: [:], passwordDatabaseShell: "/bin/bash"),
      "/bin/bash"
    )
    expectNoDifference(
      AgentEnvironmentClient.loginShell(environment: ["SHELL": ""], passwordDatabaseShell: "/usr/local/bin/fish"),
      "/usr/local/bin/fish"
    )
  }

  @Test func fallsBackToZshWhenNoLoginShellIsAvailable() {
    expectNoDifference(
      AgentEnvironmentClient.loginShell(environment: [:], passwordDatabaseShell: nil),
      "/bin/zsh"
    )
  }

  @Test func waitsForCommandExitAfterOutputCloses() async throws {
    let output = try await AgentEnvironmentClient.captureOutput(
      "/bin/sh",
      ["-c", "exec 1>&-; while :; do :; done"],
      environment: nil,
      timeout: 0.1
    )

    expectNoDifference(output, nil)
  }

  @Test func cachesSuccessButNotFailure() async throws {
    let environment = AgentEnvironment(
      claudePath: "/bin/claude", variables: [:], configDirectory: URL(fileURLWithPath: "/c"))
    let calls = LockIsolated(0)
    let cache = AgentEnvironmentCache {
      let call = calls.withValue { $0 += 1; return $0 }
      if call == 1 { throw AgentEnvironmentError.shellTimedOut }
      return environment
    }

    await #expect(throws: AgentEnvironmentError.shellTimedOut) { try await cache.resolve() }
    let second = try await cache.resolve()
    let third = try await cache.resolve()

    expectNoDifference(second, environment)
    expectNoDifference(third, environment)
    #expect(calls.value == 2)
  }
}
