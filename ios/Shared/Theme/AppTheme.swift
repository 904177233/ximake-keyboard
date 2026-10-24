//
//  AppTheme.swift
//  墨语（Moyu）· 共享层 · Theme
//
//  模块职责：
//      定义「6 套双色主题」的数据模型 `AppTheme`（浅色值 + 深色推导值），
//      作为主题配色的**唯一运行时真相源**。主题只覆盖 6 个语义色：
//      accent（主色）、tint（候选栏 / AI 条浅底）、tint2（功能键底）、
//      deep（浅底上的主色深版文字）、sub（候选词副文字）、canvas（键盘整体背景）。
//
//  依赖：
//      SwiftUI（Color）、UIKit（UIColor 动态色）；
//      Color(hex:) / UIColor(hex:) —— 定义在同目录 `Theme.swift` 的 public extension；
//      design/tokens.json 的 `theme.presets` 组（数值唯一真相源，改色先改 tokens）。
//
//  使用方：
//      `ios/Shared/Theme/ThemeStore.swift`（持久化与当前主题）；
//      宿主 App `ios/AIKeyboard/Settings/ThemeSettingsView.swift`（2 列主题网格）、
//      `ios/AIKeyboard/Settings/ThemePreviewCard.swift`（键盘等比预览）、
//      `ios/AIKeyboard/Settings/AppearanceView.swift`（外观页显示当前主题名）；
//      键盘扩展 `ios/AIKeyboardExtension/Views/KMMascot.swift`（经 `ThemeStore` 取当前主题），
//      以及键盘根视图渲染的 4 处主色：候选首选字底 / AI 选中胶囊 / 对话旋钮 / 回车键。
//
//  约束（design/05 §0、§1.1）：
//      1) 零第三方素材，默认形象只能是几何符号（本文件不涉及形象，见 extension 侧 KMMascot.swift）。
//      2) 所有颜色必须来自 Theme / AppTheme，视图里禁止裸写色值。
//      3) 主题**不改** `Theme` 的静态常量，避免破坏编译期常量语义与一致性检查脚本。
//
//  深色推导规则（design/05 §1.2）：
//      accent   = 浅色 accent 与白色混合 12%（亮度提升，在深底上可读）
//      canvas   = 统一 #1C1C1E
//      tint     = accent(深色) + 22% alpha（等价于深底上叠一层主色微光）
//      tint2    = accent(深色) + 36% alpha（功能键需要比 tint 更实一点）
//      deep     = accent 与白色混合 45%（浅底深字反过来要变浅才能读）
//      sub      = accent 与白色混合 82%，再叠 60% alpha（副文字弱于主文字）
//      textOnAccent 始终 #FFFFFF（由 Theme.textOnAccent 提供，本文件不再重复）
//
//  tokens: 1.0
//

import SwiftUI
import UIKit

/// 一套双色主题。
///
/// 用 `AppTheme.preset(_:)` 从 6 个内置预设构造，或由 `ThemeStore` 为自定义形象
/// 构造一个 `id == "custom"` 的实例（配色沿用默认主题）。
///
/// ```swift
/// let theme = AppTheme.default
/// Rectangle().fill(theme.tint)          // 候选栏 / AI 条底色
/// Circle().fill(theme.accent)           // 对话旋钮
/// ```
public struct AppTheme: Identifiable, Equatable, Sendable {

    // MARK: - 预设

    /// 6 个内置主题预设。
    ///
    /// `rawValue` 即主题 id，会写进 `ThemeStore.currentThemeID` 与
    /// `SharedStoreKey.themeCurrent`，因此**不可改名**（改名会让老用户回退到默认主题）。
    public enum Preset: String, CaseIterable, Codable, Sendable {
        /// 墨黑 —— ChatGPT 系。
        case ink
        /// 珊瑚 —— Claude 系。
        case coral
        /// 靛蓝 —— DeepSeek 系（默认主题）。
        case indigo
        /// 星紫 —— Gemini 系。
        case violet
        /// 天青 —— Kimi 系。
        case sky
        /// 松绿 —— 豆包 / 千问系。
        case pine

        /// 主题显示名（中文，2 字，用在设置页网格与键盘内选择器）。
        public var displayName: String {
            switch self {
            case .ink:
                return "墨黑"
            case .coral:
                return "珊瑚"
            case .indigo:
                return "靛蓝"
            case .violet:
                return "星紫"
            case .sky:
                return "天青"
            case .pine:
                return "松绿"
            }
        }

        /// 品牌系备注（设置页显示在主题名下方，例如「ChatGPT 系」）。
        ///
        /// 仅作视觉风格说明，**不表示官方合作**（见 docs/11 版权边界）。
        public var brandNote: String {
            switch self {
            case .ink:
                return "ChatGPT 系"
            case .coral:
                return "Claude 系"
            case .indigo:
                return "DeepSeek 系"
            case .violet:
                return "Gemini 系"
            case .sky:
                return "Kimi 系"
            case .pine:
                return "豆包 / 千问系"
            }
        }
    }

    // MARK: - 字段

    /// 主题 id。预设为 `Preset.rawValue`（`"ink"`/`"coral"`/…），
    /// 自定义形象主题固定为 `"custom"`。
    public let id: String

    /// 显示名。预设为主题中文名（墨黑 / 珊瑚 / …）；
    /// 自定义形象主题为用户设置的 `ThemeStore.customMascotName`（默认「我的形象」）。
    public let name: String

    /// 品牌备注（只有预设才有，自定义形象主题为 `nil`）。
    public let brandNote: String?

    /// 主色。只允许出现在 4 处：候选栏首选字背景、AI 工具条选中胶囊、
    /// 对话旋钮、回车键（design/05 §1.1）。深色模式下自动提亮。
    public let accent: Color

    /// 候选栏 / AI 工具条浅底。
    public let tint: Color

    /// 功能键底（⌫、空格、123、换行等）。
    public let tint2: Color

    /// 浅底上的主色深版文字（例如 `tint` 底上的强调字）。
    public let deep: Color

    /// 候选词副文字（未选中的候选、拼音串）。
    public let sub: Color

    /// 键盘整体背景。
    public let canvas: Color

    // MARK: - 构造

    /// 直接构造一套主题（`ThemeStore` 为自定义形象拼装时使用）。
    ///
    /// - Parameters:
    ///   - id: 主题 id，预设用 `Preset.rawValue`，自定义形象用 `"custom"`。
    ///   - name: 显示名。
    ///   - brandNote: 品牌备注，预设才有。
    ///   - accent: 主色（动态色）。
    ///   - tint: 候选栏 / AI 条浅底（动态色）。
    ///   - tint2: 功能键底（动态色）。
    ///   - deep: 浅底上的主色深版文字（动态色）。
    ///   - sub: 候选词副文字（动态色）。
    ///   - canvas: 键盘整体背景（动态色）。
    public init(
        id: String,
        name: String,
        brandNote: String? = nil,
        accent: Color,
        tint: Color,
        tint2: Color,
        deep: Color,
        sub: Color,
        canvas: Color
    ) {
        self.id = id
        self.name = name
        self.brandNote = brandNote
        self.accent = accent
        self.tint = tint
        self.tint2 = tint2
        self.deep = deep
        self.sub = sub
        self.canvas = canvas
    }

    // MARK: - 预设工厂

    /// 从预设构造主题。
    ///
    /// 浅色值直接来自 `design/tokens.json` 的 `theme.presets.<id>`；
    /// 深色值按 design/05 §1.2 规则从浅色值推导（本文件已算好两套 hex）。
    ///
    /// - Parameter preset: 6 个内置预设之一。
    /// - Returns: 可跟随系统深浅色自动切换的 `AppTheme`。
    public static func preset(_ preset: Preset) -> AppTheme {
        let p = palette(for: preset)
        return AppTheme(
            id: preset.rawValue,
            name: preset.displayName,
            brandNote: preset.brandNote,
            accent: adaptive(p.accent, p.accentDark),
            tint: adaptive(p.tint, p.tintDark),
            tint2: adaptive(p.tint2, p.tint2Dark),
            deep: adaptive(p.deep, p.deepDark),
            sub: adaptive(p.sub, p.subDark),
            canvas: adaptive(p.canvas, p.canvasDark)
        )
    }

    /// 全部预设，顺序即展示顺序（墨黑 → 珊瑚 → 靛蓝 → 星紫 → 天青 → 松绿）。
    public static var allPresets: [AppTheme] {
        Preset.allCases.map { AppTheme.preset($0) }
    }

    /// 默认主题（靛蓝 · DeepSeek 系）。
    ///
    /// 用于：首次启动、主题 id 找不到、配置损坏。
    public static var `default`: AppTheme {
        AppTheme.preset(.indigo)
    }

    /// 按主题 id 查找预设。
    ///
    /// - Parameter id: 主题 id（`Preset.rawValue`）。
    /// - Returns: 命中返回该主题，未命中（含 `"custom"`）返回 `nil`。
    public static func preset(withID id: String) -> AppTheme? {
        guard let preset = Preset(rawValue: id) else { return nil }
        return AppTheme.preset(preset)
    }

    /// 构造「自定义形象」主题：配色沿用默认主题，只替换 id / 名称。
    ///
    /// - Parameter mascotName: 用户为自定义形象起的名字，空串时用「我的形象」。
    /// - Returns: `id == "custom"` 的主题。
    public static func custom(mascotName: String) -> AppTheme {
        let base = AppTheme.default
        let trimmed = mascotName.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppTheme(
            id: AppTheme.customID,
            name: trimmed.isEmpty ? "我的形象" : trimmed,
            brandNote: nil,
            accent: base.accent,
            tint: base.tint,
            tint2: base.tint2,
            deep: base.deep,
            sub: base.sub,
            canvas: base.canvas
        )
    }

    /// 自定义形象主题的固定 id（`ThemeStore` 用它判断「当前是否为自定义形象」）。
    public static let customID = "custom"

    /// 是否为自定义形象主题。
    public var isCustom: Bool {
        id == AppTheme.customID
    }

    // MARK: - 深色自适应

    /// 构造一个跟随系统深浅色切换的 `Color`。
    ///
    /// 与 `Theme.adaptive(_:_:)` 同名同实现，但那份是 `Theme` 的 `private` 工具，
    /// 跨文件不可见；这里复制一份文件内私有版本，**不改 Theme.swift 的可见性**
    /// （改可见性会影响一致性检查脚本对 Theme 公开面与行数的统计）。
    ///
    /// - Parameters:
    ///   - light: 浅色模式色值（`RRGGBB` 或 `RRGGBBAA`，不含 `#`）。
    ///   - dark: 深色模式色值（同上）。
    /// - Returns: 跟随系统外观自动切换的 `Color`。
    private static func adaptive(_ light: String, _ dark: String) -> Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
            }
        )
    }

    /// 一套预设的 12 个十六进制色值（6 个浅色 + 6 个深色推导值）。
    ///
    /// 单独抽成 `struct` 是为了让「浅色值必须与 tokens 一致」这件事在代码里可读：
    /// 浅色字段（`accent`/`tint`/`tint2`/`deep`/`sub`/`canvas`）与 `design/tokens.json`
    /// 的 `theme.presets.<id>` 逐项相等；`*Dark` 字段按 design/05 §1.2 推导。
    private struct HexPalette {
        let accent: String
        let accentDark: String
        let tint: String
        let tintDark: String
        let tint2: String
        let tint2Dark: String
        let deep: String
        let deepDark: String
        let sub: String
        let subDark: String
        let canvas: String
        let canvasDark: String
    }

    /// 取某预设的配色表。
    ///
    /// 深色值的推导算式（写在注释里便于复核，改色时按同样算式重算）：
    /// - `accentDark` = accent × 0.88 + 255 × 0.12（混白 12%）
    /// - `tintDark`   = accentDark + `"38"`（22% alpha ≈ 0x38 / 255）
    /// - `tint2Dark`  = accentDark + `"5C"`（36% alpha ≈ 0x5C / 255）
    /// - `deepDark`   = accent × 0.55 + 255 × 0.45（混白 45%）
    /// - `subDark`    = accent × 0.18 + 255 × 0.82，再叠 `"99"`（60% alpha）
    /// - `canvasDark` = `"1C1C1E"`（design/05 §1.2 统一规定）
    ///
    /// - Parameter preset: 预设枚举。
    /// - Returns: 该预设的十二个色值。
    private static func palette(for preset: Preset) -> HexPalette {
        switch preset {
        case .ink:
            return HexPalette(
                accent: "101010", accentDark: "2D2D2D",
                tint: "F7F7F5", tintDark: "2D2D2D38",
                tint2: "EBEBEA", tint2Dark: "2D2D2D5C",
                deep: "101010", deepDark: "7C7C7C",
                sub: "3A3A3E", subDark: "D4D4D499",
                canvas: "D7D7DC", canvasDark: "1C1C1E"
            )
        case .coral:
            return HexPalette(
                accent: "D97757", accentDark: "DE876B",
                tint: "FDF3EE", tintDark: "DE876B38",
                tint2: "F5E2D9", tint2Dark: "DE876B5C",
                deep: "8A4B33", deepDark: "EAB4A3",
                sub: "6B4A3E", subDark: "F8E7E199",
                canvas: "DFD6D1", canvasDark: "1C1C1E"
            )
        case .indigo:
            return HexPalette(
                accent: "4D6BFE", accentDark: "627DFE",
                tint: "EEF1FF", tintDark: "627DFE38",
                tint2: "E0E5FC", tint2Dark: "627DFE5C",
                deep: "2B3B9E", deepDark: "9DAEFE",
                sub: "3A4570", subDark: "DFE4FF99",
                canvas: "D3D8EC", canvasDark: "1C1C1E"
            )
        case .violet:
            return HexPalette(
                accent: "7A5AF8", accentDark: "8A6EF9",
                tint: "F2EFFF", tintDark: "8A6EF938",
                tint2: "E7E1FD", tint2Dark: "8A6EF95C",
                deep: "4530A8", deepDark: "B6A4FB",
                sub: "4A3F72", subDark: "E7E1FE99",
                canvas: "D6D0EA", canvasDark: "1C1C1E"
            )
        case .sky:
            return HexPalette(
                accent: "2AA5E8", accentDark: "44B0EB",
                tint: "EBF7FE", tintDark: "44B0EB38",
                tint2: "DCF0FC", tint2Dark: "44B0EB5C",
                deep: "12628C", deepDark: "8ACEF2",
                sub: "2A5068", subDark: "D9EFFB99",
                canvas: "CFDFE8", canvasDark: "1C1C1E"
            )
        case .pine:
            return HexPalette(
                accent: "10A37F", accentDark: "2DAE8E",
                tint: "EDF8F4", tintDark: "2DAE8E38",
                tint2: "DCF1E9", tint2Dark: "2DAE8E5C",
                deep: "0A6449", deepDark: "7CCCB9",
                sub: "2A4F44", subDark: "D4EEE899",
                canvas: "CFE0DA", canvasDark: "1C1C1E"
            )
        }
    }
}

// MARK: - 便捷访问

public extension AppTheme {
    /// 该主题在 `Preset` 里的对应值（自定义形象主题返回 `nil`）。
    var presetValue: AppTheme.Preset? {
        AppTheme.Preset(rawValue: id)
    }

    /// 判断两个主题是否是同一个预设（只比 id，比 `Equatable` 更省：不比较 `Color`）。
    ///
    /// `Color` 的 `==` 在动态色上比较的是 provider 的标识，不同次构造可能不相等；
    /// 因此设置页做「当前选中」判断时请用 `id`，而不是 `==`。
    func isSameTheme(as other: AppTheme) -> Bool {
        id == other.id
    }
}
