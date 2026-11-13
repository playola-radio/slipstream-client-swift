import Foundation
import SlipstreamCore

enum CardContentLoader {
  static let maximumContentSize = 1 << 20

  static func noteBeforeFetching(_ row: FileChangeRow) -> String? {
    switch (row.before, row.after) {
    case (_, .absent):
      return "File deleted"
    case (_, .unavailable(let reason)):
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
    for _ in 0..<2 {
      do {
        return try await fetch(row, sessionID: sessionID, daemon: daemon)
      } catch {
        if Task.isCancelled { return nil }
        if case DaemonHTTPError.status(404, _, _) = error { return .note("Content no longer available") }
      }
    }
    return .note(failedNote)
  }

  static func isRetryable(_ content: CardContent) -> Bool {
    content == .note(failedNote) || content == .note(PlainWords.clipReason("timeout"))
  }

  private static func fetch(_ row: FileChangeRow, sessionID: String, daemon: DaemonClient) async throws -> CardContent {
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
    let isBeforeVerifiable = before != nil || row.before == .absent
    return content(
      response.clips, fallbackReason: response.fallbackReason, before: before, after: after,
      isBeforeVerifiable: isBeforeVerifiable, language: SyntaxLanguage(path: row.path)
    )
  }

  static func content(
    _ clips: [Clip], fallbackReason: String?, before: String?, after: String, isBeforeVerifiable: Bool = true,
    language: SyntaxLanguage? = nil
  ) -> CardContent {
    let shown = clips.filter { $0.after.span != nil }
    guard !shown.isEmpty else {
      if let reason = clips.lazy.compactMap({ $0.after.method == .unavailable ? $0.after.reason : nil }).first {
        return .note(PlainWords.clipReason(reason))
      }
      if fallbackReason == "truncated-after" { return .note(PlainWords.clipReason("truncated-after")) }
      return .note("Only lines removed — nothing to show")
    }
    let spans = merged(shown.compactMap(\.after.span))
    let comparison = ChangedLines.compare(before: before, after: after, spans: spans)
    let syntaxRuns = language.map {
      SyntaxLexer.lines(after.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabWidth)), language: $0)
    } ?? []
    let blocks = spans.enumerated().map { index, span in
      CodeBlock(
        id: index,
        separatorText: index == 0 ? nil : "···",
        lines: comparison.clipLines(lineStart: span.lineStart, lineEnd: span.lineEnd).map {
          codeLine($0, isVerified: isBeforeVerifiable, syntaxRuns: syntaxRuns.indices.contains($0.number - 1) ? syntaxRuns[$0.number - 1] : [])
        },
        truncationText: span.truncated ? "… truncated" : nil
      )
    }
    return .code(blocks)
  }

  private static let tabWidth = 4

  private static let removalAnnouncement = ", removed text, "

  private static func codeLine(_ line: ClipLine, isVerified: Bool, syntaxRuns: [SyntaxRun]) -> CodeLine {
    var codeLine = CodeLine(
      id: line.number, number: String(line.number),
      text: line.text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabWidth)),
      sourceText: line.text, isChanged: line.isChanged, isVerified: isVerified, syntaxRuns: syntaxRuns
    )
    guard let changedText = line.changedText else { return codeLine }
    var displayOffsets = [0]
    for character in line.text {
      displayOffsets.append(displayOffsets[displayOffsets.count - 1] + (character == "\t" ? tabWidth : character.utf16.count))
    }
    codeLine.changedRanges = changedText.inserted.map { displayOffsets[$0.lowerBound]..<displayOffsets[$0.upperBound] }
    codeLine.removalOffsets = changedText.removedAt.map { displayOffsets[$0] }
    codeLine.accessibilityText = accessibilityText(codeLine.text, removalOffsets: codeLine.removalOffsets)
    return codeLine
  }

  private static func accessibilityText(_ text: String, removalOffsets: [Int]) -> String {
    guard !removalOffsets.isEmpty else { return text }
    var result = text
    for offset in removalOffsets.sorted(by: >) {
      let index = String.Index(utf16Offset: offset, in: result)
      result.insert(contentsOf: removalAnnouncement, at: index)
    }
    return result
  }

  private static let binaryNote = "Binary file — not shown"
  private static let failedNote = "Couldn't load this change"

  private static func merged(_ spans: [ClipSpan]) -> [ClipSpan] {
    var result: [ClipSpan] = []
    for span in spans.sorted(by: { $0.lineStart < $1.lineStart }) {
      guard let last = result.last, span.lineStart <= last.lineEnd else {
        result.append(span)
        continue
      }
      let lineEnd = max(last.lineEnd, span.lineEnd)
      let truncated = last.truncated || span.truncated
      result[result.count - 1] = ClipSpan(lineStart: last.lineStart, lineEnd: lineEnd, truncated: truncated)
    }
    return result
  }

  private static func text(_ data: Data) -> String? {
    guard !data.contains(0) else { return nil }
    return String(bytes: data, encoding: .utf8)
  }
}
