import Foundation

public enum FramedLine: Equatable, Sendable {
  case line(Data)
  case overflow
}

public struct JSONLineFramer: Sendable {
  private static let cr: UInt8 = 0x0D
  private static let lf: UInt8 = 0x0A

  private let maxLineBytes: Int
  private var buffer: [UInt8] = []
  private var isDiscarding = false

  public init(maxLineBytes: Int = 1_048_576) {
    self.maxLineBytes = maxLineBytes
  }

  public mutating func append(_ chunk: Data) -> [FramedLine] {
    var framed: [FramedLine] = []
    for byte in chunk {
      if byte == Self.lf {
        finishLine(into: &framed)
      } else if !isDiscarding {
        buffer.append(byte)
        if buffer.count > maxLineBytes {
          buffer.removeAll(keepingCapacity: true)
          isDiscarding = true
        }
      }
    }
    return framed
  }

  private mutating func finishLine(into framed: inout [FramedLine]) {
    defer {
      buffer.removeAll(keepingCapacity: true)
      isDiscarding = false
    }
    if isDiscarding {
      framed.append(.overflow)
      return
    }
    if buffer.last == Self.cr {
      buffer.removeLast()
    }
    if !buffer.isEmpty {
      framed.append(.line(Data(buffer)))
    }
  }
}
