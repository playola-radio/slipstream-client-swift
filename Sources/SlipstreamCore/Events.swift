import Foundation

public enum Snapshot: Equatable, Sendable {
  case content(sha256: String, size: Int)
  case absent
  case unavailable(reason: String)
}

public struct FileChange: Equatable, Sendable {
  public var path: String
  public var before: Snapshot
  public var after: Snapshot
  public var observedAtMs: Int64

  public init(path: String, before: Snapshot, after: Snapshot, observedAtMs: Int64) {
    self.path = path
    self.before = before
    self.after = after
    self.observedAtMs = observedAtMs
  }
}

public struct TaskStarted: Equatable, Sendable {
  public var taskID: String
  public var title: String

  public init(taskID: String, title: String) {
    self.taskID = taskID
    self.title = title
  }
}

public struct CaptureGap: Equatable, Sendable {
  public enum Scope: Equatable, Sendable {
    case session
    case directory(String)
    case path(String)
  }

  public var reason: String
  public var scope: Scope

  public init(reason: String, scope: Scope) {
    self.reason = reason
    self.scope = scope
  }
}

public enum EventPayload: Equatable, Sendable {
  case sessionStarted(root: String)
  case fileChanged(FileChange)
  case taskStarted(TaskStarted)
  case captureGap(CaptureGap)
  case sessionResumed
  case recordedWithoutRow
  case unsupported(type: String)
}

public struct SlipstreamEvent: Equatable, Sendable {
  public var seq: Seq
  public var type: String
  public var payload: EventPayload

  public init(seq: Seq, type: String, payload: EventPayload) {
    self.seq = seq
    self.type = type
    self.payload = payload
  }
}

public struct EventDecodingError: Error, Equatable, Sendable {
  public var seq: String?
  public var type: String?

  public init(seq: String?, type: String?) {
    self.seq = seq
    self.type = type
  }
}

extension SlipstreamEvent {
  static let rowlessTypes: Set<String> = [
    "slipstream.file.baselined.v1",
    "slipstream.capture.baseline.completed.v1",
    "slipstream.harness.evidence.v1",
    "slipstream.change.attribution.v1",
    "slipstream.enrichment.configured.v1",
    "slipstream.enrichment.coverage.v1",
  ]

  public static func decode(_ data: Data) throws(EventDecodingError) -> SlipstreamEvent {
    let decoder = JSONDecoder()
    guard let header = try? decoder.decode(Header.self, from: data) else {
      let partial = try? decoder.decode(PartialHeader.self, from: data)
      throw EventDecodingError(seq: partial?.seq, type: partial?.type)
    }
    let failure = EventDecodingError(seq: header.seq.decimal, type: header.type)
    guard header.id == header.seq.decimal else { throw failure }
    do {
      return SlipstreamEvent(seq: header.seq, type: header.type, payload: try payload(header.type, data, decoder))
    } catch {
      throw failure
    }
  }

  private static func payload(_ type: String, _ data: Data, _ decoder: JSONDecoder) throws -> EventPayload {
    switch type {
    case "slipstream.session.started.v1":
      return .sessionStarted(root: try decoder.decode(Envelope<SessionStartedData>.self, from: data).data.root)
    case "slipstream.file.changed.v1":
      let change = try decoder.decode(Envelope<FileChangedData>.self, from: data).data
      return .fileChanged(
        FileChange(
          path: change.path,
          before: change.before.snapshot,
          after: change.after.snapshot,
          observedAtMs: change.observed_at_ms
        )
      )
    case "slipstream.task.started.v1":
      let task = try decoder.decode(Envelope<TaskStartedData>.self, from: data).data
      return .taskStarted(TaskStarted(taskID: task.task_id, title: task.title))
    case "slipstream.capture.gap.v1":
      let gap = try decoder.decode(Envelope<CaptureGapData>.self, from: data).data
      return .captureGap(CaptureGap(reason: gap.reason, scope: try gap.scope.scope))
    case "slipstream.session.resumed.v1":
      _ = try decoder.decode(Envelope<SessionResumedData>.self, from: data)
      return .sessionResumed
    case _ where rowlessTypes.contains(type):
      return .recordedWithoutRow
    default:
      return .unsupported(type: type)
    }
  }

  private struct PartialHeader: Decodable {
    var seq: String?
    var type: String?
  }

  private struct Header: Decodable {
    var id: String
    var seq: Seq
    var type: String
  }

  private struct Envelope<Payload: Decodable>: Decodable {
    var data: Payload
  }

  private struct SessionStartedData: Decodable {
    var root: String
  }

  private struct FileChangedData: Decodable {
    var path: String
    var before: SnapshotData
    var after: SnapshotData
    var observed_at_ms: Int64
  }

  private struct SnapshotData: Decodable {
    var snapshot: Snapshot

    private enum CodingKeys: String, CodingKey {
      case kind, sha256, size, reason
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      switch try container.decode(String.self, forKey: .kind) {
      case "content":
        let sha256 = try container.decode(String.self, forKey: .sha256)
        let size = try container.decode(Int.self, forKey: .size)
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy(\.isLowercaseHexDigit), size >= 0 else {
          throw DecodingError.dataCorruptedError(forKey: .sha256, in: container, debugDescription: "Bad content snapshot")
        }
        snapshot = .content(sha256: sha256, size: size)
      case "absent":
        snapshot = .absent
      case "unavailable":
        snapshot = .unavailable(reason: try container.decode(String.self, forKey: .reason))
      default:
        throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown snapshot kind")
      }
    }
  }

  private struct TaskStartedData: Decodable {
    var task_id: String
    var title: String
  }

  private struct CaptureGapData: Decodable {
    var reason: String
    var scope: ScopeData
  }

  private struct ScopeData: Decodable {
    var kind: String
    var path: String?

    var scope: CaptureGap.Scope {
      get throws {
        switch (kind, path) {
        case ("session", _): return .session
        case ("directory", let path?): return .directory(path)
        case ("path", let path?): return .path(path)
        default: throw EventDecodingError(seq: nil, type: nil)
        }
      }
    }
  }

  private struct SessionResumedData: Decodable {
    var session_id: String
  }
}

extension UInt8 {
  var isLowercaseHexDigit: Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(self)
  }
}
