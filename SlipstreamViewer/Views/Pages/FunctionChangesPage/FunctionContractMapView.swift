import SwiftUI

struct FunctionContractMapView: View {
  let model: FunctionChangesPageModel

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      LazyVStack(alignment: .leading, spacing: DesignTokens.FunctionMap.groupGap) {
        rootBar
        laneHeadings
        ForEach(model.mapGroups) { group in
          groupView(group)
        }
      }
      .frame(width: DesignTokens.FunctionMap.laneWidth, alignment: .leading)
      .padding(DesignTokens.FunctionMap.padding)
    }
    .defaultScrollAnchor(.topLeading)
    .background(DesignTokens.FunctionMap.background)
  }

  private var rootBar: some View {
    HStack(spacing: DesignTokens.FunctionMap.laneGap) {
      Text(model.scopeText)
        .font(DesignTokens.FunctionMap.codeFont)
        .foregroundStyle(DesignTokens.FunctionMap.title)
      Text(model.summaryText)
        .font(DesignTokens.FunctionMap.smallFont)
        .foregroundStyle(DesignTokens.FunctionMap.secondary)
      Spacer()
      Text(model.mapModeLabel)
        .font(DesignTokens.FunctionMap.headingFont)
        .foregroundStyle(DesignTokens.FunctionMap.heading)
    }
    .padding(DesignTokens.FunctionMap.cardPadding)
    .background(DesignTokens.FunctionMap.rootFill)
  }

  private var laneHeadings: some View {
    HStack(alignment: .top, spacing: DesignTokens.FunctionMap.laneGap) {
      heading(model.mapCodeTreeHeading, width: DesignTokens.FunctionMap.codeWidth)
      heading(model.mapInputsHeading, width: DesignTokens.FunctionMap.inputWidth)
      heading("", width: DesignTokens.FunctionMap.connectorWidth)
      heading(model.mapFunctionHeading, width: DesignTokens.FunctionMap.functionWidth)
      heading("", width: DesignTokens.FunctionMap.connectorWidth)
      heading(model.mapOutputsHeading, width: DesignTokens.FunctionMap.outputWidth)
      heading(model.mapEffectsHeading, width: DesignTokens.FunctionMap.effectsWidth)
    }
  }

  private func heading(_ title: String, width: CGFloat) -> some View {
    Text(title)
      .font(DesignTokens.FunctionMap.headingFont)
      .foregroundStyle(DesignTokens.FunctionMap.heading)
      .frame(width: width, alignment: .leading)
  }

  private func groupView(_ group: FunctionMapGroup) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.FunctionMap.groupGap) {
      HStack(spacing: DesignTokens.FunctionMap.laneGap) {
        Text(group.directory)
          .font(DesignTokens.FunctionMap.codeFont)
          .foregroundStyle(DesignTokens.FunctionMap.body)
        Text(group.summaryText)
          .font(DesignTokens.FunctionMap.smallFont)
          .foregroundStyle(DesignTokens.FunctionMap.changed)
        Spacer()
      }
      ForEach(group.files) { file in
        HStack(alignment: .top, spacing: DesignTokens.FunctionMap.laneGap) {
          fileColumn(file)
          LazyVStack(alignment: .leading, spacing: DesignTokens.FunctionMap.rowGap) {
            ForEach(file.rows) { row in
              if let status = row.statusText {
                statusRow(status)
              } else {
                declarationRow(row)
              }
            }
          }
        }
      }
    }
    .padding(DesignTokens.FunctionMap.cardPadding)
    .frame(width: DesignTokens.FunctionMap.laneWidth, alignment: .leading)
    .background(DesignTokens.FunctionMap.groupFill)
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.FunctionMap.groupRadius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.FunctionMap.groupRadius)
        .stroke(DesignTokens.FunctionMap.groupStroke)
    }
  }

  private func fileColumn(_ file: FunctionMapFile) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.FunctionMap.rowGap) {
      Text(file.name)
        .font(DesignTokens.FunctionMap.codeFont)
        .foregroundStyle(DesignTokens.FunctionMap.body)
        .lineLimit(2)
        .help(file.path)
      Text(file.summaryText)
        .font(DesignTokens.FunctionMap.smallFont)
        .foregroundStyle(
          file.isUnknown ? DesignTokens.FunctionMap.unknown : DesignTokens.FunctionMap.changed)
    }
    .frame(width: DesignTokens.FunctionMap.codeWidth, alignment: .leading)
  }

  private func declarationRow(_ row: FunctionMapRow) -> some View {
    HStack(alignment: .top, spacing: DesignTokens.FunctionMap.laneGap) {
      lineColumn(row.inputLines, width: DesignTokens.FunctionMap.inputWidth)
      arrow
      Button {
        model.declarationTapped(row.id)
      } label: {
        functionCard(row)
      }
      .buttonStyle(.plain)
      arrow
      lineColumn(row.outputLines, width: DesignTokens.FunctionMap.outputWidth)
      DesignTokens.FunctionMap.groupStroke
        .frame(width: 1, height: DesignTokens.FunctionMap.rowMinHeight)
        .frame(width: DesignTokens.FunctionMap.effectsWidth, alignment: .leading)
    }
    .frame(minHeight: DesignTokens.FunctionMap.rowMinHeight, alignment: .top)
  }

  private var arrow: some View {
    Text(model.mapArrowText)
      .font(DesignTokens.FunctionMap.codeFont)
      .foregroundStyle(DesignTokens.FunctionMap.connector)
      .frame(width: DesignTokens.FunctionMap.connectorWidth)
      .frame(height: DesignTokens.FunctionMap.rowMinHeight)
  }

  private func functionCard(_ row: FunctionMapRow) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.FunctionMap.rowGap) {
      HStack(spacing: DesignTokens.FunctionMap.rowGap) {
        if let marker = row.marker {
          Text(DesignTokens.FunctionTree.symbol(marker))
            .foregroundStyle(DesignTokens.FunctionMap.markText(marker))
        }
        Text(row.label)
          .foregroundStyle(DesignTokens.FunctionMap.markText(row.marker ?? .note))
      }
      .font(DesignTokens.FunctionMap.smallFont)
      Text(row.title)
        .font(DesignTokens.FunctionMap.functionFont)
        .foregroundStyle(DesignTokens.FunctionMap.title)
        .lineLimit(2)
        .help(row.title)
      Text(row.subtitle)
        .font(DesignTokens.FunctionMap.smallFont)
        .foregroundStyle(DesignTokens.FunctionMap.secondary)
        .lineLimit(2)
        .help(row.subtitle)
      ForEach(Array(row.headerLines.enumerated()), id: \.offset) { _, line in
        lineView(line)
      }
    }
    .padding(DesignTokens.FunctionMap.cardPadding)
    .frame(width: DesignTokens.FunctionMap.functionWidth, alignment: .leading)
    .frame(minHeight: DesignTokens.FunctionMap.rowMinHeight, alignment: .top)
    .background(
      model.selectedNodeID == row.id
        ? DesignTokens.FunctionMap.selectedFill : DesignTokens.FunctionMap.functionFill
    )
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.FunctionMap.cardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.FunctionMap.cardRadius)
        .stroke(
          model.selectedNodeID == row.id
            ? DesignTokens.FunctionMap.selectedStroke : DesignTokens.FunctionMap.functionStroke,
          lineWidth: model.selectedNodeID == row.id ? 2 : 1)
    }
  }

  private func lineColumn(_ lines: [FunctionChangeLine], width: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.FunctionMap.rowGap) {
      if lines.isEmpty {
        Text(model.mapEmptyCellText)
          .font(DesignTokens.FunctionMap.codeFont)
          .foregroundStyle(DesignTokens.FunctionMap.secondary)
      }
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        lineView(line)
      }
    }
    .frame(width: width, alignment: .leading)
  }

  private func lineView(_ line: FunctionChangeLine) -> some View {
    HStack(alignment: .top, spacing: DesignTokens.FunctionMap.rowGap) {
      Text(DesignTokens.FunctionTree.symbol(line.mark))
      Text(line.text)
        .lineLimit(3)
        .help(line.text)
    }
    .font(DesignTokens.FunctionMap.codeFont)
    .foregroundStyle(DesignTokens.FunctionMap.markText(line.mark))
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(DesignTokens.FunctionMap.rowGap)
    .background(DesignTokens.FunctionMap.markFill(line.mark))
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.FunctionMap.groupRadius))
  }

  private func statusRow(_ status: String) -> some View {
    Text(status)
      .font(DesignTokens.FunctionMap.bodyFont)
      .foregroundStyle(DesignTokens.FunctionMap.unknown)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(DesignTokens.FunctionMap.cardPadding)
      .frame(minHeight: DesignTokens.FunctionMap.rowMinHeight, alignment: .topLeading)
      .background(DesignTokens.FunctionMap.equalFill)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.FunctionMap.groupRadius))
  }
}
