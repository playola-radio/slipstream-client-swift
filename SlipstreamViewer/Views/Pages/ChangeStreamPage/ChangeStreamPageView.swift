import SlipstreamCore
import SwiftUI

struct ChangeStreamPageView: View {
  @State var model: ChangeStreamPageModel
  @State private var functionChangesDemo: FunctionChangesFixtureModel?

  private let bottomID = "feed-bottom"

  init(
    chat: ChatPageModel, instantAsk: InstantAskModel, terminals: TerminalPageModel,
    functionChangesDemo: FunctionChangesFixtureModel? = nil
  ) {
    _model = State(initialValue: ChangeStreamPageModel(
      chat: chat, instantAsk: instantAsk, terminals: terminals, isFunctionDemoVisible: functionChangesDemo != nil))
    _functionChangesDemo = State(initialValue: functionChangesDemo)
  }

  var body: some View {
    HStack(spacing: 0) {
      if model.isSidebarShown {
        WorkspaceSidebarView(model: model)
          .frame(width: model.sidebarColumnWidth)
          .transition(.move(edge: .leading))
        resizeHandle(dragged: model.sidebarEdgeDragged, doubleClicked: model.sidebarEdgeDoubleClicked)
      }
      detailPane
        .frame(width: model.detailPaneWidth)
        .frame(maxWidth: model.detailPaneMaxWidth)
      if model.isRightPaneShown {
        resizeHandle(dragged: model.chatEdgeDragged, doubleClicked: model.chatEdgeDoubleClicked)
        rightPane
          .frame(minWidth: DesignTokens.FeedPane.width, maxWidth: .infinity)
          .transition(.move(edge: .trailing))
      }
    }
    .clipped()
    .frame(
      minWidth: model.windowMinWidth(visibleScreenWidth: NSScreen.main?.visibleFrame.width ?? .infinity),
      minHeight: functionChangesDemo == nil ? 480 : DesignTokens.FunctionMap.demoWorkspaceMinHeight)
    .coordinateSpace(name: "question-workspace")
    .onGeometryChange(for: CGSize.self) { $0.size } action: { model.viewportChanged($0) }
    .overlay(alignment: .topLeading) {
      ZStack(alignment: .topLeading) { questionOverlay }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .alert(model.questionDismissTitle, isPresented: $model.isQuestionDismissConfirmationPresented) {
      Button(model.questionDiscardText, role: .destructive) { model.questionDismissed() }
      Button(model.questionKeepText, role: .cancel) {}
    } message: {
      Text(model.questionDismissMessage)
    }
    .alert(model.archiveConfirmationTitle, isPresented: $model.isArchiveConfirmationPresented) {
      Button(model.archiveConfirmText, role: .destructive) { Task { await model.archiveConfirmed() } }
      Button(model.cancelText, role: .cancel) {}
    } message: {
      Text(model.archiveConfirmationText)
    }
    .alert(model.openIn.failureTitle, isPresented: Bindable(model.openIn).isFailurePresented) {
      Button(model.openIn.failureDismissText, role: .cancel) {}
    } message: {
      Text(model.openIn.failureText)
    }
    .alert(model.workspaceFailureTitle, isPresented: $model.isWorkspaceFailurePresented) {
      if model.isWorkspaceFailureCopyShown {
        Button(model.workspaceFailureCopyText) { model.copyWorkspaceFailureTapped() }
      }
      Button(model.workspaceFailureDismissText, role: .cancel) {}
    } message: {
      Text(model.workspaceFailureText)
    }
    .sheet(isPresented: Bindable(model.naming).isDialogPresented) {
      RenameWorkspaceSheetView(model: model.naming)
    }
    .preferredColorScheme(.dark)
    .toolbar { toolbar }
    .toolbar(removing: .title)
    .toolbarBackground(DesignTokens.WindowHeader.fill, for: .windowToolbar)
    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    .focusedSceneValue(model)
    .task { await model.viewAppeared() }
    .task { model.openIn.viewAppeared() }
    .task(id: model.chat.selectedTab?.id) { await model.chat.viewAppeared() }
    .task { await model.chat.clockTask() }
    .task(id: model.isSessionPollRunning) { if model.isSessionPollRunning { await model.sessionPollTask() } }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await model.appBecameActive() }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
      model.chat.appActivityChanged(isActive: false)
    }
    .onDisappear { model.viewDisappeared() }
    .background {
      Button { Task { await model.closeShortcutPressed() } } label: { EmptyView() }
        .keyboardShortcut("w")
        .opacity(0)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var questionOverlay: some View {
    if let reply = model.reply {
      if model.showsReplyConnector {
        Path { path in
          path.move(to: model.replyPlacement.barAnchor)
          path.addLine(to: model.replyPlacement.popoverAnchor)
        }
        .stroke(DesignTokens.Reply.connectorColor, lineWidth: DesignTokens.Reply.connectorWidth)
        .allowsHitTesting(false)
        Circle().fill(DesignTokens.Reply.connectorColor)
          .frame(width: DesignTokens.Reply.connectorDot, height: DesignTokens.Reply.connectorDot)
          .position(model.replyPlacement.barAnchor)
          .allowsHitTesting(false)
      }
      ScrollView {
        QuestionThreadPageView(model: reply, dismiss: { model.replyDismissTapped() })
          .id(reply)
          .frame(width: model.replyWidth)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGSize.self) { $0.size } action: { model.replyMeasured($0) }
      }
      .scrollIndicators(.hidden)
      .frame(width: model.replyPlacement.popover.width, height: model.replyPlacement.popover.height)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Reply.radius))
      .shadow(color: DesignTokens.Reply.shadow, radius: DesignTokens.Reply.shadowBlur, y: DesignTokens.Reply.shadowY)
      .offset(x: model.replyPlacement.popover.minX, y: model.replyPlacement.popover.minY)
    }
    if let composer = model.askAgent {
      if model.showsSelectionConnector {
        Path { path in
          path.move(to: model.questionPlacement.selectionAnchor)
          path.addLine(to: model.questionPlacement.modalAnchor)
        }
        .stroke(DesignTokens.Ask.contextColor, lineWidth: DesignTokens.Ask.connectorWidth)
        .allowsHitTesting(false)
        Circle().fill(DesignTokens.Ask.contextColor)
          .frame(width: DesignTokens.Ask.connectorDot, height: DesignTokens.Ask.connectorDot)
          .position(model.questionPlacement.selectionAnchor)
          .allowsHitTesting(false)
      }
      ScrollView {
        AskAgentPageView(model: composer, dismiss: { model.questionDismissTapped() },
          submit: { Task { await model.askQuestionTapped(composer) } })
          .id(composer)
          .frame(width: model.composerWidth)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGSize.self) { $0.size } action: { model.composerMeasured($0) }
      }
      .scrollIndicators(.hidden)
      .frame(width: model.questionPlacement.modal.width, height: model.questionPlacement.modal.height)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Ask.radius))
      .shadow(color: DesignTokens.Ask.shadow, radius: DesignTokens.Ask.shadowBlur,
        y: DesignTokens.Ask.shadowY)
      .offset(x: model.questionPlacement.modal.minX, y: model.questionPlacement.modal.minY)
    }
  }

  /// Straddles the edge between two columns: zero width in the row, with a wider grab area.
  private func resizeHandle(
    dragged: @escaping (CGFloat) -> Void, doubleClicked: @escaping () -> Void
  ) -> some View {
    Color.clear
      .frame(width: 0)
      .overlay {
        Color.clear
          .frame(width: DesignTokens.Workspace.resizeHandleWidth)
          .contentShape(Rectangle())
          .pointerStyle(.columnResize)
          .onTapGesture(count: 2, perform: doubleClicked)
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
              .onChanged { dragged($0.translation.width) }
              .onEnded { _ in model.edgeDragEnded() })
      }
      .zIndex(1)
  }

  private var rightPane: some View {
    VStack(spacing: 0) {
      rightPaneStrip
      if model.isStreamShown {
        feedPane
      } else {
        TerminalPageView(model: model.terminals)
      }
    }
    .background(DesignTokens.FeedPane.fill)
    .overlay(alignment: .leading) {
      Rectangle().fill(DesignTokens.FeedPane.stroke).frame(width: 1)
    }
  }

  private var rightPaneStrip: some View {
    HStack(alignment: .bottom, spacing: DesignTokens.RightPane.Strip.gap) {
      ForEach(ChangeStreamPageModel.RightPane.allCases, id: \.self) { pane in
        let isSelected = model.isSelected(pane)
        Button { model.rightPaneSelected(pane) } label: {
          HStack(spacing: DesignTokens.RightPane.Tab.gap) {
            IconView(icon: DesignTokens.RightPane.Tab.icon(pane, isSelected: isSelected))
            Text(model.rightPaneText(pane))
              .font(DesignTokens.RightPane.Tab.font(isSelected: isSelected))
              .foregroundStyle(DesignTokens.RightPane.Tab.color(isSelected: isSelected))
            if let note = model.rightPaneNote(pane) {
              Text(note)
                .font(DesignTokens.Fonts.paneSubtitle(isQuestionSummary: model.isQuestionSummaryShown))
                .foregroundStyle(DesignTokens.Colors.paneSubtitle(isQuestionSummary: model.isQuestionSummaryShown))
                .lineLimit(1)
                .truncationMode(.tail)
            }
          }
          .padding(.horizontal, DesignTokens.RightPane.Tab.horizontalPadding)
          .frame(maxHeight: .infinity)
          .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.RightPane.Tab.underline(isSelected: isSelected))
              .frame(height: DesignTokens.RightPane.Tab.underlineWidth)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      Spacer(minLength: 0)
      compareFunctionsButton
    }
    .padding(.leading, DesignTokens.RightPane.Strip.leadingPadding)
    .padding(.trailing, DesignTokens.RightPane.Strip.trailingPadding)
    .frame(height: DesignTokens.RightPane.Strip.height)
    .overlay(alignment: .bottom) {
      Rectangle().fill(DesignTokens.RightPane.Strip.stroke).frame(height: 1)
    }
  }

  private var compareFunctionsButton: some View {
    Button { model.compareFunctionsTapped() } label: {
      HStack(spacing: DesignTokens.WindowHeader.Compare.gap) {
        IconView(icon: DesignTokens.WindowHeader.Compare.icon(isEnabled: model.canCompareFunctions))
        Text(model.compareFunctionsText)
          .font(DesignTokens.WindowHeader.Compare.font)
          .foregroundStyle(DesignTokens.WindowHeader.Compare.color(isEnabled: model.canCompareFunctions))
      }
      .padding(.horizontal, DesignTokens.WindowHeader.Compare.horizontalPadding)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!model.canCompareFunctions)
    .help(model.compareFunctionsHelpText)
    .fixedSize(horizontal: true, vertical: false)
    .layoutPriority(1)
  }

  private var feedPane: some View {
    VStack(spacing: 0) {
      if model.isCaptureStripShown {
        captureStrip
      }
      if let emptyStateText = model.emptyStateText {
        Text(emptyStateText)
          .font(DesignTokens.Fonts.liveStatus)
          .foregroundStyle(DesignTokens.Colors.paneSubtitle)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        feed
      }
      if model.isFooterShown {
        footer
      }
    }
  }

  @ViewBuilder
  private var detailPane: some View {
    if let functionChangesDemo {
      fileViewer {
        FunctionChangesFixtureView(model: functionChangesDemo)
      }
    } else if let functionChanges = model.functionChanges {
      fileViewer {
        FunctionChangesLiveView(model: functionChanges, close: { model.functionChangesClosed() })
          .id(functionChanges)
      }
    } else {
      ChatPageView(model: model.chat)
    }
  }

  private func fileViewer(@ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.FileViewer.gap) {
      Color.clear.frame(height: DesignTokens.FileViewer.toolbarHeight)
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(DesignTokens.FileViewer.padding)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DesignTokens.FileViewer.fill)
  }

  private var captureStrip: some View {
    VStack(alignment: .leading, spacing: DesignTokens.CaptureStrip.gap) {
      captureStripRow(label: model.captureStripLabel, dot: model.captureDotColor, text: model.captureText) {
        if let checked = model.captureCheckedText {
          Text(checked)
            .font(DesignTokens.CaptureStrip.checkedFont)
            .foregroundStyle(DesignTokens.CaptureStrip.checkedColor)
        }
      }
      if let detail = model.captureDetailText {
        Text(detail)
          .font(DesignTokens.CaptureStrip.detailFont)
          .foregroundStyle(DesignTokens.CaptureStrip.detailColor)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, DesignTokens.CaptureStrip.detailInset)
      }
      captureStripRow(label: model.chatStripLabel, dot: model.chatDotColor, text: model.chatLinkText) {}
    }
    .padding(.vertical, DesignTokens.CaptureStrip.verticalPadding)
    .padding(.horizontal, DesignTokens.CaptureStrip.horizontalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DesignTokens.CaptureStrip.fill)
    .overlay(alignment: .top) {
      Rectangle().fill(DesignTokens.CaptureStrip.stroke).frame(height: 1)
    }
    .overlay(alignment: .bottom) {
      Rectangle().fill(DesignTokens.CaptureStrip.stroke).frame(height: 1)
    }
  }

  private func captureStripRow(
    label: String, dot: Color, text: String?, @ViewBuilder trailing: () -> some View
  ) -> some View {
    HStack(spacing: DesignTokens.CaptureStrip.rowGap) {
      Circle().fill(dot).frame(width: DesignTokens.CaptureStrip.dotSize, height: DesignTokens.CaptureStrip.dotSize)
      Text(label)
        .font(DesignTokens.CaptureStrip.labelFont)
        .foregroundStyle(DesignTokens.CaptureStrip.labelColor)
        .frame(width: DesignTokens.CaptureStrip.labelWidth, alignment: .leading)
      Text(text ?? "")
        .font(DesignTokens.CaptureStrip.textFont)
        .foregroundStyle(DesignTokens.CaptureStrip.textColor)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      trailing()
    }
  }

  private var feed: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
          ForEach(model.sections) { section in
            Section {
              ForEach(section.items) { item in
                itemView(item, in: section)
                  .padding(.top, DesignTokens.Stream.itemGap)
              }
              Color.clear.frame(height: DesignTokens.Stream.groupGap)
            } header: {
              if let heading = section.heading {
                TaskHeadingView(heading: heading, isPinned: model.isHeadingPinned(section))
                  .onGeometryChange(for: Double.self) { geometry in
                    geometry.frame(in: .scrollView).minY
                  } action: { minY in
                    model.headingMoved(section, minY: minY)
                  }
                  .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    model.taskHeadingMeasured(height: $0)
                  }
              }
            }
          }
          Color.clear.frame(height: 1).id(bottomID)
        }
      }
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("question-workspace")) } action: {
        model.feedViewportChanged($0)
      }
      .onScrollPhaseChange { _, phase in model.scrollPhaseChanged(phase) }
      .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
        ScrollMetrics(contentHeight: geometry.contentSize.height, visibleMaxY: geometry.visibleRect.maxY)
      } action: { _, metrics in
        model.scrollGeometryChanged(contentHeight: metrics.contentHeight, visibleMaxY: metrics.visibleMaxY)
      }
      .onChange(of: model.scrollToLatestRequest) {
        proxy.scrollTo(bottomID, anchor: .bottom)
      }
      .onAppear {
        proxy.scrollTo(bottomID, anchor: .bottom)
      }
    }
  }

  @ViewBuilder
  private func itemView(_ item: FeedItem, in section: FeedSection) -> some View {
    switch item {
    case .file(let row):
      VStack(spacing: 0) {
        FileCardView(
          row: row,
          model: model,
          openIndicatorText: model.openIndicatorText(for: row),
          headerOffset: model.fileHeaderOffset(for: row),
          content: model.content(for: row),
          emphasis: model.emphasis(for: row),
          isRetryable: model.isCardRetryable(row),
          retryTapped: { Task { await model.cardRetryTapped(row) } }
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: {
          model.cardMoved(row, in: section, frame: $0)
        }
        .task(id: FeedCardTaskID(feedGeneration: model.feedGeneration, rowID: row.id)) { await model.cardAppeared(row) }
        .onDisappear { model.cardDisappeared(row) }
        ForEach(model.questionBars(for: row)) { bar in
          QuestionBarView(bar: bar) { model.questionBarTapped(bar) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("question-workspace")) } action: {
              model.questionBarMoved(bar, frame: $0)
            }
            .onDisappear { model.questionBarDisappeared(bar) }
            .padding(.horizontal, DesignTokens.Card.horizontalInset)
        }
      }
    case .marker(let marker):
      Text(marker.text)
        .font(DesignTokens.Fonts.eventTime)
        .foregroundStyle(DesignTokens.Colors.eventTime)
        .lineLimit(1)
        .padding(.horizontal, DesignTokens.Card.horizontalInset)
    }
  }

  private var footer: some View {
    HStack(spacing: DesignTokens.Footer.gap) {
      IconView(icon: DesignTokens.Icons.activity)
      Text(model.footerText)
        .font(DesignTokens.Fonts.liveStatus)
        .foregroundStyle(model.footerColor)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      if model.isRetryVisible {
        Button(model.retryButtonText) { model.retryTapped() }
          .buttonStyle(.plain)
          .font(DesignTokens.Fonts.jumpToLatest)
          .foregroundStyle(DesignTokens.Colors.jumpToLatest)
      }
      Spacer()
      Button(model.jumpToLatestText) { model.jumpToLatestTapped() }
        .buttonStyle(.plain)
        .font(DesignTokens.Fonts.jumpToLatest)
        .foregroundStyle(DesignTokens.Colors.jumpToLatest)
    }
    .padding(.vertical, DesignTokens.Footer.verticalPadding)
    .padding(.horizontal, DesignTokens.Footer.horizontalPadding)
    .overlay(alignment: .top) {
      Rectangle().fill(DesignTokens.Footer.stroke).frame(height: 1)
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      Button(model.sidebarToggleHelpText, systemImage: "sidebar.left") {
        withAnimation(DesignTokens.Workspace.paneToggleAnimation) { model.sidebarToggleTapped() }
      }
        .labelStyle(.iconOnly)
        .font(.system(size: DesignTokens.WindowHeader.toggleSize))
        .foregroundStyle(DesignTokens.WindowHeader.toggleColor)
        .help(model.sidebarToggleHelpText)
    }
    .withoutGlass()
    ToolbarItem(placement: .navigation) { breadcrumb }
      .withoutGlass()
    if model.isWorkspaceBusy {
      ToolbarItem(placement: .navigation) {
        ProgressView().controlSize(.small)
      }
      .withoutGlass()
    }
    if #available(macOS 26, *) {
      ToolbarSpacer(.flexible)
    }
    if model.isOpenInShown {
      ToolbarItem {
        OpenInButton(model: model.openIn)
      }
      .withoutGlass()
    }
    ToolbarItem {
      Button(model.rightPaneToggleHelpText, systemImage: "sidebar.right") {
        withAnimation(DesignTokens.Workspace.paneToggleAnimation) { model.rightPaneToggleTapped() }
      }
      .labelStyle(.iconOnly)
      .font(.system(size: DesignTokens.WindowHeader.toggleSize))
      .foregroundStyle(DesignTokens.WindowHeader.toggleColor)
      .help(model.rightPaneToggleHelpText)
    }
    .withoutGlass()
  }

  private var breadcrumb: some View {
    HStack(spacing: DesignTokens.WindowHeader.Breadcrumb.gap) {
      if let repository = model.breadcrumbRepositoryText {
        IconView(icon: DesignTokens.WindowHeader.Breadcrumb.repositoryIcon)
        Text(repository)
          .font(DesignTokens.WindowHeader.Breadcrumb.repositoryFont)
          .foregroundStyle(DesignTokens.WindowHeader.Breadcrumb.repositoryColor)
        IconView(icon: DesignTokens.WindowHeader.Breadcrumb.chevron)
      }
      if let workspace = model.breadcrumbWorkspaceText {
        IconView(icon: DesignTokens.WindowHeader.Breadcrumb.workspaceIcon)
        Text(workspace)
          .font(DesignTokens.WindowHeader.Breadcrumb.workspaceFont)
          .foregroundStyle(DesignTokens.WindowHeader.Breadcrumb.workspaceColor)
      }
    }
    .lineLimit(1)
    .accessibilityElement(children: .combine)
  }
}

private extension ToolbarContent {
  @ToolbarContentBuilder
  func withoutGlass() -> some ToolbarContent {
    if #available(macOS 26, *) {
      sharedBackgroundVisibility(.hidden)
    } else {
      self
    }
  }
}

private struct OpenInButton: View {
  let model: OpenInModel

  var body: some View {
    Menu {
      ForEach(model.apps) { app in
        Button { Task { await model.appSelected(app.id) } } label: {
          Label { Text(app.name) } icon: { Image(nsImage: model.icon(for: app)) }
        }
      }
    } label: {
      HStack(spacing: 0) {
        if let app = model.selectedApp {
          Image(nsImage: model.icon(for: app))
            .padding(.horizontal, DesignTokens.WindowHeader.OpenIn.appIconPadding)
        }
        Rectangle().fill(DesignTokens.WindowHeader.OpenIn.stroke).frame(width: 1)
        IconView(icon: DesignTokens.WindowHeader.OpenIn.chevron)
          .padding(.horizontal, DesignTokens.WindowHeader.OpenIn.chevronPadding)
      }
      .frame(height: DesignTokens.WindowHeader.OpenIn.height)
      .overlay {
        RoundedRectangle(cornerRadius: DesignTokens.WindowHeader.OpenIn.radius)
          .strokeBorder(DesignTokens.WindowHeader.OpenIn.stroke)
      }
      .contentShape(Rectangle())
    } primaryAction: {
      Task { await model.openTapped() }
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(model.openHelpText)
    .accessibilityLabel(model.openHelpText)
    .disabled(model.isOpenDisabled)
  }
}

private struct ScrollMetrics: Equatable {
  var contentHeight: Double
  var visibleMaxY: Double
}

struct IconView: View {
  let icon: DesignTokens.Icons.Icon

  var body: some View {
    Image(icon.assetName)
      .resizable()
      .frame(width: icon.size, height: icon.size)
      .foregroundStyle(icon.color)
  }
}

private struct QuestionBarView: View {
  let bar: QuestionBar
  let tapped: () -> Void

  var body: some View {
    Button(action: tapped) {
      HStack(spacing: DesignTokens.ReplyBar.gap) {
        Image("MessageCircle").resizable()
          .frame(width: DesignTokens.ReplyBar.iconSize, height: DesignTokens.ReplyBar.iconSize)
          .foregroundStyle(DesignTokens.ReplyBar.accent(bar.status))
        Text(bar.preview)
          .font(DesignTokens.ReplyBar.previewFont)
          .foregroundStyle(DesignTokens.ReplyBar.previewColor)
          .lineLimit(1)
        Spacer(minLength: 0)
        Text(bar.statusText)
          .font(DesignTokens.ReplyBar.statusFont)
          .foregroundStyle(DesignTokens.ReplyBar.accent(bar.status))
        Image(DesignTokens.ReplyBar.chevron(isOpen: bar.isOpen)).resizable()
          .frame(width: DesignTokens.ReplyBar.chevronSize, height: DesignTokens.ReplyBar.chevronSize)
          .foregroundStyle(DesignTokens.ReplyBar.chevronColor)
      }
      .padding(.horizontal, DesignTokens.ReplyBar.horizontalPadding)
      .frame(height: DesignTokens.ReplyBar.height)
      .background(DesignTokens.ReplyBar.fill(isOpen: bar.isOpen),
        in: RoundedRectangle(cornerRadius: DesignTokens.ReplyBar.radius))
      .overlay {
        RoundedRectangle(cornerRadius: DesignTokens.ReplyBar.radius)
          .strokeBorder(DesignTokens.ReplyBar.stroke(isOpen: bar.isOpen), lineWidth: DesignTokens.ReplyBar.strokeWidth)
      }
      .overlay(alignment: .leading) {
        UnevenRoundedRectangle(topLeadingRadius: DesignTokens.ReplyBar.radius,
          bottomLeadingRadius: DesignTokens.ReplyBar.radius)
          .fill(DesignTokens.ReplyBar.stroke(isOpen: bar.isOpen))
          .frame(width: DesignTokens.ReplyBar.leadingStrokeWidth)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(bar.statusText)
  }
}

private struct TaskHeadingView: View {
  let heading: TaskHeading
  let isPinned: Bool

  var body: some View {
    HStack(spacing: DesignTokens.TaskHeading.gap) {
      Text(heading.number)
        .font(DesignTokens.Fonts.taskBadge)
        .foregroundStyle(DesignTokens.Colors.taskBadge)
        .padding(.vertical, DesignTokens.Badge.verticalPadding)
        .padding(.horizontal, DesignTokens.Badge.horizontalPadding)
        .background(DesignTokens.Badge.fill, in: RoundedRectangle(cornerRadius: DesignTokens.Badge.radius))
      Text(heading.title)
        .font(DesignTokens.Fonts.taskTitle)
        .foregroundStyle(DesignTokens.Colors.taskTitle)
        .lineLimit(1)
      Spacer()
      IconView(icon: DesignTokens.Icons.pin(isPinned: isPinned))
    }
    .padding(.vertical, DesignTokens.TaskHeading.verticalPadding)
    .padding(.horizontal, DesignTokens.TaskHeading.horizontalPadding)
    .background(DesignTokens.TaskHeading.fill)
    .overlay(alignment: .bottom) {
      Rectangle().fill(DesignTokens.TaskHeading.stroke).frame(height: 1)
    }
  }
}

private struct FileCardView: View {
  let row: FileChangeRow
  let model: ChangeStreamPageModel
  let openIndicatorText: String?
  let headerOffset: CGFloat
  let content: CardContent
  let emphasis: CardEmphasis
  let isRetryable: Bool
  let retryTapped: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(spacing: 0) {
        header
        Rectangle().fill(DesignTokens.Card.headerStroke).frame(height: 1)
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.fileHeaderMeasured(height: $0) }
      .offset(y: headerOffset)
      .zIndex(1)
      contentView
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DesignTokens.Card.codeTopPadding)
        .padding(.horizontal, DesignTokens.Card.codeSidePadding)
        .padding(.bottom, DesignTokens.Card.codeBottomPadding)
        .background(DesignTokens.Card.codeFill(emphasis))
    }
    .background(DesignTokens.Card.fill)
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Card.radius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.Card.radius).strokeBorder(DesignTokens.Card.stroke(emphasis))
    }
    .padding(.horizontal, DesignTokens.Card.horizontalInset)
  }

  private var header: some View {
    HStack(spacing: DesignTokens.Card.headerGap) {
      IconView(icon: DesignTokens.Icons.fileText)
      Text(row.path)
        .font(DesignTokens.Fonts.filePath)
        .foregroundStyle(DesignTokens.Colors.filePath(emphasis))
        .lineLimit(1)
        .truncationMode(.head)
      Spacer()
      Text(row.time)
        .font(DesignTokens.Fonts.eventTime)
        .foregroundStyle(DesignTokens.Colors.eventTime)
      if let openIndicatorText {
        Text(openIndicatorText)
          .font(DesignTokens.Fonts.openIndicator)
          .foregroundStyle(DesignTokens.Colors.openIndicator)
      }
    }
    .padding(.vertical, DesignTokens.Card.headerVerticalPadding)
    .padding(.horizontal, DesignTokens.Card.headerHorizontalPadding)
    .background(DesignTokens.Card.headerFill(emphasis))
  }

  @ViewBuilder
  private var contentView: some View {
    switch content {
    case .loading:
      ProgressView().controlSize(.small).frame(height: model.sourceLineHeight)
    case .note(let text):
      HStack(spacing: DesignTokens.Card.headerGap) {
        Text(text)
          .font(DesignTokens.Fonts.liveStatus)
          .foregroundStyle(DesignTokens.Colors.paneSubtitle)
        if isRetryable {
          Button("Retry", action: retryTapped)
            .buttonStyle(.plain)
            .font(DesignTokens.Fonts.jumpToLatest)
            .foregroundStyle(DesignTokens.Colors.jumpToLatest)
        }
      }
      .frame(minHeight: model.sourceLineHeight)
    case .code(let blocks):
      VStack(alignment: .leading, spacing: 0) {
        ForEach(blocks) { block in
          CodeBlockView(block: block, row: row, model: model)
        }
      }
    }
  }
}

private struct CodeBlockView: View {
  let block: CodeBlock
  let row: FileChangeRow
  let model: ChangeStreamPageModel
  @State private var sourceGeometry = SourceGeometry()

  var body: some View {
    if let separatorText = block.separatorText {
      gutter {
        Text(separatorText)
          .font(DesignTokens.Fonts.lineNumber)
          .foregroundStyle(DesignTokens.Colors.lineNumber)
      } source: {
        EmptyView()
      }
    }
    VStack(alignment: .leading, spacing: 0) {
      ForEach(block.lines) { line in
        gutter(isChanged: line.isChanged, isVerified: line.isVerified) {
          Text(line.number)
            .font(DesignTokens.Fonts.lineNumber)
            .foregroundStyle(DesignTokens.Colors.lineNumber)
        } source: {
          Text(line.text)
            .font(DesignTokens.Fonts.sourceLine)
            .foregroundStyle(DesignTokens.Colors.sourceLine)
            .lineLimit(1)
            .textRenderer(ChangedTextRenderer(line: line))
            .accessibilityLabel(line.accessibilityText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(alignment: .topLeading) {
      GeometryReader { geometry in
        if let rect = model.highlightRect(row: row, block: block, width: geometry.size.width) {
          Rectangle().fill(DesignTokens.Ask.selectionFill)
            .overlay {
              Rectangle().strokeBorder(DesignTokens.Ask.selectionStroke, lineWidth: DesignTokens.Ask.selectionEdgeWidth)
            }
            .overlay(alignment: .leading) {
              Rectangle().fill(DesignTokens.Ask.selectionStroke).frame(width: DesignTokens.Ask.selectionLeftWidth)
            }
            .frame(width: rect.width, height: rect.height)
            .offset(y: rect.minY)
        }
      }
    }
    .contentShape(Rectangle())
    .overlay {
      SourceDragAdapter(dragged: { startY, endY in
        model.sourceDragged(row: row, block: block, startY: startY, endY: endY, frame: sourceGeometry.frame)
      }, ended: { model.sourceDragEnded() })
    }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("question-workspace")) } action: { frame in
      sourceGeometry.frame = frame
      model.sourceBlockMoved(row: row, block: block, frame: frame)
    }
    .onDisappear { model.sourceBlockDisappeared(row: row, block: block) }
    if let truncationText = block.truncationText {
      gutter {
        EmptyView()
      } source: {
        Text(truncationText)
          .font(DesignTokens.Fonts.lineNumber)
          .foregroundStyle(DesignTokens.Colors.lineNumber)
      }
    }
  }

  private func gutter(
    isChanged: Bool = false,
    isVerified: Bool = true,
    @ViewBuilder number: () -> some View,
    @ViewBuilder source: () -> some View
  ) -> some View {
    HStack(spacing: DesignTokens.Card.lineGap) {
      Rectangle()
        .fill(DesignTokens.Card.marker(isChanged: isChanged, isVerified: isVerified))
        .frame(width: DesignTokens.Card.markerWidth)
      number()
        .frame(width: model.sourceLineNumberWidth, alignment: .trailing)
      source()
    }
    .frame(height: model.sourceLineHeight)
  }
}

/// Draws the tint and removal ticks from glyph positions so the line stays one unsplit
/// `Text` and keeps its ligatures. Offsets are UTF-16, counted from the first glyph.
private struct ChangedTextRenderer: TextRenderer {
  let line: CodeLine

  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    guard !line.changedRanges.isEmpty || !line.removalOffsets.isEmpty else {
      for row in layout { context.draw(row) }
      return
    }
    let slices = layout.flatMap { $0 }
      .flatMap { run in run.indices.map { (slice: run[$0], isRightToLeft: run.layoutDirection == .rightToLeft) } }
      .filter { !$0.slice.characterIndices.isEmpty }
    guard let start = slices.flatMap(\.slice.characterIndices).min() else {
      for row in layout { context.draw(row) }
      return
    }
    let marks = ChangedTextMarks(
      glyphOffsets: slices.map { $0.slice.characterIndices.map { start.distance(to: $0) }.min() ?? 0 },
      length: line.text.utf16.count, isTruncated: layout.isTruncated,
      changedRanges: line.changedRanges, removalOffsets: line.removalOffsets
    )
    var tint = Path()
    for index in marks.tinted { tint.addRect(slices[index].slice.typographicBounds.rect) }
    var ticks = Path()
    for tick in marks.ticks {
      switch tick {
      case .before(let index): ticks.addRect(self.tick(atLeadingEdge: true, of: slices[index]))
      case .after(let index): ticks.addRect(self.tick(atLeadingEdge: false, of: slices[index]))
      }
    }
    context.fill(tint, with: .color(DesignTokens.Card.changedTextTint))
    for row in layout { context.draw(row) }
    context.fill(ticks, with: .color(DesignTokens.Card.removalTick))
  }

  private func tick(
    atLeadingEdge isLeading: Bool, of glyph: (slice: Text.Layout.RunSlice, isRightToLeft: Bool)
  ) -> CGRect {
    let rect = glyph.slice.typographicBounds.rect
    let x = isLeading == glyph.isRightToLeft ? rect.maxX : rect.minX
    return CGRect(
      x: x - DesignTokens.Card.removalTickWidth / 2, y: rect.minY,
      width: DesignTokens.Card.removalTickWidth, height: rect.height
    )
  }
}

@MainActor
private final class SourceGeometry {
  var frame = CGRect.zero
}
