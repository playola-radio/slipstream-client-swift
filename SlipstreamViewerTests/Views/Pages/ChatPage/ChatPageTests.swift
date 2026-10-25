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
  let link = ChatLinkFake()
  let clock = TestClock()
  let elapsed = LockIsolated<TimeInterval>(0)
  let copied = LockIsolated<[String]>([])

  func makeModel(records: [ChatTabRecord] = []) -> ChatPageModel {
    withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.agentEnvironment = agent.environmentClient
      $0.agentProcess = agent.processClient
      $0.transcripts = agent.transcriptClient
      $0.chatLink = link.client
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0.date = DateGenerator { [elapsed] in Self.start.addingTimeInterval(elapsed.value) }
      $0.timeZone = TimeZone(identifier: "UTC")!
      $0.pasteboard = PasteboardClient(copy: { [copied] text in copied.withValue { $0.append(text) } })
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

  @Test func replyArrivingDuringWriteStaysAfterPromptAndClearsSentDraft() async throws {
    agent.hold(.writes)
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)
    tab.draft = "Hello"

    let sending = Task { await model.sendTapped() }
    await Task.megaYield()
    await line(Line.assistantText("a1", "Hi"))
    await line(Line.result())
    agent.release(.writes)
    await sending.value

    expectNoDifference(
      tab.projection.items.map(\.kind),
      [
        .userMessage("Hello"),
        .reply("Hi"),
        .turnFooter(ending: .completed, duration: .seconds(41), time: Self.start),
      ])
    #expect(tab.draft == "")
  }

  @Test func sendClearsDraftWithTrailingNewline() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)

    await send(model, "Hello\n")

    #expect(model.selectedTab?.draft == "")
    expectNoDifference(agent.writes(0), [json(ClaudeInvocation.userMessage("Hello"))])
  }

  @Test func multilineDraftWaitsForSendAndWritesOnce() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)
    tab.draft = "First line\nSecond line"

    #expect(agent.launches.isEmpty)
    expectNoDifference(tab.projection.items, [])

    await model.sendTapped()

    expectNoDifference(
      tab.projection.items,
      [TranscriptItem(id: UUID(1).uuidString, kind: .userMessage("First line\nSecond line"))])
    expectNoDifference(agent.writes(0), [json(ClaudeInvocation.userMessage("First line\nSecond line"))])
    #expect(tab.draft == "")
  }

  @Test func editingDraftDuringWriteKeepsNewText() async throws {
    agent.hold(.writes)
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)
    tab.draft = "first"

    let sending = Task { await model.sendTapped() }
    await Task.megaYield()
    tab.draft = "new draft"
    agent.release(.writes)
    await sending.value

    #expect(tab.draft == "new draft")
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

  @Test func sendAfterChoiceWaitsForOldShutdown() async {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "one")
    await line(Line.result())
    agent.hold(.shutdowns)

    let choosing = Task { await model.choiceSelected(model: "claude-sonnet-5-5", effort: .low) }
    await Task.megaYield()
    let tab = model.selectedTab
    tab?.draft = "two"
    let sending = Task { await model.sendTapped() }
    await Task.megaYield()

    #expect(agent.launches.count == 1)
    agent.release(.shutdowns)
    await choosing.value
    await sending.value

    #expect(agent.shutdowns(0) == 1)
    #expect(agent.launches.count == 2)
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

  @Test func stopTabsInFolderStopsEveryAgentButKeepsItsConversations() async {
    let model = makeModel(records: [
      record(UUID(60), folder: "/b"), record(folder: "/a"), record(UUID(50), folder: "/a"),
    ])
    model.workspaceChanged(folder: "/b", emptyText: nil)
    await send(model, "b")
    await line(Line.result(), to: 0)
    model.workspaceChanged(folder: "/a", emptyText: nil)
    await send(model, "one")
    await line(Line.result(), to: 1)
    await model.tabSelected(UUID(50))
    await send(model, "two")

    _ = await model.stopTabs(in: "/a")

    #expect(model.tabs.ids == [UUID(60)])
    #expect(agent.shutdowns(0) == 0)
    #expect(agent.shutdowns(1) == 1)
    #expect(agent.shutdowns(2) == 1)
    expectNoDifference(model.records.map(\.id), [UUID(60), Self.saved, UUID(50)])

    model.workspaceChanged(folder: "/a", emptyText: nil)

    expectNoDifference(model.visibleTabs.map(\.id), [Self.saved, UUID(50)])
    #expect(model.selectedTab?.id == UUID(50))
  }

  @Test func forgetTabsInFolderRemovesOnlyThatFolder() {
    let model = makeModel(records: [record(UUID(60), folder: "/b"), record(folder: "/a")])

    model.forgetTabs(in: "/a")

    expectNoDifference(model.records, [record(UUID(60), folder: "/b")])
  }

  @Test func hasWorkingTabOnlyCountsThatFolder() async {
    let model = makeModel(records: [record(folder: "/a"), record(UUID(50), folder: "/b")])
    model.workspaceChanged(folder: "/a", emptyText: nil)
    await send(model, "one")

    #expect(model.hasWorkingTab(in: "/a"))
    #expect(!model.hasWorkingTab(in: "/b"))
  }

  @Test func sendWhileQuittingLaunchesNothing() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    await line(Line.result())
    agent.hold(.shutdowns)
    let quit = Task { await model.quitConfirmed() }
    await Task.megaYield()
    #expect(model.isMessageBoxEnabled == false)

    let tab = try #require(model.selectedTab)
    tab.draft = "again"
    let sending = Task { await model.sendTapped() }
    await Task.megaYield()
    agent.release(.shutdowns)
    await quit.value
    await sending.value
    await Task.megaYield()

    #expect(agent.launches.count == 1)
    #expect(agent.shutdownCount == 1)
  }

  @Test func sendWaitingOnShutdownWhenTabClosesLaunchesNothing() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    await line(Line.result())
    agent.hold(.shutdowns)
    agent.exit()
    await Task.megaYield()

    let tab = try #require(model.selectedTab)
    tab.draft = "again"
    let sending = Task { await model.sendTapped() }
    await Task.megaYield()
    let closing = Task { await model.closeTabTapped(Self.saved) }
    await Task.megaYield()
    agent.release(.shutdowns)
    await closing.value
    await sending.value
    await Task.megaYield()

    #expect(agent.launches.count == 1)
    #expect(tab.isWorking == false)
  }

  @Test func sendWaitingOnShutdownWhenQuitLaunchesNothing() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    await line(Line.result())
    agent.hold(.shutdowns)
    agent.exit()
    await Task.megaYield()

    let tab = try #require(model.selectedTab)
    tab.draft = "again"
    let sending = Task { await model.sendTapped() }
    await Task.megaYield()
    let quit = Task { await model.quitConfirmed() }
    await Task.megaYield()
    agent.release(.shutdowns)
    await quit.value
    await sending.value
    await Task.megaYield()

    #expect(agent.launches.count == 1)
    #expect(tab.isWorking == false)
  }

  @Test func tryAgainAfterQuitLaunchesNothing() async {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    agent.exit()
    await Task.megaYield()

    await model.quitConfirmed()
    await model.tryAgainTapped()
    await Task.megaYield()

    #expect(agent.launches.count == 1)
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

  @Test func writeFinishingAfterExitKeepsPromptAndClearsSentDraft() async throws {
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
      tab.projection.items.map(\.kind),
      [.userMessage("hi"), .turnFooter(ending: .failed, duration: .zero, time: Self.start)])
    #expect(tab.draft == "")
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
    let choosing = Task { await model.choiceSelected(model: "claude-sonnet-5-5", effort: .low) }
    await Task.megaYield()
    agent.release(.launches)
    await choosing.value
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

  @Test func quitWaitsForLaunchStillOnItsWay() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    agent.hold(.launches)
    let tab = try #require(model.selectedTab)
    tab.draft = "hi"
    let sending = Task { await model.sendTapped() }
    await Task.megaYield()

    let didQuit = LockIsolated(false)
    let quit = Task {
      await model.quitConfirmed()
      didQuit.setValue(true)
    }
    await Task.megaYield()
    #expect(didQuit.value == false)

    agent.release(.launches)
    await quit.value
    await sending.value
    #expect(agent.shutdowns(0) == 1)
    #expect(tab.isWorking == false)
  }

  @Test func writeFinishingAfterResultKeepsPromptAndWaiting() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    model.appActivityChanged(isActive: false)
    agent.hold(.writes)
    let tab = try #require(model.selectedTab)
    tab.draft = "hi"
    let sending = Task { await model.sendTapped() }
    await Task.megaYield()

    await line(Line.result(durationMs: 3_000))
    agent.release(.writes)
    await sending.value

    expectNoDifference(
      tab.projection.items.map(\.kind),
      [.userMessage("hi"), .turnFooter(ending: .completed, duration: .seconds(3), time: Self.start)])
    #expect(model.records[id: Self.saved]?.isWaiting == true)
  }

  @Test func olderTitleRefreshNeverOverwritesNewerTitle() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "one")
    agent.hold(.environment)
    await line(Line.result())
    await send(model, "two")
    await line(Line.result())

    agent.setTranscript(Self.saved, .found([.title("Second")]))
    agent.releaseLast(.environment)
    await Task.megaYield()
    agent.setTranscript(Self.saved, .found([.title("First")]))
    agent.release(.environment)
    await Task.megaYield()

    #expect(model.selectedTab?.title == "Second")
  }

  @Test func quitShutsDownEveryProcessAfterSerializedStarts() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    agent.hold(.launches)
    let tab = try #require(model.selectedTab)
    tab.draft = "one"
    let first = Task { await model.sendTapped() }
    await Task.megaYield()
    await model.stopTapped()
    tab.draft = "two"
    let second = Task { await model.sendTapped() }
    await Task.megaYield()
    agent.release(.launches)
    await second.value

    await model.quitConfirmed()
    await first.value
    #expect(agent.launches.count == 2)
    #expect(agent.shutdownCount == 2)
  }

  @Test func closingBeforeQueuedStartRunsLaunchesNothingLive() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)
    tab.draft = "hi"

    let sending = Task { await model.sendTapped() }
    let closing = Task { await model.closeTabTapped(Self.saved) }
    await closing.value
    await sending.value
    await Task.megaYield()

    #expect(agent.shutdownCount == agent.launches.count)
    #expect(tab.isWorking == false)
  }

  @Test func stopDeadlineIgnoresEarlierStaleLaunch() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    agent.hold(.launches)
    let tab = try #require(model.selectedTab)
    tab.draft = "one"
    let first = Task { await model.sendTapped() }
    await Task.megaYield()
    await model.stopTapped()
    tab.draft = "two"
    let second = Task { await model.sendTapped() }
    await Task.megaYield()
    agent.release(.launches)
    await second.value

    let stop = Task { await model.stopTapped() }
    await Task.megaYield()
    await clock.advance(by: .seconds(10))
    await stop.value

    #expect(tab.isWorking == false)
    agent.release(.launches)
    await first.value
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

  @Test func textRowsDropSurroundingBlankLines() async throws {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)

    #expect(tab.rowText(for: TranscriptItem(id: "t", kind: .thinking("Plan it.\n\n"))) == "Plan it.")
    #expect(tab.rowText(for: TranscriptItem(id: "u", kind: .userMessage("\nFix it\n"))) == "Fix it")
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

  // MARK: - Screen

  @Test func messageBoxWithoutWorkspaceIsDisabled() {
    let model = makeModel()
    model.workspaceChanged(folder: nil, emptyText: "Choose a capture session to watch its changes")

    model.draft = "lost"

    #expect(model.isMessageBoxEnabled == false)
    #expect(model.isPickerEnabled == false)
    #expect(model.showsNewTabButton == false)
    #expect(model.draft == "")
    #expect(model.pickerText == "Opus 5.5 High")
  }

  @Test func messageBoxEditsSelectedTab() async throws {
    let model = makeModel(records: [record(model: "claude-sonnet-5-5", effort: .low)])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)

    model.draft = "hello"

    #expect(tab.draft == "hello")
    #expect(model.isMessageBoxEnabled)
    #expect(model.isPickerEnabled)
    #expect(model.showsNewTabButton)
    #expect(model.pickerText == "Sonnet 5.5 Low")
    #expect(model.showsStop == false)
    await send(model, "hello")
    #expect(model.showsStop)
    #expect(model.isPickerEnabled == false)
  }

  @Test func onlySelectedTabIsSelected() async throws {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await model.newTabTapped()

    expectNoDifference(model.visibleTabs.map(model.isSelected), [false, true])
  }

  @Test func hoveringTabShowsItsClose() async throws {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await model.newTabTapped()

    model.tabHovered(UUID(0), isHovering: true)
    expectNoDifference(model.visibleTabs.map(model.isHovered), [true, false])

    model.tabHovered(UUID(1), isHovering: true)
    model.tabHovered(UUID(0), isHovering: false)
    expectNoDifference(model.visibleTabs.map(model.isHovered), [false, true])
  }

  @Test func modelChoiceKeepsEffort() async {
    let model = makeModel(records: [record(effort: .low)])
    model.workspaceChanged(folder: "/w", emptyText: nil)

    await model.modelSelected("claude-haiku-5-5")
    expectNoDifference(model.records, [record(model: "claude-haiku-5-5", effort: .low)])

    await model.effortSelected(.max)
    expectNoDifference(model.records, [record(model: "claude-haiku-5-5", effort: .max)])
  }

  @Test func closeShortcutClosesSelectedTab() async {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await model.newTabTapped()

    await model.closeShortcutPressed()

    expectNoDifference(model.visibleTabs.map(\.id), [UUID(0)])
  }

  /// With the comparison open the chat isn't on screen, so ⌘W has nothing to close.
  @Test func closeShortcutWhileComparisonShownClosesNothing() async {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await model.newTabTapped()
    model.comparisonVisibilityChanged(isShown: true)

    await model.closeShortcutPressed()

    expectNoDifference(model.visibleTabs.map(\.id), [UUID(0), UUID(1)])
  }

  @Test func thinkingStartsOpenAndToolsStartClosed() async throws {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)
    let thinking = TranscriptItem(id: "th", kind: .thinking("Hmm"))
    let tool = TranscriptItem(id: "t", kind: .toolCall(name: "Bash", target: "ls", status: .done, detail: "a.swift"))
    #expect(tab.isExpanded(thinking))
    #expect(tab.isExpanded(tool) == false)

    tab.itemToggled(thinking)
    tab.itemToggled(tool)

    #expect(tab.isExpanded(thinking) == false)
    #expect(tab.isExpanded(tool))
    #expect(tab.detailText(for: tool) == "a.swift")
    #expect(tab.detailText(for: thinking) == nil)
  }

  @Test func toolRowsShowTheirKindAndWhetherTheyRun() async throws {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)
    let running = TranscriptItem(id: "r", kind: .toolCall(name: "Bash", target: "ls", status: .running, detail: nil))
    let edited = TranscriptItem(id: "e", kind: .toolCall(name: "MultiEdit", target: "A.swift", status: .done, detail: nil))
    let reply = TranscriptItem(id: "p", kind: .reply("Hi"))

    expectNoDifference([running, edited, reply].map(tab.toolKind), [.run, .edit, nil])
    expectNoDifference([running, edited, reply].map(tab.isRunning), [true, false, false])
  }

  @Test func copyCopiesTheTurnsReply() async throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await send(model, "hi")
    await line(Line.assistantText("a1", "First"))
    await line(Line.assistantText("a2", "Second"))
    await line(Line.result())
    let tab = try #require(model.selectedTab)
    let footer = try #require(tab.projection.items.last)

    tab.copyTapped(footer)

    expectNoDifference(copied.value, ["First\n\nSecond"])
  }

  @Test func fencedCodeSplitsFromProse() throws {
    let text = """
      Run **this**:
      ```swift
      let a = 1

      let b = 2
      ```
      Then `check`.
      ```
      unclosed
      """
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)

    expectNoDifference(
      ChatTabModel.markdownBlocks(text),
      [
        .prose(try AttributedString(markdown: "Run **this**:", options: options)),
        .code("let a = 1\n\nlet b = 2"),
        .prose(try AttributedString(markdown: "Then `check`.", options: options)),
        .code("unclosed"),
      ])
    expectNoDifference(ChatTabModel.markdownBlocks("plain"), [.prose(AttributedString("plain"))])
  }

  @Test func inlineCodeWithThreeLeadingBackticksStaysProse() throws {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)

    expectNoDifference(
      ChatTabModel.markdownBlocks("```hello```"),
      [.prose(try AttributedString(markdown: "```hello```", options: options))])
  }

  @Test func longerFenceKeepsInnerFencesAsCode() {
    let text = """
      ````markdown
      ```swift
      let a = 1
      ```
      ````
      ```
      `tick` stays
      ```
      """

    expectNoDifference(
      ChatTabModel.markdownBlocks(text),
      [
        .code("```swift\nlet a = 1\n```"),
        .code("`tick` stays"),
      ])
  }

  @Test func rowMarkdownParsesInlineCode() throws {
    let model = makeModel()
    model.workspaceChanged(folder: "/w", emptyText: nil)
    let tab = try #require(model.selectedTab)
    let tool = TranscriptItem(id: "t", kind: .toolCall(name: "Bash", target: "ls", status: .done, detail: nil))

    let row = tab.rowMarkdown(for: tool)

    let code = row.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
    expectNoDifference(code.map { String(row[$0.range].characters) }, ["ls"])
  }

  // MARK: - Linking

  nonisolated static let outside = UUID(uuidString: "0D7C40A5-6E4B-4E0B-9F43-0F3A1A2B3C4D")!

  func captures(_ binding: CaptureBinding?) -> [CaptureSummary] {
    [CaptureSummary(sessionID: "capture-1", root: "/w", state: .recording, binding: binding)]
  }

  func binding(_ state: BindingState, chat: UUID = saved, generation: String = "g1") -> CaptureBinding {
    CaptureBinding(generation: generation, state: state, harnessSessionID: chat.uuidString.lowercased())
  }

  /// Opens "/w" with these tabs, each with a message when it has a transcript, and delivers the
  /// first capture read, which is the moment a window opens.
  func openWindow(
    records: [ChatTabRecord], withMessage: [UUID], captures: [CaptureSummary]
  ) async -> ChatPageModel {
    for id in withMessage { agent.setTranscript(id, .found([.title("Old")])) }
    let model = makeModel(records: records)
    model.workspaceChanged(folder: "/w", emptyText: nil)
    model.capturesArrived(captures)
    await Task.megaYield()
    return model
  }

  func refresh(_ model: ChatPageModel, to next: [CaptureSummary], count: LockIsolated<Int>? = nil) {
    model.onLinkChanged = { [weak model] in
      count?.withValue { $0 += 1 }
      model?.capturesArrived(next)
    }
  }

  func tab(_ model: ChatPageModel, _ id: UUID) throws -> ChatTabModel {
    try #require(model.tabs[id: id])
  }

  @Test func linkedTabShowsConnectedIcon() async throws {
    let model = await openWindow(records: [record()], withMessage: [Self.saved], captures: captures(binding(.connected)))

    let tab = try tab(model, Self.saved)
    #expect(model.linkIcon(for: tab) == .connected)
    #expect(model.linkHoverTitle(for: tab) == "Connected to Stream")
    #expect(model.linkHoverText(for: tab) == nil)
    #expect(model.linkHelpText(for: tab) == "Connected to Stream")
    #expect(model.outsideChatText == nil)
    #expect(model.askRoute(forFolder: "/w") == .app)
  }

  @Test func linkedTabWithoutMessageCannotBeAsked() async throws {
    let model = await openWindow(records: [record()], withMessage: [], captures: captures(binding(.connected)))

    #expect(model.askRoute(forFolder: "/w") == AskRoute.none)
  }

  @Test func setupPendingShowsWaitingIcon() async throws {
    let model = await openWindow(records: [record()], withMessage: [Self.saved], captures: captures(binding(.setupPending)))

    let tab = try tab(model, Self.saved)
    #expect(model.linkIcon(for: tab) == .waiting)
    #expect(model.linkHoverTitle(for: tab) == "Connected to Stream")
    #expect(
      model.linkHoverText(for: tab)
        == "Waiting for it to confirm. It connects the next time the agent works — send it a message to connect now.")
    #expect(
      model.linkHelpText(for: tab)
        == "Connected to Stream\nWaiting for it to confirm. It connects the next time the agent works — send it a message to connect now.")
    #expect(model.askRoute(forFolder: "/w") == .app)
  }

  @Test func unlinkedWithOldIDShowsNoIcon() async throws {
    link.setOutcomes(.skipped)
    let model = await openWindow(records: [record()], withMessage: [Self.saved], captures: captures(binding(.unlinked)))

    let tab = try tab(model, Self.saved)
    #expect(model.linkIcon(for: tab) == nil)
    #expect(model.linkHoverTitle(for: tab) == nil)
    #expect(model.linkHelpText(for: tab) == nil)
    #expect(model.outsideChatText == nil)
    #expect(model.askRoute(forFolder: "/w") == .outside)
  }

  @Test func outsideChatShowsLabelAndNoIcon() async throws {
    let model = await openWindow(
      records: [record()], withMessage: [Self.saved], captures: captures(binding(.connected, chat: Self.outside)))

    #expect(model.linkIcon(for: try tab(model, Self.saved)) == nil)
    #expect(model.outsideChatText == "Stream: outside chat")
    #expect(model.askRoute(forFolder: "/w") == .outside)
    #expect(link.calls.isEmpty)
  }

  @Test func firstTabWaitsWhenNothingLinkedAndNoMessage() async throws {
    let model = await openWindow(records: [record(), record(UUID(50))], withMessage: [], captures: captures(nil))

    let first = try tab(model, Self.saved)
    #expect(model.linkIcon(for: first) == .waiting)
    #expect(model.linkHoverTitle(for: first) == "Connected to Stream")
    #expect(
      model.linkHoverText(for: first)
        == "Waiting for it to confirm. It connects the next time the agent works — send it a message to connect now.")
    #expect(model.linkIcon(for: try tab(model, UUID(50))) == nil)
    #expect(link.calls.isEmpty)
  }

  @Test func nothingShowsBeforeCapturesAreKnown() throws {
    let model = makeModel(records: [record()])
    model.workspaceChanged(folder: "/w", emptyText: nil)

    #expect(model.linkIcon(for: try tab(model, Self.saved)) == nil)
    #expect(model.outsideChatText == nil)
  }

  @Test(arguments: [BindingState.unavailable, .unknown("paused")])
  func unavailableAndUnknownShowNothing(state: BindingState) async throws {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [UUID(50)], captures: captures(binding(state)))

    #expect(model.linkIcon(for: try tab(model, Self.saved)) == nil)
    #expect(model.linkIcon(for: try tab(model, UUID(50))) == nil)
    #expect(model.outsideChatText == nil)
    #expect(model.askRoute(forFolder: "/w") == .outside)
    #expect(link.calls.isEmpty)
  }

  @Test func windowOpenLinksFirstTabWithMessage() async {
    _ = await openWindow(
      records: [record(), record(UUID(50)), record(UUID(51))], withMessage: [UUID(50), UUID(51)],
      captures: captures(nil))

    expectNoDifference(link.calls, [.link(folder: "/w", tabID: UUID(50), replacing: nil)])
  }

  @Test func windowOpenLinksWhenTheCapturesArriveBeforeTheFolder() async {
    agent.setTranscript(Self.saved, .found([.title("Old")]))
    let model = makeModel(records: [record()])
    model.capturesArrived(captures(nil))
    model.workspaceChanged(folder: "/w", emptyText: nil)
    await Task.megaYield()

    expectNoDifference(link.calls, [.link(folder: "/w", tabID: Self.saved, replacing: nil)])
  }

  @Test func theLiveCaptureSpeaksForAFolderRecordedBefore() async throws {
    let older = CaptureSummary(
      sessionID: "capture-0", root: "/w", state: .stopped, binding: binding(.unlinked, generation: "g0"))
    let model = await openWindow(
      records: [record()], withMessage: [Self.saved], captures: [older] + captures(binding(.connected)))

    #expect(model.linkIcon(for: try tab(model, Self.saved)) == .connected)
    #expect(link.calls.isEmpty)
  }

  @Test func windowOpenLinksOverAnUnlinkedBinding() async {
    _ = await openWindow(records: [record()], withMessage: [Self.saved], captures: captures(binding(.unlinked)))

    expectNoDifference(link.calls, [.link(folder: "/w", tabID: Self.saved, replacing: nil)])
  }

  @Test func turnEndingWhileNothingLinkedLinks() async {
    let model = await openWindow(records: [], withMessage: [], captures: captures(nil))
    #expect(link.calls.isEmpty)

    await send(model, "hi")
    await line(Line.result())

    expectNoDifference(link.calls, [.link(folder: "/w", tabID: UUID(0), replacing: nil)])
  }

  @Test func turnEndingWhileLinkedDoesNothing() async {
    let model = await openWindow(records: [record()], withMessage: [Self.saved], captures: captures(binding(.connected)))

    await send(model, "hi")
    await line(Line.result())

    #expect(link.calls.isEmpty)
  }

  @Test func ordinaryRefreshNeverStartsAutoLink() async {
    let model = await openWindow(records: [record()], withMessage: [Self.saved], captures: captures(binding(.connected)))

    model.capturesArrived(captures(binding(.unlinked)))
    await Task.megaYield()
    model.capturesArrived(captures(nil))
    await Task.megaYield()

    #expect(link.calls.isEmpty)
  }

  @Test func retryLaterWaitsForNextTurnEnd() async throws {
    link.setOutcomes(.retryLater)
    let model = await openWindow(records: [], withMessage: [], captures: captures(nil))
    await send(model, "hi")
    await line(Line.result())
    #expect(link.calls.count == 1)
    #expect(model.linkIcon(for: try tab(model, UUID(0))) == nil)

    model.capturesArrived(captures(nil))
    await clock.advance(by: .seconds(60))
    #expect(link.calls.count == 1)

    await send(model, "again")
    await line(Line.result())
    #expect(link.calls.count == 2)
  }

  @Test func connectPassesSeenGeneration() async {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved, UUID(50)],
      captures: captures(binding(.connected, generation: "g7")))

    await model.connectTapped(UUID(50))

    expectNoDifference(link.calls, [.link(folder: "/w", tabID: UUID(50), replacing: "g7")])
  }

  @Test func connectWhileNothingLinkedPassesNoGeneration() async {
    link.setOutcomes(.retryLater)
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved, UUID(50)], captures: captures(binding(.unlinked)))

    await model.connectTapped(UUID(50))

    expectNoDifference(
      link.calls,
      [
        .link(folder: "/w", tabID: Self.saved, replacing: nil),
        .link(folder: "/w", tabID: UUID(50), replacing: nil),
      ])
  }

  @Test func connectOverOutsideChatPullsItIn() async {
    let model = await openWindow(
      records: [record()], withMessage: [Self.saved],
      captures: captures(binding(.connected, chat: Self.outside, generation: "g3")))

    await model.connectTapped(Self.saved)

    expectNoDifference(link.calls, [.link(folder: "/w", tabID: Self.saved, replacing: "g3")])
  }

  @Test func connectDisabledWithoutMessage() async throws {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved], captures: captures(binding(.connected)))

    #expect(model.isConnectEnabled(try tab(model, Self.saved)))
    #expect(model.isConnectEnabled(try tab(model, UUID(50))) == false)
    #expect(model.connectText == "Connect to Stream")
    #expect(model.closeTabText == "Close Tab")
    #expect(model.connectHintText(for: try tab(model, Self.saved)) == nil)
    #expect(model.connectHintText(for: try tab(model, UUID(50))) == "Send this chat a message first.")

    await model.connectTapped(UUID(50))

    #expect(link.calls.isEmpty)
  }

  @Test func skippedShowsRefreshedState() async throws {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved, UUID(50)], captures: captures(binding(.connected)))
    link.setOutcomes(.skipped)
    refresh(model, to: captures(binding(.connected, chat: Self.outside, generation: "g2")))

    await model.connectTapped(UUID(50))

    #expect(model.linkIcon(for: try tab(model, Self.saved)) == nil)
    #expect(model.linkIcon(for: try tab(model, UUID(50))) == nil)
    #expect(model.outsideChatText == "Stream: outside chat")
  }

  @Test func closingLinkedTabMovesLinkToFirstTabWithMessage() async {
    let model = await openWindow(
      records: [record(), record(UUID(50)), record(UUID(51))], withMessage: [Self.saved, UUID(51)],
      captures: captures(binding(.connected)))

    await model.closeTabTapped(Self.saved)

    expectNoDifference(link.calls, [.link(folder: "/w", tabID: UUID(51), replacing: "g1")])
  }

  @Test func closingWaitingLinkedTabMovesLinkToo() async {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved, UUID(50)],
      captures: captures(binding(.setupPending)))

    await model.closeTabTapped(Self.saved)

    expectNoDifference(link.calls, [.link(folder: "/w", tabID: UUID(50), replacing: "g1")])
  }

  @Test func closingLinkedTabWithNoOtherMessageUnlinks() async {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved], captures: captures(binding(.connected)))

    await model.closeTabTapped(Self.saved)

    expectNoDifference(link.calls, [.unlink(folder: "/w", replacing: "g1")])
  }

  @Test func closingALinkedTabWhileCapturesAreUnavailableMovesTheLinkOffOnTheNextGoodRead() async {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved, UUID(50)], captures: captures(binding(.connected)))
    model.capturesArrived(nil)

    await model.closeTabTapped(Self.saved)
    model.capturesArrived(captures(binding(.setupPending, generation: "g2")))
    await Task.megaYield()

    expectNoDifference(link.calls, [.link(folder: "/w", tabID: UUID(50), replacing: "g2")])
  }

  @Test func closingATabWhileItConnectsMovesTheLinkOff() async {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved, UUID(50)], captures: captures(binding(.connected)))
    link.hold()
    let connecting = Task { await model.connectTapped(UUID(50)) }
    await Task.megaYield()

    await model.closeTabTapped(UUID(50))
    refresh(model, to: captures(binding(.setupPending, chat: UUID(50), generation: "g2")))
    link.release()
    await connecting.value
    await Task.megaYield()

    expectNoDifference(
      link.calls,
      [
        .link(folder: "/w", tabID: UUID(50), replacing: "g1"),
        .link(folder: "/w", tabID: Self.saved, replacing: "g2"),
      ]
    )
  }

  @Test func aLinkLeftOnAClosedTabMovesOffOnTheNextGoodRead() async {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved, UUID(50)], captures: captures(binding(.connected)))
    link.hold()
    let connecting = Task { await model.connectTapped(UUID(50)) }
    await Task.megaYield()
    await model.closeTabTapped(UUID(50))
    model.onLinkChanged = { [weak model] in model?.capturesArrived(nil) }
    link.release()
    await connecting.value
    await Task.megaYield()
    expectNoDifference(link.calls, [.link(folder: "/w", tabID: UUID(50), replacing: "g1")])

    model.capturesArrived(captures(binding(.setupPending, chat: UUID(50), generation: "g2")))
    await Task.megaYield()

    expectNoDifference(link.calls.last, .link(folder: "/w", tabID: Self.saved, replacing: "g2"))
  }

  @Test func closingATabWhoseAttachLinksButReportsSetupIncompleteMovesTheLinkOff() async {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved, UUID(50)], captures: captures(binding(.connected)))
    link.setOutcomes(.refused(.setupIncomplete("this chat is linked, but setup is incomplete: no hook.")))
    link.hold()
    let connecting = Task { await model.connectTapped(UUID(50)) }
    await Task.megaYield()

    await model.closeTabTapped(UUID(50))
    refresh(model, to: captures(binding(.setupPending, chat: UUID(50), generation: "g2")))
    link.release()
    await connecting.value
    await Task.megaYield()

    expectNoDifference(link.calls.last, .link(folder: "/w", tabID: Self.saved, replacing: "g2"))
  }

  @Test func closingUnlinkedTabChangesNothing() async {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved, UUID(50)], captures: captures(binding(.connected)))

    await model.closeTabTapped(UUID(50))

    #expect(link.calls.isEmpty)
  }

  @Test(
    arguments: [
      (
        LinkRefusal.slipstreamTooOld,
        "This version of Slipstream can't connect chats run in the app. Update Slipstream, then right-click the tab and choose Connect to Stream to try again."
      ),
      (
        .slotsFull,
        "Slipstream is already connected to 10 chats, its limit. Unlink one with `slipstream unlink`, then right-click the tab and choose Connect to Stream to try again."
      ),
      (
        .setupIncomplete("this chat is linked, but setup is incomplete: the hook didn't install."),
        "Slipstream said: this chat is linked, but setup is incomplete: the hook didn't install. Right-click the tab and choose Connect to Stream to try again."
      ),
      (
        .other("the daemon is busy."),
        "Slipstream said: the daemon is busy. Right-click the tab and choose Connect to Stream to try again."
      ),
    ])
  func refusalShowsFailedIconWithReasonText(refusal: LinkRefusal, text: String) async throws {
    let model = await openWindow(
      records: [record()], withMessage: [Self.saved], captures: captures(binding(.connected, chat: Self.outside)))
    link.setOutcomes(.refused(refusal))

    await model.connectTapped(Self.saved)

    let tab = try tab(model, Self.saved)
    #expect(model.linkIcon(for: tab) == .failed)
    #expect(model.linkHoverTitle(for: tab) == "Couldn't connect to Stream")
    #expect(model.linkHoverText(for: tab) == text)
  }

  @Test func autoLinkRefusalShowsFailedIcon() async throws {
    link.setOutcomes(.refused(.slotsFull))
    let model = await openWindow(records: [record()], withMessage: [Self.saved], captures: captures(nil))

    #expect(model.linkIcon(for: try tab(model, Self.saved)) == .failed)
  }

  @Test func refusalClearsWhenTabReadsConnected() async throws {
    let model = await openWindow(
      records: [record()], withMessage: [Self.saved], captures: captures(binding(.connected, chat: Self.outside)))
    link.setOutcomes(.refused(.slotsFull))
    await model.connectTapped(Self.saved)

    model.capturesArrived(captures(binding(.connected, generation: "g2")))

    #expect(model.linkIcon(for: try tab(model, Self.saved)) == .connected)
  }

  @Test func setupFailureSurvivesLinkedRefresh() async throws {
    let model = await openWindow(
      records: [record()], withMessage: [Self.saved], captures: captures(binding(.connected, chat: Self.outside)))
    link.setOutcomes(.refused(.setupIncomplete("this chat is linked, but setup is incomplete: no hook.")))
    refresh(model, to: captures(binding(.setupPending, generation: "g2")))

    await model.connectTapped(Self.saved)

    let tab = try tab(model, Self.saved)
    #expect(model.linkIcon(for: tab) == .failed)
    #expect(model.askRoute(forFolder: "/w") == .app)
    model.capturesArrived(captures(binding(.setupPending, generation: "g2")))
    #expect(model.linkIcon(for: tab) == .failed)

    model.capturesArrived(captures(binding(.connected, generation: "g2")))
    #expect(model.linkIcon(for: tab) == .connected)
  }

  @Test func failureClearsOnRetryAndOnClose() async throws {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved, UUID(50)],
      captures: captures(binding(.connected, chat: Self.outside)))
    link.setOutcomes(.refused(.slotsFull), .retryLater, .refused(.slotsFull))
    await model.connectTapped(Self.saved)
    #expect(model.linkIcon(for: try tab(model, Self.saved)) == .failed)

    await model.connectTapped(Self.saved)
    #expect(model.linkIcon(for: try tab(model, Self.saved)) == nil)

    await model.connectTapped(UUID(50))
    let closing = try tab(model, UUID(50))
    #expect(model.linkIcon(for: closing) == .failed)
    await model.closeTabTapped(UUID(50))
    #expect(model.linkIcon(for: closing) == nil)
  }

  @Test func attachFailureAfterUnlinkLeavesUnlinkedWithFailure() async throws {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved, UUID(50)], captures: captures(binding(.connected)))
    link.setOutcomes(.refused(.slotsFull))
    refresh(model, to: captures(binding(.unlinked)))

    await model.connectTapped(UUID(50))
    await Task.megaYield()

    expectNoDifference(link.calls, [.link(folder: "/w", tabID: UUID(50), replacing: "g1")])
    #expect(model.linkIcon(for: try tab(model, UUID(50))) == .failed)
    #expect(model.linkIcon(for: try tab(model, Self.saved)) == nil)
    #expect(model.outsideChatText == nil)
    #expect(model.askRoute(forFolder: "/w") == .outside)
  }

  @Test(arguments: [LinkOutcome.linked, .unlinked, .skipped, .retryLater, .refused(.other("no."))])
  func everyOutcomeRefreshesCaptures(outcome: LinkOutcome) async {
    let model = await openWindow(records: [record()], withMessage: [Self.saved], captures: captures(binding(.connected)))
    let refreshes = LockIsolated(0)
    link.setOutcomes(outcome)
    refresh(model, to: captures(binding(.connected)), count: refreshes)

    await model.connectTapped(Self.saved)

    #expect(refreshes.value == 1)
  }

  @Test func closingLinkedTabRefreshesCaptures() async {
    let model = await openWindow(
      records: [record(), record(UUID(50))], withMessage: [Self.saved], captures: captures(binding(.connected)))
    let refreshes = LockIsolated(0)
    refresh(model, to: captures(binding(.unlinked)), count: refreshes)

    await model.closeTabTapped(Self.saved)

    #expect(refreshes.value == 1)
  }

  @Test func linkedIdleTabRestarts() async throws {
    let model = await openWindow(
      records: [record()], withMessage: [Self.saved], captures: captures(binding(.connected, chat: Self.outside)))
    await send(model, "hi")
    await line(Line.result())
    #expect(agent.shutdowns(0) == 0)

    await model.connectTapped(Self.saved)
    await Task.megaYield()

    #expect(agent.shutdowns(0) == 1)
    #expect(try tab(model, Self.saved).isWorking == false)
  }

  @Test func linkedTabWithoutProcessDoesNotRestart() async {
    let model = await openWindow(
      records: [record()], withMessage: [Self.saved], captures: captures(binding(.connected, chat: Self.outside)))

    await model.connectTapped(Self.saved)
    await send(model, "hi")

    #expect(agent.launches.count == 1)
    #expect(agent.shutdowns(0) == 0)
  }

  @Test func linkedWhileWorkingRestartsAfterTurnEnds() async throws {
    let model = await openWindow(
      records: [record()], withMessage: [Self.saved], captures: captures(binding(.connected, chat: Self.outside)))
    await send(model, "hi")

    await model.connectTapped(Self.saved)
    #expect(agent.shutdowns(0) == 0)
    #expect(try tab(model, Self.saved).isWorking)

    await line(Line.result())
    await Task.megaYield()
    #expect(agent.shutdowns(0) == 1)
    #expect(try tab(model, Self.saved).projection.items.last?.kind == .turnFooter(ending: .completed, duration: .seconds(41), time: Self.start))
  }

  @Test func nextSendResumes() async {
    let model = await openWindow(records: [], withMessage: [], captures: captures(nil))
    await send(model, "hi")
    agent.setTranscript(UUID(0), .found([.title("Saying hi")]))

    await line(Line.result())
    await Task.megaYield()
    #expect(agent.shutdowns(0) == 1)

    await send(model, "again")
    expectNoDifference(agent.launches, [launch(session: .new(UUID(0))), launch(session: .resume(UUID(0)))])
  }
}
