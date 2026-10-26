import ConcurrencyExtras
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import SwiftTerm
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(.serialized, .mainSerialExecutor)
struct TerminalTabModelTests {
  let fake = TerminalFake()
  let record = TerminalTabRecord(id: UUID(1), folder: "/tmp/project", kind: .terminal(number: 1))

  func makeTab(_ record: TerminalTabRecord? = nil) -> TerminalTabModel {
    let record = record ?? self.record
    return withDependencies {
      $0.defaultFileStorage = fake.fileStorage
      $0.terminalRuntime = fake.runtimeClient
      $0.terminalHistory = fake.historyClient
    } operation: {
      @Shared(.terminalState) var state
      $state.withLock { _ = $0.tabs.append(record) }
      let tab = TerminalTabModel(id: record.id)
      tab.surface.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
      return tab
    }
  }

  func startedTab() async -> TerminalTabModel {
    let tab = makeTab()
    await tab.start()
    return tab
  }

  func bufferLines(_ tab: TerminalTabModel) -> [String] {
    String(decoding: tab.surface.view.getTerminal().getBufferAsData(kind: .normal), as: UTF8.self)
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  @Test func startLaunchesLoginShellInFolder() async {
    let tab = await startedTab()

    var variables = TerminalFake.environment.variables
    variables["PWD"] = "/tmp/project"
    expectNoDifference(
      fake.launches,
      [
        TerminalLaunch(
          executable: "/bin/zsh", arguments: ["-l"], environment: variables, directory: "/tmp/project",
          size: tab.surface.size)
      ])
  }

  @Test func outputIsSaved() async {
    let tab = await startedTab()

    fake.send("hello\r\n")
    fake.send("world\r\n")
    await Task.megaYield()

    expectNoDifference(fake.log(record.id), "hello\r\nworld\r\n")
    expectNoDifference(bufferLines(tab), ["hello", "world"])
  }

  @Test func replayThenDividerThenShell() async {
    fake.setLog(record.id, "earlier output\r\n")
    fake.hold(.environment)
    let tab = makeTab()

    let starting = Task { await tab.start() }
    await Task.megaYield()
    tab.surface.onInput(Array("typed during replay".utf8))
    fake.release(.environment)
    await starting.value

    expectNoDifference(
      fake.calls, [.read(record.id), .append(record.id), .launch(directory: "/tmp/project")])
    let lines = bufferLines(tab)
    #expect(lines.first == "earlier output")
    #expect(lines.contains { $0.contains("Restored — earlier processes ended") })
    #expect(fake.log(record.id).contains("Restored — earlier processes ended"))
    expectNoDifference(fake.writes(0), "")
  }

  @Test func inputReachesTheShell() async {
    let tab = await startedTab()

    tab.surface.onInput(Array("ls\r".utf8))

    expectNoDifference(fake.writes(0), "ls\r")
  }

  @Test func noHistoryMeansNoDivider() async {
    let tab = await startedTab()

    expectNoDifference(fake.calls, [.read(record.id), .launch(directory: "/tmp/project")])
    expectNoDifference(bufferLines(tab), [])
  }

  @Test func exitWritesNote() async {
    let tab = await startedTab()

    fake.finish(.exited(1))
    await Task.megaYield()

    #expect(bufferLines(tab).last == "Process exited (exit 1)")
    #expect(fake.log(record.id).hasSuffix("Process exited (exit 1)\r\n"))
    #expect(fake.launches.count == 1)
  }

  @Test func launchErrorWritesItsText() async {
    fake.setLaunchError(TerminalLaunchError(text: "Couldn't find /bin/zsh"))

    let tab = await startedTab()

    #expect(bufferLines(tab).last == "Couldn't find /bin/zsh")
    #expect(fake.log(record.id).contains("Couldn't find /bin/zsh"))
  }

  @Test func environmentErrorWritesItsText() async {
    fake.setEnvironmentError(TerminalLaunchError(text: "Couldn't read PATH from your login shell"))

    let tab = await startedTab()

    #expect(bufferLines(tab).last == "Couldn't read PATH from your login shell")
    #expect(fake.launches.isEmpty)
  }

  @Test func missingFolderStartsNothing() async {
    fake.setMissing("/tmp/project")

    let tab = await startedTab()

    #expect(tab.isFolderMissing)
    #expect(tab.missingFolderPath == "/tmp/project")
    expectNoDifference(fake.calls, [])
  }

  @Test func idleCloseClosesAtOnce() async {
    let tab = await startedTab()

    #expect(tab.closeRequested())
    #expect(!tab.isCloseConfirmationVisible)
  }

  @Test func busyCloseShowsConfirmation() async {
    let tab = await startedTab()
    fake.setBusy(true)

    #expect(!tab.closeRequested())
    #expect(tab.isCloseConfirmationVisible)
    #expect(tab.closeConfirmationText == "Closing stops what's running in Terminal 1.")
  }

  @Test func keepHidesConfirmation() async {
    let tab = await startedTab()
    fake.setBusy(true)
    _ = tab.closeRequested()

    tab.keepTapped()

    #expect(!tab.isCloseConfirmationVisible)
  }

  @Test func processEndingHidesConfirmation() async {
    let tab = await startedTab()
    fake.setBusy(true)
    _ = tab.closeRequested()

    fake.finish(.exited(0))
    await Task.megaYield()

    #expect(!tab.isCloseConfirmationVisible)
    #expect(!tab.isBusy)
  }

  @Test func stopIsForwarded() async {
    let tab = await startedTab()

    await tab.stop()

    expectNoDifference(
      fake.calls,
      [.read(record.id), .launch(directory: "/tmp/project"), .stop(launch: 0), .flush(record.id)])
    #expect(!fake.log(record.id).contains("Process exited"))
  }

  @Test func stopDuringStartLaunchesNothing() async {
    fake.hold(.environment)
    let tab = makeTab()
    let starting = Task { await tab.start() }
    await Task.megaYield()

    await tab.stop()
    fake.release(.environment)
    await starting.value

    #expect(fake.launches.isEmpty)
  }

  @Test func titleFollowsTheRecord() {
    let setup = makeTab(TerminalTabRecord(id: UUID(2), folder: nil, kind: .setup(.running)))

    #expect(makeTab().title == "Terminal 1")
    #expect(setup.title == "Setup")
  }
}
