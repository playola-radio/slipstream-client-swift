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

public struct SessionStarted: Equatable, Sendable {
  public var root: String
  public var startedAtMs: Int64

  public init(root: String, startedAtMs: Int64) {
    self.root = root
    self.startedAtMs = startedAtMs
  }
}

public struct TaskStarted: Equatable, Sendable {
  public var title: String

  public init(title: String) {
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

public struct QuestionSource: Equatable, Sendable {
  public let context: QuestionContext
  public let selectedText: String

  public init(context: QuestionContext, selectedText: String) {
    self.context = context
    self.selectedText = selectedText
  }
}

public struct QuestionQueued: Equatable, Sendable {
  public var questionID: String
  public var requestID: String
  public var text: String
  public var source: QuestionSource
  public var queuedAtMs: Int64
  public var replyToQuestionID: String?

  public init(
    questionID: String, requestID: String, text: String, source: QuestionSource, queuedAtMs: Int64,
    replyToQuestionID: String?
  ) {
    self.questionID = questionID
    self.requestID = requestID
    self.text = text
    self.source = source
    self.queuedAtMs = queuedAtMs
    self.replyToQuestionID = replyToQuestionID
  }
}

public struct QuestionDispatchAttempted: Equatable, Sendable {
  public var questionID: String
  public var queuedSeq: Seq

  public init(questionID: String, queuedSeq: Seq) {
    self.questionID = questionID
    self.queuedSeq = queuedSeq
  }
}

public struct QuestionAnswered: Equatable, Sendable {
  public var questionID: String
  public var attemptSeq: Seq
  public var text: String
  public var answeredAtMs: Int64

  public init(questionID: String, attemptSeq: Seq, text: String, answeredAtMs: Int64) {
    self.questionID = questionID
    self.attemptSeq = attemptSeq
    self.text = text
    self.answeredAtMs = answeredAtMs
  }
}

public enum EventPayload: Equatable, Sendable {
  case sessionStarted(SessionStarted)
  case fileChanged(FileChange)
  case taskStarted(TaskStarted)
  case captureGap(CaptureGap)
  case sessionResumed
  case questionQueued(QuestionQueued)
  case questionDispatchAttempted(QuestionDispatchAttempted)
  case questionAnswered(QuestionAnswered)
  case agentConnection(AgentConnection)
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
      let session = try decoder.decode(Envelope<SessionStartedData>.self, from: data).data
      return .sessionStarted(SessionStarted(root: session.root, startedAtMs: session.started_at_ms))
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
      return .taskStarted(TaskStarted(title: task.title))
    case "slipstream.capture.gap.v1":
      let gap = try decoder.decode(Envelope<CaptureGapData>.self, from: data).data
      return .captureGap(CaptureGap(reason: gap.reason, scope: try gap.scope.scope))
    case "slipstream.capture.scope.v1":
      let scope = try decoder.decode(Envelope<CaptureScopeData>.self, from: data).data
      switch (scope.policy, scope.status) {
      case ("git", "active"), ("filesystem", "active"):
        return .recordedWithoutRow
      case ("git", "unavailable"):
        return .captureGap(CaptureGap(reason: "capture-scope-unavailable", scope: .session))
      default:
        throw EventDecodingError(seq: nil, type: nil)
      }
    case "slipstream.session.resumed.v1":
      _ = try decoder.decode(Envelope<SessionResumedData>.self, from: data)
      return .sessionResumed
    case "slipstream.question.queued.v1":
      let queued = try decoder.decode(Envelope<QuestionQueuedData>.self, from: data).data
      return .questionQueued(
        QuestionQueued(
          questionID: queued.question_id,
          requestID: queued.request_id,
          text: queued.text,
          source: queued.context.source,
          queuedAtMs: queued.queued_at_ms,
          replyToQuestionID: queued.reply_to_question_id
        )
      )
    case "slipstream.question.dispatch_attempted.v1":
      let attempt = try decoder.decode(Envelope<QuestionDispatchAttemptedData>.self, from: data).data
      return .questionDispatchAttempted(QuestionDispatchAttempted(questionID: attempt.question_id, queuedSeq: attempt.queued_seq))
    case "slipstream.question.answered.v1":
      let answer = try decoder.decode(Envelope<QuestionAnsweredData>.self, from: data).data
      guard !QuestionRequest.trim(answer.text).isEmpty, answer.text.utf8.count <= 16384 else {
        throw EventDecodingError(seq: nil, type: nil)
      }
      return .questionAnswered(
        QuestionAnswered(
          questionID: answer.question_id,
          attemptSeq: answer.attempt_seq,
          text: answer.text,
          answeredAtMs: answer.answered_at_ms
        )
      )
    case "slipstream.agent.connection.v1":
      let connection = try decoder.decode(Envelope<AgentConnectionWire>.self, from: data).data
      return .agentConnection(connection.connection)
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
    var started_at_ms: Int64
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

  private struct CaptureScopeData: Decodable {
    var session_id: String
    var policy: String
    var status: String
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

  private struct QuestionQueuedData: Decodable {
    var question_id: String
    var request_id: String
    var text: String
    var context: QuestionSourceData
    var queued_at_ms: Int64
    var reply_to_question_id: String?
  }

  private struct QuestionSourceData: Decodable {
    var change_seq: Seq
    var path: String
    var snapshot_sha256: String
    var line_start: Int
    var line_end: Int
    var selected_text: String

    var source: QuestionSource {
      QuestionSource(
        context: QuestionContext(
          changeSeq: change_seq.decimal,
          path: path,
          snapshotSHA256: snapshot_sha256,
          lineStart: line_start,
          lineEnd: line_end
        ),
        selectedText: selected_text
      )
    }
  }

  private struct QuestionDispatchAttemptedData: Decodable {
    var question_id: String
    var queued_seq: Seq
  }

  private struct QuestionAnsweredData: Decodable {
    var question_id: String
    var attempt_seq: Seq
    var text: String
    var answered_at_ms: Int64
  }
}

extension UInt8 {
  var isLowercaseHexDigit: Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(self)
  }
}
