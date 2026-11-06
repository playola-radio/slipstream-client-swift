import AppKit
import Dependencies

struct OpenInApp: Equatable, Identifiable, Sendable {
  let id: String
  let name: String
  let url: URL
}

/// Opens a workspace folder in another app, offering only the known apps installed on this Mac.
struct OpenInClient: Sendable {
  var installedApps: @Sendable () -> [OpenInApp]
  var icon: @MainActor @Sendable (_ app: OpenInApp) -> NSImage
  var open: @Sendable (_ folder: URL, _ app: OpenInApp) async throws -> Void
}

extension OpenInClient {
  static let knownApps: [(bundleID: String, name: String)] = [
    ("com.apple.finder", "Finder"),
    ("com.todesktop.230313mzl4w4u92", "Cursor"),
    ("com.microsoft.VSCode", "VS Code"),
    ("dev.zed.Zed", "Zed"),
    ("com.exafunction.windsurf", "Windsurf"),
    ("com.sublimetext.4", "Sublime Text"),
    ("com.apple.dt.Xcode", "Xcode"),
    ("com.google.android.studio", "Android Studio"),
    ("com.apple.Terminal", "Terminal"),
    ("com.googlecode.iterm2", "iTerm"),
    ("com.mitchellh.ghostty", "Ghostty"),
    ("dev.warp.Warp-Stable", "Warp"),
  ]
}

extension OpenInClient: DependencyKey {
  static var liveValue: Self {
    Self(
      installedApps: {
        knownApps.compactMap { known in
          NSWorkspace.shared.urlForApplication(withBundleIdentifier: known.bundleID)
            .map { OpenInApp(id: known.bundleID, name: known.name, url: $0) }
        }
      },
      icon: { app in
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        icon.size = NSSize(width: DesignTokens.OpenInButton.iconSize, height: DesignTokens.OpenInButton.iconSize)
        return icon
      },
      open: { folder, app in
        _ = try await NSWorkspace.shared.open(
          [folder], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
      }
    )
  }

  static var testValue: Self {
    Self(
      installedApps: unimplemented("OpenInClient.installedApps", placeholder: []),
      icon: { _ in NSImage() },
      open: unimplemented("OpenInClient.open")
    )
  }
}

extension DependencyValues {
  var openIn: OpenInClient {
    get { self[OpenInClient.self] }
    set { self[OpenInClient.self] = newValue }
  }
}
