import SwiftUI

struct TerminalPageView: View {
  let model: TerminalPageModel

  var body: some View {
    VStack(spacing: 0) {
      tabStrip
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DesignTokens.TerminalPane.background)
  }

  private var tabStrip: some View {
    HStack(alignment: .bottom, spacing: DesignTokens.TerminalPane.TabStrip.gap) {
      ScrollView(.horizontal) {
        HStack(alignment: .bottom, spacing: DesignTokens.TerminalPane.TabStrip.gap) {
          ForEach(model.shownTabs) { tab in
            TerminalTabView(tab: tab, isSelected: model.isSelected(tab), isHovered: model.isHovered(tab),
              showsClose: model.showsCloseButton(tab), statusIcon: tab.statusIcon,
              selected: { model.tabSelected(tab.id) },
              closed: { Task { await model.closeTabTapped(tab.id) } },
              hovered: { model.tabHovered(tab.id, isHovering: $0) })
          }
          if model.showsNewTabButton {
            Button { Task { await model.newTabTapped() } } label: {
              IconView(icon: DesignTokens.TerminalPane.NewTab.plus)
                .padding(.horizontal, DesignTokens.TerminalPane.NewTab.horizontalPadding)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.newTabAccessibilityLabel)
          }
        }
      }
      .scrollIndicators(.hidden)
    }
    .padding(.leading, DesignTokens.TerminalPane.TabStrip.leadingPadding)
    .padding(.trailing, DesignTokens.TerminalPane.TabStrip.trailingPadding)
    .frame(height: DesignTokens.TerminalPane.TabStrip.height)
    .overlay(alignment: .bottom) {
      Rectangle().fill(DesignTokens.TerminalPane.stroke).frame(height: 1)
    }
  }

  @ViewBuilder
  private var content: some View {
    if model.isEmptyStateVisible {
      messageColumn {
        Text(model.emptyTitle)
          .font(DesignTokens.TerminalPane.Message.titleFont)
          .foregroundStyle(DesignTokens.TerminalPane.Message.titleColor)
        Text(model.emptyText)
          .font(DesignTokens.TerminalPane.Message.detailFont)
          .foregroundStyle(DesignTokens.TerminalPane.Message.detailColor)
      }
    } else if let tab = model.selectedTab {
      if let path = tab.missingFolderPath {
        messageColumn {
          IconView(icon: DesignTokens.TerminalPane.Message.folderMissing)
          Text(tab.folderMissingText)
            .font(DesignTokens.TerminalPane.Message.titleFont)
            .foregroundStyle(DesignTokens.TerminalPane.Message.titleColor)
          Text(path)
            .font(DesignTokens.TerminalPane.Message.pathFont)
            .foregroundStyle(DesignTokens.TerminalPane.Message.pathColor)
          Text(tab.noShellText)
            .font(DesignTokens.TerminalPane.Message.detailFont)
            .foregroundStyle(DesignTokens.TerminalPane.Message.detailColor)
        }
      } else {
        VStack(spacing: 0) {
          TerminalHostView(surface: tab.surface)
            .padding(.vertical, DesignTokens.TerminalPane.shellVerticalPadding)
            .padding(.horizontal, DesignTokens.TerminalPane.shellHorizontalPadding)
          if tab.isCloseConfirmationVisible {
            closeBox(tab)
          }
          if let footerText = tab.footerText {
            setupFooter(footerText, icon: tab.statusIcon)
          }
        }
      }
    } else {
      Spacer()
    }
  }

  private func messageColumn<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: DesignTokens.TerminalPane.Message.gap, content: content)
      .padding(DesignTokens.TerminalPane.Message.padding)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func setupFooter(_ text: String, icon: TerminalTabStatusIcon?) -> some View {
    HStack(spacing: DesignTokens.TerminalPane.Footer.gap) {
      switch icon {
      case .running: SpinnerView(spinner: DesignTokens.TerminalPane.Footer.spinner)
      case .finished: IconView(icon: DesignTokens.TerminalPane.Footer.finished)
      case .failed: IconView(icon: DesignTokens.TerminalPane.Footer.failed)
      case nil: EmptyView()
      }
      Text(text)
        .font(DesignTokens.TerminalPane.Footer.font)
        .foregroundStyle(DesignTokens.TerminalPane.Footer.textColor(for: icon))
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, DesignTokens.TerminalPane.Footer.horizontalPadding)
    .frame(height: DesignTokens.TerminalPane.Footer.height)
    .overlay(alignment: .top) {
      Rectangle().fill(DesignTokens.TerminalPane.stroke).frame(height: 1)
    }
  }

  private func closeBox(_ tab: TerminalTabModel) -> some View {
    HStack(spacing: DesignTokens.TerminalPane.CloseBox.gap) {
      IconView(icon: DesignTokens.TerminalPane.CloseBox.icon)
      VStack(alignment: .leading, spacing: DesignTokens.TerminalPane.CloseBox.textGap) {
        Text(tab.stillRunningText)
          .font(DesignTokens.TerminalPane.CloseBox.titleFont)
          .foregroundStyle(DesignTokens.TerminalPane.CloseBox.titleColor)
        Text(tab.closeConfirmationText)
          .font(DesignTokens.TerminalPane.CloseBox.detailFont)
          .foregroundStyle(DesignTokens.TerminalPane.CloseBox.detailColor)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button { tab.keepTapped() } label: {
        Text(tab.keepText)
          .font(DesignTokens.TerminalPane.CloseBox.buttonFont)
          .foregroundStyle(DesignTokens.TerminalPane.CloseBox.keepColor)
          .padding(.vertical, DesignTokens.TerminalPane.CloseBox.buttonVerticalPadding)
          .padding(.horizontal, DesignTokens.TerminalPane.CloseBox.buttonHorizontalPadding)
          .background(DesignTokens.TerminalPane.CloseBox.keepFill,
            in: RoundedRectangle(cornerRadius: DesignTokens.TerminalPane.CloseBox.buttonRadius))
      }
      .buttonStyle(.plain)
      Button { Task { await model.closeConfirmed(tab.id) } } label: {
        Text(tab.closeText)
          .font(DesignTokens.TerminalPane.CloseBox.buttonFont)
          .foregroundStyle(DesignTokens.TerminalPane.CloseBox.closeColor)
          .padding(.vertical, DesignTokens.TerminalPane.CloseBox.buttonVerticalPadding)
          .padding(.horizontal, DesignTokens.TerminalPane.CloseBox.buttonHorizontalPadding)
          .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.TerminalPane.CloseBox.buttonRadius)
              .strokeBorder(DesignTokens.TerminalPane.CloseBox.closeStroke)
          }
      }
      .buttonStyle(.plain)
    }
    .padding(.vertical, DesignTokens.TerminalPane.CloseBox.verticalPadding)
    .padding(.horizontal, DesignTokens.TerminalPane.CloseBox.horizontalPadding)
    .background(DesignTokens.TerminalPane.CloseBox.fill,
      in: RoundedRectangle(cornerRadius: DesignTokens.TerminalPane.CloseBox.radius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.TerminalPane.CloseBox.radius)
        .strokeBorder(DesignTokens.TerminalPane.CloseBox.stroke)
    }
    .padding(DesignTokens.TerminalPane.CloseBox.areaPadding)
  }
}

private struct TerminalTabView: View {
  let tab: TerminalTabModel
  let isSelected: Bool
  let isHovered: Bool
  let showsClose: Bool
  let statusIcon: TerminalTabStatusIcon?
  let selected: () -> Void
  let closed: () -> Void
  let hovered: (Bool) -> Void

  var body: some View {
    HStack(spacing: DesignTokens.TerminalPane.Tab.gap) {
      Button(action: selected) {
        HStack(spacing: DesignTokens.TerminalPane.Tab.gap) {
          switch statusIcon {
          case .running: SpinnerView(spinner: DesignTokens.TerminalPane.StatusIcon.spinner)
          case .finished: IconView(icon: DesignTokens.TerminalPane.StatusIcon.finished)
          case .failed: IconView(icon: DesignTokens.TerminalPane.StatusIcon.failed)
          case nil: EmptyView()
          }
          Text(tab.title)
            .font(DesignTokens.TerminalPane.Tab.titleFont)
            .foregroundStyle(DesignTokens.TerminalPane.Tab.titleColor(isSelected: isSelected))
            .lineLimit(1)
        }
        .padding(.horizontal, DesignTokens.TerminalPane.Tab.horizontalPadding)
        .frame(maxHeight: .infinity)
        .background(DesignTokens.TerminalPane.Tab.fill(isHovered: isHovered),
          in: UnevenRoundedRectangle(topLeadingRadius: DesignTokens.TerminalPane.Tab.hoverRadius,
            topTrailingRadius: DesignTokens.TerminalPane.Tab.hoverRadius))
        .overlay(alignment: .bottom) {
          Rectangle().fill(DesignTokens.TerminalPane.Tab.underline(isSelected: isSelected))
            .frame(height: DesignTokens.TerminalPane.Tab.underlineWidth)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if showsClose {
        Button(action: closed) { IconView(icon: DesignTokens.TerminalPane.Tab.close) }
          .buttonStyle(.plain)
          .accessibilityLabel(tab.closeAccessibilityLabel)
      }
    }
    .frame(maxHeight: .infinity)
    .onHover(perform: hovered)
  }
}
