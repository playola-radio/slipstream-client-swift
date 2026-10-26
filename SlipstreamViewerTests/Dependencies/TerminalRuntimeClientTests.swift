import CustomDump
import Foundation
import Testing

@testable import SlipstreamViewer

struct TerminalRuntimeClientTests {
  @Test func environmentNeedsPath() {
    #expect(throws: TerminalLaunchError.self) {
      try TerminalRuntimeClient.terminalEnvironment(login: ["HOME": "/h"], passwordDatabaseShell: "/bin/zsh")
    }
  }

  @Test func environmentSetsTerminalVariables() throws {
    let environment = try TerminalRuntimeClient.terminalEnvironment(
      login: ["PATH": "/nowhere", "TERM": "dumb", "SHELL": "/bin/bash"], passwordDatabaseShell: "/bin/zsh")

    expectNoDifference(
      environment,
      TerminalEnvironment(
        variables: [
          "PATH": "/nowhere", "TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "en_US.UTF-8",
          "SHELL": "/bin/bash",
        ],
        shell: "/bin/bash",
        slipstream: nil
      )
    )
  }

  @Test func environmentKeepsExistingLang() throws {
    let environment = try TerminalRuntimeClient.terminalEnvironment(
      login: ["PATH": "/nowhere", "LANG": "fr_FR.UTF-8"], passwordDatabaseShell: "/bin/zsh")

    expectNoDifference(environment.variables["LANG"], "fr_FR.UTF-8")
  }

  @Test func environmentFindsSlipstreamOnPath() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "terminal-env-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let slipstream = folder.appending(path: "slipstream")
    FileManager.default.createFile(
      atPath: slipstream.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

    let environment = try TerminalRuntimeClient.terminalEnvironment(
      login: ["PATH": "/nowhere:\(folder.path)"], passwordDatabaseShell: "/bin/zsh")

    expectNoDifference(environment.slipstream, slipstream.path)
    expectNoDifference(environment.shell, "/bin/zsh")
  }
}
