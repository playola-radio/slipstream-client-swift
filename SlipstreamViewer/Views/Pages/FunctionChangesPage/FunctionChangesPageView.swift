import SwiftUI

struct FunctionChangesPageView: View {
  @State var model: FunctionChangesPageModel

  var body: some View {
    VStack(spacing: 0) {
      header
      controls
      if !model.noticeText.isEmpty {
        Text(model.noticeText)
          .font(DesignTokens.FunctionTree.smallFont)
          .foregroundStyle(DesignTokens.FunctionTree.changed)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 24)
          .padding(.vertical, 8)
          .background(DesignTokens.FunctionTree.bannerFill)
      }
      tree
      footer
    }
    .background(DesignTokens.FunctionTree.background)
    .preferredColorScheme(.dark)
    .frame(minWidth: 900, minHeight: 650)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("FUNCTION CHANGES")
          .font(DesignTokens.FunctionTree.labelFont)
          .foregroundStyle(DesignTokens.FunctionTree.muted)
        Spacer()
        Text(model.fixtureText)
          .font(DesignTokens.FunctionTree.smallFont)
          .foregroundStyle(DesignTokens.FunctionTree.changed)
      }
      HStack(alignment: .firstTextBaseline) {
        Text(model.titleText)
          .font(DesignTokens.FunctionTree.titleFont)
          .foregroundStyle(DesignTokens.FunctionTree.title)
        Spacer()
        Text(model.boundaryText)
          .font(DesignTokens.FunctionTree.labelFont)
          .foregroundStyle(DesignTokens.FunctionTree.secondary)
      }
      Text(model.subtitleText)
        .font(DesignTokens.FunctionTree.bodyFont)
        .foregroundStyle(DesignTokens.FunctionTree.secondary)
      HStack {
        Text(model.summaryText)
          .foregroundStyle(DesignTokens.FunctionTree.title)
        Spacer()
        Text(model.scopeText)
          .foregroundStyle(DesignTokens.FunctionTree.secondary)
      }
      .font(DesignTokens.FunctionTree.bodyFont)
      Text(model.analysisText)
        .font(DesignTokens.FunctionTree.bodyFont)
        .foregroundStyle(DesignTokens.FunctionTree.changed)
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.FunctionTree.bannerFill)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.FunctionTree.controlRadius))
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
    .background(DesignTokens.FunctionTree.headerFill)
  }

  private var controls: some View {
    HStack(spacing: 18) {
      TextField(model.searchPrompt, text: $model.searchText)
        .textFieldStyle(.plain)
        .font(DesignTokens.FunctionTree.bodyFont)
        .foregroundStyle(DesignTokens.FunctionTree.title)
        .padding(.horizontal, 11)
        .frame(width: 270, height: 30)
        .background(DesignTokens.FunctionTree.inputFill)
        .overlay {
          RoundedRectangle(cornerRadius: DesignTokens.FunctionTree.controlRadius).stroke(
            DesignTokens.FunctionTree.cardStroke)
        }
      Button(model.showsUnchanged ? "Hide unchanged branches" : "Show unchanged branches") {
        model.showUnchangedTapped()
      }
      Spacer()
      legend("+", "Added", DesignTokens.FunctionTree.added)
      legend("~", "Changed", DesignTokens.FunctionTree.changed)
      legend("−", "Removed", DesignTokens.FunctionTree.removed)
      Text(model.legendText)
        .foregroundStyle(DesignTokens.FunctionTree.muted)
    }
    .font(DesignTokens.FunctionTree.smallFont)
    .buttonStyle(.plain)
    .foregroundStyle(DesignTokens.FunctionTree.secondary)
    .padding(.horizontal, 24)
    .frame(height: 54)
    .background(DesignTokens.FunctionTree.background)
    .overlay(alignment: .bottom) { DesignTokens.FunctionTree.divider.frame(height: 1) }
  }

  private func legend(_ symbol: String, _ text: String, _ color: Color) -> some View {
    Text("\(symbol) \(text)").foregroundStyle(color)
  }

  private var tree: some View {
    ScrollViewReader { proxy in
      ScrollView([.horizontal, .vertical]) {
        treeCanvas
          .scaleEffect(model.zoom, anchor: .topLeading)
          .frame(
            width: model.canvasSize.width * model.zoom,
            height: model.canvasSize.height * model.zoom, alignment: .topLeading)
      }
      .background(DesignTokens.FunctionTree.canvasFill)
      .onGeometryChange(for: CGSize.self) {
        $0.size
      } action: { size in
        model.viewportChanged(width: size.width, height: size.height)
      }
      .onChange(of: model.focusRequest) {
        if let id = model.focusedNodeID { proxy.scrollTo(id, anchor: .center) }
      }
    }
  }

  private var treeCanvas: some View {
    ZStack(alignment: .topLeading) {
      DesignTokens.FunctionTree.canvasFill
      Canvas { context, _ in
        for (start, end) in model.edges {
          var path = Path()
          let middle = (start.y + end.y) / 2
          path.move(to: start)
          path.addLine(to: CGPoint(x: start.x, y: middle))
          path.addLine(to: CGPoint(x: end.x, y: middle))
          path.addLine(to: end)
          context.stroke(path, with: .color(DesignTokens.FunctionTree.connector), lineWidth: 1.5)
        }
      }
      .allowsHitTesting(false)
      ForEach(model.nodes) { node in
        nodeView(node)
          .frame(width: node.width, height: node.height)
          .position(x: node.x, y: node.y + node.height / 2)
          .id(node.id)
      }
    }
    .frame(width: model.canvasSize.width, height: model.canvasSize.height, alignment: .topLeading)
  }

  @ViewBuilder
  private func nodeView(_ node: FunctionChangeNode) -> some View {
    if node.kind == .declaration {
      Button {
        model.declarationTapped(node.id)
      } label: {
        card(node)
      }
      .buttonStyle(.plain)
    } else {
      card(node)
    }
  }

  private func card(_ node: FunctionChangeNode) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        if let marker = node.marker {
          Text(DesignTokens.FunctionTree.symbol(marker))
            .foregroundStyle(DesignTokens.FunctionTree.mark(marker))
        }
        Text(node.title)
          .foregroundStyle(DesignTokens.FunctionTree.title)
          .lineLimit(2)
        Spacer(minLength: 2)
        if node.changedCount > 0 {
          Text("\(node.changedCount)")
            .foregroundStyle(DesignTokens.FunctionTree.changed)
        }
        if node.unknownCount > 0 {
          Text("?")
            .foregroundStyle(DesignTokens.FunctionTree.changed)
        }
      }
      .font(DesignTokens.FunctionTree.labelFont)
      if let status = node.statusText {
        Text(status)
          .font(DesignTokens.FunctionTree.smallFont)
          .foregroundStyle(DesignTokens.FunctionTree.secondary)
      }
      if !node.lines.isEmpty {
        DesignTokens.FunctionTree.divider.frame(height: 1)
        ForEach(Array(node.lines.enumerated()), id: \.offset) { _, line in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(DesignTokens.FunctionTree.symbol(line.mark))
              .frame(width: 10, alignment: .leading)
            Text(line.text)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(
            line.mark == .note
              ? DesignTokens.FunctionTree.smallFont : DesignTokens.FunctionTree.codeFont
          )
          .foregroundStyle(DesignTokens.FunctionTree.mark(line.mark))
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      model.selectedNodeID == node.id
        ? DesignTokens.FunctionTree.selectedFill : DesignTokens.FunctionTree.cardFill
    )
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.FunctionTree.cardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.FunctionTree.cardRadius)
        .stroke(
          model.selectedNodeID == node.id
            ? DesignTokens.FunctionTree.selectedStroke : DesignTokens.FunctionTree.cardStroke,
          lineWidth: model.selectedNodeID == node.id ? 2 : 1)
    }
  }

  private var footer: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Button("−") { model.zoomOutTapped() }
        Text(model.zoomText).frame(width: 48)
        Button("+") { model.zoomInTapped() }
        Button("Fit tree") { model.fitTreeTapped() }
        Button("Zoom to selection") { model.zoomToSelectionTapped() }
          .disabled(model.selectedNodeID == nil)
        Spacer()
        Text(model.selectionText)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(DesignTokens.FunctionTree.labelFont)
      .buttonStyle(.plain)
      .foregroundStyle(DesignTokens.FunctionTree.secondary)
      .padding(.horizontal, 20)
      .frame(height: 58)
      .background(DesignTokens.FunctionTree.controlFill)
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(model.searchNotice)
          Text(model.coverageText).lineLimit(1)
        }
        Spacer()
        if model.canSelectBefore {
          Button("Before") { model.sourceSideTapped(.before) }
        }
        if model.canSelectAfter {
          Button("After") { model.sourceSideTapped(.after) }
        }
      }
      .font(DesignTokens.FunctionTree.smallFont)
      .foregroundStyle(DesignTokens.FunctionTree.muted)
      .buttonStyle(.plain)
      .padding(.horizontal, 24)
      .frame(height: 44)
      .background(DesignTokens.FunctionTree.background)
    }
  }
}
