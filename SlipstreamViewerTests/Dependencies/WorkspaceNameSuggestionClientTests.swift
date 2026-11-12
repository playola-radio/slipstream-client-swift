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
struct WorkspaceNameSuggestionClientTests {
  nonisolated static let result =
    #"{"type":"result","subtype":"success","is_error":false,"structured_output":{"name":"Workspace Loading Indicator"}}"#

  let agent = AgentFake()
  let clock = TestClock()

  func start(message: String = "Add a loading spinner") async -> Task<Result<String, WorkspaceNameSuggestionError>, Never> {
    let task = withDependencies {
      $0.agentProcess = agent.processClient
      $0.continuousClock = clock
    } operation: {
      Task { () -> Result<String, WorkspaceNameSuggestionError> in
        do {
          return .success(try await WorkspaceNameSuggestionClient.liveValue.suggest(message, AgentFake.environment))
        } catch let error as WorkspaceNameSuggestionError {
          return .failure(error)
        } catch {
          return .failure(.unavailable)
        }
      }
    }
    await Task.megaYield()
    return task
  }

  @Test func launchesHaikuInAnEmptyTemporaryDirectoryAndRemovesIt() async throws {
    let run = await start()
    let launch = try #require(agent.launches.first)
    var isDirectory: ObjCBool = false

    expectNoDifference(launch.executable, AgentFake.environment.claudePath)
    expectNoDifference(launch.arguments, ClaudeInvocation.workspaceNameArguments(schema: WorkspaceNameSuggestion.schema))
    expectNoDifference(launch.environment, AgentFake.environment.variables)
    #expect(FileManager.default.fileExists(atPath: launch.directory, isDirectory: &isDirectory) && isDirectory.boolValue)
    expectNoDifference(try FileManager.default.contentsOfDirectory(atPath: launch.directory), [])

    agent.sendLine(Self.result)
    _ = await run.value
    #expect(!FileManager.default.fileExists(atPath: launch.directory))
  }

  @Test func writesThePromptThenClosesInput() async {
    let run = await start()

    expectNoDifference(
      agent.rawWrites(0), [Data(WorkspaceNameSuggestion.prompt(for: "Add a loading spinner").utf8)])
    #expect(agent.isInputClosed(0))
    run.cancel()
    _ = await run.value
  }

  @Test func resultLineReturnsTheNameAndShutsDown() async {
    let run = await start()

    agent.sendLine(#"{"type":"system","subtype":"init"}"#)
    agent.sendLine(Self.result)

    let result = await run.value
    expectNoDifference(result, .success("Workspace Loading Indicator"))
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func resultWithoutStructuredOutputIsBadReply() async {
    let run = await start()

    agent.sendLine(#"{"type":"result","subtype":"error_max_turns","is_error":false}"#)

    let result = await run.value
    expectNoDifference(result, .failure(.badReply))
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func nonzeroExitIsUnavailable() async {
    let run = await start()

    agent.exit(status: 2, stderrTail: "\nError: Invalid API key\n")

    let result = await run.value
    expectNoDifference(result, .failure(.unavailable))
  }

  @Test func cleanExitWithoutAResultIsBadReply() async {
    let run = await start()

    agent.exit(status: 0)

    let result = await run.value
    expectNoDifference(result, .failure(.badReply))
  }

  @Test func launchFailureIsThrownAndRemovesTheDirectory() async {
    agent.setLaunchError(AgentProcessError.launchFailed(errno: ENOENT))
    let run = await start()

    let result = await run.value
    expectNoDifference(result, .failure(.unavailable))
    #expect(agent.shutdownCount == 0)
  }

  @Test func overTheTimeLimitShutsDownAsTimedOut() async {
    let run = await start()

    await clock.advance(by: .seconds(19))
    #expect(agent.shutdownCount == 0)
    await clock.advance(by: .seconds(1))

    let result = await run.value
    expectNoDifference(result, .failure(.timedOut))
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func timeoutRemovesTheDirectory() async throws {
    let run = await start()
    let directory = try #require(agent.launches.first).directory

    await clock.advance(by: .seconds(20))
    _ = await run.value

    #expect(!FileManager.default.fileExists(atPath: directory))
  }
}
