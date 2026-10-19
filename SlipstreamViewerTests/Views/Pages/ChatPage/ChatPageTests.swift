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

  func launch(folder: String = "/w", model: String = "claude-opus-5-5", effort: String = "high", session: ClaudeSessionStart) -> AgentLaunch {
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

    expectNoDifference(agent.launches, [launch(session: .new(Self.saved))])
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

    expectNoDifference(agent.launches, [launch(session: .resume(Self.saved))])
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

  // MARK: - Turns

  @Test func resultEndsTurnOnce() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await model.viewAppeared()
    await send(model, "hi")
    let loadsBeforeResult = agent.loads.count
    agent.setTranscript(Self.saved, .found([.title("Saying hi")]))
    elapsed.setValue(41)

    await line(Line.result(durationMs: 41_000))
    await line(Line.idle)
    await line(Line.result())

    let tab = try #require(model.selectedTab)
    expectNoDifference(
      tab.projection.items,
      [
        TranscriptItem(id: UUID(1).uuidString, kind: .userMessage("hi")),
        TranscriptItem(
          id: UUID(0).uuidString,
          kind: .turnFooter(ending: .completed, duration: .seconds(41), time: Self.start.addingTimeInterval(41))),
      ])
    #expect(tab.isWorking == false)
    #expect(tab.workingText == nil)
    #expect(tab.title == "Saying hi")
    #expect(agent.loads.count == loadsBeforeResult + 1)
  }

  @Test func errorResultFailsWithItsText() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")

    await line(Line.result(isError: true, text: "Model not found"))

    let tab = try #require(model.selectedTab)
    #expect(tab.errorText == "Model not found")
    #expect(tab.projection.items.last?.kind == .turnFooter(ending: .failed, duration: .seconds(41), time: Self.start))
  }

  @Test func exitBeforeResultFailsOnce() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    elapsed.setValue(5)

    agent.exit(status: 1, stderrTail: "Error: out of memory\n")
    await Task.megaYield()

    let tab = try #require(model.selectedTab)
    expectNoDifference(
      tab.projection.items,
      [
        TranscriptItem(id: UUID(1).uuidString, kind: .userMessage("hi")),
        TranscriptItem(
          id: UUID(0).uuidString,
          kind: .turnFooter(ending: .failed, duration: .seconds(5), time: Self.start.addingTimeInterval(5))),
      ])
    #expect(tab.errorText == "Claude stopped unexpectedly\nError: out of memory")
    #expect(tab.isWorking == false)
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func exitWhileIdleRelaunchesOnNextSend() async {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "one")
    await line(Line.result())
    agent.setTranscript(Self.saved, .found([]))

    agent.exit()
    await Task.megaYield()
    await send(model, "two")

    #expect(model.selectedTab?.errorText == nil)
    expectNoDifference(
      agent.launches, [launch(session: .new(Self.saved)), launch(session: .resume(Self.saved))])
    expectNoDifference(agent.writes(1), [json(ClaudeInvocation.userMessage("two"))])
  }

  @Test func staleGenerationLinesIgnored() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    let tab = try #require(model.selectedTab)

    agent.sendLine(Line.assistantText("a1", "late"))
    await tab.shutdown()
    await Task.megaYield()

    expectNoDifference(tab.projection.items, [TranscriptItem(id: UUID(1).uuidString, kind: .userMessage("hi"))])
    #expect(tab.isWorking == false)
  }

  @Test func canUseToolIsAnswered() async {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")

    await line(Line.canUseTool("req-1"))

    expectNoDifference(
      agent.writes(0),
      [
        json(ClaudeInvocation.userMessage("hi")),
        json(ClaudeInvocation.reply(requestID: "req-1", subtype: "can_use_tool", input: .object(["command": .string("ls")]))),
      ])
  }

  // MARK: - Waiting

  @Test func turnEndingOffScreenMarksWaiting() async {
    let model = makeModel(records: [record(folder: "/a")])
    model.workspaceChanged(folder: "/a", emptyText: nil)
    await send(model, "hi")

    model.workspaceChanged(folder: "/b", emptyText: nil)
    await line(Line.result())

    #expect(model.records[id: Self.saved]?.isWaiting == true)
    #expect(model.isWaiting(folder: "/a"))
    #expect(model.isWaiting(folder: "/b") == false)
    #expect(agent.shutdownCount == 0)
  }

  @Test func turnEndingOnScreenDoesNotMarkWaiting() async {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")

    await line(Line.result())

    #expect(model.records[id: Self.saved]?.isWaiting == false)
  }

  @Test func turnEndingInOtherTabMarksWaiting() async {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")

    await model.newTabTapped()
    await line(Line.result())

    #expect(model.records[id: Self.saved]?.isWaiting == true)
  }

  @Test func turnEndingWhileAppInactiveMarksWaiting() async {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")

    model.appActivityChanged(isActive: false)
    await line(Line.result())

    #expect(model.records[id: Self.saved]?.isWaiting == true)
  }

  @Test func turnEndingUnderComparisonMarksWaiting() async {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")

    model.comparisonVisibilityChanged(isShown: true)
    await line(Line.result())

    #expect(model.records[id: Self.saved]?.isWaiting == true)
  }

  @Test func turnEndingAfterReturningIsNotWaiting() async {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    model.appActivityChanged(isActive: false)
    model.comparisonVisibilityChanged(isShown: true)

    model.appActivityChanged(isActive: true)
    model.comparisonVisibilityChanged(isShown: false)
    await line(Line.result())

    #expect(model.records[id: Self.saved]?.isWaiting == false)
  }

  @Test func selectingWaitingTabKeepsItBold() async throws {
    let model = makeModel(records: [record(isWaiting: true), record(UUID(50))])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await model.tabSelected(UUID(50))

    await model.tabSelected(Self.saved)

    let tab = try #require(model.selectedTab)
    #expect(tab.isTitleBold)
    #expect(model.tabs[id: UUID(50)]?.isTitleBold == false)
  }

  // MARK: - Working line

  @Test func workingLineTicks() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let clockTask = Task { await model.clockTask() }
    await Task.megaYield()
    await send(model, "hi")
    let tab = try #require(model.selectedTab)
    #expect(tab.showsSpinner)
    #expect(tab.showsStop)

    elapsed.setValue(69)
    await line(Line.assistantText("a1", "Looking"))
    elapsed.setValue(72)
    await clock.advance(by: .seconds(72))
    #expect(tab.workingText == "Working 1m 12s · last output 3s ago")

    elapsed.setValue(73)
    await clock.advance(by: .seconds(1))
    #expect(tab.workingText == "Working 1m 13s · last output 4s ago")

    clockTask.cancel()
    await clockTask.value
  }

  @Test func ignoredLinesCountAsOutput() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")

    elapsed.setValue(30)
    await line(#"{"type":"rate_limit_event"}"#)

    #expect(model.selectedTab?.workingText == "Working 30s · last output 0s ago")
  }

  // MARK: - Stop, Try again and model change

  @Test func stopWritesInterruptAndEndsStopped() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")

    let stop = Task { await model.stopTapped() }
    await Task.megaYield()
    expectNoDifference(
      agent.writes(0),
      [json(ClaudeInvocation.userMessage("hi")), json(ClaudeInvocation.interrupt(requestID: UUID(2).uuidString))])
    #expect(model.selectedTab?.isWorking == true)

    await line(Line.result(durationMs: 12_000))
    await clock.advance(by: .seconds(10))
    await stop.value

    let tab = try #require(model.selectedTab)
    #expect(tab.projection.items.last?.kind == .turnFooter(ending: .stopped, duration: .seconds(12), time: Self.start))
    #expect(tab.isWorking == false)
    #expect(agent.shutdownCount == 0)
  }

  @Test func stopPressedResultWithIsErrorEndsStopped() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    let stop = Task { await model.stopTapped() }
    await Task.megaYield()

    await line(Line.interruptedResult(durationMs: 12_000))

    let tab = try #require(model.selectedTab)
    #expect(tab.projection.items.last?.kind == .turnFooter(ending: .stopped, duration: .seconds(12), time: Self.start))
    #expect(tab.errorText == nil)
    await clock.advance(by: .seconds(10))
    await stop.value
  }

  @Test func stopWithoutResultShutsDownAfterTenSeconds() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    let stop = Task { await model.stopTapped() }
    await Task.megaYield()

    elapsed.setValue(9)
    await clock.advance(by: .seconds(9))
    #expect(agent.shutdownCount == 0)
    #expect(model.selectedTab?.isWorking == true)

    elapsed.setValue(10)
    await clock.advance(by: .seconds(1))
    await stop.value

    let tab = try #require(model.selectedTab)
    #expect(agent.shutdownCount == 1)
    #expect(tab.isWorking == false)
    #expect(tab.showsSpinner == false)
    #expect(
      tab.projection.items.last?.kind
        == .turnFooter(ending: .stopped, duration: .seconds(10), time: Self.start.addingTimeInterval(10)))

    agent.setTranscript(Self.saved, .found([]))
    await send(model, "again")
    expectNoDifference(agent.launches.last, launch(session: .resume(Self.saved)))
  }

  @Test func stopWhileLaunchingEndsStoppedAndLaunchesNothing() async throws {
    agent.hold(.environment)
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)
    tab.draft = "hi"
    let sending = Task { await model.sendTapped() }
    await Task.megaYield()
    #expect(tab.isWorking)

    let stop = Task { await model.stopTapped() }
    await Task.megaYield()
    #expect(tab.isWorking == false)
    agent.release(.environment)
    await stop.value
    await sending.value
    await Task.megaYield()

    #expect(tab.isWorking == false)
    #expect(tab.projection.items.last?.kind == .turnFooter(ending: .stopped, duration: .zero, time: Self.start))
    #expect(tab.errorText == nil)
    #expect(agent.launches.isEmpty)
    #expect(tab.draft == "hi")
  }

  @Test func exitAfterStopEndsStopped() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    let stop = Task { await model.stopTapped() }
    await Task.megaYield()

    agent.exit(status: 130)
    await Task.megaYield()

    let tab = try #require(model.selectedTab)
    #expect(tab.projection.items.last?.kind == .turnFooter(ending: .stopped, duration: .zero, time: Self.start))
    #expect(tab.errorText == nil)
    await clock.advance(by: .seconds(10))
    await stop.value
    #expect(agent.shutdownCount == 1)
  }

  @Test func tryAgainReloadsAndNeverResends() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    agent.exit(stderrTail: "boom")
    await Task.megaYield()
    let history: [AgentLine] = [
      .user(uuid: "u1", timestamp: Self.start, isPrompt: true, blocks: [.text("hi")]),
      .title("Saying hi"),
    ]
    agent.setTranscript(Self.saved, .found(history))

    await model.tryAgainTapped()
    await Task.megaYield()

    let tab = try #require(model.selectedTab)
    #expect(tab.errorText == nil)
    expectNoDifference(tab.projection, .history(history))
    #expect(tab.title == "Saying hi")
    expectNoDifference(agent.launches.last, launch(session: .resume(Self.saved)))
    expectNoDifference(agent.writes(1), [])
  }

  @Test func choiceChangeOnIdleTabRestartsWithNewFlags() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "one")
    await line(Line.result())

    await model.choiceSelected(model: "claude-sonnet-5-5", effort: .low)

    expectNoDifference(model.records[id: Self.saved], record(model: "claude-sonnet-5-5", effort: .low))
    #expect(agent.shutdowns(0) == 1)
    #expect(model.selectedTab?.pickerText == "Sonnet 5.5 Low")

    agent.setTranscript(Self.saved, .found([]))
    await send(model, "two")
    expectNoDifference(
      agent.launches.last, launch(model: "claude-sonnet-5-5", effort: "low", session: .resume(Self.saved)))
    #expect(agent.launches[1].arguments.contains("--resume=4bad416c-1d04-4063-9e76-61ebb936ae06"))
  }

  @Test func pickerDisabledWhileWorking() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)
    #expect(tab.pickerText == "Opus 5.5 High")
    #expect(tab.isPickerEnabled)

    await send(model, "hi")
    #expect(tab.isPickerEnabled == false)
    await model.choiceSelected(model: "claude-haiku-5-5", effort: .max)

    expectNoDifference(model.records[id: Self.saved], record())
    #expect(agent.shutdownCount == 0)
  }

  // MARK: - Close and quit

  @Test func closingWorkingTabRemovesRecordThenShutsDown() async throws {
    let model = makeModel(records: [record(), record(UUID(50))])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    let tab = try #require(model.selectedTab)

    agent.sendLine(Line.assistantText("a1", "late"))
    await model.closeTabTapped(Self.saved)
    await Task.megaYield()

    expectNoDifference(model.records, [record(UUID(50))])
    #expect(model.tabs.ids == [UUID(50)])
    #expect(agent.shutdowns(0) == 1)
    expectNoDifference(tab.projection.items, [TranscriptItem(id: UUID(1).uuidString, kind: .userMessage("hi"))])
    #expect(model.workingTabCount == 0)
  }

  @Test func quitAlertTextCountsWorkingTabsInAllFolders() async {
    let model = makeModel(records: [record(folder: "/a"), record(UUID(50), folder: "/b")])
    #expect(model.quitAlertText == nil)
    model.workspaceChanged(folder: "/a", emptyText: nil)
    await send(model, "one")
    model.workspaceChanged(folder: "/b", emptyText: nil)
    await send(model, "two")

    #expect(model.workingTabCount == 2)
    #expect(
      model.quitAlertText
        == "Claude is still working in 2 tabs. Quitting stops them. You can pick the conversations up again next time.")

    await line(Line.result(), to: 1)
    #expect(
      model.quitAlertText
        == "Claude is still working in 1 tab. Quitting stops them. You can pick the conversations up again next time.")

    await line(Line.result(), to: 0)
    #expect(model.quitAlertText == nil)
  }

  @Test func quitConfirmedShutsDownEverything() async {
    let model = makeModel(records: [record(folder: "/a"), record(UUID(50), folder: "/b")])
    model.workspaceChanged(folder: "/a", emptyText: nil)
    await send(model, "one")
    await line(Line.result())
    model.workspaceChanged(folder: "/b", emptyText: nil)
    await send(model, "two")

    await model.quitConfirmed()

    #expect(agent.shutdowns(0) == 1)
    #expect(agent.shutdowns(1) == 1)
    #expect(model.workingTabCount == 0)
  }

  @Test func hiddenFolderTabsStillCount() async {
    let model = makeModel(records: [record(folder: "/a")])
    model.workspaceChanged(folder: "/a", emptyText: nil)
    await send(model, "hi")

    model.workspaceChanged(folder: nil, emptyText: "Choose a capture session to watch its changes")

    #expect(model.visibleTabs.isEmpty)
    #expect(model.workingTabCount == 1)
    #expect(agent.shutdownCount == 0)
  }

  // MARK: - Races

  @Test func stopWithBlockedWriteStillShutsDownAfterTenSeconds() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    agent.hold(.writes)

    let stop = Task { await model.stopTapped() }
    await Task.megaYield()
    await clock.advance(by: .seconds(10))
    await stop.value

    #expect(model.selectedTab?.isWorking == false)
    #expect(agent.shutdownCount == 1)
    agent.release(.writes)
  }

  @Test func sendAfterStopDeadlineIsNotKilled() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    let stop = Task { await model.stopTapped() }
    await Task.megaYield()

    agent.hold(.environment)
    await clock.advance(by: .seconds(10))
    await stop.value
    let tab = try #require(model.selectedTab)
    tab.draft = "again"
    let sending = Task { await model.sendTapped() }
    await Task.megaYield()
    agent.release(.environment)
    await sending.value
    await Task.megaYield()

    #expect(tab.isWorking)
    #expect(agent.shutdowns(0) == 1)
    #expect(agent.shutdowns(1) == 0)
  }

  @Test func shutdownInProgressHoldsBackSend() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    let stop = Task { await model.stopTapped() }
    await Task.megaYield()

    agent.hold(.shutdowns)
    await clock.advance(by: .seconds(10))
    let tab = try #require(model.selectedTab)
    #expect(tab.isWorking)
    await send(model, "again")
    #expect(agent.launches.count == 1)

    agent.release(.shutdowns)
    await stop.value
    #expect(tab.isWorking == false)
    #expect(tab.projection.items.last?.kind == .turnFooter(ending: .stopped, duration: .zero, time: Self.start))
  }

  @Test func closingDuringTryAgainLaunchesNothing() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    agent.exit()
    await Task.megaYield()

    agent.hold(.environment)
    let retry = Task { await model.tryAgainTapped() }
    await Task.megaYield()
    await model.closeTabTapped(Self.saved)
    agent.release(.environment)
    await retry.value
    await Task.megaYield()

    #expect(agent.launches.count == 1)
  }

  @Test func quitWaitsForShutdownAlreadyRunning() async {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    agent.hold(.shutdowns)
    agent.exit()
    await Task.megaYield()

    let didQuit = LockIsolated(false)
    let quit = Task {
      await model.quitConfirmed()
      didQuit.setValue(true)
    }
    await Task.megaYield()
    #expect(didQuit.value == false)

    agent.release(.shutdowns)
    await quit.value
    #expect(didQuit.value)
    #expect(agent.shutdowns(0) == 1)
  }

  @Test func writeFinishingAfterExitShowsNoBubble() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    agent.hold(.writes)
    let tab = try #require(model.selectedTab)
    tab.draft = "hi"
    let sending = Task { await model.sendTapped() }
    await Task.megaYield()

    agent.exit()
    await Task.megaYield()
    agent.release(.writes)
    await sending.value

    expectNoDifference(
      tab.projection.items.map(\.kind), [.turnFooter(ending: .failed, duration: .zero, time: Self.start)])
    #expect(tab.draft == "hi")
  }

  @Test func choiceChangeDuringTryAgainLaunchUsesNewFlags() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "one")
    agent.exit()
    await Task.megaYield()
    agent.setTranscript(Self.saved, .found([]))

    agent.hold(.launches)
    let retry = Task { await model.tryAgainTapped() }
    await Task.megaYield()
    await model.choiceSelected(model: "claude-sonnet-5-5", effort: .low)
    agent.release(.launches)
    await retry.value
    await Task.megaYield()
    #expect(agent.shutdowns(1) == 1)

    await send(model, "two")
    expectNoDifference(
      agent.launches.last, launch(model: "claude-sonnet-5-5", effort: "low", session: .resume(Self.saved)))
  }

  @Test func titleRefreshDoesNotHoldBackNextTurn() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "one")
    agent.hold(.environment)
    await line(Line.result())

    await send(model, "two")
    await line(Line.result())

    let tab = try #require(model.selectedTab)
    #expect(tab.isWorking == false)
    #expect(tab.projection.items.filter { if case .turnFooter = $0.kind { true } else { false } }.count == 2)
    agent.release(.environment)
  }

  @Test func sendDuringFirstHistoryLoadKeepsHistory() async throws {
    let history: [AgentLine] = [
      .user(uuid: "u1", timestamp: Self.start, isPrompt: true, blocks: [.text("Fix the build")]),
      .title("Fixing the build"),
    ]
    agent.setTranscript(Self.saved, .found(history))
    agent.hold(.environment)
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)
    let appearing = Task { await model.viewAppeared() }
    await Task.megaYield()
    tab.draft = "more"
    let sending = Task { await model.sendTapped() }
    await Task.megaYield()

    agent.release(.environment)
    await appearing.value
    await sending.value

    var expected = TranscriptProjection.history(history)
    expected.userSent("more", id: UUID(1).uuidString)
    expectNoDifference(tab.projection, expected)
    #expect(tab.title == "Fixing the build")
  }

  // MARK: - Row text

  @Test func toolRowsChangeTenseWithStatus() async throws {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)
    func tool(_ name: String, _ target: String?, _ status: ToolStatus) -> String {
      tab.rowText(for: TranscriptItem(id: "t", kind: .toolCall(name: name, target: target, status: status, detail: nil)))
    }

    #expect(tool("Bash", "swift test", .running) == "Running `swift test`")
    #expect(tool("Bash", "swift test", .done) == "Ran `swift test`")
    #expect(tool("Bash", "swift test", .failed) == "Ran `swift test` · failed")
    #expect(tool("Bash", "swift test", .stopped) == "Ran `swift test` · stopped")
    #expect(tool("Edit", "File.swift", .done) == "Edited `File.swift`")
    #expect(tool("Write", "File.swift", .running) == "Editing `File.swift`")
    #expect(tool("Read", "File.swift", .done) == "Read `File.swift`")
    #expect(tool("Grep", nil, .done) == "Used `Grep`")
  }

  @Test func otherRowsShowTheirText() async throws {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)

    #expect(tab.rowText(for: TranscriptItem(id: "u", kind: .userMessage("Fix it"))) == "Fix it")
    #expect(tab.rowText(for: TranscriptItem(id: "r", kind: .reply("Fixed."))) == "Fixed.")
    #expect(tab.rowText(for: TranscriptItem(id: "g", kind: .gap)) == "Part of this conversation couldn't be shown")
  }

  @Test func footerRowsShowEndingDurationAndTime() async throws {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)
    let threeOhNine = Date(timeIntervalSince1970: 1_760_022_540)
    func footer(_ ending: TurnEnding, _ duration: Duration) -> String {
      tab.rowText(for: TranscriptItem(id: "f", kind: .turnFooter(ending: ending, duration: duration, time: threeOhNine)))
    }

    #expect(footer(.completed, .seconds(41)) == "41s · 3:09 PM")
    #expect(footer(.completed, .milliseconds(72_900)) == "1m 12s · 3:09 PM")
    #expect(footer(.stopped, .seconds(41)) == "Stopped · 41s · 3:09 PM")
    #expect(footer(.failed, .seconds(41)) == "Failed · 41s · 3:09 PM")
  }
}
