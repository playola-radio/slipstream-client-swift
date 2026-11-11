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
    static let bodyFont = variableFont(family: geistFamily, size: 12, weight: 400)
    static let smallFont = variableFont(family: geistFamily, size: 10, weight: 400)
    static let labelFont = variableFont(family: geistMonoFamily, size: 11, weight: 500)
    static let codeFont = variableFont(family: geistMonoFamily, size: 11, weight: 400)
    static let cardRadius: CGFloat = 5
    static let controlRadius: CGFloat = 4
    static let controlStackGap: CGFloat = 8

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
    static let bodyFont = variableFont(family: geistFamily, size: 13, weight: 400)
    static let smallFont = variableFont(family: geistFamily, size: 11, weight: 400)
    static let headingFont = variableFont(family: geistFamily, size: 10, weight: 500)
    static let codeFont = variableFont(family: geistMonoFamily, size: 12, weight: 400)
    static let functionFont = variableFont(family: geistMonoFamily, size: 17, weight: 500)
    static let codeWidth: CGFloat = 130
    static let inputWidth: CGFloat = 190
    static let connectorWidth: CGFloat = 20
    static let functionWidth: CGFloat = 180
    static let outputWidth: CGFloat = 190
    static let effectsWidth: CGFloat = 80
    static let laneGap: CGFloat = 10
    static let groupGap: CGFloat = 14
    static let rowGap: CGFloat = 8
    static let padding: CGFloat = 24
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 5
    static let groupRadius: CGFloat = 3
    static let rowMinHeight: CGFloat = 100
    static let demoWorkspaceMinWidth: CGFloat = 1200
    static let demoWorkspaceMinHeight: CGFloat = 650

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

  struct FontToken: Sendable {
    let family: String
    let size: CGFloat
    let weight: CGFloat
    let codeLigatures: Bool

    var bold: FontToken {
      FontToken(family: family, size: size, weight: 600, codeLigatures: codeLigatures)
    }

    func font(scale: CGFloat) -> Font {
      nsFont(scale: scale).map(Font.init) ?? .system(size: size * scale)
    }

    func nsFont(scale: CGFloat) -> NSFont? {
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
      return NSFont(descriptor: NSFontDescriptor(fontAttributes: attributes), size: size * scale)
    }
  }

  private static func variableFont(
    family: String, size: CGFloat, weight: CGFloat, codeLigatures: Bool = false
  ) -> FontToken {
    FontToken(family: family, size: size, weight: weight, codeLigatures: codeLigatures)
  }

  enum TerminalPane {
    static let background = Color(hex: 0x0E1318)
    static let foreground = Color(hex: 0xE6EDF3)
    static let font = variableFont(family: geistMonoFamily, size: 12, weight: 400)
    static let shellVerticalPadding: CGFloat = 14
    static let shellHorizontalPadding: CGFloat = 16
    /// The "Restored" divider is written into the terminal, so its colours are escape codes.
    static let dividerRuleColor = "\u{1b}[38;2;42;54;64m"
    static let dividerLabelColor = "\u{1b}[38;2;139;154;166m"
    static let stroke = Color(hex: 0x2A3640)

    private static let primary = Color(hex: 0xE6EDF3)
    private static let secondary = Color(hex: 0x8B9AA6)
    private static let accent = Color(hex: 0x6CB6FF)
    private static let danger = Color(hex: 0xF0A4AB)
    private static let calloutStroke = Color(hex: 0x5C3B32)

    enum TabStrip {
      static let height: CGFloat = 40
      static let gap: CGFloat = 2
      static let leadingPadding: CGFloat = 10
      static let trailingPadding: CGFloat = 6
    }

    enum Tab {
      static let horizontalPadding: CGFloat = 12
      static let gap: CGFloat = 6
      static let underlineWidth: CGFloat = 2
      static let hoverRadius: CGFloat = 6
      static let titleFont: FontToken = variableFont(family: geistFamily, size: 12.5, weight: 400)
      static let close = Icons.Icon(assetName: "X", size: 12, color: secondary)

      static func underline(isSelected: Bool) -> Color { isSelected ? accent : .clear }

      static func fill(isHovered: Bool) -> Color { isHovered ? Color(hex: 0x1C232B) : .clear }

      static func titleColor(isSelected: Bool) -> Color { isSelected ? primary : secondary }
    }

    enum StatusIcon {
      static let spinner = Chat.Spinner(size: 12, lineWidth: 1.5, color: accent)
      static let finished = Icons.Icon(assetName: "Check", size: 12, color: Color(hex: 0x8DD9B1))
      static let failed = Icons.Icon(assetName: "CircleAlert", size: 12, color: danger)
    }

    enum Footer {
      static let height: CGFloat = 34
      static let gap: CGFloat = 8
      static let horizontalPadding: CGFloat = 16
      static let font: FontToken = variableFont(family: geistFamily, size: 12, weight: 400)
      static let spinner = Chat.Spinner(size: 13, lineWidth: 1.5, color: accent)
      static let finished = Icons.Icon(assetName: "Check", size: 13, color: Color(hex: 0x8DD9B1))
      static let failed = Icons.Icon(assetName: "CircleAlert", size: 13, color: danger)

      static func textColor(for icon: TerminalTabStatusIcon?) -> Color {
        icon == .failed ? danger : Color(hex: 0xB7C3CD)
      }
    }

    enum NewTab {
      static let horizontalPadding: CGFloat = 10
      static let plus = Icons.Icon(assetName: "Plus", size: 14, color: secondary)
    }

    enum Message {
      static let gap: CGFloat = 8
      static let padding: CGFloat = 24
      static let titleFont: FontToken = variableFont(family: geistFamily, size: 13, weight: 400)
      static let titleColor = primary
      static let detailFont: FontToken = variableFont(family: geistFamily, size: 12, weight: 400)
      static let detailColor = secondary
      static let pathFont: FontToken = variableFont(family: geistMonoFamily, size: 12, weight: 400)
      static let pathColor = secondary
      static let folderMissing = Icons.Icon(assetName: "FolderX", size: 20, color: secondary)
    }

    enum CloseBox {
      static let areaPadding: CGFloat = 12
      static let fill = Color(hex: 0x2A2220)
      static let stroke = calloutStroke
      static let radius: CGFloat = 8
      static let verticalPadding: CGFloat = 12
      static let horizontalPadding: CGFloat = 14
      static let gap: CGFloat = 10
      static let textGap: CGFloat = 3
      static let icon = Icons.Icon(assetName: "CircleAlert", size: 15, color: Color(hex: 0xF0A070))
      static let titleFont: FontToken = variableFont(family: geistFamily, size: 13, weight: 600)
      static let titleColor = primary
      static let detailFont: FontToken = variableFont(family: geistFamily, size: 12, weight: 400)
      static let detailColor = Color(hex: 0xB7C3CD)
      static let buttonRadius: CGFloat = 6
      static let buttonVerticalPadding: CGFloat = 6
      static let buttonHorizontalPadding: CGFloat = 12
      static let buttonFont: FontToken = variableFont(family: geistFamily, size: 12, weight: 500)
      static let keepFill = Color(hex: 0x2F3A45)
      static let keepColor = primary
      static let closeStroke = calloutStroke
      static let closeColor = danger
    }
  }

  enum Ask {
    static func sendOpacity(isEnabled: Bool) -> Double { isEnabled ? 1 : 0.4 }
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
    static let pausedNoticeFill = Color(hex: 0x1A2129)
    static let pausedNoticeColor = Color(hex: 0xA4B8C7)
    static let pausedNoticeIcon = Icons.Icon(assetName: "Pause", size: 13, color: pausedNoticeColor)
    static let pausedNoticeGap: CGFloat = 10
    static let pausedNoticeVerticalPadding: CGFloat = 8
    static let pausedNoticeHorizontalPadding: CGFloat = 10
    static let recordFill = Color(hex: 0x1F3A30)
    static let recordStroke = Color(hex: 0x2F5A48)
    static let recordColor = Color(hex: 0x83BDA4)
    static let recordFont = variableFont(family: geistFamily, size: 12, weight: 550)
    static let recordIcon = Icons.Icon(assetName: "CircleDot", size: 11, color: recordColor)
    static let recordSpinner = Chat.Spinner(size: 11, lineWidth: 1.5, color: recordColor)
    static let recordGap: CGFloat = 6
    static let recordVerticalPadding: CGFloat = 5
    static let recordHorizontalPadding: CGFloat = 10
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
      switch status {
      case .waiting, .notDelivered: Color(hex: 0xD8BE89)
      case .working: Color(hex: 0xE4C282)
      case .done: Color(hex: 0x8DD9B1)
      case .newReply, .answered: Color(hex: 0xC6E7FF)
      }
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
    static let progressIconSize: CGFloat = 12
    static let progressRowGap: CGFloat = 8
    static let progressGap: CGFloat = 6
    static let progressStroke = Color(hex: 0x34414E)
    static let progressStrokeWidth: CGFloat = 1
    static let progressPadding = EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 0)
    static let failureColor = Color(hex: 0xF0A4AB)
    static let failureDetailColor = sourceColor
    static let progressActionsPadding = EdgeInsets(top: 4, leading: 20, bottom: 0, trailing: 0)
    static let tryAgainFill = Color(hex: 0x192631)
    static let tryAgainStroke = Color(hex: 0x516579)
    static let tryAgainText = Color(hex: 0xDBE9F3)
    static let tryAgainFont = variableFont(family: geistFamily, size: 12, weight: 550)
    static let tryAgainRadius: CGFloat = 4
    static let tryAgainVerticalPadding: CGFloat = 6
    static let tryAgainHorizontalPadding: CGFloat = 10
    static let progressDetailColor = sourceColor

    static func progressIcon(_ mark: RelayProgress.Mark) -> Icons.Icon {
      switch mark {
      case .done: Icons.Icon(assetName: "Check", size: progressIconSize, color: Color(hex: 0x8DD9B1))
      case .waiting: Icons.Icon(assetName: "Hourglass", size: progressIconSize, color: Color(hex: 0xE4C282))
      case .working: Icons.Icon(assetName: "LoaderCircle", size: progressIconSize, color: Color(hex: 0xE4C282))
      case .notDoneYet: Icons.Icon(assetName: "CircleDashed", size: progressIconSize, color: Color(hex: 0xE4C282))
      case .warning: Icons.Icon(assetName: "CircleAlert", size: progressIconSize, color: Color(hex: 0xE4C282))
      case .failed: Icons.Icon(assetName: "X", size: progressIconSize, color: failureColor)
      }
    }
  }

  enum Fonts {
    static let paneSubtitle: FontToken = variableFont(family: geistFamily, size: 10, weight: 400)
    static let taskTitle: FontToken = variableFont(family: geistFamily, size: 15, weight: 400)
    static let taskBadge: FontToken = variableFont(family: geistMonoFamily, size: 12, weight: 400)
    static let filePath: FontToken = variableFont(family: geistMonoFamily, size: 11, weight: 400)
    static let eventTime: FontToken = variableFont(family: geistFamily, size: 10, weight: 400)
    static let lineNumber: FontToken = variableFont(family: geistMonoFamily, size: 10, weight: 400)
    static let sourceLine: FontToken = variableFont(family: geistMonoFamily, size: 12, weight: 400, codeLigatures: true)
    static let liveStatus: FontToken = variableFont(family: geistFamily, size: 11, weight: 400)
    static let jumpToLatest: FontToken = variableFont(family: geistFamily, size: 10, weight: 400)
    static let openIndicator: FontToken = variableFont(family: geistMonoFamily, size: 9, weight: 400)

    static func paneSubtitle(isQuestionSummary: Bool) -> FontToken {
      isQuestionSummary ? questionSummary : paneSubtitle
    }

    private static let questionSummary: FontToken = variableFont(family: geistFamily, size: 11, weight: 400)
  }

  enum Colors {
    static let paneSubtitle = Color(hex: 0x7D98AD)
    static let taskTitle = Color(hex: 0xE0EBF1)
    static let taskBadge = Color(hex: 0xB2DEC9)
    static let eventTime = Color(hex: 0x68879E)
    static let lineNumber = Color(hex: 0x5F8099)
    static let sourceLine = Color(hex: 0xBDCDDF)
    static let liveStatus = Color(hex: 0x789F91)
    static let jumpToLatest = Color(hex: 0x82AAC5)
    static let openIndicator = Color(hex: 0x78AAD0)

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
  }

  enum RightPane {
    private static let primary = Color(hex: 0xE6EDF3)
    private static let secondary = Color(hex: 0x8B9AA6)

    enum Strip {
      static let height: CGFloat = 40
      static let gap: CGFloat = 2
      static let leadingPadding: CGFloat = 12
      static let trailingPadding: CGFloat = 10
      static let stroke = Color(hex: 0x2A3640)
    }

    enum Tab {
      static let gap: CGFloat = 7
      static let horizontalPadding: CGFloat = 12
      static let underlineWidth: CGFloat = 2

      static func icon(_ pane: ChangeStreamPageModel.RightPane, isSelected: Bool) -> Icons.Icon {
        let color = isSelected ? Color(hex: 0x96B7CA) : secondary
        switch pane {
        case .stream: return Icons.Icon(assetName: "ListTree", size: 14, color: color)
        case .terminals: return Icons.Icon(assetName: "SquareTerminal", size: 14, color: color)
        }
      }

      static func font(isSelected: Bool) -> FontToken {
        variableFont(family: geistFamily, size: 12.5, weight: isSelected ? 550 : 400)
      }

      static func color(isSelected: Bool) -> Color { isSelected ? primary : secondary }

      static func underline(isSelected: Bool) -> Color { isSelected ? Color(hex: 0x6CB6FF) : .clear }
    }
  }

  enum FileViewer {
    static let fill = Color(hex: 0x11171D)
    static let padding: CGFloat = 12
    static let gap: CGFloat = 8
    static let toolbarHeight: CGFloat = 34
  }

  enum OpenInButton {
    static let iconSize: CGFloat = 14
  }

  enum WindowHeader {
    private static let secondary = Color(hex: 0x8B9AA6)
    private static let muted = Color(hex: 0x5C6B77)

    static let fill = Sidebar.fill
    static let toggleSize: CGFloat = 15
    static let toggleColor = secondary

    enum Breadcrumb {
      static let gap: CGFloat = 7
      static let repositoryIcon = Icons.Icon(assetName: "FolderGit2", size: 13, color: secondary)
      static let workspaceIcon = Icons.Icon(assetName: "GitBranch", size: 13, color: secondary)
      static let chevron = Icons.Icon(assetName: "ChevronRight", size: 12, color: muted)
      static let repositoryFont = variableFont(family: geistFamily, size: 12.5, weight: 400)
      static let repositoryColor = secondary
      static let workspaceFont = variableFont(family: geistFamily, size: 12.5, weight: 500)
      static let workspaceColor = Color(hex: 0xE6EDF3)
    }

    enum OpenIn {
      static let height: CGFloat = 24
      static let radius: CGFloat = 5
      static let stroke = Sidebar.stroke
      static let appIconPadding: CGFloat = 6
      static let chevron = Icons.Icon(assetName: "ChevronDown", size: 12, color: secondary)
      static let chevronPadding: CGFloat = 5
    }

    enum Compare {
      static let gap: CGFloat = 6
      static let horizontalPadding: CGFloat = 8
      static let font = variableFont(family: geistFamily, size: 12, weight: 400)

      static func icon(isEnabled: Bool) -> Icons.Icon {
        Icons.Icon(assetName: "GitCompare", size: 14, color: color(isEnabled: isEnabled))
      }

      static func color(isEnabled: Bool) -> Color { isEnabled ? secondary : muted }
    }
  }

  enum Stream {
    static let groupGap: CGFloat = 28
    static let itemGap: CGFloat = 24
  }

  enum Workspace {
    static let sidebarWidth: CGFloat = 260
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarMaxWidth: CGFloat = 420
    static let chatWidth: CGFloat = 720
    static let chatMinWidth: CGFloat = 420
    static let chatNarrowScreenMinWidth: CGFloat = 320
    static let resizeHandleWidth: CGFloat = 8
    static let paneToggleAnimation = Animation.snappy(duration: 0.2)
  }

  enum Sidebar {
    static let fill = Color(hex: 0x0E1318)
    static let stroke = Color(hex: 0x2A3640)

    static let headerHeight: CGFloat = 40
    static let headerLeadingPadding: CGFloat = 16
    static let headerTrailingPadding: CGFloat = 10
    static let titleFont = variableFont(family: geistFamily, size: 12.5, weight: 550)
    static let titleColor = Color(hex: 0xE6EDF3)
    static let headerGap: CGFloat = 8
    static let recordingCountFont = variableFont(family: geistFamily, size: 11, weight: 400)
    static let recordingCountColor = Color(hex: 0x789F91)

    static let listGap: CGFloat = 14
    static let listVerticalPadding: CGFloat = 10
    static let listHorizontalPadding: CGFloat = 8
    static let groupGap: CGFloat = 2

    static let groupHeaderHeight: CGFloat = 30
    static let groupHeaderGap: CGFloat = 8
    static let groupHeaderLeadingPadding: CGFloat = 8
    static let groupHeaderTrailingPadding: CGFloat = 6
    static let groupIcon = Icons.Icon(assetName: "FolderGit2", size: 14, color: Color(hex: 0x7D98AD))
    static let groupNameFont = variableFont(family: geistFamily, size: 12.5, weight: 550)
    static let groupNameColor = Color(hex: 0xC9D6DF)
    static let newWorkspaceIcon = Icons.Icon(assetName: "Plus", size: 14, color: Color(hex: 0x8B9AA6))
    static let iconButtonPadding: CGFloat = 5

    static let rowHeight: CGFloat = 32
    static let rowRadius: CGFloat = 5
    static let rowGap: CGFloat = 8
    static let rowLeadingPadding: CGFloat = 26
    static let rowTrailingPadding: CGFloat = 10
    static let selectedRowFill = Color(hex: 0x222A33)
    static let highlightedRowFill = Color(hex: 0x1A2129)
    static let archiveIcon = Icons.Icon(assetName: "Archive", size: 13, color: Color(hex: 0x8B9AA6))
    static let spinner = Chat.Spinner(size: 13, lineWidth: 1.5, color: Color(hex: 0x6CB6FF))

    static func rowIcon(isSelected: Bool) -> Icons.Icon {
      Icons.Icon(assetName: "GitBranch", size: 13, color: isSelected ? Color(hex: 0xC9D6DF) : Color(hex: 0x6B7C89))
    }

    static func rowNameFont(isBold: Bool) -> FontToken {
      variableFont(family: geistFamily, size: 12.5, weight: isBold ? 600 : 400)
    }

    static func rowNameColor(isBold: Bool, isSelected: Bool) -> Color {
      isBold || isSelected ? Color(hex: 0xE6EDF3) : Color(hex: 0xA9B7C2)
    }

    static func pausedRowIcon(isHighlighted: Bool) -> Icons.Icon {
      Icons.Icon(assetName: "CirclePause", size: 13, color: isHighlighted ? Color(hex: 0x6B7C89) : Color(hex: 0x3F4C57))
    }

    static func pausedRowNameColor(isHighlighted: Bool) -> Color {
      isHighlighted ? Color(hex: 0x8B9AA6) : Color(hex: 0x56646F)
    }

    static let recordingDotSize: CGFloat = 6
    static let recordingDotColor = Color(hex: 0x83BDA4)

    struct RowAction {
      let fill: Color
      let stroke: Color
      let icon: Icons.Icon
      let textColor: Color

      static let record = RowAction(
        fill: Color(hex: 0x1F3A30), stroke: Color(hex: 0x3E7A62),
        icon: Icons.Icon(assetName: "CircleDot", size: 11, color: Color(hex: 0x83BDA4)), textColor: Color(hex: 0xB8E0CD))
      static let pause = RowAction(
        fill: Color(hex: 0x26303A), stroke: Color(hex: 0x3A4753),
        icon: Icons.Icon(assetName: "Pause", size: 11, color: Color(hex: 0xC9D6DF)), textColor: Color(hex: 0xC9D6DF))

      static let height: CGFloat = 20
      static let radius: CGFloat = 4
      static let strokeWidth: CGFloat = 1
      static let gap: CGFloat = 4
      static let horizontalPadding: CGFloat = 7
      static let font = variableFont(family: geistFamily, size: 11, weight: 500)
      static let workingOpacity: Double = 0.7

      var spinner: Chat.Spinner { Chat.Spinner(size: icon.size, lineWidth: 1.5, color: icon.color) }

      static func opacity(isWorking: Bool) -> Double {
        isWorking ? workingOpacity : 1
      }
    }

    static func rowAction(isRecord: Bool) -> RowAction {
      isRecord ? .record : .pause
    }

    static let messageFont = variableFont(family: geistFamily, size: 11.5, weight: 400)
    static let messageLineSpacing: CGFloat = 11.5 * (1.4 - 1)
    static let rowMessageInsets = EdgeInsets(top: 0, leading: 47, bottom: 6, trailing: 10)
    static let footerMessageInsets = EdgeInsets(top: 2, leading: 34, bottom: 4, trailing: 10)

    static func messageColor(isFull: Bool) -> Color {
      isFull ? Color(hex: 0xE3B341) : Color(hex: 0xF07178)
    }

    static let footerVerticalPadding: CGFloat = 6
    static let footerLineHeight: CGFloat = 32
    static let footerGap: CGFloat = 8
    static let footerHorizontalPadding: CGFloat = 16
    static let footerIcon = Icons.Icon(assetName: "FolderPlus", size: 14, color: Color(hex: 0x8B9AA6))
    static let recordFolderIcon = Icons.Icon(assetName: "CircleDot", size: 14, color: Color(hex: 0x8B9AA6))
    static let footerFont = variableFont(family: geistFamily, size: 12, weight: 400)
    static let footerColor = Color(hex: 0x8B9AA6)
  }

  enum RenameDialog {
    static let width: CGFloat = 420
    static let padding: CGFloat = 24
    static let gap: CGFloat = 14
    static let fill = Color(hex: 0x1B222A)

    static let headerGap: CGFloat = 10
    static let headerIcon = Icons.Icon(assetName: "Folder", size: 18, color: Color(hex: 0xA9B7C2))
    static let titleFont = variableFont(family: geistFamily, size: 17, weight: 600)
    static let titleColor = Color(hex: 0xE6EDF3)

    static let fieldHeight: CGFloat = 38
    static let fieldHorizontalPadding: CGFloat = 10
    static let fieldRadius: CGFloat = 6
    static let fieldFill = Color(hex: 0x11171D)
    static let fieldFont = variableFont(family: geistFamily, size: 14, weight: 400)

    static func fieldTextColor(isDisabled: Bool) -> Color {
      isDisabled ? Color(hex: 0x6B7C89) : Color(hex: 0xE6EDF3)
    }

    static func fieldStroke(isInvalid: Bool, isDisabled: Bool) -> Color {
      if isDisabled { return Color(hex: 0x2A3640) }
      return isInvalid ? Color(hex: 0xF0A4AB) : Color(hex: 0x6CB6FF)
    }

    static let errorGap: CGFloat = 6
    static let errorIcon = Icons.Icon(assetName: "CircleAlert", size: 13, color: Color(hex: 0xF0A4AB))
    static let errorFont = variableFont(family: geistFamily, size: 12, weight: 400)
    static let errorColor = Color(hex: 0xF0A4AB)
    static let errorLineSpacing: CGFloat = 12 * (1.35 - 1)

    static let detailInsets = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 8)
    static let detailGap: CGFloat = 8
    static let detailRadius: CGFloat = 6
    static let detailFill = Color(hex: 0x11171D)
    static let detailStroke = Color(hex: 0x2A3640)
    static let detailFont = variableFont(family: geistMonoFamily, size: 11.5, weight: 400)
    static let detailColor = Color(hex: 0xC9D6DF)
    static let detailLineSpacing: CGFloat = 11.5 * (1.45 - 1)

    static let copyInsets = EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7)
    static let copyGap: CGFloat = 4
    static let copyRadius: CGFloat = 4
    static let copyStroke = Color(hex: 0x34414E)
    static let copyIcon = Icons.Icon(assetName: "Copy", size: 12, color: Color(hex: 0xA9B7C2))
    static let copyFont = variableFont(family: geistFamily, size: 11.5, weight: 500)
    static let copyColor = Color(hex: 0xA9B7C2)

    static let helperFont = variableFont(family: geistFamily, size: 12, weight: 400)
    static let helperColor = Color(hex: 0x6B7C89)
    static let helperLineSpacing: CGFloat = 12 * (1.4 - 1)

    static let buttonGap: CGFloat = 8
    static let buttonHeight: CGFloat = 32
    static let buttonHorizontalPadding: CGFloat = 14
    static let buttonRadius: CGFloat = 6
    static let buttonContentGap: CGFloat = 6
    static let buttonFont = variableFont(family: geistFamily, size: 13, weight: 500)

    struct ButtonColors {
      let fill: Color
      let text: Color
    }

    private static let dimmedButton = ButtonColors(fill: Color(hex: 0x26303A), text: Color(hex: 0x56646F))

    static func cancelButton(isDimmed: Bool) -> ButtonColors {
      isDimmed ? dimmedButton : ButtonColors(fill: .clear, text: Color(hex: 0xC9D6DF))
    }

    static func primaryButton(isDimmed: Bool) -> ButtonColors {
      isDimmed ? dimmedButton : ButtonColors(fill: Color(hex: 0x6CB6FF), text: Color(hex: 0x0E1318))
    }

    static let savingSpinner = Chat.Spinner(size: 13, lineWidth: 1.5, color: Color(hex: 0x0E1318))
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

  enum RecorderMessage {
    static let width: CGFloat = 600
    static let gap: CGFloat = 12
    static let headlineGap: CGFloat = 8
    static let headlineFont: FontToken = variableFont(family: geistFamily, size: 14, weight: 600)
    static let headlineColor = Color(hex: 0xE6EDF3)
    static let headlineLineSpacing: CGFloat = 14 * (1.4 - 1)
    static let dockFill = Color(hex: 0x191F27)
    static let dockGap: CGFloat = 10
    static let dockFont: FontToken = variableFont(family: geistFamily, size: 11, weight: 400)
    static let dockEvidenceMaxHeight: CGFloat = 320
    static let linkColor = Color(hex: 0x82AAC5)
    static let blockFill = Color(hex: 0x0F1318)
    static let blockStroke = Color(hex: 0x2A3640)
    static let blockRadius: CGFloat = 6
    static let sourceFont: FontToken = variableFont(family: geistMonoFamily, size: 10, weight: 400)
    static let sourceColor = Color(hex: 0x7D98AD)
    static let sourceVerticalPadding: CGFloat = 7
    static let sourceHorizontalPadding: CGFloat = 10
    static let copyGap: CGFloat = 5
    static let copyFont: FontToken = variableFont(family: geistFamily, size: 11, weight: 400)
    static let copyIcon = Icons.Icon(assetName: "Copy", size: 12, color: linkColor)
    static let bodyFont: FontToken = variableFont(family: geistMonoFamily, size: 10.5, weight: 400)
    static let bodyColor = Color(hex: 0xC9D6E0)
    static let bodyLineSpacing: CGFloat = 10.5 * (1.55 - 1)
    static let bodyPadding: CGFloat = 10
    static let buttonGap: CGFloat = 8
    static let buttonFont: FontToken = variableFont(family: geistFamily, size: 12.5, weight: 500)
    static let buttonText = Color(hex: 0xE6EDF3)
    static let primaryButtonFill = Color(hex: 0x2F3A45)
    static let secondaryButtonStroke = Color(hex: 0x3E5260)
    static let buttonRadius: CGFloat = 6
    static let buttonVerticalPadding: CGFloat = 6
    static let buttonHorizontalPadding: CGFloat = 12

    static func color(_ tone: SlipstreamViewer.RecorderMessage.Tone) -> Color {
      switch tone {
      case .neutral: Color(hex: 0x8B9AA6)
      case .warning: Color(hex: 0xFF9F0A)
      case .error: Color(hex: 0xFF6B6B)
      }
    }

    static func headlineIcon(_ message: SlipstreamViewer.RecorderMessage) -> Icons.Icon {
      let color = message.tone == .warning ? Color(hex: 0xF0A070) : color(message.tone)
      return Icons.Icon(assetName: assetName(message.icon), size: 16, color: color)
    }

    static func footerIcon(_ message: SlipstreamViewer.RecorderMessage) -> Icons.Icon {
      Icons.Icon(assetName: assetName(message.icon), size: 13, color: color(message.tone))
    }

    private static func assetName(_ icon: SlipstreamViewer.RecorderMessage.Icon) -> String {
      switch icon {
      case .starting: "LoaderCircle"
      case .restarting: "RefreshCw"
      case .warning: "CircleAlert"
      case .failure: "OctagonX"
      }
    }
  }

  enum CaptureStrip {
    static let fill = Color(hex: 0x1B222A)
    static let stroke = Color(hex: 0x314351)
    static let verticalPadding: CGFloat = 10
    static let horizontalPadding: CGFloat = 20
    static let gap: CGFloat = 6
    static let rowGap: CGFloat = 8
    static let dotSize: CGFloat = 7
    static let labelWidth: CGFloat = 54
    static let detailInset: CGFloat = 77
    static let labelFont: FontToken = variableFont(family: geistMonoFamily, size: 10, weight: 400)
    static let labelColor = Color(hex: 0x7D98AD)
    static let textFont: FontToken = variableFont(family: geistFamily, size: 12, weight: 400)
    static let textColor = Color(hex: 0xDBE9F3)
    static let checkedFont: FontToken = variableFont(family: geistFamily, size: 10, weight: 400)
    static let checkedColor = Color(hex: 0x68879E)
    static let detailFont: FontToken = variableFont(family: geistFamily, size: 11, weight: 400)
    static let detailColor = Color(hex: 0x9EB7CB)

    static func dot(_ dot: CaptureDot) -> Color {
      switch dot {
      case .recording: Color(hex: 0x83BDA4)
      case .attention: Color(hex: 0xD8BE89)
      case .unknown: Color(hex: 0xA4B4C3)
      case .linked: Color(hex: 0xA4D5F1)
      case .noChat: Color(hex: 0x68879E)
      }
    }
  }

  enum Chat {
    struct Spinner {
      let size: CGFloat
      let lineWidth: CGFloat
      let color: Color

      static let arc: CGFloat = 0.7
      static let secondsPerTurn: TimeInterval = 1
    }

    static let fill = Color(hex: 0x12171D)
    static let stroke = Color(hex: 0x2A3640)

    private static let primary = Color(hex: 0xE6EDF3)
    private static let secondary = Color(hex: 0x8B9AA6)
    private static let muted = Color(hex: 0x5E6C78)
    private static let accent = Color(hex: 0x6CB6FF)

    enum TabStrip {
      static let height: CGFloat = 40
      static let gap: CGFloat = 4
      static let horizontalPadding: CGFloat = 16
    }

    enum Tab {
      static let horizontalPadding: CGFloat = 14
      static let gap: CGFloat = 8
      static let underlineWidth: CGFloat = 2
      static let hoverRadius: CGFloat = 6
      static let close = Icons.Icon(assetName: "X", size: 12, color: secondary)
      static let spinner = Spinner(size: 11, lineWidth: 1.5, color: accent)

      static func underline(isSelected: Bool) -> Color { isSelected ? accent : .clear }

      static func fill(isHovered: Bool) -> Color { isHovered ? Color(hex: 0x1C232B) : .clear }

      static func titleFont(isBold: Bool) -> FontToken {
        variableFont(family: geistFamily, size: 12.5, weight: isBold ? 700 : 400)
      }

      static func titleColor(isSelected: Bool, isBold: Bool) -> Color {
        isSelected || isBold ? primary : secondary
      }

      static func link(_ icon: ChatLinkIcon) -> Icons.Icon {
        switch icon {
        case .connected: Icons.Icon(assetName: "Link", size: 12, color: Color(hex: 0x6CB6FF))
        case .waiting: Icons.Icon(assetName: "Link", size: 12, color: Color(hex: 0xD8BE89))
        case .failed: Icons.Icon(assetName: "Unlink", size: 12, color: Color(hex: 0xF0A070))
        }
      }
    }

    enum OutsideChat {
      static let gap: CGFloat = 6
      static let icon = Icons.Icon(assetName: "Link", size: 12, color: secondary)
      static let font: FontToken = variableFont(family: geistFamily, size: 12, weight: 400)
      static let color = secondary
    }

    enum NewTab {
      static let horizontalPadding: CGFloat = 10
      static let plus = Icons.Icon(assetName: "Plus", size: 14, color: secondary)
    }

    enum Transcript {
      static let gap: CGFloat = 14
      static let topPadding: CGFloat = 20
      static let horizontalPadding: CGFloat = 48
      static let bottomPadding: CGFloat = 12
      static let noWorkspaceFont: FontToken = variableFont(family: geistFamily, size: 14, weight: 400)
      static let noWorkspaceColor = muted
    }

    enum Bubble {
      static let fill = Color(hex: 0x232C36)
      static let verticalPadding: CGFloat = 10
      static let horizontalPadding: CGFloat = 16
      static let radius: CGFloat = 8
      static let maxWidth: CGFloat = 520
    }

    enum Relay {
      static let gap: CGFloat = 8
      static let tagGap: CGFloat = 6
      static let tagIcon = Icons.Icon(assetName: "MessageCircle", size: 11, color: Color(hex: 0xA4D5F1))
      static let tagFont: FontToken = variableFont(family: geistMonoFamily, size: 10, weight: 400)
      static let tagColor = Color(hex: 0xA4D5F1)
      static let statusGap: CGFloat = 6
      static let statusFont: FontToken = variableFont(family: geistMonoFamily, size: 10, weight: 400)
      static let detailColor = Color(hex: 0x91A8B9)

      /// A relay the agent hasn't read is faded.
      static func opacity(_ status: RelayStatus?) -> Double { status == nil ? 1 : 0.55 }

      static func icon(_ status: RelayStatus) -> Icons.Icon {
        switch status {
        case .waiting: Icons.Icon(assetName: "Hourglass", size: 12, color: statusColor(status))
        case .notDelivered: Icons.Icon(assetName: "X", size: 12, color: statusColor(status))
        }
      }

      static func statusColor(_ status: RelayStatus) -> Color {
        switch status {
        case .waiting: Color(hex: 0xE4C282)
        case .notDelivered: Color(hex: 0xF0A4AB)
        }
      }
    }

    enum Paragraph {
      static let font: FontToken = variableFont(family: geistFamily, size: 14, weight: 400)
      static let color = primary
      static let lineSpacing: CGFloat = 14 * (1.65 - 1)
      static let inlineCodeFont: FontToken = variableFont(family: geistMonoFamily, size: 12, weight: 400)
      static let inlineCodeColor = secondary

      /// Inline `code` runs take the code font and colour and bold runs the bold weight of `base`;
      /// the rest keeps the view's font. A variable font ignores the bold intent on its own.
      static func styled(_ text: AttributedString, base: FontToken, scale: CGFloat) -> AttributedString {
        var text = text
        for run in text.runs {
          guard let intent = run.inlinePresentationIntent else { continue }
          if intent.contains(.code) {
            text[run.range].font = inlineCodeFont.font(scale: scale)
            text[run.range].foregroundColor = inlineCodeColor
          } else if intent.contains(.stronglyEmphasized) {
            text[run.range].font = base.bold.font(scale: scale)
          }
        }
        return text
      }
    }

    /// Not drawn in the mockups; sized against the 14pt paragraph.
    enum Heading {
      static let color = primary

      static func font(level: Int) -> FontToken {
        let size: CGFloat = switch level {
        case 1: 20
        case 2: 17
        case 3: 15
        default: 14
        }
        return variableFont(family: geistFamily, size: size, weight: 600)
      }
    }

    /// Not drawn in the mockups.
    enum List {
      static let itemGap: CGFloat = 6
      static let markerGap: CGFloat = 8
      static let markerMinWidth: CGFloat = 14
      static let markerColor = secondary

      static func indent(depth: Int) -> CGFloat { CGFloat(depth) * 20 }
    }

    /// Not drawn in the mockups.
    enum Quote {
      static let color = secondary
      static let barColor = stroke
      static let barWidth: CGFloat = 3
      static let leadingPadding: CGFloat = 14
    }

    /// Not drawn in the mockups.
    enum Rule {
      static let color = stroke
      static let height: CGFloat = 1
    }

    /// Not drawn in the mockups; sized to sit with the tool targets.
    enum CodeBlock {
      static let font: FontToken = variableFont(family: geistMonoFamily, size: 12, weight: 400, codeLigatures: true)
      static let color = primary
      static let fill = Bubble.fill
      static let padding: CGFloat = 12
      static let radius: CGFloat = 6
    }

    enum TurnFooter {
      static let gap: CGFloat = 12
      static let font: FontToken = variableFont(family: geistFamily, size: 12, weight: 400)
      static let color = muted
      static let copy = Icons.Icon(assetName: "Copy", size: 13, color: muted)
      static let more = Icons.Icon(assetName: "Ellipsis", size: 13, color: muted)
    }

    enum Thinking {
      static let gap: CGFloat = 8
      static let icon = Icons.Icon(assetName: "Brain", size: 13, color: secondary)
      static let labelFont: FontToken = variableFont(family: geistFamily, size: 13, weight: 400)
      static let labelColor = secondary
      static let bodyFont: FontToken = variableFont(family: geistFamily, size: 13.5, weight: 400)
      static let bodyColor = muted
      static let bodyLineSpacing: CGFloat = 13.5 * (1.65 - 1)

      static func chevron(isExpanded: Bool) -> Icons.Icon {
        Icons.Icon(assetName: isExpanded ? "ChevronDown" : "ChevronRight", size: 12, color: muted)
      }
    }

    enum ToolCall {
      static let gap: CGFloat = 8
      static let verbFont: FontToken = variableFont(family: geistFamily, size: 12.5, weight: 400)
      static let verbColor = muted
      static let detailFont = Paragraph.inlineCodeFont
      static let detailColor = muted
      static let spinner = Spinner(size: 11, lineWidth: 1.5, color: secondary)

      static func icon(_ kind: ChatToolKind) -> Icons.Icon {
        let assetName = switch kind {
        case .edit: "Pencil"
        case .run: "Terminal"
        case .read: "FileText"
        case .other: "Wrench"
        }
        return Icons.Icon(assetName: assetName, size: 13, color: muted)
      }

      static func chevron(isExpanded: Bool) -> Icons.Icon {
        Icons.Icon(assetName: isExpanded ? "ChevronDown" : "ChevronRight", size: 12, color: muted)
      }
    }

    enum WorkingStatus {
      static let gap: CGFloat = 8
      static let topPadding: CGFloat = 4
      static let font = ToolCall.verbFont
      static let color = secondary
      static let spinner = Spinner(size: 12, lineWidth: 1.6, color: accent)
    }

    enum StartError {
      static let fill = Color(hex: 0x2A2220)
      static let stroke = Color(hex: 0x5C3B32)
      static let gap: CGFloat = 10
      static let headerGap: CGFloat = 8
      static let verticalPadding: CGFloat = 14
      static let horizontalPadding: CGFloat = 16
      static let radius: CGFloat = 8
      static let alert = Icons.Icon(assetName: "CircleAlert", size: 15, color: Color(hex: 0xF0A070))
      static let titleFont: FontToken = variableFont(family: geistFamily, size: 14, weight: 600)
      static let titleColor = primary
      static let tryAgainFill = Color(hex: 0x2F3A45)
      static let tryAgainVerticalPadding: CGFloat = 6
      static let tryAgainHorizontalPadding: CGFloat = 12
      static let tryAgainRadius: CGFloat = 6
      static let tryAgainFont: FontToken = variableFont(family: geistFamily, size: 12.5, weight: 500)
      static let tryAgainColor = primary
    }

    enum MessageBox {
      static let areaHorizontalPadding: CGFloat = 24
      static let areaBottomPadding: CGFloat = 20
      static let fill = FeedPane.fill
      static let stroke = Chat.stroke
      static let strokeWidth: CGFloat = 1
      static let topPadding: CGFloat = 14
      static let horizontalPadding: CGFloat = 16
      static let bottomPadding: CGFloat = 12
      static let radius: CGFloat = 10
      static let height: CGFloat = 120
      static let font = Paragraph.font
      static let color = primary

      static func opacity(isEnabled: Bool) -> Double { isEnabled ? 1 : 0.55 }

      static func placeholderColor(isEnabled: Bool) -> Color {
        isEnabled ? muted : Color(hex: 0x3E4954)
      }
    }

    enum AgentPicker {
      static let gap: CGFloat = 6
      static let font: FontToken = variableFont(family: geistFamily, size: 12.5, weight: 500)
      static let color = primary
      static let chevron = Icons.Icon(assetName: "ChevronDown", size: 12, color: secondary)
    }

    enum Send {
      static let fill = StartError.tryAgainFill
      static let radius: CGFloat = 6
      static let size: CGFloat = 26
      static let arrow = Icons.Icon(assetName: "ArrowUp", size: 14, color: secondary)
      static let stopFill = primary
      static let stopSquareFill = Chat.fill
      static let stopSquareSize: CGFloat = 9
      static let stopSquareRadius: CGFloat = 1.5
    }
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

    static let fileText = Icon(assetName: "FileText", size: 12, color: Color(hex: 0x789FB9))
    static let activity = Icon(assetName: "Activity", size: 13, color: Color(hex: 0x83BDA4))

    static func pin(isPinned: Bool) -> Icon {
      Icon(assetName: "Pin", size: 13, color: isPinned ? Color(hex: 0x9ACBB8) : Color(hex: 0x7F96A6))
    }
  }
}

extension View {
  func font(_ token: DesignTokens.FontToken) -> some View {
    modifier(ScaledFont(token: token))
  }
}

private struct ScaledFont: ViewModifier {
  let token: DesignTokens.FontToken
  @Environment(\.fontScale) private var scale

  func body(content: Content) -> some View {
    content.font(token.font(scale: scale))
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
