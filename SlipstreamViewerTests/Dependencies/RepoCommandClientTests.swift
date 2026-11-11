import CustomDump
import Foundation
import Testing

@testable import SlipstreamViewer

struct RepoCommandClientTests {
  let client = RepoCommandClient.live(loginEnvironment: { ProcessInfo.processInfo.environment })

  func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "repo-command-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  @Test func capturesStdoutStderrAndExit() async {
    let folder = URL(fileURLWithPath: "/tmp")

    let result = await client.run(["sh", "-c", "echo out; echo err >&2; exit 3"], folder, .seconds(10))

    expectNoDifference(
      result,
      CommandResult(
        command: ["sh", "-c", "echo out; echo err >&2; exit 3"], folder: folder, ending: .exit(3),
        stdout: "out\n", stderr: "err\n")
    )
    #expect(!result.succeeded)
  }

  @Test func runsInFolder() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let result = await client.run(["pwd"], folder, .seconds(10))

    expectNoDifference(
      URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .newlines)).resolvingSymlinksInPath(),
      folder.resolvingSymlinksInPath())
  }

  @Test func drainsLargeOutputOnBothPipes() async {
    let result = await client.run(
      ["sh", "-c", "yes x | head -c 5000000; yes y | head -c 5000000 >&2"], URL(fileURLWithPath: "/tmp"), .seconds(10))

    expectNoDifference(result.ending, .exit(0))
    expectNoDifference([result.stdout.utf8.count, result.stderr.utf8.count], [5_000_000, 5_000_000])
  }

  @Test func timesOut() async {
    let result = await client.run(["sleep", "30"], URL(fileURLWithPath: "/tmp"), .milliseconds(200))

    expectNoDifference(result.ending, .timedOut(.milliseconds(200)))
  }

  @Test func missingToolFails() async {
    let result = await client.run(["definitely-not-a-tool"], URL(fileURLWithPath: "/tmp"), .seconds(10))

    #expect(!result.succeeded)
    #expect(!result.stderr.isEmpty)
  }

  @Test func findsToolsOnTheLoginPath() async throws {
    let tools = try makeFolder()
    defer { try? FileManager.default.removeItem(at: tools) }
    let tool = tools.appending(path: "login-only-tool")
    try "#!/bin/sh\necho found\n".write(to: tool, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let client = RepoCommandClient.live(loginEnvironment: { ["PATH": tools.path + ":/usr/bin:/bin"] })

    let result = await client.run(["login-only-tool"], URL(fileURLWithPath: "/tmp"), .seconds(10))

    expectNoDifference(result.stdout, "found\n")
  }

  @Test func fallsBackToProcessEnvironmentWhenLoginShellFails() async {
    struct LoginShellFailed: Error {}
    let client = RepoCommandClient.live(loginEnvironment: { throw LoginShellFailed() })

    let result = await client.run(["echo", "hi"], URL(fileURLWithPath: "/tmp"), .seconds(10))

    expectNoDifference(result.stdout, "hi\n")
  }

  @Test func commandLineQuotes() {
    let result = CommandResult(
      command: ["git", "switch", "-c", "a b"], folder: URL(fileURLWithPath: "/tmp"), ending: .exit(0), stdout: "",
      stderr: "")

    expectNoDifference(result.commandLine, "git switch -c 'a b'")
  }
}
