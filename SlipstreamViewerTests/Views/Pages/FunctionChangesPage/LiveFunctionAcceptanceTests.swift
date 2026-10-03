import CustomDump
import Dependencies
import Foundation
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

private func hasDisposableAcceptanceStore(environment: [String: String], home: URL) -> Bool {
  guard let configured = environment["SLIPSTREAM_STORE"], !configured.isEmpty else { return false }
  let selected = DescriptorDiscovery.storeURL(environment: environment, home: home)
    .resolvingSymlinksInPath()
  let real = home.appending(path: ".slipstream").resolvingSymlinksInPath()
  return selected.path != real.path
}

private let acceptanceMode =
  ProcessInfo.processInfo.environment["SLIPSTREAM_FS3_MODE"] ?? "ready"

@Test func acceptanceStoreGuardExpandsLiteralTilde() {
  let home = FileManager.default.homeDirectoryForCurrentUser
  #expect(!hasDisposableAcceptanceStore(environment: [:], home: home))
  #expect(
    !hasDisposableAcceptanceStore(environment: ["SLIPSTREAM_STORE": "~/.slipstream"], home: home))
  #expect(
    hasDisposableAcceptanceStore(
      environment: ["SLIPSTREAM_STORE": "/tmp/fs3-disposable"], home: home))
}

@MainActor
@Suite(
  .enabled(
    if: ProcessInfo.processInfo.environment["SLIPSTREAM_FS3_ACCEPTANCE"] != nil
      && hasDisposableAcceptanceStore(
        environment: ProcessInfo.processInfo.environment,
        home: FileManager.default.homeDirectoryForCurrentUser),
    "Set SLIPSTREAM_FS3_ACCEPTANCE to the independent consumer summary and SLIPSTREAM_STORE to its disposable store"
  ))
struct LiveFunctionAcceptanceTests {
  struct Summary: Decodable {
    struct File: Decodable {
      struct Span: Decodable {
        let byteStart: Int
        let byteEnd: Int

        enum CodingKeys: String, CodingKey {
          case byteStart = "byte_start"
          case byteEnd = "byte_end"
        }
      }

      let path: String
      let beforeSha: String
      let afterSha: String
      let beforeSpan: Span
      let afterSpan: Span
    }

    struct ReturnedFile: Decodable, Hashable {
      let path: String
      let identical: Bool
    }

    let sessionID: String
    let beforeSeq: String
    let afterSeq: String
    let returnedFiles: [ReturnedFile]
    let files: [File]
  }

  @Test(.enabled(if: acceptanceMode == "ready"))
  func liveAppModelMatchesIndependentAuthenticatedConsumer() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["SLIPSTREAM_FS3_ACCEPTANCE"])
    let summary = try JSONDecoder().decode(
      Summary.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let before = try #require(Seq(summary.beforeSeq))
    let after = try #require(Seq(summary.afterSeq))
    let model = withDependencies {
      $0.daemon = .liveValue
    } operation: {
      FunctionChangesLiveModel(sessionID: summary.sessionID, before: before, after: after)
    }

    await model.viewAppeared()

    let page = try #require(model.page)
    #expect(page.comparison.page.complete)
    #expect(page.comparison.status == .ready)
    expectNoDifference(page.detectedChanges, 2)
    expectNoDifference(page.filesNotCompared, 0)
    expectNoDifference(
      Set(
        page.comparison.files.map {
          Summary.ReturnedFile(path: $0.path, identical: $0.status == .identical)
        }),
      Set(summary.returnedFiles))
    for expected in summary.files {
      let row = try #require(
        page.mapGroups.flatMap(\.files).first { $0.path == expected.path }?.rows.first)
      page.declarationTapped(row.id)
      let afterSelection = try #require(page.sourceSelection)
      expectNoDifference(afterSelection.sessionID, summary.sessionID)
      expectNoDifference(afterSelection.beforeSeq, before)
      expectNoDifference(afterSelection.afterSeq, after)
      expectNoDifference(afterSelection.sha256, expected.afterSha)
      expectNoDifference(
        afterSelection.byteRange, expected.afterSpan.byteStart..<expected.afterSpan.byteEnd)
      page.sourceSideTapped(.before)
      let beforeSelection = try #require(page.sourceSelection)
      expectNoDifference(beforeSelection.sha256, expected.beforeSha)
      expectNoDifference(
        beforeSelection.byteRange, expected.beforeSpan.byteStart..<expected.beforeSpan.byteEnd)
    }
  }

  @Test(.enabled(if: acceptanceMode == "blob-loss"))
  func missingRecordedBlobStaysUnavailableInLiveModel() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["SLIPSTREAM_FS3_ACCEPTANCE"])
    let summary = try JSONDecoder().decode(
      Summary.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let model = withDependencies {
      $0.daemon = .liveValue
    } operation: {
      FunctionChangesLiveModel(
        sessionID: summary.sessionID,
        before: Seq(summary.beforeSeq)!, after: Seq(summary.afterSeq)!)
    }
    await model.viewAppeared()
    let page = try #require(model.page)
    #expect(page.comparison.status == .partial)
    #expect(page.comparison.page.complete)
    expectNoDifference(page.filesNotCompared, 1)
    let file = try #require(page.comparison.files.first { $0.path == "src/fs3-live.ts" })
    if case .unavailable(let reason) = file.status {
      expectNoDifference(reason, "before-blob-missing")
    } else {
      Issue.record("Missing recorded blob was not unavailable")
    }
    #expect(page.summaryText.contains("not compared"))
  }

  @Test(.enabled(if: acceptanceMode == "session-removed"))
  func removedSessionNeedsANewSelectionInLiveModel() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["SLIPSTREAM_FS3_ACCEPTANCE"])
    let summary = try JSONDecoder().decode(
      Summary.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let model = withDependencies {
      $0.daemon = .liveValue
    } operation: {
      FunctionChangesLiveModel(
        sessionID: summary.sessionID,
        before: Seq(summary.beforeSeq)!, after: Seq(summary.afterSeq)!)
    }
    await model.viewAppeared()
    #expect(model.statusText?.contains("session removed") == true)
    #expect(!model.canRetry)
    #expect(model.page == nil)
  }
}
