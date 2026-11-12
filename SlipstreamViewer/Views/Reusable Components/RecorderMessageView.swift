import SlipstreamCore
import SwiftUI

struct RecorderMessageView: View {
  let message: RecorderMessage
  let isDocked: Bool
  let actionTapped: (RecorderMessage.Action) -> Void
  let copyTapped: () -> Void

  var body: some View {
    if isDocked {
      docked
    } else {
      full
    }
  }

  private var full: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignTokens.RecorderMessage.gap) {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.RecorderMessage.headlineGap) {
          IconView(icon: DesignTokens.RecorderMessage.headlineIcon(message))
          Text(message.headline)
            .font(DesignTokens.RecorderMessage.headlineFont)
            .foregroundStyle(DesignTokens.RecorderMessage.headlineColor)
            .lineSpacing(DesignTokens.RecorderMessage.headlineLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        if let evidence = message.evidence {
          EvidenceBlockView(evidence: evidence, copyTapped: copyTapped)
        }
        HStack(spacing: DesignTokens.RecorderMessage.buttonGap) {
          ForEach(message.actions, id: \.self) { action in
            Button(action.title) { actionTapped(action) }
              .buttonStyle(RecorderButtonStyle(isPrimary: message.isPrimary(action)))
          }
        }
      }
    }
    .frame(maxWidth: DesignTokens.RecorderMessage.width, alignment: .leading)
  }

  private var docked: some View {
    VStack(alignment: .leading, spacing: DesignTokens.RecorderMessage.dockGap) {
      HStack(spacing: DesignTokens.Footer.gap) {
        IconView(icon: DesignTokens.RecorderMessage.footerIcon(message))
        Text(message.headline)
          .font(DesignTokens.RecorderMessage.dockFont)
          .foregroundStyle(DesignTokens.RecorderMessage.color(message.tone))
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        ForEach(message.dockedActions, id: \.self) { action in
          Button(action.title) { actionTapped(action) }
            .buttonStyle(.plain)
            .font(DesignTokens.RecorderMessage.dockFont)
            .foregroundStyle(DesignTokens.RecorderMessage.linkColor)
        }
      }
      if let evidence = message.evidence {
        ScrollView {
          EvidenceBlockView(evidence: evidence, copyTapped: copyTapped)
        }
        .frame(maxHeight: DesignTokens.RecorderMessage.dockEvidenceMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, DesignTokens.Footer.verticalPadding)
    .padding(.horizontal, DesignTokens.Footer.horizontalPadding)
    .background(DesignTokens.RecorderMessage.dockFill)
    .overlay(alignment: .top) {
      Rectangle().fill(DesignTokens.Footer.stroke).frame(height: 1)
    }
  }
}

private struct EvidenceBlockView: View {
  let evidence: Evidence
  let copyTapped: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: DesignTokens.RecorderMessage.headlineGap) {
        Text(evidence.source)
          .font(DesignTokens.RecorderMessage.sourceFont)
          .foregroundStyle(DesignTokens.RecorderMessage.sourceColor)
          .textSelection(.enabled)
        Spacer(minLength: 0)
        Button(action: copyTapped) {
          HStack(spacing: DesignTokens.RecorderMessage.copyGap) {
            IconView(icon: DesignTokens.RecorderMessage.copyIcon)
            Text("Copy")
              .font(DesignTokens.RecorderMessage.copyFont)
              .foregroundStyle(DesignTokens.RecorderMessage.linkColor)
          }
        }
        .buttonStyle(.plain)
      }
      .padding(.vertical, DesignTokens.RecorderMessage.sourceVerticalPadding)
      .padding(.horizontal, DesignTokens.RecorderMessage.sourceHorizontalPadding)
      .overlay(alignment: .bottom) {
        Rectangle().fill(DesignTokens.RecorderMessage.blockStroke).frame(height: 1)
      }
      Text(evidence.text)
        .font(DesignTokens.RecorderMessage.bodyFont)
        .foregroundStyle(DesignTokens.RecorderMessage.bodyColor)
        .lineSpacing(DesignTokens.RecorderMessage.bodyLineSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .padding(DesignTokens.RecorderMessage.bodyPadding)
    }
    .background(DesignTokens.RecorderMessage.blockFill)
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.RecorderMessage.blockRadius))
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.RecorderMessage.blockRadius)
        .stroke(DesignTokens.RecorderMessage.blockStroke, lineWidth: 1)
    )
  }
}

private struct RecorderButtonStyle: ButtonStyle {
  let isPrimary: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(DesignTokens.RecorderMessage.buttonFont)
      .foregroundStyle(DesignTokens.RecorderMessage.buttonText)
      .padding(.vertical, DesignTokens.RecorderMessage.buttonVerticalPadding)
      .padding(.horizontal, DesignTokens.RecorderMessage.buttonHorizontalPadding)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.RecorderMessage.buttonRadius)
          .fill(isPrimary ? DesignTokens.RecorderMessage.primaryButtonFill : .clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.RecorderMessage.buttonRadius)
          .stroke(isPrimary ? .clear : DesignTokens.RecorderMessage.secondaryButtonStroke, lineWidth: 1)
      )
      .contentShape(Rectangle())
  }
}

private let previewIdentity = RuntimeIdentity(
  version: "0.3.2", build: "7f3c9a1e-5b0d-4f8e-a1c4-96d2e07b5f13", appBuild: 12)

private let previewStore = "/Users/me/.slipstream"

private let previewEvidence = Evidence(
  source: "daemon.err.log · last 4 lines",
  text: """
    node:internal/modules/cjs/loader:1228
      throw err;
      ^
    Error: Cannot find module '/Users/me/.slipstream/runtime/current/dist/daemon.js'
        at Module._resolveFilename (node:internal/modules/cjs/loader:1225:15)
        at Module._load (node:internal/modules/cjs/loader:1051:27)
        at node:internal/main/run_main_module:28:49 {
      code: 'MODULE_NOT_FOUND'
    }
    """)

private struct RecorderMessagePreview: View {
  let state: RecorderState
  var isDocked = false

  var body: some View {
    RecorderMessageView(
      message: RecorderMessage(state: state, store: previewStore, replaceIsAvailable: true)!,
      isDocked: isDocked,
      actionTapped: { _ in },
      copyTapped: {}
    )
    .padding(isDocked ? 0 : DesignTokens.Footer.horizontalPadding)
    .frame(width: DesignTokens.RecorderMessage.width + 2 * DesignTokens.Footer.horizontalPadding)
    .background(DesignTokens.FunctionTree.background)
  }
}

#Preview("Starting") {
  RecorderMessagePreview(state: .starting(previewIdentity))
}

#Preview("Restarting") {
  RecorderMessagePreview(state: .restarting(from: "0.3.1", to: previewIdentity))
}

#Preview("Update didn't finish") {
  RecorderMessagePreview(
    state: .updateDidntFinish(
      running: DaemonBuild(version: "0.3.1", build: "2d8b64c0-91ae-4c37-b5f2-0a7e3d1c8e46"),
      bundled: previewIdentity,
      .mismatch("watcher.node hash"),
      previewEvidence))
}

#Preview("Another recorder") {
  RecorderMessagePreview(
    state: .anotherRecorder(
      pid: 30117, running: DaemonBuild(version: "0.3.0", build: nil), bundled: previewIdentity, previewEvidence))
}

#Preview("Newer recorder") {
  RecorderMessagePreview(
    state: .anotherRecorder(
      pid: 8594, running: DaemonBuild(version: "0.3.3", build: nil), bundled: previewIdentity, previewEvidence))
}

#Preview("Won't start") {
  RecorderMessagePreview(state: .wontStart(previewIdentity, .exited(code: "1"), previewEvidence))
}

#Preview("Migration incomplete") {
  RecorderMessagePreview(
    state: .migrationIncomplete(
      previewIdentity, MigrationFailure(links: ["slipstream"], adoptFailed: true), previewEvidence))
}

#Preview("Won't start — docked") {
  RecorderMessagePreview(
    state: .wontStart(previewIdentity, .exited(code: "1"), previewEvidence), isDocked: true)
}

#Preview("Migration incomplete — docked") {
  RecorderMessagePreview(
    state: .migrationIncomplete(
      previewIdentity, MigrationFailure(links: ["slipstream"], adoptFailed: true), previewEvidence),
    isDocked: true)
}
