import CustomDump
import Foundation
import Testing

@testable import SlipstreamViewer

struct TerminalRuntimeClientTests {
  @Test func environmentNeedsPath() {
    #expect(throws: TerminalLaunchError.self) {
      try TerminalRuntimeClient.terminalEnvironment(
        login: ["HOME": "/h"], passwordDatabaseShell: "/bin/zsh", slipstream: "/rt/bin/slipstream")
    }
  }

  @Test func environmentSetsTerminalVariables() throws {
    let environment = try TerminalRuntimeClient.terminalEnvironment(
      login: ["PATH": "/nowhere", "TERM": "dumb", "SHELL": "/bin/bash"], passwordDatabaseShell: "/bin/zsh", slipstream: "/rt/bin/slipstream")

    expectNoDifference(
      environment,
      TerminalEnvironment(
        variables: [
          "PATH": "/nowhere", "TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "en_US.UTF-8",
          "SHELL": "/bin/bash",
        ],
        shell: "/bin/bash",
        slipstream: "/rt/bin/slipstream"
      )
    )
  }

  @Test func environmentKeepsExistingLang() throws {
    let environment = try TerminalRuntimeClient.terminalEnvironment(
      login: ["PATH": "/nowhere", "LANG": "fr_FR.UTF-8"], passwordDatabaseShell: "/bin/zsh", slipstream: "/rt/bin/slipstream")

    expectNoDifference(environment.variables["LANG"], "fr_FR.UTF-8")
  }

  @Test func environmentSetsUTF8WhenLocaleValuesAreEmpty() throws {
    let environment = try TerminalRuntimeClient.terminalEnvironment(
      login: ["PATH": "/nowhere", "LANG": "", "LC_ALL": "", "LC_CTYPE": ""],
      passwordDatabaseShell: "/bin/zsh", slipstream: "/rt/bin/slipstream")

    expectNoDifference(environment.variables["LANG"], "en_US.UTF-8")
  }
}
