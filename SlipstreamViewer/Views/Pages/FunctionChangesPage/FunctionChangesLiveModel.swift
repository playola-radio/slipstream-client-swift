import Dependencies
import Foundation
import Observation
import SlipstreamCore

@MainActor
@Observable
final class FunctionChangesLiveModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.daemon) var daemon

  // MARK: - Initialization

  init(sessionID: String, before: Seq, after: Seq) {
    self.sessionID = sessionID
    self.before = before
    self.after = after
    super.init()
  }

  // MARK: - Properties

  let sessionID: String
  let before: Seq
  let after: Seq
  private(set) var page: FunctionChangesPageModel?
  private(set) var statusText: String?
  private(set) var isLoading = false
  private(set) var canRetry = false
  @ObservationIgnored private var hasAppeared = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var nextCursor: String?
  @ObservationIgnored private var files: [InterfaceFileResult] = []
  @ObservationIgnored private var seenPaths: Set<Data> = []
  @ObservationIgnored private var pausedPagePaths: Set<Data> = []
  @ObservationIgnored private var inventory: InterfaceInventory?
  @ObservationIgnored private var gaps: [InterfaceGap]?
  @ObservationIgnored private var gapsComplete = false

  // MARK: - Display Text

  let headingText = "Function changes"
  let retryText = "Retry"
  let loadingText = "Comparing recorded functions…"

  // MARK: - User Actions

  func viewAppeared() async {
    guard !hasAppeared else { return }
    hasAppeared = true
    await load()
  }

  func retryTapped() async {
    guard canRetry else { return }
    await load()
  }

  func viewDisappeared() {
    if isLoading { hasAppeared = false }
    generation += 1
    loadTask?.cancel()
    loadTask = nil
    isLoading = false
  }

  // MARK: - Private Helpers

  private func load() async {
    guard !isLoading else { return }
    generation += 1
    let current = generation
    isLoading = true
    canRetry = false
    statusText = nil
    let task = Task { [weak self] in
      guard let self else { return }
      await self.loadPages(generation: current)
    }
    loadTask = task
    await task.value
    guard generation == current else { return }
    isLoading = false
    loadTask = nil
  }

  private func loadPages(generation: Int) async {
    while generation == self.generation, !Task.isCancelled {
      let requestedCursor = nextCursor
      do {
        let response = try await requestPage(afterPath: requestedCursor)
        guard generation == self.generation, !Task.isCancelled else { return }
        guard response.sessionID == sessionID, response.beforeSeq == before,
          response.afterSeq == after
        else {
          throw DaemonHTTPError.invalidResponse
        }
        guard metadataAgrees(with: response) else { throw DaemonHTTPError.invalidResponse }
        guard
          response.page.complete || samePath(response.page.nextAfterPath, response.files.last?.path)
            || response.files.isEmpty && samePath(response.page.nextAfterPath, requestedCursor)
        else {
          throw DaemonHTTPError.invalidResponse
        }
        let pagePaths = response.files.map { Data($0.path.utf8) }
        guard Set(pagePaths).count == pagePaths.count,
          pagePaths.allSatisfy({ !seenPaths.subtracting(pausedPagePaths).contains($0) })
        else {
          throw DaemonHTTPError.invalidResponse
        }
        if !response.files.isEmpty {
          seenPaths.subtract(pausedPagePaths)
          files.removeAll { pausedPagePaths.contains(Data($0.path.utf8)) }
          pausedPagePaths = []
        }
        if let inventory = response.inventory {
          self.inventory = inventory
          gaps = response.gaps
          gapsComplete = response.gapsComplete
        }
        seenPaths.formUnion(pagePaths)
        files += response.files
        let hasNonReadyFile = files.contains { $0.status != .ready && $0.status != .identical }
        let status: InterfaceComparison.Status
        if files.isEmpty, case .skipped(let reason) = response.status {
          status = .skipped(reason)
        } else if !hasNonReadyFile {
          status = .ready
        } else {
          status = .partial
        }
        let combined = InterfaceComparison(
          sessionID: sessionID, beforeSeq: before, afterSeq: after, status: status,
          inventory: inventory, gaps: gaps, gapsComplete: gapsComplete, files: files,
          page: response.page)
        if let page {
          page.comparisonUpdated(combined, afterPath: requestedCursor)
        } else {
          page = withDependencies(from: self) {
            FunctionChangesPageModel(
              comparison: combined, afterPath: requestedCursor, isAccumulatedRange: true)
          }
        }
        if response.files.contains(where: { file in
          file.status == .skipped(reason: "timeout") || file.status == .skipped(reason: "cancelled")
        }) {
          statusText =
            "Comparison paused after a file timed out or was cancelled. \(incompleteText)"
          canRetry = true
          pausedPagePaths = Set(pagePaths)
          return
        }
        if response.page.complete { return }
        if case .skipped(let reason) = response.status {
          statusText = "Page skipped: \(reason.rawValue). \(incompleteText)"
          canRetry = true
          return
        }
        guard let cursor = response.page.nextAfterPath, !samePath(cursor, requestedCursor) else {
          statusText = "Comparison paused before the next file. \(incompleteText)"
          canRetry = true
          return
        }
        nextCursor = cursor
      } catch {
        guard generation == self.generation, !Task.isCancelled else { return }
        statusText = errorText(error)
        canRetry = isRetryable(error)
        return
      }
    }
  }

  private func requestPage(afterPath: String?) async throws -> InterfaceComparison {
    let descriptor = try await daemon.discover()
    do {
      return try await daemon.interfaces(
        descriptor, sessionID, before, after, nil, afterPath, true)
    } catch DaemonHTTPError.status(401, _) {
      try Task.checkCancellation()
      let refreshed = try await daemon.discover()
      return try await daemon.interfaces(
        refreshed, sessionID, before, after, nil, afterPath, true)
    }
  }

  private func samePath(_ first: String?, _ second: String?) -> Bool {
    switch (first, second) {
    case (nil, nil): true
    case (let first?, let second?): first.utf8.elementsEqual(second.utf8)
    default: false
    }
  }

  private func metadataAgrees(with response: InterfaceComparison) -> Bool {
    guard inventory != nil else { return true }
    guard response.inventory != nil else { return true }
    return inventory == response.inventory && gaps == response.gaps
      && gapsComplete == response.gapsComplete
  }

  private func isRetryable(_ error: any Error) -> Bool {
    if case DaemonHTTPError.status(let code, _) = error,
      code == 400 || code == 404 || code == 409 || code == 410
    {
      return false
    }
    return true
  }

  private var incompleteText: String {
    files.isEmpty ? "No comparison results were loaded." : "Loaded results remain incomplete."
  }

  private func errorText(_ error: any Error) -> String {
    if case DaemonHTTPError.status(let code, let durableSeq) = error {
      switch code {
      case 400: return "Comparison request rejected (400). \(incompleteText)"
      case 401: return "Daemon authentication failed. Retry after reconnecting."
      case 404: return "Capture session not found. \(incompleteText)"
      case 409:
        let boundary = durableSeq.map { "#\($0.decimal)" } ?? "an earlier position"
        return
          "The chosen head #\(after.decimal) is beyond daemon history \(boundary). Choose a new range."
      case 410: return "Capture session removed. \(incompleteText)"
      case 500: return "Analysis failed on the daemon (500). \(incompleteText)"
      default: return "Comparison request failed (\(code)). \(incompleteText)"
      }
    }
    if error is InterfaceDecodingError || error is DaemonHTTPError {
      return "Unreadable comparison response. \(incompleteText)"
    }
    if let urlError = error as? URLError, urlError.code == .timedOut {
      return "Comparison timed out. \(incompleteText)"
    }
    return "Couldn't load the comparison. \(incompleteText)"
  }
}
