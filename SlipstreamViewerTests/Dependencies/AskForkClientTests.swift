import Clocks
import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct AskForkClientTests {
  nonisolated static let parent = UUID(uuidString: "4BAD416C-1D04-4063-9E76-61EBB936AE06")!
  nonisolated static let request = AskForkRequest(
    parentSessionID: parent,
    folder: "/w",
    environment: AgentFake.environment,
    model: "claude-opus-5-5",
    effort: .high,
    prompt: "What does this do?",
    kind: .answer(allowsChangeRequests: false)
  )
  nonisolated static let isolatedInit =
    #"{"type":"system","subtype":"init","session_id":"fork-1","tools":["Glob","Grep","Read","StructuredOutput"],"mcp_servers":[]}"#
  nonisolated static let result =
    #"{"type":"result","subtype":"success","is_error":false,"session_id":"fork-1","structured_output":{"reply":"It adds two numbers."}}"#

  let agent = AgentFake()
  let clock = TestClock()

  func start(_ request: AskForkRequest = request) async -> Task<Result<AskForkResult, AskForkError>, Never> {
    let task = withDependencies {
      $0.agentProcess = agent.processClient
      $0.continuousClock = clock
    } operation: {
      Task { () -> Result<AskForkResult, AskForkError> in
        do throws(AskForkError) {
          return .success(try await AskForkClient.liveValue.run(request))
        } catch {
          return .failure(error)
        }
      }
    }
    await Task.megaYield()
    return task
  }

  func line(_ json: String) async {
    agent.sendLine(json)
    await Task.megaYield()
  }

  @Test func launchesForkArgumentsInFolderWithEnvironment() async {
    let run = await start()

    expectNoDifference(
      agent.launches,
      [
        AgentLaunch(
          executable: AgentFake.environment.claudePath,
          arguments: ClaudeInvocation.forkArguments(
            parentSessionID: Self.parent, model: "claude-opus-5-5", effort: "high",
            schema: AskPrompt.answerSchema(allowsChangeRequests: false)),
          environment: AgentFake.environment.variables,
          directory: "/w"
        )
      ]
    )
    run.cancel()
    _ = await run.value
  }

  @Test func writesPromptThenClosesInput() async {
    let run = await start()

    expectNoDifference(agent.rawWrites(0), [Data("What does this do?".utf8)])
    #expect(agent.isInputClosed(0))
    run.cancel()
    _ = await run.value
  }

  @Test func resultLineReturnsAnswerAndShutsDown() async {
    let run = await start()

    await line(Self.isolatedInit)
    await line(Self.result)

    let outcome = await run.value
    expectNoDifference(
      outcome,
      .success(.answer(forkSessionID: "fork-1", reply: "It adds two numbers.", isChangeRequest: false))
    )
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func notIsolatedInitShutsDownAsUnavailable() async {
    let run = await start()

    await line(#"{"type":"system","subtype":"init","tools":["Bash","Read"],"mcp_servers":[]}"#)

    let outcome = await run.value
    expectNoDifference(
      outcome,
      .failure(
        .unavailable(
          "The read-only copy of the chat wasn't isolated. It had tools Bash, Read and MCP servers none."))
    )
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func errorResultCarriesClaudesOwnText() async {
    let run = await start()

    await line(Self.isolatedInit)
    await line(#"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key"}"#)

    let outcome = await run.value
    expectNoDifference(outcome, .failure(.unavailable("Claude Code reported an error: Invalid API key")))
  }

  @Test func exitBeforeResultNamesTheStatus() async {
    let run = await start()

    await line(Self.isolatedInit)
    agent.exit(status: 1)

    let outcome = await run.value
    expectNoDifference(outcome, .failure(.unavailable("Claude Code exited with status 1.")))
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func exitBeforeResultIncludesStderr() async {
    let run = await start()

    await line(Self.isolatedInit)
    agent.exit(status: 2, stderrTail: "\nwarming up\nError: Invalid API key\n\n")

    let outcome = await run.value
    expectNoDifference(
      outcome, .failure(.unavailable("Claude Code exited with status 2: warming up · Error: Invalid API key")))
  }

  @Test func exitBeforeResultCapsTheDetailKeepingTheEndOfStderr() async {
    let run = await start()
    let prefix = "Claude Code exited with status 2: "

    agent.exit(status: 2, stderrTail: String(repeating: "x", count: 600) + "Error: Invalid API key")

    let outcome = await run.value
    let kept = DiagnosticText.limit - prefix.count - 1
    expectNoDifference(
      outcome,
      .failure(.unavailable(prefix + "…" + String((String(repeating: "x", count: 600) + "Error: Invalid API key").suffix(kept))))
    )
  }

  @Test func exitWithOnlyBlankStderrOmitsIt() async {
    let run = await start()

    agent.exit(status: 3, stderrTail: " \n\t\n")

    let outcome = await run.value
    expectNoDifference(outcome, .failure(.unavailable("Claude Code exited with status 3.")))
  }

  @Test func cleanExitBeforeResultIsBadReply() async {
    let run = await start()

    await line(Self.isolatedInit)
    agent.exit(status: 0)

    let outcome = await run.value
    expectNoDifference(outcome, .failure(.badReply("Claude Code exited without an answer.")))
  }

  @Test func overflowIsBadReply() async {
    let run = await start()

    agent.send(.overflow)

    let outcome = await run.value
    expectNoDifference(outcome, .failure(.badReply("Claude Code's reply was too long to read.")))
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func streamEndingWithoutExitIsUnavailable() async {
    let run = await start()

    agent.finishEvents()

    let outcome = await run.value
    expectNoDifference(outcome, .failure(.unavailable("Claude Code stopped unexpectedly.")))
  }

  @Test func launchFailureNamesTheErrno() async {
    agent.setLaunchError(AgentProcessError.launchFailed(errno: ENOENT))
    let run = await start()

    let outcome = await run.value
    expectNoDifference(
      outcome, .failure(.unavailable("Claude Code couldn't start: No such file or directory")))
    #expect(agent.shutdownCount == 0)
  }

  @Test func otherLaunchFailureUsesItsDescription() async {
    struct Broken: LocalizedError { var errorDescription: String? { "the disk is full" } }
    agent.setLaunchError(Broken())
    let run = await start()

    let outcome = await run.value
    expectNoDifference(outcome, .failure(.unavailable("Claude Code couldn't start: the disk is full")))
  }

  @Test func promptWriteFailureNamesTheErrno() async {
    agent.setWriteError(AgentProcessError.writeFailed(errno: EPIPE))
    let run = await start()

    let outcome = await run.value
    expectNoDifference(
      outcome, .failure(.unavailable("The question couldn't be sent to Claude Code: Broken pipe")))
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func stderrSummaryKeepsTheLastThreeNonEmptyLines() {
    expectNoDifference(
      AskForkClient.stderrSummary("one\n\n two \nthree\n\nfour\n"), "two · three · four")
  }

  @Test func stderrSummaryRemovesControlCharacters() {
    expectNoDifference(AskForkClient.stderrSummary("\u{1B}[31mboom\u{7}\tdone\r\n"), "[31mboom done")
  }

  @Test func stderrSummaryOfBlankTextIsEmpty() {
    expectNoDifference(AskForkClient.stderrSummary(" \n\t \n"), "")
  }

  @Test func stderrSummaryCapsAtFiveHundredCharactersKeepingTheEnd() {
    let long = String(repeating: "a", count: 600) + "END"
    let summary = AskForkClient.stderrSummary(long)
    expectNoDifference(summary.count, 500)
    expectNoDifference(summary.first, "…")
    #expect(summary.hasSuffix("aaaEND"))
    expectNoDifference(AskForkClient.stderrSummary(String(repeating: "b", count: 500)), String(repeating: "b", count: 500))
  }

  @Test func overTimeLimitShutsDownAsTimedOut() async {
    let run = await start()
    await line(Self.isolatedInit)

    await clock.advance(by: .seconds(119))
    #expect(agent.shutdownCount == 0)
    await clock.advance(by: .seconds(1))

    let outcome = await run.value
    expectNoDifference(outcome, .failure(.timedOut))
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func overTimeLimitAfterAPIRetriesNamesTheLastError() async {
    let run = await start()
    await line(Self.isolatedInit)
    await line(#"{"type":"system","subtype":"api_retry","attempt":1,"error_status":401,"error":"authentication_failed"}"#)

    await clock.advance(by: .seconds(120))

    let outcome = await run.value
    expectNoDifference(
      outcome,
      .failure(
        .unavailable("Claude Code didn't answer within 120 seconds. Its last API call failed: 401 authentication_failed."))
    )
  }

  @Test func launchesWithCredentialsFromUserSettings() async throws {
    let directory = try Self.configDirectory(
      #"{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","PATH":"/corp/bin","HOME":"/corp"},"apiKeyHelper":"/opt/bin/key","hooks":{}}"#)
    defer { try? FileManager.default.removeItem(at: directory) }
    var environment = AgentFake.environment
    environment.configDirectory = directory
    let run = await start(Self.request(environment))

    expectNoDifference(
      agent.launches.first?.environment, ["PATH": "/opt/claude/bin:/usr/bin", "CLAUDE_CODE_USE_BEDROCK": "1"])
    expectNoDifference(agent.launches.first?.arguments.suffix(2), ["--settings", #"{"apiKeyHelper":"/opt/bin/key"}"#])
    run.cancel()
    _ = await run.value
  }

  @Test func malformedUserSettingsDoesNotLaunch() async throws {
    let directory = try Self.configDirectory(#"{"apiKeyHelper":true}"#)
    defer { try? FileManager.default.removeItem(at: directory) }
    var environment = AgentFake.environment
    environment.configDirectory = directory
    let run = await start(Self.request(environment))

    let outcome = await run.value
    expectNoDifference(
      outcome,
      .failure(
        .unavailable(
          "Claude Code's settings file \(directory.appending(path: "settings.json").path) couldn't be used: its apiKeyHelper isn't text."
        ))
    )
    expectNoDifference(agent.launches, [])
  }

  nonisolated static func request(_ environment: AgentEnvironment) -> AskForkRequest {
    AskForkRequest(
      parentSessionID: parent, folder: "/w", environment: environment, model: "claude-opus-5-5", effort: .high,
      prompt: "What does this do?", kind: .answer(allowsChangeRequests: false))
  }

  static func configDirectory(_ settings: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "AskForkClientTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(settings.utf8).write(to: directory.appending(path: "settings.json"))
    return directory
  }

  @Test func blockedPromptWriteStillShutsDownAtTimeLimit() async {
    agent.hold(.writes)
    let run = await start()

    await clock.advance(by: .seconds(120))

    #expect(agent.shutdowns(0) == 1)
    agent.release(.writes)
    let outcome = await run.value
    expectNoDifference(outcome, .failure(.timedOut))
  }

  @Test func cancellationShutsDown() async {
    let run = await start()
    await line(Self.isolatedInit)

    run.cancel()
    let outcome = await run.value

    #expect(agent.shutdowns(0) == 1)
    expectNoDifference(outcome, .failure(.unavailable("The question was cancelled.")))
  }
}
