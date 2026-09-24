public struct SSEEvent: Equatable, Sendable {
  public var id: String?
  public var event: String?
  public var data: String

  public init(id: String?, event: String?, data: String) {
    self.id = id
    self.event = event
    self.data = data
  }
}

public enum SSEItem: Equatable, Sendable {
  case event(SSEEvent)
  case comment(String)
}

public struct SSEParser: Sendable {
  private enum BOMState: Sendable {
    case checking([UInt8])
    case done
  }

  private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
  private static let cr: UInt8 = 0x0D
  private static let lf: UInt8 = 0x0A

  private var bomState: BOMState = .checking([])
  private var lineBuffer: [UInt8] = []
  private var pendingCR = false

  private var currentId: String?
  private var currentEvent: String?
  private var dataLines: [String] = []
  private var sawData = false

  public init() {}

  public mutating func consume(_ bytes: some Sequence<UInt8>) -> [SSEItem] {
    var items: [SSEItem] = []
    for byte in bytes {
      consumeByte(byte, into: &items)
    }
    return items
  }

  private mutating func consumeByte(_ byte: UInt8, into items: inout [SSEItem]) {
    switch bomState {
    case .checking(var matched):
      matched.append(byte)
      if matched == Self.bom {
        bomState = .done
      } else if Self.bom.starts(with: matched) {
        bomState = .checking(matched)
      } else {
        bomState = .done
        for pending in matched {
          consumeLineByte(pending, into: &items)
        }
      }
    case .done:
      consumeLineByte(byte, into: &items)
    }
  }

  private mutating func consumeLineByte(_ byte: UInt8, into items: inout [SSEItem]) {
    if pendingCR && byte == Self.lf {
      pendingCR = false
      return
    }
    pendingCR = false
    if byte == Self.cr {
      dispatchLine(into: &items)
      pendingCR = true
    } else if byte == Self.lf {
      dispatchLine(into: &items)
    } else {
      lineBuffer.append(byte)
    }
  }

  private mutating func dispatchLine(into items: inout [SSEItem]) {
    let line = String(decoding: lineBuffer, as: UTF8.self)
    lineBuffer.removeAll(keepingCapacity: true)

    if line.isEmpty {
      if sawData {
        items.append(.event(SSEEvent(id: currentId, event: currentEvent, data: dataLines.joined(separator: "\n"))))
      }
      currentId = nil
      currentEvent = nil
      dataLines = []
      sawData = false
      return
    }

    if line.hasPrefix(":") {
      var comment = line.dropFirst()
      if comment.hasPrefix(" ") {
        comment = comment.dropFirst()
      }
      items.append(.comment(String(comment)))
      return
    }

    let field: Substring
    var value: Substring
    if let colonIndex = line.firstIndex(of: ":") {
      field = line[line.startIndex..<colonIndex]
      value = line[line.index(after: colonIndex)...]
      if value.hasPrefix(" ") {
        value = value.dropFirst()
      }
    } else {
      field = line[...]
      value = ""
    }

    switch field {
    case "data":
      dataLines.append(String(value))
      sawData = true
    case "event":
      currentEvent = String(value)
    case "id":
      if !value.unicodeScalars.contains(where: { $0.value == 0 }) {
        currentId = String(value)
      }
    default:
      break
    }
  }
}
