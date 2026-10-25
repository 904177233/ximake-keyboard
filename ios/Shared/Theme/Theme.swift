//
//  Theme.swift
//  ios/Shared/Theme
//
//  模块职责：墨语全局设计令牌（颜色 / 字体 / 间距 / 圆角 / 尺寸 / 动效 / 阴影 / 材质）。
//            所有 UI 代码只允许引用这里的常量，禁止在页面里写魔法数字与裸色值。
//  依赖：SwiftUI（`Color` / `Font` / `Animation`）、UIKit（仅用 `UIColor` 动态色，供深色自适应）。
//  使用方：ios/AIKeyboard（宿主 App 全部界面）、ios/AIKeyboardExtension（键盘 UI）。
//
//  令牌来源：design/tokens.json（七组为 docs/02 §5 强制基线，键名不可改）。
//  映射规则：`color.light.*` 与 `color.dark.*` 成对 → 一个 `UIColor { trait in }` 动态色，
//            SwiftUI 侧用 `Color(uiColor:)` 包装后自动跟随系统深色模式。
//  tokens: 1.0
//

import SwiftUI
import UIKit

// MARK: - Theme 根命名空间

/// 墨语设计令牌总入口。
///
/// 用法：
/// ```swift
/// Text("发送").foregroundColor(Theme.textPrimary)
///     .font(Theme.fontBody)
///     .padding(Theme.Spacing.lg)
///     .background(Theme.surface)
///     .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
/// ```
///
/// 约定：
/// - 颜色是**动态色**，无需手写 `@Environment(\.colorScheme)` 分支；
/// - 尺寸单位统一为 `CGFloat`（点），动效时长单位为秒；
/// - 全部常量在编译期已知，可安全用于 `static let` 与 `@inlinable` 之外的任意位置。
public enum Theme {

    // MARK: - 颜色（tokens: color.light / color.dark，共 36 对）

    // 背景层（键盘背景 → 键帽 → 表面）

    /// 键盘整体背景色。`bg.keyboard` #D1D3D9 / #2C2C2E
    public static let keyboardBackground = adaptive("D1D3D9", "2C2C2E")
    /// 普通字母键键帽背景。`bg.key` #FFFFFF / #636366
    public static let keyBackground = adaptive("FFFFFF", "636366")
    /// 普通键按下态背景。`bg.key.pressed` #E5E5E5 / #7A7A7E
    public static let keyBackgroundPressed = adaptive("E5E5E5", "7A7A7E")
    /// 功能键（Shift / Delete / 123 等）背景。`bg.key.function` #ADB3BC / #48484A
    public static let keyFunctionBackground = adaptive("ADB3BC", "48484A")
    /// 功能键按下态背景。`bg.key.function.pressed` #9AA0A9 / #565658
    public static let keyFunctionBackgroundPressed = adaptive("9AA0A9", "565658")
    /// 卡片 / 面板表面色。`bg.surface` #FFFFFF / #1C1C1E
    public static let surface = adaptive("FFFFFF", "1C1C1E")
    /// 抬升表面色（页面底色、分组卡片底）。`bg.surfaceElevated` #F2F2F7 / #2C2C2E
    public static let surfaceElevated = adaptive("F2F2F7", "2C2C2E")
    /// 分组列表底色。`bg.surfaceGrouped` #F2F2F7 / #000000
    public static let surfaceGrouped = adaptive("F2F2F7", "000000")
    /// 玻璃材质着色叠层。`bg.glassTint` #FFFFFF33 / #FFFFFF1A
    public static let glassTint = adaptive("FFFFFF33", "FFFFFF1A")

    // 文本层

    /// 主文本色。`text.primary` #000000 / #FFFFFF
    public static let textPrimary = adaptive("000000", "FFFFFF")
    /// 次要文本色。`text.secondary` #3C3C4399 / #EBEBF599
    public static let textSecondary = adaptive("3C3C4399", "EBEBF599")
    /// 三级文本色（弱提示）。`text.tertiary` #3C3C434D / #EBEBF54D
    public static let textTertiary = adaptive("3C3C434D", "EBEBF54D")
    /// 占位符文本色。`text.placeholder` #3C3C4399 / #EBEBF54D
    public static let textPlaceholder = adaptive("3C3C4399", "EBEBF54D")
    /// 强调色之上的文本色。`text.onAccent` #FFFFFF / #FFFFFF
    public static let textOnAccent = adaptive("FFFFFF", "FFFFFF")

    // 强调与状态色

    /// 品牌强调色（系统蓝）。`accent` #0A84FF / #0A84FF
    public static let accent = adaptive("0A84FF", "0A84FF")
    /// 强调色低透明度填充（选中胶囊底、按钮次级底）。`accent.soft` #0A84FF1A / #0A84FF33
    public static let accentSoft = adaptive("0A84FF1A", "0A84FF33")
    /// 强调色按下态。`accent.pressed` #0070E0 / #409CFF
    public static let accentPressed = adaptive("0070E0", "409CFF")
    /// 成功色。`success` #34C759 / #30D158
    public static let success = adaptive("34C759", "30D158")
    /// 成功色填充。`success.soft` #34C7591A / #30D15826
    public static let successSoft = adaptive("34C7591A", "30D15826")
    /// 警告色。`warning` #FF9F0A / #FFD60A
    public static let warning = adaptive("FF9F0A", "FFD60A")
    /// 警告色填充。`warning.soft` #FF9F0A1A / #FFD60A26
    public static let warningSoft = adaptive("FF9F0A1A", "FFD60A26")
    /// 危险色。`danger` #FF3B30 / #FF453A
    public static let danger = adaptive("FF3B30", "FF453A")
    /// 危险色填充。`danger.soft` #FF3B301A / #FF453A26
    public static let dangerSoft = adaptive("FF3B301A", "FF453A26")

    // 分隔线

    /// 分隔线（半透明）。`separator` #3C3C434D / #54545899
    public static let separator = adaptive("3C3C434D", "54545899")
    /// 不透明分隔线（分组卡边框）。`separator.opaque` #C6C6C8 / #38383A
    public static let separatorOpaque = adaptive("C6C6C8", "38383A")

    // 候选栏 / 输入码 / 芯片

    /// 候选栏背景。`candidate.bar` #FFFFFF / #3A3A3C
    public static let candidateBar = adaptive("FFFFFF", "3A3A3C")
    /// 候选词选中态背景。`candidate.selected` #0A84FF1A / #0A84FF40
    public static let candidateSelected = adaptive("0A84FF1A", "0A84FF40")
    /// 候选词分隔线。`candidate.separator` #3C3C4326 / #54545866
    public static let candidateSeparator = adaptive("3C3C4326", "54545866")
    /// 玻璃芯片背景（AI 工具条胶囊）。`chip.bg` #FFFFFFCC / #FFFFFF1F
    public static let chipBackground = adaptive("FFFFFFCC", "FFFFFF1F")
    /// 玻璃芯片按下态背景。`chip.bg.pressed` #FFFFFF99 / #FFFFFF14
    public static let chipBackgroundPressed = adaptive("FFFFFF99", "FFFFFF14")
    /// 玻璃芯片描边。`chip.border` #FFFFFF66 / #FFFFFF2E
    public static let chipBorder = adaptive("FFFFFF66", "FFFFFF2E")
    /// 玻璃芯片文字。`chip.text` #1C1C1E / #FFFFFF
    public static let chipText = adaptive("1C1C1E", "FFFFFF")

    // 阴影 / 遮罩 / 光晕

    /// 键帽阴影色。`shadow.key` #00000026 / #00000066
    public static let keyShadow = adaptive("00000026", "00000066")
    /// 键盘顶部投影色。`keyboard.topShadow` #00000014 / #00000040
    public static let keyboardTopShadow = adaptive("00000014", "00000040")
    /// 模态遮罩色。`overlay.scrim` #00000066 / #00000099
    public static let overlayScrim = adaptive("00000066", "00000099")
    /// AI 状态光晕色。`ai.glow` #0A84FF33 / #0A84FF4D
    public static let aiGlow = adaptive("0A84FF33", "0A84FF4D")

    // MARK: - 字体（tokens: typography）

    /// 候选词字号 17 / regular。
    public static let fontCandidate: Font = .system(size: 17, weight: .regular)
    /// 键帽字号 22 / regular。
    public static let fontKey: Font = .system(size: 22, weight: .regular)
    /// 正文字号 15 / regular。
    public static let fontBody: Font = .system(size: 15, weight: .regular)
    /// 说明文字 12 / regular。
    public static let fontCaption: Font = .system(size: 12, weight: .regular)
    /// 标题 20 / semibold。
    public static let fontTitle: Font = .system(size: 20, weight: .semibold)
    /// 小标题 17 / semibold。
    public static let fontHeadline: Font = .system(size: 17, weight: .semibold)
    /// 芯片文字 13 / medium。
    public static let fontChip: Font = .system(size: 13, weight: .medium)
    /// AI 结果正文 16 / regular（行高 24，用 `.lineSpacing(4)` 补齐）。
    public static let fontResult: Font = .system(size: 16, weight: .regular)
    /// 大标题 34 / bold（主 App 页面标题）。
    public static let fontLargeTitle: Font = .system(size: 34, weight: .bold)
    /// 脚注 13 / regular。
    public static let fontFootnote: Font = .system(size: 13, weight: .regular)
    /// 按钮文字 17 / semibold。
    public static let fontButton: Font = .system(size: 17, weight: .semibold)
    /// 等宽数字 16 / medium（token 计数、页码等）。
    public static let fontMonoDigit: Font = .system(size: 16, weight: .medium, design: .monospaced)

    // MARK: - 间距（tokens: spacing）

    /// 间距刻度（点）。
    public enum Spacing {
        /// 2
        public static let xs: CGFloat = 2
        /// 4
        public static let sm: CGFloat = 4
        /// 8
        public static let md: CGFloat = 8
        /// 12
        public static let lg: CGFloat = 12
        /// 16
        public static let xl: CGFloat = 16
        /// 24
        public static let xxl: CGFloat = 24
        /// 32
        public static let xxxl: CGFloat = 32
        /// 16（页面左右安全边距）
        public static let screenMargin: CGFloat = 16
        /// 28（设置页分组之间）
        public static let sectionGap: CGFloat = 28
        /// 44（列表行最小高度，也等于最小点按目标）
        public static let rowMinHeight: CGFloat = 44
    }

    // MARK: - 圆角（tokens: radius）

    /// 圆角刻度（点，均配 `.continuous` 曲线使用）。
    public enum Radius {
        /// 8（键帽、设置行）
        public static let key: CGFloat = 8
        /// 16（卡片）
        public static let card: CGFloat = 16
        /// 999（胶囊，实际用 `Capsule()` 亦可）
        public static let capsule: CGFloat = 999
        /// 24（Sheet 顶部）
        public static let sheet: CGFloat = 24
        /// 14（玻璃芯片）
        public static let chip: CGFloat = 14
        /// 10（按钮 / 输入框）
        public static let control: CGFloat = 10
        /// 12（缩略图）
        public static let thumbnail: CGFloat = 12
        /// 6（小标签）
        public static let small: CGFloat = 6
    }

    // MARK: - 尺寸（tokens: sizing）

    /// 键盘与组件尺寸（点）。全部来自 design/tokens.json `sizing` 组。
    public enum Sizing {
        /// 258 —— 竖屏键盘总高度（v1 契约值，`consistency_check` 钉死、docs/02 §5 引用）
        ///
        /// v1.3 起候选条与 AI 工具条合并为同一条 44pt 效用行，实际高度由
        /// `KMLayout.portraitHeight = utilityRowHeight + keyRowsHeight` 算得 **218**；
        /// 这个令牌保持 v1 契约值不变，避免与 docs/02 §5 的基线冲突。
        public static let keyboardHeightPortrait: CGFloat = 258
        /// 200 —— 横屏键盘总高度（横屏本来就只有一行，未变）
        public static let keyboardHeightLandscape: CGFloat = 200
        /// 44 —— 效用行高度（候选条与 AI 工具条共用同一行，v1.3 起）
        public static let candidateBarHeight: CGFloat = 44
        /// 44 —— 效用行高度（与 `candidateBarHeight` 同值，语义化别名）
        public static let utilityRowHeight: CGFloat = 44
        /// 40 —— AI 面板内部的标题条高度（工具条本身已并入效用行）
        public static let aiBarHeight: CGFloat = 40
        /// 42 —— 单行键帽高度
        public static let keyHeight: CGFloat = 42
        /// 6 —— 键帽纵向/横向间隙
        public static let keyGap: CGFloat = 6
        /// 3 —— 键盘左右内边距
        public static let keyHorizontalPadding: CGFloat = 3
        /// 168 —— AI 面板展开后额外增加的高度
        public static let aiPanelExtraHeight: CGFloat = 168
        /// 180 —— 结果卡片展开后额外增加的高度
        public static let resultExtraHeight: CGFloat = 180

        // 键盘几何（tokens 扩展键，供精确布局使用）

        /// 4 —— 字母区行数
        public static let keyboardRowCount: Int = 4
        /// 46 —— 字母行高（v1.4 由 39 提高：用户反馈「导航栏砍了之后键盘高度太低了」）
        public static let letterRowHeight: CGFloat = 50
        /// 34.5 —— 横屏字母行间距
        public static let letterRowPitchLandscape: CGFloat = 34.5
        /// 33 —— 字母键宽
        public static let letterKeyWidth: CGFloat = 33
        /// 42 —— 功能键宽（Shift / Delete）
        public static let functionKeyWidth: CGFloat = 42
        /// 88 —— 回车键宽
        public static let returnKeyWidth: CGFloat = 88
        /// 108 —— 数字键宽（数字页 4 行 × (3 数字键 + 42 功能列)：(384 − 42 − 3×6) ÷ 3 = 108）
        public static let numberKeyWidth: CGFloat = 108
        /// 194 —— 空格键宽（底行：384 − 42×2 − 88 − 6×3 = 194）
        public static let spaceBarWidth: CGFloat = 194
        /// 30 —— AI 芯片高度
        public static let aiChipHeight: CGFloat = 30
        /// 8 —— AI 芯片间距
        public static let aiChipGap: CGFloat = 8
        /// 56 —— AI 芯片最小宽度
        public static let aiChipMinWidth: CGFloat = 56
        /// 8 —— AI 工具条内边距
        public static let aiBarInset: CGFloat = 8
        /// 24 —— AI 工具条左右渐隐宽度
        public static let aiBarFadeWidth: CGFloat = 24
        /// 48 —— 候选词最小宽度
        public static let candidateItemMinWidth: CGFloat = 48
        /// 20 —— 候选词间距
        public static let candidateItemGap: CGFloat = 20
        /// 6 —— 分页圆点直径
        public static let pageDotSize: CGFloat = 6
        /// 5 —— 分页圆点间距
        public static let pageDotGap: CGFloat = 5
        /// 44 —— AI 面板输入框高度
        public static let aiPanelInputHeight: CGFloat = 44
        /// 44 —— AI 面板语气行高度
        public static let aiPanelToneRowHeight: CGFloat = 44
        /// 120 —— 结果卡片最小高度
        public static let resultCardMinHeight: CGFloat = 120
        /// 180 —— 结果卡片高度
        public static let resultCardHeight: CGFloat = 180
        /// 36 —— 结果卡片操作按钮高度
        public static let resultActionHeight: CGFloat = 36
        /// 44 —— 最小点按目标（HIG）
        public static let minTapTarget: CGFloat = 44
        /// 47 —— 状态栏高度（带刘海机型参考值）
        public static let statusBarHeight: CGFloat = 47
        /// 34 —— Home Indicator 高度
        public static let homeIndicatorHeight: CGFloat = 34
        /// 49 —— Tab Bar 高度
        public static let tabBarHeight: CGFloat = 49
        /// 52 —— 大标题区高度
        public static let largeTitleHeight: CGFloat = 52
        /// 44 —— 导航栏高度
        public static let navBarHeight: CGFloat = 44
        /// 1024 —— App 图标导出尺寸（像素）
        public static let appIconSize: CGFloat = 1024
    }

    // MARK: - 动效（tokens: motion）

    /// 动效时长与曲线。
    ///
    /// 说明：`spring` 用 iOS 16 可用的 `Animation.spring(response:dampingFraction:)` 构造，
    /// 不使用 iOS 17 才有的 `.spring(duration:bounce:)`。
    public enum Motion {
        /// 0.15 —— 轻量状态切换
        public static let fast: Double = 0.15
        /// 0.25 —— 常规过渡
        public static let normal: Double = 0.25
        /// 0.35 —— 弹簧动画 response
        public static let springDuration: Double = 0.35
        /// 0.82 —— 弹簧动画阻尼
        public static let springDamping: Double = 0.82

        /// 弹簧动画（键盘展开 / 结果卡片进入）。
        public static let spring: Animation = .spring(
            response: springDuration,
            dampingFraction: springDamping
        )

        /// 0.08 —— 按键按下高亮
        public static let keyPress: Double = 0.08
        /// 0.35 —— AI 面板展开
        public static let expandDuration: Double = 0.35
        /// 0.28 —— AI 面板收起
        public static let collapseDuration: Double = 0.28
        /// 0.9 —— 流式输出光标闪烁周期
        public static let streamCursorBlink: Double = 0.9
        /// 2.0 —— Toast 停留时长
        public static let toastDuration: Double = 2.0
        /// 0.0 —— 开启「减弱动态效果」时的缩放系数
        public static let reducedMotionScale: Double = 0

        /// 轻量动画（等价 `.easeOut(duration: 0.15)`）。
        public static let fastAnimation: Animation = .easeOut(duration: fast)
        /// 常规动画（等价 `.easeInOut(duration: 0.25)`）。
        public static let normalAnimation: Animation = .easeInOut(duration: normal)
    }

    // MARK: - 阴影（tokens: shadow）

    /// 阴影参数（`y` 偏移 / `blur` 模糊半径 / `opacity` 不透明度）。
    public struct Shadow: Equatable, Sendable {
        /// 纵向偏移（点，负值向上）。
        public let y: CGFloat
        /// 模糊半径（点）。
        public let blur: CGFloat
        /// 不透明度（0...1）。
        public let opacity: Double

        /// 创建阴影参数。
        public init(y: CGFloat, blur: CGFloat, opacity: Double) {
            self.y = y
            self.blur = blur
            self.opacity = opacity
        }

        /// 键帽阴影：y 1 / blur 0 / opacity 0.18
        public static let key = Shadow(y: 1, blur: 0, opacity: 0.18)
        /// 卡片阴影：y 8 / blur 24 / opacity 0.12
        public static let card = Shadow(y: 8, blur: 24, opacity: 0.12)
        /// 芯片阴影：y 1 / blur 4 / opacity 0.08
        public static let chip = Shadow(y: 1, blur: 4, opacity: 0.08)
        /// 玻璃阴影：y 2 / blur 16 / opacity 0.10
        public static let glass = Shadow(y: 2, blur: 16, opacity: 0.10)
        /// 键盘顶边投影：y -1 / blur 0 / opacity 0.08
        public static let keyboardTop = Shadow(y: -1, blur: 0, opacity: 0.08)
    }

    // MARK: - 材质（tokens: material，可选项）

    /// 玻璃材质描述。iOS 16 上 `Material` 可用，但不支持 Liquid Glass 高光，
    /// 降级方案为不透明叠层（`fallbackAlpha`）。
    public enum MaterialToken {
        /// 候选栏 / AI 工具条 / 结果卡片底
        public static let barBlurRadius: CGFloat = 20
        /// 主 App 卡片
        public static let cardBlurRadius: CGFloat = 24
        /// 键盘内设置 Sheet
        public static let sheetBlurRadius: CGFloat = 30
        /// 卡片材质描边宽度（点）
        public static let strokeWidth: CGFloat = 0.5
        /// 候选栏在 iOS 16 的不透明降级叠层透明度
        public static let barFallbackAlpha: Double = 0.94
        /// 卡片在 iOS 16 的不透明降级叠层透明度
        public static let cardFallbackAlpha: Double = 1.0
    }

    // MARK: - 内部辅助

    /// 由 light / dark 两个十六进制色构造深色自适应 `Color`。
    ///
    /// - Parameters:
    ///   - light: 浅色模式色值（`RRGGBB` 或 `RRGGBBAA`，不含 `#`）。
    ///   - dark: 深色模式色值（同上）。
    /// - Returns: 跟随系统外观自动切换的 `Color`（内部是 `UIColor` 动态色）。
    private static func adaptive(_ light: String, _ dark: String) -> Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
            }
        )
    }
}

// MARK: - 十六进制颜色

public extension Color {
    /// 用十六进制字符串创建颜色（支持 `RRGGBB` 与 `RRGGBBAA`，可带 `#`）。
    ///
    /// - Parameter hex: 例如 `"#0A84FF"`、`"0A84FF1A"`。
    ///
    /// 解析失败时返回透明色（`.clear`），避免在 UI 上出现刺眼的调试色。
    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
    }

    /// 用十六进制整数创建颜色（`0xRRGGBB`，alpha 固定 1.0）。
    ///
    /// - Parameter rgb: 例如 `0x0A84FF`。
    init(rgb: UInt32) {
        self.init(uiColor: UIColor(rgb: rgb))
    }
}

extension UIColor {
    /// 用十六进制字符串创建颜色（支持 `RRGGBB` / `RRGGBBAA`，可带 `#`）。
    ///
    /// 解析失败时返回透明色，便于尽早暴露错误色值。
    public convenience init(hex: String) {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        guard cleaned.count == 6 || cleaned.count == 8,
              let value = UInt64(cleaned, radix: 16) else {
            self.init(red: 0, green: 0, blue: 0, alpha: 0)
            return
        }
        if cleaned.count == 8 {
            self.init(
                red: CGFloat((value >> 24) & 0xFF) / 255.0,
                green: CGFloat((value >> 16) & 0xFF) / 255.0,
                blue: CGFloat((value >> 8) & 0xFF) / 255.0,
                alpha: CGFloat(value & 0xFF) / 255.0
            )
        } else {
            self.init(
                red: CGFloat((value >> 16) & 0xFF) / 255.0,
                green: CGFloat((value >> 8) & 0xFF) / 255.0,
                blue: CGFloat(value & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
    }

    /// 用十六进制整数创建颜色（`0xRRGGBB`，alpha 固定 1.0）。
    public convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
