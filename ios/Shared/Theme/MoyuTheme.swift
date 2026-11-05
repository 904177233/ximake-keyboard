//
//  MoyuTheme.swift
//  墨语 · 主题
//
//  双色主题：一种底色系，一种主色。主色只出现在 AI 圆钮、发送键、首选候选的下划线和选中态上，
//  其余全部是中性色。App 和键盘共用这一份，所有颜色都从这里取，界面代码里不写色值。
//

import SwiftUI
import UIKit

/// 主题。
public enum MoyuThemeID: String, CaseIterable, Codable, Sendable, Identifiable {
    case ink, coral, indigo, violet, sky, pine

    public var id: String { rawValue }

    /// 中文名。
    public var title: String {
        switch self {
        case .ink: return "墨黑"
        case .coral: return "珊瑚"
        case .indigo: return "靛蓝"
        case .violet: return "星紫"
        case .sky: return "天青"
        case .pine: return "松绿"
        }
    }

    /// 浅色下的主色。
    var accentHex: UInt32 {
        switch self {
        case .ink: return 0x141414
        case .coral: return 0xD97757
        case .indigo: return 0x4D6BFE
        case .violet: return 0x7A5AF8
        case .sky: return 0x2AA5E8
        case .pine: return 0x10A37F
        }
    }
}

/// 一套算好的颜色。
public struct MoyuPalette {
    /// 键盘底色。
    public let canvas: UIColor
    /// 功能键。
    public let function: UIColor
    /// 字母键。
    public let key: UIColor
    /// 字母键按下。
    public let keyPressed: UIColor
    /// 功能键按下。
    public let functionPressed: UIColor
    /// 主文字。
    public let text: UIColor
    /// 次要文字。
    public let secondary: UIColor
    /// 主色。
    public let accent: UIColor
    /// 主色上的文字。
    public let onAccent: UIColor
    /// 用主色写的文字（首选候选、选中态）。
    public let accentText: UIColor
    /// 分隔线。
    public let line: UIColor
    /// 键帽下沿。
    public let edge: UIColor

    /// 计算颜色。
    /// - Parameters:
    ///   - theme: 主题。
    ///   - dark: 是否深色。
    public init(theme: MoyuThemeID, dark: Bool) {
        let base = UIColor(hex: theme.accentHex)
        let isInk = theme == .ink
        if dark {
            accent = isInk ? UIColor(hex: 0xF1F1EE) : base.mixed(with: .white, amount: 0.12)
            onAccent = isInk ? UIColor(hex: 0x111111) : .white
            accentText = isInk ? UIColor(hex: 0xF1F1EE) : base.mixed(with: .white, amount: 0.32)
            canvas = UIColor(hex: 0x141518).mixed(with: base, amount: isInk ? 0 : 0.05)
            function = UIColor(hex: 0x27282D).mixed(with: base, amount: isInk ? 0 : 0.09)
            key = UIColor(hex: 0x3B3C42).mixed(with: base, amount: isInk ? 0 : 0.05)
            keyPressed = UIColor(hex: 0x55565C).mixed(with: base, amount: isInk ? 0 : 0.10)
            functionPressed = key
            text = UIColor(hex: 0xF3F3F5)
            secondary = UIColor(hex: 0xA2A4AC)
            line = UIColor.white.withAlphaComponent(0.11)
            edge = UIColor.black.withAlphaComponent(0.55)
        } else {
            accent = base
            onAccent = .white
            accentText = isInk ? base : base.mixed(with: .black, amount: 0.22)
            canvas = UIColor(hex: 0xE6E7EA).mixed(with: base, amount: isInk ? 0 : 0.06)
            function = UIColor(hex: 0xCBCDD3).mixed(with: base, amount: isInk ? 0 : 0.13)
            key = .white
            keyPressed = UIColor.white.mixed(with: base, amount: isInk ? 0.10 : 0.14)
            functionPressed = .white
            text = UIColor(hex: 0x15161A)
            secondary = UIColor(hex: 0x6E7078).mixed(with: base, amount: isInk ? 0 : 0.14)
            line = UIColor(red: 20 / 255, green: 22 / 255, blue: 30 / 255, alpha: 0.13)
            edge = UIColor(red: 20 / 255, green: 22 / 255, blue: 30 / 255, alpha: 0.24)
        }
    }
}

public extension UIColor {

    /// 用 0xRRGGBB 构造。
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255,
                  green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }

    /// 和另一种颜色按比例混合。
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        var red1: CGFloat = 0, green1: CGFloat = 0, blue1: CGFloat = 0, alpha1: CGFloat = 0
        var red2: CGFloat = 0, green2: CGFloat = 0, blue2: CGFloat = 0, alpha2: CGFloat = 0
        getRed(&red1, green: &green1, blue: &blue1, alpha: &alpha1)
        other.getRed(&red2, green: &green2, blue: &blue2, alpha: &alpha2)
        return UIColor(red: red1 + (red2 - red1) * amount,
                       green: green1 + (green2 - green1) * amount,
                       blue: blue1 + (blue2 - blue1) * amount,
                       alpha: alpha1 + (alpha2 - alpha1) * amount)
    }
}

/// 小形象：空格键右边那个小图案。
public enum MascotSymbol: String, CaseIterable, Codable, Sendable, Identifiable {
    case drop, sparkle, star, moon, leaf, fish, cat, paw, custom

    public var id: String { rawValue }

    /// 中文名。
    public var title: String {
        switch self {
        case .drop: return "墨滴"
        case .sparkle: return "星芒"
        case .star: return "星星"
        case .moon: return "月牙"
        case .leaf: return "叶子"
        case .fish: return "小鱼"
        case .cat: return "小猫"
        case .paw: return "爪印"
        case .custom: return "我的图"
        }
    }

    /// SF Symbol 名字；自定义图片为 nil。
    public var systemName: String? {
        switch self {
        case .drop: return "drop.fill"
        case .sparkle: return "sparkle"
        case .star: return "star.fill"
        case .moon: return "moon.fill"
        case .leaf: return "leaf.fill"
        case .fish: return "fish.fill"
        case .cat: return "cat.fill"
        case .paw: return "pawprint.fill"
        case .custom: return nil
        }
    }
}

/// 键盘偏好。App 和键盘都读写这一份。
public struct KeyboardPrefs: Codable, Equatable, Sendable {

    /// 键盘布局。
    public enum Layout: String, Codable, Sendable, CaseIterable {
        case qwerty, nineKey

        public var title: String { self == .qwerty ? "26 键" : "九宫格" }
    }

    /// 键盘高度。
    public enum Height: String, Codable, Sendable, CaseIterable {
        case low, standard, tall

        public var title: String {
            switch self {
            case .low: return "矮"
            case .standard: return "标准"
            case .tall: return "高"
            }
        }
    }

    public var theme: MoyuThemeID = .ink
    public var mascot: MascotSymbol = .drop
    public var layout: Layout = .qwerty
    public var height: Height = .standard
    public var haptics: Bool = true
    public var keySound: Bool = false
    public var fuzzyPinyin: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case theme, mascot, layout, height, haptics, keySound, fuzzyPinyin
    }

    /// 容错解码：缺字段或值不认识都用默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? container.decodeIfPresent(MoyuThemeID.self, forKey: .theme)) ?? .ink
        mascot = (try? container.decodeIfPresent(MascotSymbol.self, forKey: .mascot)) ?? .drop
        layout = (try? container.decodeIfPresent(Layout.self, forKey: .layout)) ?? .qwerty
        height = (try? container.decodeIfPresent(Height.self, forKey: .height)) ?? .standard
        haptics = (try? container.decodeIfPresent(Bool.self, forKey: .haptics)) ?? true
        keySound = (try? container.decodeIfPresent(Bool.self, forKey: .keySound)) ?? false
        fuzzyPinyin = (try? container.decodeIfPresent(Bool.self, forKey: .fuzzyPinyin)) ?? true
    }

    /// 读取。
    public static func load(from store: SharedStore = .shared) -> KeyboardPrefs {
        guard let data = store.data(forKey: SharedStoreKey.keyboardPrefs),
              let decoded = try? JSONDecoder().decode(KeyboardPrefs.self, from: data) else {
            return KeyboardPrefs()
        }
        return decoded
    }

    /// 保存。
    public func save(to store: SharedStore = .shared) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        store.setData(data, forKey: SharedStoreKey.keyboardPrefs)
    }
}

public extension UIColor {
    /// 转成 SwiftUI 颜色。
    var color: Color { Color(uiColor: self) }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = MoyuPalette(theme: .ink, dark: false)
}

public extension EnvironmentValues {
    /// 当前调色板。
    var palette: MoyuPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
