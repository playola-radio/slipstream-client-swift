import Foundation

public enum OwnerLock {
  /// Parsed like the daemon's `parseLock`: a JSON object's positive integer `pid`, else a leading bare integer.
  public static func pid(in text: String) -> Int32? {
    if let lock = try? JSONDecoder().decode(LockFile.self, from: Data(text.utf8)) {
      return lock.pid.flatMap { Int32(exactly: $0) }.flatMap { $0 > 0 ? $0 : nil }
    }
    let digits = text.drop { $0.isWhitespace }.prefix { $0.isASCII && $0.isNumber }
    return Int32(digits).flatMap { $0 > 0 ? $0 : nil }
  }

  private struct LockFile: Decodable { let pid: Double? }
}
