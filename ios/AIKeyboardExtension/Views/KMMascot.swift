//
//  KMMascot.swift
//  AIKeyboardExtension
//
//  键盘右下角的小形象（design/05-主题与小形象规范.md §3）。
//
//  设计要点：
//  - 全部符号都用 24×24 的 `Path` 手绘，不依赖图片资源、不依赖 SF Symbol
//    （键盘扩展包体要小，而且 SF Symbol 的可用性随系统版本变化）。
//  - 若用户在宿主 App 里设置了自定义形象（`ThemeStore.shared.customMascotData`），
//    优先显示自定义图片，并裁剪成圆形。
//  - 生成中（`isBusy`）时做 1.2s 的呼吸动画；开启「减弱动态效果」时保持静态。
//
//  只读依赖：`ThemeStore`（Shared/Theme）、`Theme`（Shared/Theme）。
//

import SwiftUI
import UIKit

// MARK: - 可选符号

/// 小形象可选符号（design/05 §3.2 的 8 个内置形象）。
///
/// 取值会持久化到 `SharedStore`，因此 `rawValue` 必须稳定，不要随意改名。
public enum KMMascotSymbol: String, CaseIterable, Identifiable, Sendable {
    /// 鲸尾 A（默认）。
    case whale
    /// 鲸尾 B（更饱满的尾鳍）。
    case whale2
    /// 四角星芒。
    case spark
    /// 五角星。
    case star
    /// 月牙。
    case moon
    /// 叶子。
    case leaf
    /// 圆点。
    case dot
    /// Q 版小头像。
    case chibi

    public var id: String { rawValue }

    /// 中文显示名（设置页横排选择器用）。
    public var displayName: String {
        switch self {
        case .whale: return "鲸尾 A"
        case .whale2: return "鲸尾 B"
        case .spark: return "四角星"
        case .star: return "五角星"
        case .moon: return "月牙"
        case .leaf: return "叶子"
        case .dot: return "圆点"
        case .chibi: return "Q 版"
        }
    }

    /// 默认符号（design/05 §3.2 指定鲸尾 A 为默认）。
    public static let defaultSymbol: KMMascotSymbol = .whale
}

// MARK: - 持久化

/// 小形象相关的本地开关与选择（持久化在 `SharedStore` 里）。
///
/// 「是否显示」这一个开关**必须与宿主 App 共用一个键** `moyu.theme.showsMascot`：
/// 用户在 App 里关掉小形象，键盘里就该立刻不显示（有 App Group 时是同一份存储，
/// 没有时各存一份但语义一致）。统一走 `ThemeStore.shared.showsMascot`
/// （Shared 层已提供，别在这里手写字符串，否则前缀化逻辑容易对不上）。
///
/// 符号选择是键盘侧独有的偏好，仍留在键盘前缀 `moyu.keyboard.*` 下。
enum KMMascotSettings {
    /// 当前选中符号的存储键。
    static let symbolKey = "moyu.keyboard.mascot.symbol"

    /// 是否在键盘右下角显示小形象（默认 true，与宿主 App 同一个键）。
    static var isEnabled: Bool {
        get { ThemeStore.shared.showsMascot }
        set { ThemeStore.shared.showsMascot = newValue }
    }

    /// 当前选中的符号（非法值时回退默认符号）。
    static var symbol: KMMascotSymbol {
        get {
            let raw = SharedStore.shared.string(forKey: symbolKey) ?? ""
            return KMMascotSymbol(rawValue: raw) ?? .defaultSymbol
        }
        set { SharedStore.shared.set(newValue.rawValue, forKey: symbolKey) }
    }
}

// MARK: - 视图

/// 底行小形象角落格的渲染配置（由 `KeyboardRootView` / `ChatPanelView` 组装后传入 `KeyRowsView`）。
struct KMMascotConfig: Equatable {
    /// 要显示的符号（无自定义图片时生效）。
    var symbol: KMMascotSymbol = .defaultSymbol

    /// 是否处于「AI 正在生成」状态（呼吸动画）。
    var isBusy: Bool = false

    /// 是否显示自定义图片（`ThemeStore.shared.customMascotData` 存在时为 true）。
    var usesCustomImage: Bool = false

    /// 主色（跟随当前主题）。
    var accent: Color = Theme.accent
}

/// 小形象视图（键盘底行角落格里 22pt / 横屏 18pt）。
///
/// 自定义图片优先：宿主 App 写入 `ThemeStore.shared.customMascotData` 后，
/// 键盘侧直接显示这张图（圆形裁切）；没有自定义图片时按 `symbol` 画内置符号。
public struct KMMascotView: View {
    /// 视觉尺寸（不含点击扩展）。
    public var size: CGFloat = KMLayout.mascotVisualSize

    /// 当前符号（仅在无自定义图片时生效）。
    public var symbol: KMMascotSymbol = .defaultSymbol

    /// 是否处于「AI 正在生成」状态（呼吸动画）。
    public var isBusy: Bool = false

    /// 主色（跟随主题）。
    public var accent: Color = Theme.accent

    /// 是否开启「减弱动态效果」。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 呼吸动画相位（0.6 ↔ 1.0）。
    @State private var breathing: Bool = false

    init(
        size: CGFloat = KMLayout.mascotVisualSize,
        symbol: KMMascotSymbol = .defaultSymbol,
        isBusy: Bool = false,
        accent: Color = Theme.accent
    ) {
        self.size = size
        self.symbol = symbol
        self.isBusy = isBusy
        self.accent = accent
    }

    public var body: some View {
        Group {
            if let data = ThemeStore.shared.customMascotData,
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                KMMascotGlyph(symbol: symbol, tint: accent)
                    .frame(width: size, height: size)
            }
        }
        .opacity(isBusy && breathing ? 1.0 : (isBusy ? 0.6 : 1.0))
        .animation(breathingAnimation, value: breathing)
        .onAppear { startBreathingIfNeeded() }
        .onChange(of: isBusy) { newValue in
            if newValue {
                startBreathingIfNeeded()
            } else {
                breathing = false
            }
        }
        .accessibilityHidden(true)
    }

    /// 呼吸动画（开启减弱动态效果时返回 nil，静态显示）。
    private var breathingAnimation: Animation? {
        guard isBusy, !reduceMotion else { return nil }
        return .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
    }

    /// 进入生成态时启动呼吸循环。
    private func startBreathingIfNeeded() {
        guard isBusy, !reduceMotion else { return }
        breathing = true
    }
}

// MARK: - 内置符号绘制

/// 24×24 绘制框里的内置符号（全部用 `Path` / 基础图形手绘）。
struct KMMascotGlyph: View {
    /// 符号。
    let symbol: KMMascotSymbol

    /// 绘制颜色。
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let unit = side / 24.0
            ZStack {
                shape(unit: unit)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 按符号分发绘制。
    @ViewBuilder
    private func shape(unit: CGFloat) -> some View {
        switch symbol {
        case .whale:
            whaleTail(unit: unit, filled: false)
        case .whale2:
            whaleTail(unit: unit, filled: true)
        case .spark:
            sparkle(unit: unit)
        case .star:
            fivePointStar(unit: unit)
        case .moon:
            moon(unit: unit)
        case .leaf:
            leaf(unit: unit)
        case .dot:
            Circle()
                .fill(tint)
                .frame(width: 14 * unit, height: 14 * unit)
        case .chibi:
            chibi(unit: unit)
        }
    }

    /// 鲸尾（`filled` = true 时是实心版，false 时是描边版）。
    private func whaleTail(unit: CGFloat, filled: Bool) -> some View {
        let path = Path { p in
            // 尾柄从左上弯到右下，尾鳍左右展开。
            p.move(to: CGPoint(x: 6.0 * unit, y: 20.0 * unit))
            p.addQuadCurve(
                to: CGPoint(x: 12.0 * unit, y: 9.0 * unit),
                control: CGPoint(x: 6.5 * unit, y: 13.0 * unit)
            )
            p.addQuadCurve(
                to: CGPoint(x: 18.5 * unit, y: 4.5 * unit),
                control: CGPoint(x: 14.0 * unit, y: 5.0 * unit)
            )
            p.addQuadCurve(
                to: CGPoint(x: 15.0 * unit, y: 11.5 * unit),
                control: CGPoint(x: 16.0 * unit, y: 8.0 * unit)
            )
            p.addQuadCurve(
                to: CGPoint(x: 20.5 * unit, y: 16.5 * unit),
                control: CGPoint(x: 19.5 * unit, y: 12.5 * unit)
            )
            p.addQuadCurve(
                to: CGPoint(x: 12.5 * unit, y: 15.5 * unit),
                control: CGPoint(x: 16.5 * unit, y: 15.0 * unit)
            )
            p.addQuadCurve(
                to: CGPoint(x: 9.5 * unit, y: 21.0 * unit),
                control: CGPoint(x: 10.5 * unit, y: 18.0 * unit)
            )
            p.addQuadCurve(
                to: CGPoint(x: 6.0 * unit, y: 20.0 * unit),
                control: CGPoint(x: 8.0 * unit, y: 21.5 * unit)
            )
            p.closeSubpath()
        }
        return Group {
            if filled {
                path.fill(tint)
            } else {
                path.stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    /// 四角星芒（外径 9、内径 2.8，中心在画布中心）。
    private func sparkle(unit: CGFloat) -> some View {
        let center = CGPoint(x: 12.0 * unit, y: 12.0 * unit)
        let outer = 9.0 * unit
        let inner = 2.8 * unit
        let path = Path { p in
            for index in 0..<8 {
                let angle = Double(index) * Double.pi / 4.0 - Double.pi / 2.0
                let radius = index % 2 == 0 ? outer : inner
                let point = CGPoint(
                    x: center.x + CGFloat(cos(angle)) * radius,
                    y: center.y + CGFloat(sin(angle)) * radius
                )
                if index == 0 {
                    p.move(to: point)
                } else {
                    p.addLine(to: point)
                }
            }
            p.closeSubpath()
        }
        return path.fill(tint)
    }

    /// 五角星（外径 9.5、内径 4.1）。
    private func fivePointStar(unit: CGFloat) -> some View {
        let center = CGPoint(x: 12.0 * unit, y: 12.4 * unit)
        let outer = 9.5 * unit
        let inner = 4.1 * unit
        let path = Path { p in
            for index in 0..<10 {
                let angle = Double(index) * Double.pi / 5.0 - Double.pi / 2.0
                let radius = index % 2 == 0 ? outer : inner
                let point = CGPoint(
                    x: center.x + CGFloat(cos(angle)) * radius,
                    y: center.y + CGFloat(sin(angle)) * radius
                )
                if index == 0 {
                    p.move(to: point)
                } else {
                    p.addLine(to: point)
                }
            }
            p.closeSubpath()
        }
        return path.fill(tint)
    }

    /// 月牙（大圆减小圆，用 evenOdd 填充规则挖空）。
    private func moon(unit: CGFloat) -> some View {
        let path = Path { p in
            p.addEllipse(in: CGRect(x: 4.0 * unit, y: 2.5 * unit, width: 17.0 * unit, height: 19.0 * unit))
            p.addEllipse(in: CGRect(x: 9.5 * unit, y: 1.0 * unit, width: 16.0 * unit, height: 18.0 * unit))
        }
        return path.fill(tint, style: FillStyle(eoFill: true))
    }

    /// 叶子（两段圆弧围成的叶形 + 中间叶脉）。
    private func leaf(unit: CGFloat) -> some View {
        let outline = Path { p in
            p.move(to: CGPoint(x: 5.0 * unit, y: 19.0 * unit))
            p.addQuadCurve(
                to: CGPoint(x: 19.0 * unit, y: 5.0 * unit),
                control: CGPoint(x: 5.0 * unit, y: 5.0 * unit)
            )
            p.addQuadCurve(
                to: CGPoint(x: 5.0 * unit, y: 19.0 * unit),
                control: CGPoint(x: 19.0 * unit, y: 19.0 * unit)
            )
            p.closeSubpath()
        }
        let vein = Path { p in
            p.move(to: CGPoint(x: 6.8 * unit, y: 17.2 * unit))
            p.addLine(to: CGPoint(x: 16.4 * unit, y: 7.6 * unit))
        }
        return ZStack {
            outline.fill(tint)
            vein.stroke(
                Theme.keyboardBackground,
                style: StrokeStyle(lineWidth: 1.2 * unit, lineCap: .round)
            )
        }
    }

    /// Q 版小头像（圆头 + 两点眼 + 两腮红）。
    private func chibi(unit: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(tint)
                .frame(width: 17.0 * unit, height: 17.0 * unit)
            HStack(spacing: 4.2 * unit) {
                Circle()
                    .fill(Theme.keyboardBackground)
                    .frame(width: 1.9 * unit, height: 2.6 * unit)
                Circle()
                    .fill(Theme.keyboardBackground)
                    .frame(width: 1.9 * unit, height: 2.6 * unit)
            }
            .offset(y: -1.0 * unit)
            HStack(spacing: 8.4 * unit) {
                Ellipse()
                    .fill(Theme.warning.opacity(0.55))
                    .frame(width: 2.6 * unit, height: 1.6 * unit)
                Ellipse()
                    .fill(Theme.warning.opacity(0.55))
                    .frame(width: 2.6 * unit, height: 1.6 * unit)
            }
            .offset(y: 2.4 * unit)
        }
        .frame(width: 20.0 * unit, height: 20.0 * unit)
    }
}

// MARK: - 设置页横排选择器

/// 小形象符号横排选择器（设置页展开态用，8 个符号 + 名称）。
struct KMMascotSymbolPicker: View {
    /// 当前选中符号。
    let selected: KMMascotSymbol

    /// 主色（跟随主题）。
    var accent: Color = Theme.accent

    /// 点选回调。
    let onSelect: (KMMascotSymbol) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(KMMascotSymbol.allCases) { symbol in
                        Button {
                            KMHaptics.chip()
                            onSelect(symbol)
                        } label: {
                            VStack(spacing: Theme.Spacing.xs) {
                                KMMascotGlyph(symbol: symbol, tint: accent)
                                    .frame(
                                        width: KMLayout.mascotVisualSize,
                                        height: KMLayout.mascotVisualSize
                                    )
                                    .frame(width: Theme.Spacing.xxxl, height: Theme.Spacing.xxxl)
                                    .background(
                                        Circle()
                                            .fill(
                                                symbol == selected
                                                    ? accent.opacity(0.16)
                                                    : Theme.chipBackground
                                            )
                                    )
                                    .overlay(
                                        Circle()
                                            .strokeBorder(
                                                symbol == selected ? accent : Theme.chipBorder,
                                                lineWidth: Theme.MaterialToken.strokeWidth
                                            )
                                    )
                                Text(symbol.displayName)
                                    .font(Theme.fontCaption)
                                    .foregroundColor(
                                        symbol == selected ? accent : Theme.textSecondary
                                    )
                                    .lineLimit(1)
                            }
                            .frame(minWidth: Theme.Sizing.minTapTarget, minHeight: Theme.Sizing.minTapTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(KMPressableStyle(scale: 0.94, duration: Theme.Motion.fast))
                        .accessibilityLabel(Text("小形象 \(symbol.displayName)"))
                        .accessibilityAddTraits(symbol == selected ? [.isButton, .isSelected] : .isButton)
                        .id(symbol.id)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
            }
            .onChange(of: selected) { newValue in
                proxy.scrollTo(newValue.id, anchor: .center)
            }
        }
    }
}

#if DEBUG
/// 小形象预览宿主（仅 DEBUG，不参与正式构建）。
struct KMMascotPreviewHost: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            HStack(spacing: Theme.Spacing.lg) {
                ForEach(KMMascotSymbol.allCases) { symbol in
                    VStack(spacing: Theme.Spacing.sm) {
                        KMMascotView(symbol: symbol, isBusy: false)
                        Text(symbol.displayName).font(Theme.fontCaption)
                    }
                }
            }
            HStack(spacing: Theme.Spacing.lg) {
                KMMascotView(size: KMLayout.mascotVisualSize, symbol: .whale, isBusy: true)
                KMMascotView(size: KMLayout.mascotVisualSizeLandscape, symbol: .spark)
            }
        }
        .padding()
        .background(Theme.keyboardBackground)
    }
}
#endif
