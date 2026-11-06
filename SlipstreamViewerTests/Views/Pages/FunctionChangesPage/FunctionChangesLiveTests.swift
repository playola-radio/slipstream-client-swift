import ConcurrencyExtras
import CustomDump
import Dependencies
import Foundation
import SlipstreamCore
import Testing

@testable import SlipstreamViewer

@MainActor
@Suite(.serialized)
struct FunctionChangesLiveTests {
  private var fixtureRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Tests/SlipstreamCoreTests/Fixtures/interface-v2")
  }

  private func fixture(_ name: String) throws -> InterfaceComparison {
    try InterfaceComparison.decode(
      Data(contentsOf: fixtureRoot.appending(path: "cases/\(name)/expected.json")))
  }

  @Test func emptyFinalContinuationPreservesEarlierResultsAndCompletesRange() async throws {
    var first = try fixture("ts-parameter-change")
    first.page = InterfacePage(complete: false, nextAfterPath: first.files[0].path)
    var last = first
    last.files = []
    last.page = InterfacePage(complete: true, nextAfterPath: nil)
    let fake = DaemonFake()
    fake.setInterfacePages([first, last])
    let model = withDependencies {
      $0.daemon = fake.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: first.sessionID, before: first.beforeSeq, after: first.afterSeq)
    }

    await model.viewAppeared()

    expectNoDifference(fake.interfaceRequests.map(\.5), [nil, "src/f.ts"])
    expectNoDifference(model.page?.comparison.files, first.files)
    #expect(model.page?.comparison.page.complete == true)
    #expect(model.page?.afterPath == "src/f.ts")
    #expect(model.page?.summaryText.contains("loaded files") == false)
    #expect(model.canRetry == false)
    model.viewDisappeared()
    await model.viewAppeared()
    expectNoDifference(fake.interfaceRequests.count, 2)
    #expect(model.statusText == nil)
  }

  @Test func skippedContinuationRetainsLoadedRowsAndRequiresManualRetry() async throws {
    var first = try fixture("ts-parameter-change")
    first.page = InterfacePage(complete: false, nextAfterPath: first.files[0].path)
    var skipped = try fixture("range-admission-skipped")
    skipped.sessionID = first.sessionID
    skipped.beforeSeq = first.beforeSeq
    skipped.afterSeq = first.afterSeq
    skipped.page = InterfacePage(complete: false, nextAfterPath: first.files[0].path)
    let fake = DaemonFake()
    fake.setInterfacePages([first, skipped])
    let model = withDependencies {
      $0.daemon = fake.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: first.sessionID, before: first.beforeSeq, after: first.afterSeq)
    }

    await model.viewAppeared()

    expectNoDifference(model.page?.comparison.files, first.files)
    #expect(model.page?.comparison.page.complete == false)
    #expect(model.canRetry)
    #expect(model.statusText?.contains("skipped") == true)
    expectNoDifference(fake.interfaceRequests.count, 2)
  }

  @Test func noRowUnchangedCursorStopsUntilManualRetry() async throws {
    var interrupted = try fixture("ts-parameter-change")
    interrupted.files = []
    interrupted.page = InterfacePage(complete: false, nextAfterPath: nil)
    let fake = DaemonFake()
    fake.setInterfacePages([interrupted])
    let model = withDependencies {
      $0.daemon = fake.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: interrupted.sessionID, before: interrupted.beforeSeq, after: interrupted.afterSeq
      )
    }
    await model.viewAppeared()
    #expect(model.page?.comparison.page.complete == false)
    #expect(model.page?.emptyStateText.contains("more files may exist") == true)
    #expect(model.canRetry)
    expectNoDifference(fake.interfaceRequests.count, 1)
    var completed = interrupted
    completed.page = InterfacePage(complete: true, nextAfterPath: nil)
    fake.setInterfacePages([completed])
    await model.retryTapped()
    expectNoDifference(fake.interfaceRequests.map(\.5), [nil, nil])
    #expect(model.page?.comparison.page.complete == true)
  }

  @Test func timedOutFileIsRetriedAtTheSameCursorInsteadOfBeingSkipped() async throws {
    var first = try fixture("ts-parameter-change")
    first.files[0].status = .skipped(reason: "timeout")
    first.page = InterfacePage(complete: false, nextAfterPath: first.files[0].path)
    var retried = try fixture("ts-parameter-change")
    retried.page = InterfacePage(complete: true, nextAfterPath: nil)
    let fake = DaemonFake()
    fake.setInterfacePages([first, retried])
    let model = withDependencies {
      $0.daemon = fake.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: first.sessionID, before: first.beforeSeq, after: first.afterSeq)
    }

    await model.viewAppeared()
    expectNoDifference(fake.interfaceRequests.count, 1)
    #expect(model.canRetry)
    #expect(model.page?.comparison.files[0].status == .skipped(reason: "timeout"))
    #expect(model.page?.comparison.page.complete == false)
    await model.retryTapped()
    expectNoDifference(fake.interfaceRequests.map(\.5), [nil, nil])
    #expect(model.page?.comparison.page.complete == true)
    expectNoDifference(model.page?.comparison.files, retried.files)
  }

  @Test func timedOutFileOnTheFinalPageStillOffersRetry() async throws {
    var final = try fixture("ts-parameter-change")
    final.files[0].status = .skipped(reason: "timeout")
    final.page = InterfacePage(complete: true, nextAfterPath: nil)
    let fake = DaemonFake()
    fake.setInterfacePages([final])
    let model = withDependencies {
      $0.daemon = fake.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: final.sessionID, before: final.beforeSeq, after: final.afterSeq)
    }

    await model.viewAppeared()
    #expect(model.canRetry)
    #expect(model.page?.comparison.files[0].status == .skipped(reason: "timeout"))

    var retried = try fixture("ts-parameter-change")
    retried.page = InterfacePage(complete: true, nextAfterPath: nil)
    fake.setInterfacePages([retried])
    await model.retryTapped()
    expectNoDifference(fake.interfaceRequests.map(\.5), [nil, nil])
    #expect(model.page?.comparison.page.complete == true)
    expectNoDifference(model.page?.comparison.files, retried.files)
  }

  @Test func retryAfterAMidPageTimeoutReplacesTheWholePausedPage() async throws {
    let paused = try fixture("range-deadline-mid-page")
    var retried = paused
    retried.files[1].status = .ready
    retried.status = .ready
    retried.page = InterfacePage(complete: true, nextAfterPath: nil)
    let fake = DaemonFake()
    fake.setInterfacePages([paused, retried])
    let model = withDependencies {
      $0.daemon = fake.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: paused.sessionID, before: paused.beforeSeq, after: paused.afterSeq)
    }

    await model.viewAppeared()
    #expect(model.canRetry)
    await model.retryTapped()

    expectNoDifference(fake.interfaceRequests.map(\.5), [nil, nil])
    expectNoDifference(model.page?.comparison.files, retried.files)
    #expect(model.page?.comparison.page.complete == true)
    #expect(model.statusText == nil)
  }

  @Test func skippedRetryKeepsThePausedPage() async throws {
    let paused = try fixture("range-deadline-mid-page")
    var skipped = try fixture("range-admission-skipped")
    skipped.sessionID = paused.sessionID
    skipped.beforeSeq = paused.beforeSeq
    skipped.afterSeq = paused.afterSeq
    skipped.page = InterfacePage(complete: false, nextAfterPath: nil)
    let fake = DaemonFake()
    fake.setInterfacePages([paused, skipped])
    let model = withDependencies {
      $0.daemon = fake.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: paused.sessionID, before: paused.beforeSeq, after: paused.afterSeq)
    }

    await model.viewAppeared()
    await model.retryTapped()

    expectNoDifference(model.page?.comparison.files, paused.files)
    #expect(model.canRetry)
  }

  @Test func rejectedRetryKeepsThePausedPage() async throws {
    let paused = try fixture("range-deadline-mid-page")
    var duplicated = paused
    duplicated.files.append(duplicated.files[0])
    duplicated.page = InterfacePage(complete: true, nextAfterPath: nil)
    var empty = paused
    empty.files = []
    empty.page = InterfacePage(complete: false, nextAfterPath: nil)
    let fake = DaemonFake()
    fake.setInterfacePages([paused, duplicated, empty])
    let model = withDependencies {
      $0.daemon = fake.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: paused.sessionID, before: paused.beforeSeq, after: paused.afterSeq)
    }

    await model.viewAppeared()
    await model.retryTapped()

    expectNoDifference(model.page?.comparison.files, paused.files)
    #expect(model.canRetry)

    await model.retryTapped()

    expectNoDifference(model.page?.comparison.files, paused.files)
    #expect(model.canRetry)
  }

  @Test func canonicallyEquivalentDistinctPathsStayDistinct() async throws {
    var first = try fixture("ts-parameter-change")
    first.files[0].path = "src/caf\u{00E9}/a.ts"
    first.page = InterfacePage(complete: false, nextAfterPath: first.files[0].path)
    var final = first
    final.files[0].path = "src/cafe\u{0301}/a.ts"
    final.page = InterfacePage(complete: true, nextAfterPath: nil)
    let fake = DaemonFake()
    fake.setInterfacePages([first, final])
    let model = withDependencies {
      $0.daemon = fake.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: first.sessionID, before: first.beforeSeq, after: first.afterSeq)
    }

    await model.viewAppeared()
    expectNoDifference(fake.interfaceRequests.count, 2)
    #expect(model.page?.comparison.files.count == 2)
    #expect(model.page?.comparison.page.complete == true)
    let page = try #require(model.page)
    #expect(!page.summaryText.contains("unavailable"))
    let mapFiles = page.mapGroups.flatMap(\.files)
    #expect(mapFiles.count == 2)
    #expect(Set(mapFiles.map(\.id)).count == 2)
    #expect(Set(page.nodes.map(\.id)).count == page.nodes.count)
    for file in mapFiles {
      let row = try #require(file.rows.first)
      page.declarationTapped(row.id)
      #expect(page.sourceSelection.map { Data($0.path.utf8) } == Data(file.path.utf8))
    }
  }

  @Test func descriptorRefreshRetries401OnceWithSameFrozenRequest() async throws {
    let ready = try fixture("ts-parameter-change")
    let fake = DaemonFake()
    fake.setTokens(["old", "fresh"])
    fake.setInterfaceReplies([.failure(.status(401, durableSeq: nil)), .page(ready)])
    let model = withDependencies {
      $0.daemon = fake.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: ready.sessionID, before: ready.beforeSeq, after: ready.afterSeq)
    }
    await model.viewAppeared()
    expectNoDifference(fake.interfaceRequests.map(\.0), ["old", "fresh"])
    expectNoDifference(fake.interfaceRequests.map(\.5), [nil, nil])
    #expect(model.page?.comparison.page.complete == true)
  }

  @Test func rejectedAndUnavailableRangesNeedANewSelection() async throws {
    let ready = try fixture("ts-parameter-change")
    for (code, expected) in [
      (400, "request rejected"), (404, "session not found"),
      (409, "beyond daemon history"), (410, "session removed"),
    ] {
      let fake = DaemonFake()
      fake.setInterfaceReplies([.failure(.status(code, durableSeq: Seq("1")))])
      let model = withDependencies {
        $0.daemon = fake.client
      } operation: {
        FunctionChangesLiveModel(
          sessionID: ready.sessionID, before: ready.beforeSeq, after: ready.afterSeq)
      }
      await model.viewAppeared()
      #expect(model.statusText?.contains(expected) == true)
      #expect(model.statusText?.contains("Loaded results remain incomplete") == false)
      #expect(!model.canRetry)
      #expect(model.page == nil)
    }
  }

  @Test func hostFailureShowsAnalysisErrorWithoutInventingEmptyComparison() async throws {
    let ready = try fixture("ts-parameter-change")
    let fake = DaemonFake()
    fake.setInterfaceReplies([.failure(.status(500, durableSeq: nil))])
    let model = withDependencies {
      $0.daemon = fake.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: ready.sessionID, before: ready.beforeSeq, after: ready.afterSeq)
    }
    await model.viewAppeared()
    #expect(model.statusText?.contains("Analysis failed") == true)
    #expect(model.statusText?.contains("Loaded results remain incomplete") == false)
    #expect(model.canRetry)
    #expect(model.page == nil)
  }

  @Test func cancellationPreventsLatePageFromPublishing() async throws {
    let ready = try fixture("ts-parameter-change")
    let fake = DaemonFake(gatesEachInterfaceCall: true)
    fake.setInterfacePages([ready])
    let model = withDependencies {
      $0.daemon = fake.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: ready.sessionID, before: ready.beforeSeq, after: ready.afterSeq)
    }
    let loading = Task { await model.viewAppeared() }
    await fake.waitForInterfaceCall(1)
    model.viewDisappeared()
    fake.releaseInterfaceCall(1)
    await loading.value
    #expect(model.page == nil)
    #expect(!model.isLoading)
    fake.setInterfacePages([ready])
    let resumed = Task { await model.viewAppeared() }
    await Task.megaYield()
    #expect(fake.interfaceRequests.count == 2)
    if fake.interfaceRequests.count == 2 { fake.releaseInterfaceCall(2) }
    await resumed.value
    #expect(model.page?.comparison.page.complete == true)
  }

  @Test func partialFilesAndUnknownMetadataStayVisible() async throws {
    let partial = try fixture("range-cancelled-mid-page")
    let fake = DaemonFake()
    fake.setInterfacePages([partial])
    let model = withDependencies {
      $0.daemon = fake.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: partial.sessionID, before: partial.beforeSeq, after: partial.afterSeq)
    }
    await model.viewAppeared()
    #expect(model.page?.filesNotCompared == 1)
    #expect(model.page?.summaryText.contains("not compared") == true)
    #expect(model.page?.comparison.page.complete == false)

    let skipped = try fixture("range-admission-skipped")
    let other = DaemonFake()
    other.setInterfacePages([skipped])
    let otherModel = withDependencies {
      $0.daemon = other.client
    } operation: {
      FunctionChangesLiveModel(
        sessionID: skipped.sessionID, before: skipped.beforeSeq, after: skipped.afterSeq)
    }
    await otherModel.viewAppeared()
    #expect(otherModel.page?.comparison.inventory == nil)
    #expect(otherModel.page?.comparison.gaps == nil)
    #expect(otherModel.page?.noticeText.contains("not evaluated") == true)
  }
}
