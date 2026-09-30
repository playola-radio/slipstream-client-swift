import CustomDump
import Dependencies
import Foundation
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(
  .enabled(
    if: ProcessInfo.processInfo.environment["SLIPSTREAM_FS3_ACCEPTANCE"] != nil,
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

    let sessionID: String
    let beforeSeq: String
    let afterSeq: String
    let files: [File]
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SLIPSTREAM_FS3_BLOB_LOSS"] != "1"))
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
    expectNoDifference(Set(page.comparison.files.map(\.path)), Set(summary.files.map(\.path)))
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
    print(
      "FS3 live model matched independent HTTP consumer for \(summary.files.count) files at #\(before)…#\(after)"
    )
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SLIPSTREAM_FS3_BLOB_LOSS"] == "1"))
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
}
