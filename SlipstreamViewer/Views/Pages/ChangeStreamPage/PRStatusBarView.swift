import SwiftUI

struct PRStatusBarView: View {
  @Bindable var model: PRStatusBarModel

  var body: some View {
    HStack(spacing: DesignTokens.PRStatusBar.gap) {
      if model.isRowContentShown {
        if let url = model.pullRequestURL, let number = model.prNumberText {
          chip(number: number, url: url)
        }
        status
        Spacer(minLength: 0)
        if let button = model.primaryButton {
          primaryButton(button)
        }
        if model.isContinueShown {
          continueButton
        }
        if model.isArchiveShown {
          archiveButton
        }
        if model.isDetailsShown {
          detailsButton
        }
      }
    }
    .padding(.horizontal, DesignTokens.PRStatusBar.horizontalPadding)
    .frame(maxWidth: .infinity)
    .frame(height: DesignTokens.PRStatusBar.height)
    .background(DesignTokens.PRStatusBar.fill(model.tone))
    .overlay(alignment: .bottom) {
      Rectangle().fill(DesignTokens.PRStatusBar.stroke).frame(height: 1)
    }
    .task(id: model.pollKey) { await model.pollTask() }
  }

  private func chip(number: String, url: URL) -> some View {
    Link(destination: url) {
      HStack(spacing: DesignTokens.PRStatusBar.Chip.gap) {
        Text(number)
          .font(DesignTokens.PRStatusBar.Chip.font)
          .foregroundStyle(DesignTokens.PRStatusBar.Chip.color(model.tone))
        IconView(icon: DesignTokens.PRStatusBar.Chip.arrow(model.tone))
      }
      .padding(.horizontal, DesignTokens.PRStatusBar.Chip.horizontalPadding)
      .frame(height: DesignTokens.PRStatusBar.Chip.height)
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.PRStatusBar.Chip.cornerRadius)
          .stroke(DesignTokens.PRStatusBar.Chip.stroke(model.tone), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Pull request \(number)")
  }

  private var status: some View {
    HStack(spacing: DesignTokens.PRStatusBar.Status.gap) {
      if let iconName = model.statusIconName {
        IconView(icon: DesignTokens.PRStatusBar.Status.icon(named: iconName, tone: model.tone))
      }
      Text(model.statusLabel)
        .font(DesignTokens.PRStatusBar.Status.labelFont)
        .foregroundStyle(DesignTokens.PRStatusBar.Status.color(model.tone))
      if let detail = model.statusDetail {
        Text(detail)
          .font(DesignTokens.PRStatusBar.Status.detailFont)
          .foregroundStyle(DesignTokens.PRStatusBar.detailColor)
      }
    }
    .lineLimit(1)
    .accessibilityElement(children: .combine)
  }

  private func primaryButton(_ button: PRBarButton) -> some View {
    PRBarActionButton(
      title: button.title, iconName: button.iconName, shortcutText: button.shortcutText,
      appearance: DesignTokens.PRStatusBar.Button.appearance(button)
    ) {
      Task { await model.primaryButtonTapped() }
    }
    .keyboardShortcut(button.shortcut)
    .disabled(!model.isPrimaryButtonEnabled)
  }

  private var continueButton: some View {
    PRBarActionButton(
      title: PRStatusBarModel.continueText, iconName: DesignTokens.PRStatusBar.Button.continueIconName,
      shortcutText: nil, appearance: DesignTokens.PRStatusBar.Button.continueAppearance
    ) {
      Task { await model.continueTapped() }
    }
  }

  private var archiveButton: some View {
    PRBarActionButton(
      title: PRStatusBarModel.archiveText, iconName: DesignTokens.PRStatusBar.Button.archiveIconName,
      shortcutText: nil, appearance: DesignTokens.PRStatusBar.Button.archiveAppearance
    ) {
      model.archiveTapped()
    }
  }

  private var detailsButton: some View {
    PRBarActionButton(
      title: PRStatusBarModel.detailsText, iconName: DesignTokens.PRStatusBar.Button.detailsIconName,
      shortcutText: nil, appearance: DesignTokens.PRStatusBar.Button.detailsAppearance
    ) {
      model.detailsTapped()
    }
    .popover(isPresented: $model.isDetailsPopoverPresented, arrowEdge: .bottom) {
      detailsPopover
    }
  }

  private var detailsPopover: some View {
    VStack(alignment: .leading, spacing: DesignTokens.PRStatusBar.Details.gap) {
      HStack(spacing: DesignTokens.PRStatusBar.Details.headerGap) {
        Text(model.failure?.title ?? "")
          .font(DesignTokens.PRStatusBar.Details.commandFont)
          .foregroundStyle(DesignTokens.PRStatusBar.Details.commandColor)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
        copyButton
      }
      ScrollView {
        Text(model.failure?.details ?? "")
          .font(DesignTokens.PRStatusBar.Details.outputFont)
          .foregroundStyle(DesignTokens.PRStatusBar.Details.outputColor)
          .lineSpacing(DesignTokens.PRStatusBar.Details.outputLineSpacing)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: DesignTokens.PRStatusBar.Details.outputMaxHeight)
    }
    .padding(DesignTokens.PRStatusBar.Details.padding)
    .frame(width: DesignTokens.PRStatusBar.Details.width)
    .background(DesignTokens.PRStatusBar.Details.fill)
  }

  private var copyButton: some View {
    Button {
      model.copyTapped()
    } label: {
      HStack(spacing: DesignTokens.PRStatusBar.Details.Copy.gap) {
        IconView(icon: DesignTokens.PRStatusBar.Details.Copy.icon)
        Text(PRStatusBarModel.copyText)
          .font(DesignTokens.PRStatusBar.Details.Copy.font)
          .foregroundStyle(DesignTokens.PRStatusBar.Details.Copy.color)
      }
      .padding(.horizontal, DesignTokens.PRStatusBar.Details.Copy.horizontalPadding)
      .frame(height: DesignTokens.PRStatusBar.Details.Copy.height)
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.PRStatusBar.Details.Copy.cornerRadius)
          .stroke(DesignTokens.PRStatusBar.Details.Copy.stroke, lineWidth: 1))
    }
    .buttonStyle(.plain)
  }
}

private struct PRBarActionButton: View {
  let title: String
  let iconName: String
  let shortcutText: String?
  let appearance: DesignTokens.PRStatusBar.Button.Appearance
  let action: () -> Void

  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(action: action) {
      HStack(spacing: DesignTokens.PRStatusBar.Button.gap) {
        IconView(icon: appearance.icon(named: iconName))
        Text(title)
          .font(DesignTokens.PRStatusBar.Button.labelFont)
          .foregroundStyle(appearance.foreground)
        if let shortcutText {
          Text(shortcutText)
            .font(DesignTokens.PRStatusBar.Button.shortcutFont)
            .foregroundStyle(appearance.shortcut)
        }
      }
      .padding(.horizontal, DesignTokens.PRStatusBar.Button.horizontalPadding)
      .frame(height: DesignTokens.PRStatusBar.Button.height)
      .background(
        appearance.fill, in: RoundedRectangle(cornerRadius: DesignTokens.PRStatusBar.Button.cornerRadius)
      )
      .overlay {
        if let stroke = appearance.stroke {
          RoundedRectangle(cornerRadius: DesignTokens.PRStatusBar.Button.cornerRadius).stroke(stroke, lineWidth: 1)
        }
      }
      .opacity(DesignTokens.PRStatusBar.Button.opacity(isEnabled: isEnabled))
      .contentShape(RoundedRectangle(cornerRadius: DesignTokens.PRStatusBar.Button.cornerRadius))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }
}
