import Foundation

public struct ClipSpan: Equatable, Sendable, Decodable {
  public var lineStart: Int
  public var lineEnd: Int
  public var truncated: Bool

  public init(lineStart: Int, lineEnd: Int, truncated: Bool) {
    self.lineStart = lineStart
    self.lineEnd = lineEnd
    self.truncated = truncated
  }

  private enum CodingKeys: String, CodingKey {
    case lineStart = "line_start"
    case lineEnd = "line_end"
    case truncated
  }
}

public struct ClipSide: Equatable, Sendable, Decodable {
  public enum Method: String, Equatable, Sendable, Decodable {
    case function
    case changedRange = "changed-range"
    case wholeFile = "whole-file"
    case absent
    case unavailable
  }

  public var span: ClipSpan?
  public var method: Method
  public var reason: String?

  public init(span: ClipSpan?, method: Method, reason: String? = nil) {
    self.span = span
    self.method = method
    self.reason = reason
  }
}

public struct Clip: Equatable, Sendable, Decodable {
  public var after: ClipSide

  public init(after: ClipSide) {
    self.after = after
  }
}

public struct ClipsResponse: Equatable, Sendable, Decodable {
  public enum Status: String, Equatable, Sendable, Decodable {
    case ready, fallback, skipped, unavailable
  }

  public var status: Status
  public var fallbackReason: String?
  public var clips: [Clip]

  public init(status: Status, fallbackReason: String? = nil, clips: [Clip]) {
    self.status = status
    self.fallbackReason = fallbackReason
    self.clips = clips
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case fallbackReason = "fallback_reason"
    case clips
  }
}
