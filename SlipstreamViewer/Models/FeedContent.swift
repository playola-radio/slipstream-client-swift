import Foundation
import IdentifiedCollections
import SlipstreamCore

struct SessionOption: Identifiable, Equatable, Sendable {
  var id: String
  var label: String
}

enum ConnectionState: Equatable, Sendable {
  case idle
  case connecting
  case live
  case reconnecting(attempt: Int)
  case disconnected
  case sessionRemoved
  case halted(String)
}

struct FileChangeRow: Identifiable, Equatable, Sendable {
  var id: Seq
  var path: String
  var before: Snapshot
  var after: Snapshot
  var time: String
}

struct FeedMarker: Identifiable, Equatable, Sendable {
  var id: Seq
  var text: String
}

enum FeedItem: Identifiable, Equatable, Sendable {
  case file(FileChangeRow)
  case marker(FeedMarker)

  var id: Seq {
    switch self {
    case .file(let row): row.id
    case .marker(let marker): marker.id
    }
  }
}

struct TaskHeading: Equatable, Sendable {
  var number: String
  var title: String
}

struct FeedSection: Identifiable, Equatable, Sendable {
  var id: Seq
  var heading: TaskHeading?
  var items: IdentifiedArrayOf<FeedItem> = []
}

struct CodeLine: Identifiable, Equatable, Sendable {
  var id: Int
  var number: String
  var text: String
  var isChanged: Bool
}

struct CodeBlock: Identifiable, Equatable, Sendable {
  var id: Int
  var separatorText: String?
  var lines: [CodeLine]
  var truncationText: String?
}

enum CardContent: Equatable, Sendable {
  case loading
  case note(String)
  case code(subtitle: String, blocks: [CodeBlock])
}

enum PlainWords {
  static func snapshotReason(_ reason: String) -> String {
    switch reason {
    case "oversize": "Too large to show"
    case "unreadable": "File couldn't be read"
    case "unstable": "File was changing too fast to capture"
    case "io-error": "File couldn't be read (disk error)"
    case "baseline-unknown": "Earlier version wasn't captured"
    default: fallback(reason)
    }
  }

  static func clipReason(_ reason: String) -> String {
    switch reason {
    case "not-utf8": "Binary file — not shown"
    case "oversize": "Too large to show"
    case "no-content": "No content on either side"
    case "no-change": "Content is unchanged"
    case "clip-too-large": "Change is too large to show"
    case "timeout", "overloaded": "Took too long to prepare — reopen the session to try again"
    case "invalid-hex", "open-failed", "read-failed", "before-missing": "Content no longer available"
    case "internal-error", "worker-error": "Couldn't prepare this change"
    default: snapshotReason(reason)
    }
  }

  static func gapReason(_ reason: String) -> String {
    switch reason {
    case "coalesced": "changes were coalesced"
    case "baseline-unreadable": "the starting version couldn't be read"
    case "watcher-error": "the file watcher failed"
    case "restart": "the daemon restarted"
    case "storage": "storage failed"
    default: fallback(reason).lowercased()
    }
  }

  static func gapScope(_ scope: CaptureGap.Scope) -> String {
    switch scope {
    case .session: "whole session"
    case .directory(let path): path + "/"
    case .path(let path): path
    }
  }

  private static func fallback(_ reason: String) -> String {
    let words = reason.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    return words.prefix(1).uppercased() + words.dropFirst()
  }
}
