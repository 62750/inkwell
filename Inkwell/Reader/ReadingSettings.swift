import Foundation
import UIKit

// MARK: - 阅读设置

enum ReaderTheme: String, Codable, CaseIterable, Sendable {
    case paper, sepia, night, green, black, gray

    var background: UIColor {
        switch self {
        case .paper: return UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        case .sepia: return UIColor(red: 0.94, green: 0.89, blue: 0.79, alpha: 1)
        case .night: return UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)
        case .green: return UIColor(red: 0.80, green: 0.89, blue: 0.81, alpha: 1)
        case .black: return .black
        case .gray: return UIColor(white: 0.16, alpha: 1)
        }
    }

    var textColor: UIColor {
        switch self {
        case .paper: return UIColor(white: 0.13, alpha: 1)
        case .sepia: return UIColor(red: 0.28, green: 0.22, blue: 0.14, alpha: 1)
        case .night: return UIColor(white: 0.76, alpha: 1)
        case .green: return UIColor(red: 0.13, green: 0.20, blue: 0.14, alpha: 1)
        case .black: return UIColor(white: 0.72, alpha: 1)
        case .gray: return UIColor(white: 0.82, alpha: 1)
        }
    }

    var secondaryColor: UIColor { textColor.withAlphaComponent(0.55) }
    var isDark: Bool { self == .night || self == .black || self == .gray }
    var label: String {
        switch self {
        case .paper: return "纸白"
        case .sepia: return "羊皮"
        case .night: return "夜间"
        case .green: return "护眼"
        case .black: return "纯黑"
        case .gray: return "深灰"
        }
    }
}

enum PageTurnMode: String, Codable, CaseIterable, Sendable {
    case scroll          // 上下滚动
    case scrollHorizontal // 左右滚动
    case pageCurl        // 翻页（滑动）
    case none            // 覆盖

    var label: String {
        switch self {
        case .scroll: return "上下滚动"
        case .scrollHorizontal: return "水平滚动"
        case .pageCurl: return "仿真翻页"
        case .none: return "无动画"
        }
    }
}

enum ComicLayoutMode: String, Codable, CaseIterable, Sendable {
    case vertical        // 条漫：纵向连续
    case pageHorizontal  // 页漫：左右翻页
    case doublePage      // 双页
    case rightToLeft     // 日漫右→左

    var label: String {
        switch self {
        case .vertical: return "条漫纵向"
        case .pageHorizontal: return "页漫翻页"
        case .doublePage: return "双页"
        case .rightToLeft: return "日漫右开"
        }
    }
}

struct ReadingSettings: Codable, Equatable, Sendable {
    var fontSize: CGFloat = 19
    var lineHeightMultiple: CGFloat = 1.75
    var fontFamily: String = "system"
    var theme: ReaderTheme = .paper
    var turnMode: PageTurnMode = .pageCurl
    var comicLayout: ComicLayoutMode = .vertical
    var paragraphSpacing: CGFloat = 0.6
    var firstLineIndent: Bool = true
    var letterSpacing: CGFloat = 0.3
    var marginH: CGFloat = 20
    var marginV: CGFloat = 16
    var justify: Bool = true
    var showProgress: Bool = true
    var showClock: Bool = true
    var autoNightMode: Bool = false
    var keepScreenOn: Bool = true
    var comicPageGap: CGFloat = 0
    var comicFitWidth: Bool = true
    var preloadCount: Int = 6

    static let `default` = ReadingSettings()

    var uiFont: UIFont {
        switch fontFamily {
        case "serif":
            return UIFont(name: "Songti SC", size: fontSize)
                ?? UIFont(name: "Georgia", size: fontSize)
                ?? UIFont.systemFont(ofSize: fontSize)
        case "kai":
            return UIFont(name: "Kaiti SC", size: fontSize)
                ?? UIFont.systemFont(ofSize: fontSize)
        case "hei":
            return UIFont(name: "PingFang SC", size: fontSize)
                ?? UIFont.systemFont(ofSize: fontSize)
        default:
            return UIFont.systemFont(ofSize: fontSize)
        }
    }

    static let fontOptions: [(id: String, name: String)] = [
        ("system", "系统"),
        ("hei", "黑体"),
        ("serif", "宋体"),
        ("kai", "楷体")
    ]
}

// MARK: - 段落样式

enum ParagraphStyleBuilder {

    static func attributed(_ text: String, settings: ReadingSettings,
                           indent: Bool = true) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = settings.lineHeightMultiple
        style.paragraphSpacing = settings.fontSize * settings.paragraphSpacing
        style.firstLineHeadIndent = indent && settings.firstLineIndent ? settings.fontSize * 2 : 0
        style.headIndent = 0
        style.alignment = settings.justify ? .justified : .natural
        style.lineBreakMode = .byWordWrapping
        // 中文避头尾
        style.lineBreakStrategy = []
        style.hyphenationFactor = 0

        let attrs: [NSAttributedString.Key: Any] = [
            .font: settings.uiFont,
            .foregroundColor: settings.theme.textColor,
            .paragraphStyle: style,
            .kern: settings.letterSpacing
        ]

        // 段落之间空行：把 \n 变成 \n 后面正常，靠 paragraphSpacing 生效
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return NSAttributedString(string: normalized, attributes: attrs)
    }
}
