import Darwin
import Foundation

public struct DaemonDescriptor: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  public let baseURL: URL
  public let token: String

  public init(baseURL: URL, token: String) {
    self.baseURL = baseURL
    self.token = token
  }

  public var description: String {
    "DaemonDescriptor(baseURL: \(baseURL.absoluteString), token: <redacted>)"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "baseURL": baseURL,
        "token": "<redacted>",
      ],
      displayStyle: .struct
    )
  }
}

public enum DescriptorError: Error, Equatable, Sendable {
  case noDaemonRunning(store: String)
}

public enum DescriptorDiscovery {
  public static func storeURL(environment: [String: String], home: URL) -> URL {
    if let raw = environment["SLIPSTREAM_STORE"], !raw.isEmpty {
      return expandTilde(raw, home: home)
    }
    return home.appendingPathComponent(".slipstream")
  }

  public static func discover(store: URL, currentUID: uid_t = getuid()) throws(DescriptorError) -> DaemonDescriptor {
    let runtimeDir = store.appendingPathComponent("runtime")
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: runtimeDir.path) else {
      throw DescriptorError.noDaemonRunning(store: store.path)
    }

    var newest: DaemonDescriptor?
    var newestMTime = Date.distantPast
    for name in names where name.hasSuffix(".json") {
      let path = runtimeDir.appendingPathComponent(name).path
      guard let (descriptor, mtime) = validCandidate(at: path, currentUID: currentUID) else { continue }
      if newest == nil || mtime > newestMTime {
        newest = descriptor
        newestMTime = mtime
      }
    }

    guard let result = newest else {
      throw DescriptorError.noDaemonRunning(store: store.path)
    }
    return result
  }

  private static func expandTilde(_ path: String, home: URL) -> URL {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
    return URL(fileURLWithPath: path)
  }

  /// Opens, stats and validates a single runtime descriptor candidate.
  /// Any failure at any step means the candidate is skipped, not fatal.
  private static func validCandidate(at path: String, currentUID: uid_t) -> (DaemonDescriptor, Date)? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var st = stat()
    guard fstat(fd, &st) == 0 else { return nil }
    guard (st.st_mode & S_IFMT) == S_IFREG else { return nil }
    guard (st.st_mode & 0o077) == 0 else { return nil }
    guard st.st_uid == currentUID else { return nil }

    let size = Int(st.st_size)
    var data = Data(count: size)
    let bytesRead = data.withUnsafeMutableBytes { ptr in
      read(fd, ptr.baseAddress, size)
    }
    guard bytesRead == size else { return nil }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    guard let urlString = json["url"] as? String, let token = json["token"] as? String else { return nil }
    guard let url = URL(string: urlString), isValidDaemonURL(url) else { return nil }

    return (DaemonDescriptor(baseURL: url, token: token), date(from: st.st_mtimespec))
  }

  private static func isValidDaemonURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "http" else { return false }
    guard let host = url.host, ["127.0.0.1", "::1", "localhost"].contains(host) else { return false }
    guard url.port != nil else { return false }
    guard url.user == nil, url.password == nil else { return false }
    guard url.path.isEmpty || url.path == "/" else { return false }
    guard url.query == nil else { return false }
    guard url.fragment == nil else { return false }
    return true
  }

  private static func date(from spec: timespec) -> Date {
    Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
  }
}
