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
struct RecordingControlsModelTests {
  nonisolated static let farmerville = "/Users/brian/conductor/workspaces/playola/farmerville"
  nonisolated static let mbabane = "/Users/brian/conductor/workspaces/playola/mbabane"
  nonisolated static let notes = "/Users/brian/notes"

  let recordingFake = RecordingFake()
  let changes = LockIsolated<[String?]>([])
  let recorded = LockIsolated<[String]>([])

  func makeModel(choose: URL?...) -> RecordingControlsModel {
    let choices = LockIsolated(choose)
    return withDependencies {
      $0.recording = recordingFake.client
      $0.workspace.chooseFolder = { message, prompt in
        expectNoDifference([message, prompt], ["Choose a folder to record", "Record"])
        return choices.withValue { $0.isEmpty ? nil : $0.removeFirst() }
      }
    } operation: {
      let model = RecordingControlsModel()
      model.onChanged = { folder in changes.withValue { $0.append(folder) } }
      model.onRecorded = { folder in recorded.withValue { $0.append(folder) } }
      return model
    }
  }

  enum Action: Sendable { case record, pause }

  @Test(arguments: [
    (
      Action.record,
      QuestionError.rejected(
        code: "CAPTURE_LIMIT_REACHED",
        message: "32/32 capture slots in use. This workspace is NOT recording. Pause one first."),
      RecordingMessage(text: "All recording slots are in use. Pause a workspace first.", isFull: true)
    ),
    (
      .record, .rejected(code: "ROOT_OVERLAP", message: "overlaps"),
      RecordingMessage(text: "Couldn't record farmerville: it overlaps a folder that's already recording.", isFull: false)
    ),
    (
      .record, .rejected(code: "SESSION_RESUME_FAILED", message: "the session could not resume"),
      RecordingMessage(text: "Couldn't record: the session could not resume", isFull: false)
    ),
    (
      .record, .unavailable,
      RecordingMessage(text: "Couldn't record: couldn't reach Slipstream.", isFull: false)
    ),
    (
      .record, .outcomeUnknown,
      RecordingMessage(text: "Recording not confirmed. Checking…", isFull: false)
    ),
    (
      .pause, .rejected(code: "TARGET_NOT_FOUND", message: "no capture"),
      RecordingMessage(text: "This workspace's recording no longer exists. Refreshing…", isFull: false)
    ),
    (
      .pause, .rejected(code: "STORAGE_UNAVAILABLE", message: "the store is unavailable"),
      RecordingMessage(text: "Couldn't pause: the store is unavailable", isFull: false)
    ),
    (
      .pause, .unavailable,
      RecordingMessage(text: "Couldn't pause: couldn't reach Slipstream.", isFull: false)
    ),
    (
      .pause, .outcomeUnknown,
      RecordingMessage(text: "Couldn't pause: Slipstream didn't confirm it. Checking again…", isFull: false)
    ),
  ])
  func failureShowsTheFoldersMessage(action: Action, error: QuestionError, message: RecordingMessage) async {
    let model = makeModel()
    recordingFake.setFailures(error)

    switch action {
    case .record: await model.recordTapped(folder: Self.farmerville)
    case .pause: await model.pauseTapped(folder: Self.farmerville)
    }

    expectNoDifference(model.messages, [Self.farmerville: message])
    expectNoDifference(model.operations, [:])
  }

  @Test func aSecondTapOnTheSameFolderIsIgnoredWhileOneRuns() async {
    let model = makeModel()
    recordingFake.hold()

    let first = Task { await model.recordTapped(folder: Self.farmerville) }
    await Task.yield()
    expectNoDifference(model.operations, [Self.farmerville: .recording])

    await model.pauseTapped(folder: Self.farmerville)
    recordingFake.release()
    await first.value

    expectNoDifference(recordingFake.calls, [.record(Self.farmerville)])
    expectNoDifference(model.operations, [:])
  }

  @Test func recordSuccessClearsTheFoldersMessageRefreshesAndAsksChatToLink() async {
    let model = makeModel()
    recordingFake.setFailures(.unavailable)
    await model.recordTapped(folder: Self.farmerville)
    changes.setValue([])

    await model.recordTapped(folder: Self.farmerville)

    expectNoDifference(model.messages, [:])
    expectNoDifference(changes.value, [nil])
    expectNoDifference(recorded.value, [Self.farmerville])
  }

  @Test func pauseSuccessRefreshesWithoutLinking() async {
    let model = makeModel()

    await model.pauseTapped(folder: Self.farmerville)

    expectNoDifference(recordingFake.calls, [.pause(Self.farmerville)])
    expectNoDifference(changes.value, [nil])
    expectNoDifference(recorded.value, [])
  }

  @Test func outcomeUnknownShowsNotConfirmedAndRefreshes() async {
    let model = makeModel()
    recordingFake.setFailures(.outcomeUnknown, .outcomeUnknown)

    await model.recordTapped(folder: Self.farmerville)
    await model.pauseTapped(folder: Self.mbabane)

    expectNoDifference(
      model.messages,
      [
        Self.farmerville: RecordingMessage(text: "Recording not confirmed. Checking…", isFull: false),
        Self.mbabane: RecordingMessage(
          text: "Couldn't pause: Slipstream didn't confirm it. Checking again…", isFull: false),
      ])
    expectNoDifference(changes.value, [nil, nil])
    expectNoDifference(recorded.value, [])
  }

  @Test func aRefusedRecordSetsOnlyThatFoldersMessage() async {
    let model = makeModel()
    recordingFake.setFailures(.unavailable)
    await model.pauseTapped(folder: Self.mbabane)

    recordingFake.setFailures(.rejected(code: "CAPTURE_LIMIT_REACHED", message: "full"))
    await model.recordTapped(folder: Self.farmerville)

    expectNoDifference(
      model.messages,
      [
        Self.mbabane: RecordingMessage(text: "Couldn't pause: couldn't reach Slipstream.", isFull: false),
        Self.farmerville: RecordingMessage(
          text: "All recording slots are in use. Pause a workspace first.", isFull: true),
      ])
    expectNoDifference(recorded.value, [])
  }

  @Test func recordAFolderCancelDoesNothing() async {
    let model = makeModel(choose: nil)

    await model.recordFolderTapped()

    expectNoDifference(recordingFake.calls, [])
    expectNoDifference(changes.value, [])
  }

  @Test func recordAFolderSuccessRefreshesPreferringTheFolder() async {
    let model = makeModel(choose: URL(fileURLWithPath: Self.notes))

    await model.recordFolderTapped()

    expectNoDifference(recordingFake.calls, [.record(Self.notes)])
    expectNoDifference(changes.value, [Self.notes])
    expectNoDifference(recorded.value, [Self.notes])
    expectNoDifference(model.footerMessage, nil)
  }

  @Test func recordAFolderPrefersNothingOnceTheSelectionMoved() async {
    let model = makeModel(choose: URL(fileURLWithPath: Self.notes))

    await model.recordFolderTapped(keepsSelection: { false })

    expectNoDifference(changes.value, [nil])
  }

  @Test func anOlderFolderRecordLeavesANewerFootersMessage() async {
    let model = makeModel(choose: URL(fileURLWithPath: Self.notes), URL(fileURLWithPath: Self.farmerville))
    recordingFake.hold()
    let older = Task { await model.recordFolderTapped() }
    await Task.megaYield()

    recordingFake.setFailures(.rejected(code: "ROOT_OVERLAP", message: "overlaps"))
    await model.recordFolderTapped()
    recordingFake.release()
    await older.value

    expectNoDifference(
      model.footerMessage,
      RecordingMessage(text: "Couldn't record farmerville: it overlaps a folder that's already recording.", isFull: false))
  }

  @Test func recordAFolderRefusalSetsTheFooterMessage() async {
    let model = makeModel(choose: URL(fileURLWithPath: Self.notes))
    recordingFake.setFailures(.rejected(code: "ROOT_OVERLAP", message: "overlaps"))

    await model.recordFolderTapped()

    expectNoDifference(
      model.footerMessage,
      RecordingMessage(text: "Couldn't record notes: it overlaps a folder that's already recording.", isFull: false))
    expectNoDifference(model.messages, [:])
    expectNoDifference(changes.value, [])
  }

  @Test func aNewTapClearsTheFooterMessage() async {
    let model = makeModel(choose: URL(fileURLWithPath: Self.notes))
    recordingFake.setFailures(.unavailable)
    await model.recordFolderTapped()

    await model.pauseTapped(folder: Self.farmerville)

    expectNoDifference(model.footerMessage, nil)
  }
}
