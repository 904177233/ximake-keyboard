//
//  PrimaryButton.swift
//  墨语 · 宿主 App 组件
//
//  L1 原子组件：项目里**只有这两种按钮**（契约 §2.2）。
//  胶囊形状由 `shape` 固定为 `.capsule`，通过 `tone` / `size` 表达语义与尺寸。
//
import SwiftUI

/// 主按钮（强调色 / 危险 / 中性）。
///
/// 规则（契约 §2.2）：一个屏幕最多一个 `.accent .large`。
struct PrimaryButton: View {

    /// 色调。
    enum Tone {
        case accent
        case destructive
        case neutral
    }

    /// 尺寸（高 50 / 44 / 36）。
    enum Size {
        case large
        case medium
        case small
    }

    /// 标题。
    let title: String

    /// 左侧图标（可空）。
    var systemImage: String?

    /// 色调。
    var tone: Tone

    /// 尺寸。
    var size: Size

    /// 是否可用。
    var isEnabled: Bool

    /// 是否加载中（转圈替换图标，文字保留）。
    var isLoading: Bool

    /// 是否占满宽度。
    var fullWidth: Bool

    /// 点击回调。
    var action: () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        tone: Tone = .accent,
        size: Size = .large,
        isEnabled: Bool = true,
        isLoading: Bool = false,
        fullWidth: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
        self.size = size
        self.isEnabled = isEnabled
        self.isLoading = isLoading
        self.fullWidth = fullWidth
        self.action = action
    }

    var body: some View {
        Button {
            guard isEnabled && !isLoading else { return }
            Haptics.light()
            action()
        } label: {
            HStack(spacing: AppMetrics.chipIconGap) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: foreground))
                        .scaleEffect(0.8)
                } else if let systemImage {
                    IconGlyph(symbol: systemImage, fallback: "›", size: glyphSize, weight: .semibold, tint: foreground)
                }
                Text(title)
                    .font(textFont)
                    .lineLimit(1)
            }
            .foregroundColor(foreground)
            .padding(.horizontal, AppMetrics.cardPadding)
            .frame(height: height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(background)
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PrimaryButtonPressStyle())
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(Text(title))
    }

    // MARK: - 视觉

    /// 高度。
    private var height: CGFloat {
        switch size {
        case .large:
            return AppMetrics.buttonLargeHeight
        case .medium:
            return AppMetrics.buttonMediumHeight
        case .small:
            return AppMetrics.buttonSmallHeight
        }
    }

    /// 字号。
    private var textFont: Font {
        switch size {
        case .large, .medium:
            return AppFont.button
        case .small:
            return AppFont.body.weight(.medium)
        }
    }

    /// 图标字号。
    private var glyphSize: CGFloat {
        size == .small ? AppMetrics.glyphSizeSmall : AppMetrics.glyphSize
    }

    /// 前景色。
    private var foreground: Color {
        switch tone {
        case .accent:
            return AppColor.onAccent
        case .destructive:
            return AppColor.onAccent
        case .neutral:
            return Theme.accent
        }
    }

    /// 背景色。
    private var background: Color {
        switch tone {
        case .accent:
            return Theme.accent
        case .destructive:
            return Theme.danger
        case .neutral:
            return Theme.surfaceElevated
        }
    }
}

/// 次按钮（中性 / 危险描边）。
///
/// 视觉比 `PrimaryButton` 克制，用于「取消」「复制」等次要路径。
struct SecondaryButton: View {

    /// 色调（契约：只有 neutral / destructive）。
    enum Tone {
        case neutral
        case destructive
    }

    /// 尺寸。
    enum Size {
        case large
        case medium
        case small
    }

    /// 标题。
    let title: String

    /// 左侧图标（可空）。
    var systemImage: String?

    /// 色调。
    var tone: Tone

    /// 尺寸。
    var size: Size

    /// 是否可用。
    var isEnabled: Bool

    /// 是否加载中。
    var isLoading: Bool

    /// 是否占满宽度。
    var fullWidth: Bool

    /// 点击回调。
    var action: () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        tone: Tone = .neutral,
        size: Size = .medium,
        isEnabled: Bool = true,
        isLoading: Bool = false,
        fullWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
        self.size = size
        self.isEnabled = isEnabled
        self.isLoading = isLoading
        self.fullWidth = fullWidth
        self.action = action
    }

    var body: some View {
        Button {
            guard isEnabled && !isLoading else { return }
            Haptics.light()
            action()
        } label: {
            HStack(spacing: AppMetrics.chipIconGap) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: foreground))
                        .scaleEffect(0.8)
                } else if let systemImage {
                    IconGlyph(symbol: systemImage, fallback: "", size: glyphSize, tint: foreground)
                }
                Text(title)
                    .font(textFont)
                    .lineLimit(1)
            }
            .foregroundColor(foreground)
            .padding(.horizontal, AppMetrics.cardPadding)
            .frame(height: height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(background)
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PrimaryButtonPressStyle())
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(Text(title))
    }

    // MARK: - 视觉

    /// 高度（与 PrimaryButton 同尺寸体系）。
    private var height: CGFloat {
        switch size {
        case .large:
            return AppMetrics.buttonLargeHeight
        case .medium:
            return AppMetrics.buttonMediumHeight
        case .small:
            return AppMetrics.buttonSmallHeight
        }
    }

    /// 字号。
    private var textFont: Font {
        switch size {
        case .large, .medium:
            return AppFont.button
        case .small:
            return AppFont.body.weight(.medium)
        }
    }

    /// 图标字号。
    private var glyphSize: CGFloat {
        size == .small ? AppMetrics.glyphSizeSmall : AppMetrics.glyphSize
    }

    /// 前景色。
    private var foreground: Color {
        tone == .destructive ? Theme.danger : Theme.accent
    }

    /// 背景色。
    private var background: Color {
        tone == .destructive ? AppColor.dangerWash : Theme.surfaceElevated
    }
}

/// 按钮按压反馈：缩放 0.97 + 透明度 0.85，0.15s（契约 §2.2 / §5）。
private struct PrimaryButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.Motion.fast, value: configuration.isPressed)
    }
}

#if DEBUG
struct PrimaryButton_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: AppMetrics.blockGap) {
            PrimaryButton(title: "开始使用", systemImage: "arrow.right", action: {})
            PrimaryButton(title: "保存", tone: .neutral, size: .medium, fullWidth: false, action: {})
            PrimaryButton(title: "删除", systemImage: "trash", tone: .destructive, size: .medium, action: {})
            PrimaryButton(title: "测试连接", isLoading: true, size: .medium, action: {})
            HStack(spacing: AppMetrics.blockGap) {
                SecondaryButton(title: "取消", action: {})
                SecondaryButton(title: "复制", size: .small, action: {})
                SecondaryButton(title: "删除", tone: .destructive, size: .small, action: {})
            }
        }
        .padding(AppMetrics.pageInset)
        .background(AppColor.pageBackground)
    }
}
#endif
