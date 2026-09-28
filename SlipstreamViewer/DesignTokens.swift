import AppKit
import SwiftUI

enum CardEmphasis: Equatable, Sendable {
  case newest, other
}

enum DesignTokens {

  enum FunctionTree {
    static let background = Color(hex: 0x15191F)
    static let headerFill = Color(hex: 0x191E25)
    static let canvasFill = Color(hex: 0x121B24)
    static let cardFill = Color(hex: 0x202F3C)
    static let selectedFill = Color(hex: 0x2B465B)
    static let cardStroke = Color(hex: 0x516579)
    static let selectedStroke = Color(hex: 0xB0D7F1)
    static let connector = Color(hex: 0x516579)
    static let divider = Color(hex: 0x34414E)
    static let title = Color(hex: 0xDBE9F3)
    static let secondary = Color(hex: 0x9EB7CB)
    static let muted = Color(hex: 0x839EB4)
    static let added = Color(hex: 0x8DD9B1)
    static let removed = Color(hex: 0xF0A4AB)
    static let changed = Color(hex: 0xE4C282)
    static let unknown = Color(hex: 0xA4B4C3)
    static let inputFill = Color(hex: 0x11171D)
    static let controlFill = Color(hex: 0x192631)
    static let bannerFill = Color(hex: 0x1B222A)
    static let titleFont = variableFont(family: geistFamily, size: 28, weight: 450)
    static let bodyFont = variableFont(family: geistFamily, size: 12, weight: 400)
    static let smallFont = variableFont(family: geistFamily, size: 10, weight: 400)
    static let labelFont = variableFont(family: geistMonoFamily, size: 11, weight: 500)
    static let codeFont = variableFont(family: geistMonoFamily, size: 11, weight: 400)
    static let cardRadius: CGFloat = 5
    static let controlRadius: CGFloat = 4

    static func mark(_ value: FunctionChangeLine.Mark) -> Color {
      switch value {
      case .equal: secondary
      case .added: added
      case .removed: removed
      case .changed: changed
      case .note: muted
      }
    }

    static func symbol(_ value: FunctionChangeLine.Mark) -> String {
      switch value {
      case .equal: "="
      case .added: "+"
      case .removed: "−"
      case .changed: "~"
      case .note: ""
      }
    }
  }

  enum FunctionMap {
    static let background = Color(hex: 0x15191F)
    static let groupFill = Color(hex: 0x192129)
    static let groupStroke = Color(hex: 0x33424F)
    static let rootFill = Color(hex: 0x202B35)
    static let functionFill = Color(hex: 0x202C37)
    static let selectedFill = Color(hex: 0x293F50)
    static let functionStroke = Color(hex: 0x476073)
    static let selectedStroke = Color(hex: 0xA9CBE3)
    static let equalFill = Color(hex: 0x1C252E)
    static let addedFill = Color(hex: 0x203A32)
    static let removedFill = Color(hex: 0x38282F)
    static let title = Color(hex: 0xEDF3F8)
    static let body = Color(hex: 0xD4E2ED)
    static let secondary = Color(hex: 0x9EB1C0)
    static let heading = Color(hex: 0x8FA7BA)
    static let added = Color(hex: 0x8DD9B1)
    static let removed = Color(hex: 0xF0A4AB)
    static let changed = Color(hex: 0xE4C282)
    static let unknown = Color(hex: 0xA4B4C3)
    static let connector = Color(hex: 0x607D91)
    static let titleFont = variableFont(family: geistFamily, size: 30, weight: 450)
    static let bodyFont = variableFont(family: geistFamily, size: 13, weight: 400)
    static let smallFont = variableFont(family: geistFamily, size: 11, weight: 400)
    static let headingFont = variableFont(family: geistFamily, size: 10, weight: 500)
    static let codeFont = variableFont(family: geistMonoFamily, size: 12, weight: 400)
    static let functionFont = variableFont(family: geistMonoFamily, size: 17, weight: 500)
    static let codeWidth: CGFloat = 170
    static let inputWidth: CGFloat = 240
    static let connectorWidth: CGFloat = 28
    static let functionWidth: CGFloat = 200
    static let outputWidth: CGFloat = 240
    static let effectsWidth: CGFloat = 120
    static let laneGap: CGFloat = 10
    static let groupGap: CGFloat = 14
    static let rowGap: CGFloat = 8
    static let padding: CGFloat = 24
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 5
    static let groupRadius: CGFloat = 3
    static let rowMinHeight: CGFloat = 100

    static var laneWidth: CGFloat {
      codeWidth + inputWidth + connectorWidth + functionWidth + connectorWidth + outputWidth
        + effectsWidth + laneGap * 6
    }

    struct Layout {
      let codeWidth: CGFloat
      let inputWidth: CGFloat
      let connectorWidth: CGFloat
      let functionWidth: CGFloat
      let outputWidth: CGFloat
      let effectsWidth: CGFloat

      var laneWidth: CGFloat {
        codeWidth + inputWidth + connectorWidth + functionWidth + connectorWidth + outputWidth
          + effectsWidth + FunctionMap.laneGap * 6
      }
    }

    static func layout(for viewportWidth: CGFloat) -> Layout {
      let available = max(laneWidth, viewportWidth - padding * 2)
      let ownerWidth: CGFloat = 1900 - padding * 2
      let progress = min(1, (available - laneWidth) / (ownerWidth - laneWidth))
      let extraEffects = max(0, available - ownerWidth)
      return Layout(
        codeWidth: codeWidth + (226 - codeWidth) * progress,
        inputWidth: inputWidth + (336 - inputWidth) * progress,
        connectorWidth: connectorWidth + (36 - connectorWidth) * progress,
        functionWidth: functionWidth + (262 - functionWidth) * progress,
        outputWidth: outputWidth + (336 - outputWidth) * progress,
        effectsWidth: effectsWidth + (560 - effectsWidth) * progress + extraEffects)
    }

    static func markText(_ mark: FunctionChangeLine.Mark) -> Color {
      switch mark {
      case .equal: secondary
      case .added: added
      case .removed: removed
      case .changed: changed
      case .note: secondary
      }
    }

    static func markFill(_ mark: FunctionChangeLine.Mark) -> Color {
      switch mark {
      case .equal, .changed, .note: equalFill
      case .added: addedFill
      case .removed: removedFill
      }
    }
  }

  private static let geistFamily = "Geist"
  private static let geistMonoFamily = "Geist Mono"

  private static func variableFont(family: String, size: CGFloat, weight: CGFloat, codeLigatures: Bool = false) -> Font {
    let wghtAxis = 0x7767_6874 as UInt32
    var attributes: [NSFontDescriptor.AttributeName: Any] = [
      .name: family,
      .variation: [NSNumber(value: wghtAxis): NSNumber(value: Double(weight))],
    ]
    if codeLigatures {
      attributes[.featureSettings] = [
        [
          NSFontDescriptor.FeatureKey.typeIdentifier: kStylisticAlternativesType,
          NSFontDescriptor.FeatureKey.selectorIdentifier: kStylisticAltElevenOnSelector,
        ]
      ]
    }
    let descriptor = NSFontDescriptor(fontAttributes: attributes)
    guard let nsFont = NSFont(descriptor: descriptor, size: size) else {
      return .system(size: size)
    }
    return Font(nsFont)
  }

  enum Ask {
    static let width: CGFloat = 640
    static let fill = Color(hex: 0x202B35)
    static let stroke = Color(hex: 0x83C7F0)
    static let strokeWidth: CGFloat = 1.5
    static let radius: CGFloat = 10
    static let topPadding: CGFloat = 16
    static let padding: CGFloat = 24
    static let gap: CGFloat = 12
    static let smallGap: CGFloat = 8
    static let controlGap: CGFloat = 10
    static let actionGap: CGFloat = 18
    static let shadow = Color.black.opacity(0.4)
    static let shadowY: CGFloat = 12
    static let shadowBlur: CGFloat = 30
    static let titleColor = Color(hex: 0xC0D0DD)
    static let titleFont = variableFont(family: geistFamily, size: 13, weight: 550)
    static let closeColor = Color(hex: 0xB4C4D0)
    static let iconSize: CGFloat = 16
    static let editorHeight: CGFloat = 180
    static let editorFill = Color(hex: 0x111D26)
    static let editorText = Color(hex: 0xEDF4FA)
    static let editorPadding: CGFloat = 18
    static let editorFontSize: CGFloat = 20
    static let editorLineHeight: CGFloat = 30
    static let controlRadius: CGFloat = 5
    static let contextColor = Color(hex: 0xA4D5F1)
    static let contextFont = variableFont(family: geistFamily, size: 12, weight: 400)
    static let bodyFont = variableFont(family: geistFamily, size: 13, weight: 400)
    static let cancelColor = Color(hex: 0xC4D4DF)
    static let sendFill = Color(hex: 0xB2DAEE)
    static let sendText = Color(hex: 0x132735)
    static let sendFont = variableFont(family: geistFamily, size: 13, weight: 600)
    static let sendVerticalPadding: CGFloat = 11
    static let sendHorizontalPadding: CGFloat = 17
    static let divider = Color(hex: 0x3B505F)
    static let savedTopPadding: CGFloat = 20
    static let savedLabel = Color(hex: 0xA4B8C7)
    static let savedFont = variableFont(family: geistFamily, size: 12, weight: 550)
    static let dropdownFill = Color(hex: 0x15212B)
    static let dropdownStroke = Color(hex: 0x779CB5)
    static let dropdownIcon = Color(hex: 0xACBFCC)
    static let controlVerticalPadding: CGFloat = 12
    static let controlHorizontalPadding: CGFloat = 14
    static let appendFill = Color(hex: 0x344D5E)
    static let appendText = Color(hex: 0xE6F2FA)
    static let appendFont = variableFont(family: geistFamily, size: 13, weight: 550)
    static let menuFill = Color(hex: 0x18232D)
    static let menuStroke = Color(hex: 0x455C6D)
    static let menuPadding: CGFloat = 5
    static let menuSelected = Color(hex: 0x2C4354)
    static let menuText = Color(hex: 0xE2EDF5)
    static let menuItemRadius: CGFloat = 3
    static let menuVerticalPadding: CGFloat = 11
    static let menuHorizontalPadding: CGFloat = 12
    static let menuDivider = Color(hex: 0x354957)
    static let selectionFill = Color(hex: 0x315D7A)
    static let selectionStroke = Color(hex: 0xA4D5F1)
    static let selectionLeftWidth: CGFloat = 3
    static let selectionEdgeWidth: CGFloat = 2
    static let connectorWidth: CGFloat = 2
    static let connectorDot: CGFloat = 8
    static let connectorLength: CGFloat = 36
    static let viewportInset: CGFloat = 16
  }

  enum ReplyBar {
    static let height: CGFloat = 42
    static let radius: CGFloat = 4
    static let gap: CGFloat = 10
    static let horizontalPadding: CGFloat = 12
    static let strokeWidth: CGFloat = 1
    static let leadingStrokeWidth: CGFloat = 3
    static let iconSize: CGFloat = 15
    static let chevronSize: CGFloat = 14
    static let chevronColor = Color(hex: 0xC6E7FF)
    static let previewFont = variableFont(family: geistFamily, size: 12, weight: 550)
    static let previewColor = Color(hex: 0xF0F7FC)
    static let statusFont = variableFont(family: geistFamily, size: 11, weight: 550)

    static func fill(isOpen: Bool) -> Color {
      isOpen ? Color(hex: 0x345E7B) : Color(hex: 0x294C68)
    }

    static func stroke(isOpen: Bool) -> Color {
      isOpen ? Color(hex: 0xB2DFFF) : Color(hex: 0x76AED5)
    }

    static func chevron(isOpen: Bool) -> String {
      isOpen ? "ChevronRight" : "ChevronDown"
    }

    static func accent(_ status: QuestionBarStatus) -> Color {
      status == .waiting ? Color(hex: 0xD8BE89) : Color(hex: 0xC6E7FF)
    }
  }

  enum Reply {
    static let width: CGFloat = 420
    static let fill = Color(hex: 0x202B35)
    static let radius: CGFloat = 6
    static let stroke = Color(hex: 0x83C7F0)
    static let strokeWidth: CGFloat = 1
    static let shadow = Color.black.opacity(0.4)
    static let shadowY: CGFloat = 8
    static let shadowBlur: CGFloat = 22
    static let gap: CGFloat = 14
    static let padding: CGFloat = 16
    static let titleFont = variableFont(family: geistFamily, size: 12, weight: 550)
    static let titleColor = Color(hex: 0xC0D0DD)
    static let closeColor = Color(hex: 0xA4B8C7)
    static let iconSize: CGFloat = 15
    static let questionFont = variableFont(family: geistFamily, size: 14, weight: 550)
    static let questionColor = Color(hex: 0xEEF5FA)
    static let questionLineSpacing: CGFloat = 14 * 0.4
    static let answerGap: CGFloat = 8
    static let agentFont = variableFont(family: geistMonoFamily, size: 10, weight: 400)
    static let agentColor = Color(hex: 0xA4D5F1)
    static let waitingColor = Color(hex: 0xD8BE89)
    static let answerFont = variableFont(family: geistFamily, size: 13, weight: 400)
    static let answerColor = Color(hex: 0xDDE7EF)
    static let answerLineSpacing: CGFloat = 13 * 0.55
    static let inputHeight: CGFloat = 68
    static let inputMaxHeight: CGFloat = 136
    static let inputFill = Color(hex: 0x111D26)
    static let inputRadius: CGFloat = 4
    static let inputStroke = Color(hex: 0x59798F)
    static let inputPadding: CGFloat = 12
    static let draftFont = variableFont(family: geistFamily, size: 13, weight: 400)
    static let draftColor = Color(hex: 0xE0EAF2)
    static let draftLineSpacing: CGFloat = 13 * 0.4
    static let actionGap: CGFloat = 12
    static let sourceFont = variableFont(family: geistMonoFamily, size: 10, weight: 400)
    static let sourceColor = Color(hex: 0x91A8B9)
    static let noticeColor = waitingColor
    static let sendFill = Color(hex: 0xB2DAEE)
    static let sendText = Color(hex: 0x132735)
    static let sendFont = variableFont(family: geistFamily, size: 12, weight: 550)
    static let sendRadius: CGFloat = 4
    static let sendVerticalPadding: CGFloat = 9
    static let sendHorizontalPadding: CGFloat = 13
    static let connectorColor = Color(hex: 0xA4D5F1)
    static let connectorDot: CGFloat = 6
    static let connectorWidth: CGFloat = 2
    static let connectorLength: CGFloat = 44
    static let viewportInset: CGFloat = 16
  }

  enum Fonts {
    static let paneTitle: Font = variableFont(family: geistFamily, size: 16, weight: 400)
    static let paneSubtitle: Font = variableFont(family: geistFamily, size: 10, weight: 400)
    static let taskTitle: Font = variableFont(family: geistFamily, size: 15, weight: 400)
    static let taskBadge: Font = variableFont(family: geistMonoFamily, size: 12, weight: 400)
    static let filePath: Font = variableFont(family: geistMonoFamily, size: 11, weight: 400)
    static let eventTime: Font = variableFont(family: geistFamily, size: 10, weight: 400)
    static let lineNumber: Font = variableFont(family: geistMonoFamily, size: 10, weight: 400)
    static let sourceLine: Font = variableFont(family: geistMonoFamily, size: 12, weight: 400, codeLigatures: true)
    static let liveStatus: Font = variableFont(family: geistFamily, size: 11, weight: 400)
    static let jumpToLatest: Font = variableFont(family: geistFamily, size: 10, weight: 400)
    static let hideFeed: Font = variableFont(family: geistFamily, size: 10, weight: 400)
    static let openIndicator: Font = variableFont(family: geistMonoFamily, size: 9, weight: 400)
    static let restoreFeed: Font = variableFont(family: geistFamily, size: 11, weight: 400)

    static func paneSubtitle(isQuestionSummary: Bool) -> Font {
      isQuestionSummary ? questionSummary : paneSubtitle
    }

    private static let questionSummary: Font = variableFont(family: geistFamily, size: 11, weight: 400)
  }

  enum Colors {
    static let paneTitle = Color(hex: 0xD9E7EF)
    static let paneSubtitle = Color(hex: 0x7D98AD)
    static let taskTitle = Color(hex: 0xE0EBF1)
    static let taskBadge = Color(hex: 0xB2DEC9)
    static let eventTime = Color(hex: 0x68879E)
    static let lineNumber = Color(hex: 0x5F8099)
    static let sourceLine = Color(hex: 0xBDCDDF)
    static let liveStatus = Color(hex: 0x789F91)
    static let jumpToLatest = Color(hex: 0x82AAC5)
    static let hideFeed = Color(hex: 0x9EBACB)
    static let openIndicator = Color(hex: 0x78AAD0)
    static let restoreFeed = Color(hex: 0xBFCBD9)

    static func paneSubtitle(isQuestionSummary: Bool) -> Color {
      isQuestionSummary ? Color(hex: 0xA4D5F1) : paneSubtitle
    }

    static func filePath(_ emphasis: CardEmphasis) -> Color {
      switch emphasis {
      case .newest: Color(hex: 0xA2CBE3)
      case .other: Color(hex: 0x8DA9BD)
      }
    }
  }

  enum FeedPane {
    static let width: CGFloat = 680
    static let fill = Color(hex: 0x191F27)
    static let stroke = Color(hex: 0x405562)
    static let headerHeight: CGFloat = 52
    static let horizontalPadding: CGFloat = 20
    static let headerGap: CGFloat = 10
  }

  enum HideFeedButton {
    static let stroke = Color(hex: 0x3E5260)
    static let radius: CGFloat = 4
    static let verticalPadding: CGFloat = 6
    static let horizontalPadding: CGFloat = 8
    static let gap: CGFloat = 6
  }

  enum FileViewer {
    static let fill = Color(hex: 0x11171D)
    static let padding: CGFloat = 12
    static let gap: CGFloat = 8
    static let toolbarHeight: CGFloat = 34
    static let paneFill = Color(hex: 0x151B22)
    static let paneStroke = Color(hex: 0x34414D)
  }

  enum Stream {
    static let groupGap: CGFloat = 28
    static let itemGap: CGFloat = 24
  }

  enum TaskHeading {
    static let fill = Color(hex: 0x24313B)
    static let stroke = Color(hex: 0x526B7B)
    static let verticalPadding: CGFloat = 12
    static let horizontalPadding: CGFloat = 20
    static let gap: CGFloat = 12
  }

  enum Badge {
    static let fill = Color(hex: 0x344B57)
    static let radius: CGFloat = 3
    static let verticalPadding: CGFloat = 6
    static let horizontalPadding: CGFloat = 8
  }

  enum Card {
    static let horizontalInset: CGFloat = 20
    static let radius: CGFloat = 8
    static let fill = Color(hex: 0x1C2630)

    static func stroke(_ emphasis: CardEmphasis) -> Color {
      switch emphasis {
      case .newest: Color(hex: 0x5B859F)
      case .other: Color(hex: 0x3F5363)
      }
    }

    static func headerFill(_ emphasis: CardEmphasis) -> Color {
      switch emphasis {
      case .newest: Color(hex: 0x2B4050)
      case .other: Color(hex: 0x283642)
      }
    }

    static let headerStroke = Color(hex: 0x405564)
    static let headerVerticalPadding: CGFloat = 12
    static let headerHorizontalPadding: CGFloat = 14
    static let headerGap: CGFloat = 7

    static func codeFill(_ emphasis: CardEmphasis) -> Color {
      switch emphasis {
      case .newest: Color(hex: 0x1D2D3B)
      case .other: Color(hex: 0x1C2630)
      }
    }

    static let codeTopPadding: CGFloat = 14
    static let codeSidePadding: CGFloat = 10
    static let codeBottomPadding: CGFloat = 16
    static let lineHeight: CGFloat = 22
    static let lineGap: CGFloat = 10
    static let lineNumberWidth: CGFloat = 25
    static func marker(isChanged: Bool, isVerified: Bool = true) -> Color {
      guard isChanged else { return .clear }
      return isVerified ? Color(hex: 0x4B9CDA) : Color(hex: 0x4B9CDA).opacity(0.35)
    }

    static let markerWidth: CGFloat = 3
    static let changedTextTint = Color(hex: 0x4B9CDA).opacity(0.5)
    static let removalTick = Color(hex: 0x4B9CDA)
    static let removalTickWidth: CGFloat = 2
  }

  enum Footer {
    static let stroke = Color(hex: 0x314351)
    static let verticalPadding: CGFloat = 10
    static let horizontalPadding: CGFloat = 20
    static let gap: CGFloat = 8
  }

  enum Status {
    static let warning = Color.orange
    static let error = Color.red
  }

  enum Icons {
    struct Icon {
      let assetName: String
      let size: CGFloat
      let color: Color
    }

    static let listTree = Icon(assetName: "ListTree", size: 15, color: Color(hex: 0x96B7CA))
    static let hideFeed = Icon(assetName: "PanelLeftClose", size: 14, color: Color(hex: 0x9EBACB))
    static let fileText = Icon(assetName: "FileText", size: 12, color: Color(hex: 0x789FB9))
    static let activity = Icon(assetName: "Activity", size: 13, color: Color(hex: 0x83BDA4))

    static func pin(isPinned: Bool) -> Icon {
      Icon(assetName: "Pin", size: 13, color: isPinned ? Color(hex: 0x9ACBB8) : Color(hex: 0x7F96A6))
    }
  }
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: 1
    )
  }
}
