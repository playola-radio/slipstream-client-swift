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
    expectNoDifference(outcome, .failure(.unavailable))
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func exitBeforeResultIsUnavailable() async {
    let run = await start()

    await line(Self.isolatedInit)
    agent.exit(status: 1)

    let outcome = await run.value
    expectNoDifference(outcome, .failure(.unavailable))
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func cleanExitBeforeResultIsBadReply() async {
    let run = await start()

    await line(Self.isolatedInit)
    agent.exit(status: 0)

    let outcome = await run.value
    expectNoDifference(outcome, .failure(.badReply))
  }

  @Test func overflowIsBadReply() async {
    let run = await start()

    agent.send(.overflow)

    let outcome = await run.value
    expectNoDifference(outcome, .failure(.badReply))
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func launchFailureIsUnavailable() async {
    agent.setLaunchError(AgentProcessError.launchFailed(errno: ENOENT))
    let run = await start()

    let outcome = await run.value
    expectNoDifference(outcome, .failure(.unavailable))
    #expect(agent.shutdownCount == 0)
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

  @Test func cancellationShutsDown() async {
    let run = await start()
    await line(Self.isolatedInit)

    run.cancel()
    _ = await run.value

    #expect(agent.shutdowns(0) == 1)
  }
}
