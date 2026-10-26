import SwiftUI

struct WorkspaceSidebarView: View {
  let model: ChangeStreamPageModel

  var body: some View {
    VStack(spacing: 0) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Sidebar.listGap) {
          ForEach(model.sidebarGroups) { group in
            VStack(alignment: .leading, spacing: DesignTokens.Sidebar.groupGap) {
              groupHeader(group)
              ForEach(group.rows) { session in
                WorkspaceRowView(model: model, session: session)
              }
            }
          }
        }
        .padding(.vertical, DesignTokens.Sidebar.listVerticalPadding)
        .padding(.horizontal, DesignTokens.Sidebar.listHorizontalPadding)
      }
      footer
    }
    .background(DesignTokens.Sidebar.fill)
    .overlay(alignment: .trailing) {
      Rectangle().fill(DesignTokens.Sidebar.stroke).frame(width: 1)
    }
    .disabled(model.isWorkspaceBusy)
  }

  private var header: some View {
    HStack {
      Text(model.sidebarTitleText)
        .font(DesignTokens.Sidebar.titleFont)
        .foregroundStyle(DesignTokens.Sidebar.titleColor)
      Spacer()
    }
    .padding(.leading, DesignTokens.Sidebar.headerLeadingPadding)
    .padding(.trailing, DesignTokens.Sidebar.headerTrailingPadding)
    .frame(height: DesignTokens.Sidebar.headerHeight)
    .overlay(alignment: .bottom) {
      Rectangle().fill(DesignTokens.Sidebar.stroke).frame(height: 1)
    }
  }

  private func groupHeader(_ group: SidebarGroup) -> some View {
    HStack(spacing: DesignTokens.Sidebar.groupHeaderGap) {
      IconView(icon: DesignTokens.Sidebar.groupIcon)
      Text(group.name)
        .font(DesignTokens.Sidebar.groupNameFont)
        .foregroundStyle(DesignTokens.Sidebar.groupNameColor)
        .lineLimit(1)
      Spacer()
      if group.newWorkspaceFolder != nil {
        Button { Task { await model.newWorkspaceTapped(in: group) } } label: {
          IconView(icon: DesignTokens.Sidebar.newWorkspaceIcon)
            .padding(DesignTokens.Sidebar.iconButtonPadding)
        }
        .buttonStyle(.plain)
        .help(model.newWorkspaceHelpText)
      }
    }
    .padding(.leading, DesignTokens.Sidebar.groupHeaderLeadingPadding)
    .padding(.trailing, DesignTokens.Sidebar.groupHeaderTrailingPadding)
    .frame(height: DesignTokens.Sidebar.groupHeaderHeight)
  }

  private var footer: some View {
    Button { Task { await model.newWorkspaceTapped() } } label: {
      HStack(spacing: DesignTokens.Sidebar.footerGap) {
        IconView(icon: DesignTokens.Sidebar.footerIcon)
        Text(model.addRepositoryText)
          .font(DesignTokens.Sidebar.footerFont)
          .foregroundStyle(DesignTokens.Sidebar.footerColor)
        Spacer()
      }
      .padding(.horizontal, DesignTokens.Sidebar.footerHorizontalPadding)
      .frame(height: DesignTokens.Sidebar.footerHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .top) {
      Rectangle().fill(DesignTokens.Sidebar.stroke).frame(height: 1)
    }
  }
}

private struct WorkspaceRowView: View {
  let model: ChangeStreamPageModel
  let session: SessionOption
  @FocusState private var isFocused: Bool

  var body: some View {
    let isSelected = model.isSelected(session)
    let isBold = model.isBold(session)
    HStack(spacing: DesignTokens.Sidebar.rowGap) {
      Button { model.sessionSelected(session.id) } label: {
        HStack(spacing: DesignTokens.Sidebar.rowGap) {
          IconView(icon: DesignTokens.Sidebar.rowIcon(isSelected: isSelected))
          Text(model.rowName(session))
            .font(DesignTokens.Sidebar.rowNameFont(isBold: isBold))
            .foregroundStyle(DesignTokens.Sidebar.rowNameColor(isBold: isBold, isSelected: isSelected))
            .lineLimit(1)
          Spacer()
          if model.isWorking(session) {
            SpinnerView(spinner: DesignTokens.Sidebar.spinner)
          }
        }
        .padding(.leading, DesignTokens.Sidebar.rowLeadingPadding)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focused($isFocused)
      .accessibilityActions {
        if model.isArchivable(session) {
          Button(model.archiveWorkspaceHelpText) { model.archiveTapped(session) }
        }
      }
      if model.isArchiveIconShown(for: session) {
        Button { model.archiveTapped(session) } label: {
          IconView(icon: DesignTokens.Sidebar.archiveIcon)
            .padding(DesignTokens.Sidebar.iconButtonPadding)
        }
        .buttonStyle(.plain)
        .help(model.archiveWorkspaceHelpText)
      }
    }
    .padding(.trailing, DesignTokens.Sidebar.rowTrailingPadding)
    .frame(height: DesignTokens.Sidebar.rowHeight)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: DesignTokens.Sidebar.rowRadius).fill(DesignTokens.Sidebar.selectedRowFill)
      } else if model.isHighlighted(session) {
        RoundedRectangle(cornerRadius: DesignTokens.Sidebar.rowRadius).fill(DesignTokens.Sidebar.highlightedRowFill)
      }
    }
    .onHover { model.rowHoverChanged(session, isHovering: $0) }
    .onChange(of: isFocused) { model.rowFocusChanged(session, isFocused: isFocused) }
  }
}
