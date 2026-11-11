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

public enum DescriptorError: Error, Equatable, Sendable, CustomStringConvertible {
  case noRuntimeDirectory(path: String, errno: Int32, message: String)
  case noUsableDescriptor(directory: String, rejected: [DescriptorRejection])

  public var description: String {
    switch self {
    case .noRuntimeDirectory(let path, let errno, let message):
      return "can't read \(path): \(message) (errno \(errno))"
    case .noUsableDescriptor(let directory, let rejected) where rejected.isEmpty:
      return "no usable descriptor in \(directory): no .json files"
    case .noUsableDescriptor(let directory, let rejected):
      return (["no usable descriptor in \(directory):"] + rejected.map { "  \($0.file): \($0.reason)" })
        .joined(separator: "\n")
    }
  }
}

public struct DescriptorRejection: Error, Equatable, Sendable {
  public let file: String
  public let reason: String

  public init(file: String, reason: String) {
    self.file = file
    self.reason = reason
  }
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
    guard let handle = opendir(runtimeDir.path) else {
      let code = errno
      throw .noRuntimeDirectory(path: runtimeDir.path, errno: code, message: String(cString: strerror(code)))
    }
    closedir(handle)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: runtimeDir.path)) ?? []

    var newest: DaemonDescriptor?
    var newestMTime = Date.distantPast
    var rejected: [DescriptorRejection] = []
    for name in names.sorted() where name.hasSuffix(".json") {
      switch validCandidate(at: runtimeDir.appendingPathComponent(name).path, currentUID: currentUID) {
      case .success(let (descriptor, mtime)):
        if newest == nil || mtime > newestMTime {
          newest = descriptor
          newestMTime = mtime
        }
      case .failure(let reason):
        rejected.append(DescriptorRejection(file: name, reason: reason.message))
      }
    }

    guard let result = newest else {
      throw .noUsableDescriptor(directory: runtimeDir.path, rejected: rejected)
    }
    return result
  }

  private static func expandTilde(_ path: String, home: URL) -> URL {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
    return URL(fileURLWithPath: path)
  }

  static let maximumDescriptorSize = 1 << 16

  private struct Rejected: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  /// Opens, stats and validates a single runtime descriptor candidate.
  /// A rejection names the failed check and never includes the token or anything else read from the url.
  private static func validCandidate(at path: String, currentUID: uid_t) -> Result<(DaemonDescriptor, Date), Rejected> {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return .failure(Rejected("open: \(errnoText())")) }
    defer { close(fd) }

    var st = stat()
    guard fstat(fd, &st) == 0 else { return .failure(Rejected("fstat: \(errnoText())")) }
    guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(Rejected("not a regular file")) }
    let mode = st.st_mode & 0o777
    guard (mode & 0o077) == 0 else {
      return .failure(Rejected("mode 0\(String(mode, radix: 8)) (group/other bits set)"))
    }
    guard st.st_uid == currentUID else {
      return .failure(Rejected("owner uid \(st.st_uid), expected \(currentUID)"))
    }
    guard st.st_size <= maximumDescriptorSize else {
      return .failure(Rejected("\(st.st_size) bytes, larger than \(maximumDescriptorSize)"))
    }

    let size = Int(st.st_size)
    var data = Data(count: size)
    let bytesRead = data.withUnsafeMutableBytes { ptr in
      read(fd, ptr.baseAddress, size)
    }
    guard bytesRead == size else {
      return .failure(Rejected(bytesRead < 0 ? "read: \(errnoText())" : "read \(bytesRead) of \(size) bytes"))
    }

    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      let message = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "unreadable"
      return .failure(Rejected("invalid JSON: \(message)"))
    }
    guard let json = object as? [String: Any] else { return .failure(Rejected("JSON is not an object")) }
    guard let urlString = json["url"] as? String else { return .failure(Rejected(#"missing "url" string"#)) }
    guard let token = json["token"] as? String else { return .failure(Rejected(#"missing "token" string"#)) }
    guard let url = URL(string: urlString) else { return .failure(Rejected("url is not a valid URL")) }
    if let problem = urlProblem(url, token: token) { return .failure(Rejected(problem)) }

    return .success((DaemonDescriptor(baseURL: url, token: token), date(from: st.st_mtimespec)))
  }

  private static func urlProblem(_ url: URL, token: String) -> String? {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" else { return "url scheme is not http" }
    guard url.user == nil, url.password == nil else { return "url contains credentials" }
    guard let host = url.host, ["127.0.0.1", "::1", "localhost"].contains(host) else {
      let shown = url.host.map { !token.isEmpty && $0.contains(token) ? "<redacted>" : $0 } ?? ""
      return "url is not loopback: http://\(shown)\(url.port.map { ":\($0)" } ?? "")"
    }
    guard url.port != nil else { return "url has no port" }
    guard url.path.isEmpty || url.path == "/" else { return "url has a path" }
    guard url.query == nil else { return "url has a query" }
    guard url.fragment == nil else { return "url has a fragment" }
    return nil
  }

  private static func errnoText() -> String {
    let code = errno
    return "\(String(cString: strerror(code))) (errno \(code))"
  }

  private static func date(from spec: timespec) -> Date {
    Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
  }
}
