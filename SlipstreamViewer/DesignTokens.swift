import AppKit
import SwiftUI

enum CardEmphasis: Equatable, Sendable {
  case newest, other
}

enum DesignTokens {

  private static let geistFamily = "Geist"
  private static let geistMonoFamily = "Geist Mono"

  private static func variableFont(family: String, size: CGFloat, weight: CGFloat) -> Font {
    let wghtAxis = 0x7767_6874 as UInt32
    let descriptor = NSFontDescriptor(fontAttributes: [
      .name: family,
      .variation: [NSNumber(value: wghtAxis): NSNumber(value: Double(weight))],
    ])
    guard let nsFont = NSFont(descriptor: descriptor, size: size) else {
      return .system(size: size)
    }
    return Font(nsFont)
  }

  enum Fonts {
    static let paneTitle: Font = variableFont(family: geistFamily, size: 16, weight: 550)
    static let paneSubtitle: Font = variableFont(family: geistFamily, size: 10, weight: 400)
    static let taskTitle: Font = variableFont(family: geistFamily, size: 15, weight: 550)
    static let taskBadge: Font = variableFont(family: geistMonoFamily, size: 12, weight: 400)
    static let filePath: Font = variableFont(family: geistMonoFamily, size: 11, weight: 400)
    static let eventTime: Font = variableFont(family: geistFamily, size: 10, weight: 400)
    static let lineNumber: Font = variableFont(family: geistMonoFamily, size: 10, weight: 400)
    static let sourceLine: Font = variableFont(family: geistMonoFamily, size: 12, weight: 400)
    static let liveStatus: Font = variableFont(family: geistFamily, size: 11, weight: 400)
    static let jumpToLatest: Font = variableFont(family: geistFamily, size: 10, weight: 400)
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

    static func filePath(_ emphasis: CardEmphasis) -> Color {
      switch emphasis {
      case .newest: Color(hex: 0xA2CBE3)
      case .other: Color(hex: 0x8DA9BD)
      }
    }
  }

  enum FeedPane {
    static let fill = Color(hex: 0x191F27)
    static let stroke = Color(hex: 0x405562)
    static let headerHeight: CGFloat = 52
    static let horizontalPadding: CGFloat = 20
    static let headerGap: CGFloat = 10
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
    static let marker = Color(hex: 0x4B9CDA)
    static let markerWidth: CGFloat = 3
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
      let systemName: String
      let size: CGFloat
      let color: Color
    }

    static let listTree = Icon(systemName: "list.bullet.indent", size: 15, color: Color(hex: 0x96B7CA))
    static let fileText = Icon(systemName: "doc.text", size: 12, color: Color(hex: 0x789FB9))
    static let activity = Icon(systemName: "waveform.path.ecg", size: 13, color: Color(hex: 0x83BDA4))
    static let pinPinned = Icon(systemName: "pin", size: 13, color: Color(hex: 0x9ACBB8))
    static let pinIdle = Icon(systemName: "pin", size: 13, color: Color(hex: 0x7F96A6))
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
