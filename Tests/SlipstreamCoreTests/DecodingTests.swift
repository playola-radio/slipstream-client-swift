import CustomDump
import Foundation
import SlipstreamCore
import Testing

private func fixture(_ name: String) throws -> Data {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
  return try Data(contentsOf: url)
}

private let shaA = String(repeating: "a", count: 64)
private let shaB = String(repeating: "b", count: 64)

struct EventDecodingTests {
  @Test func sessionStarted() throws {
    expectNoDifference(
      try SlipstreamEvent.decode(fixture("session-started")),
      SlipstreamEvent(seq: Seq("1")!, type: "slipstream.session.started.v1", payload: .sessionStarted(root: "/tmp/qa/worktree"))
    )
  }

  @Test func fileChangedWithContentSnapshotsIgnoresUnknownFields() throws {
    expectNoDifference(
      try SlipstreamEvent.decode(fixture("file-changed-content")),
      SlipstreamEvent(
        seq: Seq("12")!,
        type: "slipstream.file.changed.v1",
        payload: .fileChanged(
          FileChange(
            path: "src/types/user.ts",
            before: .content(sha256: shaA, size: 120),
            after: .content(sha256: shaB, size: 180),
            observedAtMs: 1_790_246_538_123
          )
        )
      )
    )
  }

  @Test func fileChangedFromAbsentToEmptyContent() throws {
    expectNoDifference(
      try SlipstreamEvent.decode(fixture("file-changed-created")).payload,
      .fileChanged(
        FileChange(path: "src/new.ts", before: .absent, after: .content(sha256: shaB, size: 0), observedAtMs: 1_790_246_539_000)
      )
    )
  }

  @Test func fileChangedWithUnavailableSnapshots() throws {
    expectNoDifference(
      try SlipstreamEvent.decode(fixture("file-changed-unavailable")).payload,
      .fileChanged(
        FileChange(
          path: "big.bin",
          before: .unavailable(reason: "baseline-unknown"),
          after: .unavailable(reason: "oversize"),
          observedAtMs: 1_790_246_540_000
        )
      )
    )
  }

  @Test func taskStarted() throws {
    expectNoDifference(
      try SlipstreamEvent.decode(fixture("task-started")).payload,
      .taskStarted(TaskStarted(title: "Convert isActive from a boolean to an enum"))
    )
  }

  @Test func captureGap() throws {
    expectNoDifference(
      try SlipstreamEvent.decode(fixture("capture-gap")).payload,
      .captureGap(CaptureGap(reason: "watcher-error", scope: .directory("src/api")))
    )
  }

  @Test func sessionResumed() throws {
    expectNoDifference(try SlipstreamEvent.decode(fixture("session-resumed")).payload, .sessionResumed)
  }

  @Test func baselineIsRecordedWithoutRow() throws {
    expectNoDifference(try SlipstreamEvent.decode(fixture("file-baselined")).payload, .recordedWithoutRow)
  }

  @Test func unknownTypeIsUnsupported() throws {
    expectNoDifference(
      try SlipstreamEvent.decode(fixture("unknown-type")).payload,
      .unsupported(type: "slipstream.future.thing.v1")
    )
  }

  @Test func malformedKnownTypeThrowsWithSeqAndType() throws {
    let json = #"{"id":"5","seq":"5","type":"slipstream.file.changed.v1","data":{"path":"a.ts"}}"#
    #expect(throws: EventDecodingError(seq: "5", type: "slipstream.file.changed.v1")) {
      try SlipstreamEvent.decode(Data(json.utf8))
    }
  }

  @Test func unknownSnapshotKindThrows() throws {
    let json = #"{"id":"5","seq":"5","type":"slipstream.file.changed.v1","data":{"path":"a","before":{"kind":"weird"},"after":{"kind":"absent"},"observed_at_ms":1}}"#
    #expect(throws: EventDecodingError(seq: "5", type: "slipstream.file.changed.v1")) {
      try SlipstreamEvent.decode(Data(json.utf8))
    }
  }

  @Test func idMustEqualSeq() throws {
    let json = #"{"id":"6","seq":"5","type":"slipstream.future.v1","data":{}}"#
    #expect(throws: EventDecodingError(seq: "5", type: "slipstream.future.v1")) {
      try SlipstreamEvent.decode(Data(json.utf8))
    }
  }

  @Test func nonCanonicalSeqThrows() throws {
    let json = #"{"id":"05","seq":"05","type":"slipstream.future.v1","data":{}}"#
    #expect(throws: EventDecodingError(seq: "05", type: "slipstream.future.v1")) {
      try SlipstreamEvent.decode(Data(json.utf8))
    }
  }

  @Test func notJSONThrows() {
    #expect(throws: EventDecodingError(seq: nil, type: nil)) {
      try SlipstreamEvent.decode(Data("nope".utf8))
    }
  }

  @Test func seqBeyondUInt64Decodes() throws {
    let json = #"{"id":"99999999999999999999999","seq":"99999999999999999999999","type":"slipstream.future.v1","data":{}}"#
    expectNoDifference(try SlipstreamEvent.decode(Data(json.utf8)).seq.decimal, "99999999999999999999999")
  }
}

struct ClipsDecodingTests {
  @Test func readyWithMultipleClips() throws {
    expectNoDifference(
      try JSONDecoder().decode(ClipsResponse.self, from: fixture("clips-ready")),
      ClipsResponse(
        status: .ready,
        clips: [
          Clip(
            after: ClipSide(span: ClipSpan(lineStart: 6, lineEnd: 10, truncated: false), method: .function)
          ),
          Clip(
            after: ClipSide(span: ClipSpan(lineStart: 16, lineEnd: 16, truncated: true), method: .changedRange)
          ),
        ]
      )
    )
  }

  @Test func skippedCarriesFallbackReason() throws {
    expectNoDifference(
      try JSONDecoder().decode(ClipsResponse.self, from: fixture("clips-skipped")),
      ClipsResponse(status: .skipped, fallbackReason: "not-utf8", clips: [])
    )
  }

  @Test func unavailableSideCarriesReason() throws {
    expectNoDifference(
      try JSONDecoder().decode(ClipsResponse.self, from: fixture("clips-unavailable-side")).clips,
      [
        Clip(
          after: ClipSide(span: ClipSpan(lineStart: 1, lineEnd: 1, truncated: false), method: .wholeFile)
        )
      ]
    )
  }
}
