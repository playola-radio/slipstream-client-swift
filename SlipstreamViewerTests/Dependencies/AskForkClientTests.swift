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

  func start() async -> Task<Result<AskForkResult, AskForkError>, Never> {
    let task = withDependencies {
      $0.agentProcess = agent.processClient
      $0.continuousClock = clock
    } operation: {
      Task { () -> Result<AskForkResult, AskForkError> in
        do throws(AskForkError) {
          return .success(try await AskForkClient.liveValue.run(Self.request))
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

  @Test func exitBeforeResultCapsTheCompletedDetail() async {
    let run = await start()
    let stderr = String(repeating: "x", count: 600)

    agent.exit(status: 2, stderrTail: stderr)

    let outcome = await run.value
    expectNoDifference(
      outcome,
      .failure(.unavailable(DiagnosticText.line("Claude Code exited with status 2: " + stderr)))
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
