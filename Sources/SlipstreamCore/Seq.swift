public struct Seq: Hashable, Sendable, Comparable, CustomStringConvertible {
  public let decimal: String

  public static let zero = Seq(unchecked: "0")

  public init?(_ decimal: String) {
    guard
      !decimal.isEmpty,
      decimal.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
      decimal == "0" || decimal.utf8.first != UInt8(ascii: "0")
    else { return nil }
    self.decimal = decimal
  }

  private init(unchecked decimal: String) {
    self.decimal = decimal
  }

  public var description: String { decimal }

  public var successor: Seq {
    var digits = Array(decimal.utf8)
    var index = digits.count - 1
    while index >= 0 {
      if digits[index] == UInt8(ascii: "9") {
        digits[index] = UInt8(ascii: "0")
        index -= 1
      } else {
        digits[index] += 1
        return Seq(unchecked: String(decoding: digits, as: UTF8.self))
      }
    }
    return Seq(unchecked: "1" + String(decoding: digits, as: UTF8.self))
  }

  public static func < (lhs: Seq, rhs: Seq) -> Bool {
    if lhs.decimal.utf8.count != rhs.decimal.utf8.count {
      return lhs.decimal.utf8.count < rhs.decimal.utf8.count
    }
    return lhs.decimal < rhs.decimal
  }
}

extension Seq: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let string = try container.decode(String.self)
    guard let seq = Seq(string) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Not a canonical decimal seq: \(string)")
    }
    self = seq
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(decimal)
  }
}
