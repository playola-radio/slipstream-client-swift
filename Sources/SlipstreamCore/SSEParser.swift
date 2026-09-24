public struct SSEEvent: Equatable, Sendable {
  public var id: String?
  public var data: String

  public init(id: String?, data: String) {
    self.id = id
    self.data = data
  }
}

public enum SSEItem: Equatable, Sendable {
  case event(SSEEvent)
  case comment
  case malformedLine
}

public struct SSEParser: Sendable {
  private enum BOMState: Sendable {
    case checking([UInt8])
    case done
  }

  private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
  private static let cr: UInt8 = 0x0D
  private static let lf: UInt8 = 0x0A
  static let maximumLineLength = 1 << 20

  private var bomState: BOMState = .checking([])
  private var lineBuffer: [UInt8] = []
  private var pendingCR = false

  private var currentId: String?
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
      if lineBuffer.count > Self.maximumLineLength {
        lineBuffer.removeAll(keepingCapacity: true)
        currentId = nil
        dataLines = []
        sawData = false
        items.append(.malformedLine)
      }
    }
  }

  private mutating func dispatchLine(into items: inout [SSEItem]) {
    guard let line = String(bytes: lineBuffer, encoding: .utf8) else {
      lineBuffer.removeAll(keepingCapacity: true)
      currentId = nil
      dataLines = []
      sawData = false
      items.append(.malformedLine)
      return
    }
    lineBuffer.removeAll(keepingCapacity: true)

    if line.isEmpty {
      if sawData {
        items.append(.event(SSEEvent(id: currentId, data: dataLines.joined(separator: "\n"))))
      }
      currentId = nil
      dataLines = []
      sawData = false
      return
    }

    if line.hasPrefix(":") {
      items.append(.comment)
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
    case "id":
      if !value.unicodeScalars.contains(where: { $0.value == 0 }) {
        currentId = String(value)
      }
    default:
      break
    }
  }
}
