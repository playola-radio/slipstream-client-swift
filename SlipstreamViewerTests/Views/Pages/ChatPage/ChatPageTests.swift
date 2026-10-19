import Clocks
import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct ChatPageTests {
  nonisolated static let start = Date(timeIntervalSince1970: 1_760_000_000)
  nonisolated static let saved = UUID(uuidString: "4BAD416C-1D04-4063-9E76-61EBB936AE06")!

  let agent = AgentFake()
  let clock = TestClock()
  let elapsed = LockIsolated<TimeInterval>(0)

  func makeModel(records: [ChatTabRecord] = []) -> ChatPageModel {
    withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.agentEnvironment = agent.environmentClient
      $0.agentProcess = agent.processClient
      $0.transcripts = agent.transcriptClient
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.date = DateGenerator { [elapsed] in Self.start.addingTimeInterval(elapsed.value) }
      $0.timeZone = TimeZone(identifier: "UTC")!
    } operation: {
      @Shared(.chatTabs) var stored
      $stored.withLock { $0 = IdentifiedArray(uniqueElements: records) }
      return ChatPageModel()
    }
  }

  func record(
    _ id: UUID = saved, folder: String = "/w", model: String = "claude-opus-5-5",
    effort: ChatEffort = .high, isWaiting: Bool = false
  ) -> ChatTabRecord {
    ChatTabRecord(id: id, folder: folder, model: model, effort: effort, isWaiting: isWaiting)
  }

  func launch(_ id: UUID, folder: String = "/w", model: String = "claude-opus-5-5", effort: String = "high", session: ClaudeSessionStart) -> AgentLaunch {
    AgentLaunch(
      executable: AgentFake.environment.claudePath,
      arguments: ClaudeInvocation.arguments(model: model, effort: effort, session: session),
      environment: AgentFake.environment.variables,
      directory: folder
    )
  }

  func send(_ model: ChatPageModel, _ text: String) async {
    model.selectedTab?.draft = text
    await model.sendTapped()
    await Task.megaYield()
  }

  func line(_ json: String, to launch: Int? = nil) async {
    agent.sendLine(json, to: launch)
    await Task.megaYield()
  }

  // MARK: - Tabs and workspaces

  @Test func firstVisitToFolderCreatesNewChat() {
    let model = makeModel()

    model.workspaceChanged(folder: "/w", emptyText: nil)

    expectNoDifference(model.visibleTabs.map(\.title), ["New chat"])
    expectNoDifference(model.records, [record(UUID(0))])
    #expect(model.selectedTab?.id == UUID(0))
  }

  @Test func newTabCopiesCurrentChoice() async {
    let model = makeModel(records: [record(model: "claude-sonnet-5-5", effort: .low)])
    model.workspaceChanged(folder: "/w", emptyText: nil)

    await model.newTabTapped()

    expectNoDifference(
      model.records,
      [record(model: "claude-sonnet-5-5", effort: .low), record(UUID(0), model: "claude-sonnet-5-5", effort: .low)])
    #expect(model.selectedTab?.id == UUID(0))
    #expect(model.selectedTab?.title == "New chat")
  }

  @Test func noWorkspaceShowsFeedText() {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)

    model.workspaceChanged(folder: nil, emptyText: "Choose a capture session to watch its changes")

    #expect(model.noWorkspaceText == "Choose a capture session to watch its changes")
    #expect(model.visibleTabs.isEmpty)
    #expect(model.selectedTab == nil)
  }

  @Test func workspaceShowsOnlyItsFolderTabs() {
    let model = makeModel(records: [record(), record(UUID(50), folder: "/other")])

    model.workspaceChanged(folder: "/other", emptyText: "ignored")

    expectNoDifference(model.visibleTabs.map(\.id), [UUID(50)])
    #expect(model.noWorkspaceText == nil)
  }

  @Test func closingCurrentSelectsLeftThenRight() async {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await model.newTabTapped()
    await model.newTabTapped()

    await model.closeTabTapped(UUID(2))
    #expect(model.selectedTab?.id == UUID(1))

    await model.tabSelected(UUID(0))
    await model.closeTabTapped(UUID(0))
    #expect(model.selectedTab?.id == UUID(1))
    expectNoDifference(model.visibleTabs.map(\.id), [UUID(1)])
    expectNoDifference(model.records.ids, [UUID(1)])
  }

  @Test func closingOtherTabKeepsSelection() async {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await model.newTabTapped()

    await model.closeTabTapped(UUID(0))

    #expect(model.selectedTab?.id == UUID(1))
  }

  @Test func closingLastTabLeavesFreshNewChat() async {
    let model = makeModel(records: [record(model: "claude-haiku-5-5")])
    model.workspaceChanged(folder: "/w", emptyText: nil)

    await model.closeTabTapped(Self.saved)

    expectNoDifference(model.records, [record(UUID(0), model: "claude-haiku-5-5")])
    expectNoDifference(model.visibleTabs.map(\.title), ["New chat"])
    #expect(model.tabs.ids == [UUID(0)])
  }

  // MARK: - Launching

  @Test func missingTranscriptStartsNewSession() async {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await model.viewAppeared()

    await send(model, "hi")

    expectNoDifference(agent.launches, [launch(Self.saved, session: .new(Self.saved))])
    #expect(agent.launches[0].arguments.contains("--session-id=4bad416c-1d04-4063-9e76-61ebb936ae06"))
  }

  @Test func foundTranscriptResumesAndShowsHistory() async throws {
    let lines: [AgentLine] = [
      .user(uuid: "u1", timestamp: Self.start, isPrompt: true, blocks: [.text("Fix the build")]),
      .assistant(uuid: "a1", timestamp: Self.start.addingTimeInterval(41), blocks: [.text("Fixed.")]),
      .title("Fixing the build"),
    ]
    agent.setTranscript(Self.saved, .found(lines))
    let model = makeModel(records: [record(), record(UUID(50))])
    model.workspaceChanged(folder: "/w", emptyText: nil)

    await model.tabSelected(Self.saved)

    let tab = try #require(model.tabs[id: Self.saved])
    expectNoDifference(tab.projection, TranscriptProjection.history(lines))
    #expect(tab.title == "Fixing the build")

    await send(model, "And the tests")

    expectNoDifference(agent.launches, [launch(Self.saved, session: .resume(Self.saved))])
  }

  @Test func historyLoadsOnceWhileProcessLives() async {
    agent.setTranscript(Self.saved, .found([.title("Old")]))
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await model.viewAppeared()
    await send(model, "hi")
    let loadsAfterSend = agent.loads.count

    await model.viewAppeared()
    await model.tabSelected(Self.saved)

    #expect(agent.loads.count == loadsAfterSend)
  }

  @Test func unreadableTranscriptShowsErrorAndDoesNotLaunch() async {
    agent.setUnreadable(Self.saved)
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)

    await model.viewAppeared()
    #expect(model.selectedTab?.errorText == "Couldn't read this chat's history from Claude")

    await send(model, "hi")

    #expect(model.selectedTab?.errorText == "Couldn't read this chat's history from Claude")
    #expect(agent.launches.isEmpty)
    #expect(model.selectedTab?.isWorking == false)
    #expect(model.selectedTab?.draft == "hi")
  }

  @Test func environmentErrorShowsMessageAndLaunchesNothing() async {
    agent.setEnvironmentError(.tooOld(found: "2.1.200"))
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)

    await send(model, "hi")

    #expect(model.selectedTab?.errorText == AgentEnvironmentError.tooOld(found: "2.1.200").message)
    #expect(agent.launches.isEmpty)
    #expect(model.selectedTab?.isWorking == false)
  }

  // MARK: - Sending

  @Test func sendAddsBubbleWritesLineAndClearsWaiting() async throws {
    let model = makeModel(records: [record(isWaiting: true)])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await model.viewAppeared()

    await send(model, "Hello")

    let tab = try #require(model.selectedTab)
    expectNoDifference(tab.projection.items, [TranscriptItem(id: UUID(1).uuidString, kind: .userMessage("Hello"))])
    expectNoDifference(agent.writes(0), [json(ClaudeInvocation.userMessage("Hello"))])
    #expect(tab.draft == "")
    #expect(tab.isWorking)
    #expect(model.records[id: Self.saved]?.isWaiting == false)
  }

  @Test func failedWriteKeepsDraftAndWaiting() async throws {
    agent.setWriteError(WriteFailed())
    let model = makeModel(records: [record(isWaiting: true)])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await model.viewAppeared()

    await send(model, "Hello")

    let tab = try #require(model.selectedTab)
    #expect(tab.draft == "Hello")
    #expect(tab.projection.items.isEmpty)
    #expect(tab.isWorking == false)
    #expect(tab.errorText == "Couldn't send your message to Claude")
    #expect(model.records[id: Self.saved]?.isWaiting == true)
  }

  @Test func emptyDraftSendsNothing() async {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)

    await send(model, "  \n")

    #expect(agent.launches.isEmpty)
  }

  @Test func secondSendReusesProcess() async {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "one")
    await line(Line.result())

    await send(model, "two")

    #expect(agent.launches.count == 1)
    expectNoDifference(agent.writes(0), [json(ClaudeInvocation.userMessage("one")), json(ClaudeInvocation.userMessage("two"))])
  }
}
