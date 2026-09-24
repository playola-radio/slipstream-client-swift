import Foundation
import SlipstreamCore

enum CardContentLoader {
  static let maximumContentSize = 1 << 20

  static func noteBeforeFetching(_ row: FileChangeRow) -> String? {
    switch (row.before, row.after) {
    case (_, .absent):
      return "File deleted"
    case (.unavailable(let reason), _), (_, .unavailable(let reason)):
      return PlainWords.snapshotReason(reason)
    case (.content(_, let size), _) where size > maximumContentSize:
      return "Too large to show"
    case (_, .content(_, let size)) where size > maximumContentSize:
      return "Too large to show"
    default:
      return nil
    }
  }

  @concurrent
  static func load(_ row: FileChangeRow, sessionID: String, daemon: DaemonClient) async -> CardContent? {
    do {
      let descriptor = try await daemon.discover()
      let response = try await daemon.clips(descriptor, sessionID, row.id)
      if response.status == .skipped || response.status == .unavailable {
        return .note(PlainWords.clipReason(response.fallbackReason ?? "unavailable"))
      }
      guard case .content(let afterSHA, _) = row.after else { return .note("File deleted") }
      guard let after = text(try await daemon.blob(descriptor, afterSHA)) else {
        return .note(binaryNote)
      }
      var before: String?
      if case .content(let beforeSHA, _) = row.before {
        guard let text = text(try await daemon.blob(descriptor, beforeSHA)) else { return .note(binaryNote) }
        before = text
      }
      return content(response.clips, before: before, after: after)
    } catch {
      if Task.isCancelled { return nil }
      if case DaemonHTTPError.status(404, _) = error { return .note("Content no longer available") }
      return .note("Couldn't load this change")
    }
  }

  static func content(_ clips: [Clip], before: String?, after: String) -> CardContent {
    let shown = merged(clips.compactMap { clip in clip.after.span.map { (clip.after.method, $0) } })
    guard !shown.isEmpty else {
      if let reason = clips.lazy.compactMap({ $0.after.method == .unavailable ? $0.after.reason : nil }).first {
        return .note(PlainWords.clipReason(reason))
      }
      return .note("Only lines removed — nothing to show")
    }
    let blocks = shown.enumerated().map { index, entry in
      let span = entry.1
      let lines = ChangedLines.clipLines(before: before, after: after, lineStart: span.lineStart, lineEnd: span.lineEnd)
      return CodeBlock(
        id: index,
        separatorText: index == 0 ? nil : "···",
        lines: lines.map { CodeLine(id: $0.number, number: String($0.number), text: $0.text.replacingOccurrences(of: "\t", with: "    "), isChanged: $0.isChanged) },
        truncationText: span.truncated ? "… truncated" : nil
      )
    }
    var subtitles: [String] = []
    for (method, _) in shown {
      let subtitle = subtitle(method)
      if !subtitles.contains(subtitle) { subtitles.append(subtitle) }
    }
    return .code(subtitle: subtitles.joined(separator: " · "), blocks: blocks)
  }

  private static let binaryNote = "Binary file — not shown"

  private static func merged(_ spans: [(ClipSide.Method, ClipSpan)]) -> [(ClipSide.Method, ClipSpan)] {
    var result: [(ClipSide.Method, ClipSpan)] = []
    for (method, span) in spans.sorted(by: { $0.1.lineStart < $1.1.lineStart }) {
      guard let (lastMethod, last) = result.last, span.lineStart <= last.lineEnd else {
        result.append((method, span))
        continue
      }
      let lineEnd = max(last.lineEnd, span.lineEnd)
      let truncated = (last.lineEnd == lineEnd && last.truncated) || (span.lineEnd == lineEnd && span.truncated)
      result[result.count - 1] = (
        lastMethod == .function || method == .function ? .function : lastMethod,
        ClipSpan(lineStart: last.lineStart, lineEnd: lineEnd, truncated: truncated)
      )
    }
    return result
  }

  private static func subtitle(_ method: ClipSide.Method) -> String {
    switch method {
    case .function: "Full function"
    case .changedRange: "Changed lines"
    case .wholeFile, .absent, .unavailable: "Whole file"
    }
  }

  private static func text(_ data: Data) -> String? {
    guard !data.contains(0) else { return nil }
    return String(bytes: data, encoding: .utf8)
  }
}
