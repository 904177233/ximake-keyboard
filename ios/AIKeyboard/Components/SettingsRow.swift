//
//  SettingsRow.swift
//  墨语 · 宿主 App 组件
//
//  设置列表行（契约：design/组件库.md §4.2）。
//  一行 = 28×28 色块图标 + 标题（+ 副标题） + 右侧附件。
//
import SwiftUI

/// 行首图标规格：色块 + SF Symbol。
struct IconSpec {

    /// SF Symbol 名。
    var symbol: String

    /// 图标与文案主色。
    var tint: Color

    /// 色块底色（默认取 tint 的 14% 浅底）。
    var background: Color

    init(symbol: String, tint: Color = Theme.accent, background: Color? = nil) {
        self.symbol = symbol
        self.tint = tint
        self.background = background ?? tint.opacity(0.14)
    }
}

/// 状态点的语义。
enum StatusDot {
    case neutral
    case success
    case warning
    case danger
    case testing
}

/// 设置行。
struct SettingsRow: View {

    /// 右侧附件类型。
    enum Accessory {
        /// 无附件。
        case none
        /// 右箭头。
        case chevron
        /// 开关（状态由外部 Binding 拥有）。
        case toggle(Binding<Bool>)
        /// 右侧文字值。
        case value(String)
        /// 勾选标记。
        case checkmark(Bool)
        /// 状态点。
        case status(StatusDot)
    }

    var icon: IconSpec?
    var title: String
    var subtitle: String?
    var accessory: Accessory
    var isDestructive: Bool = false
    var onTap: (() -> Void)?

    /// `accessory == .value(...)` 时的文字颜色（nil 表示默认的次要色）。
    ///
    /// CONTRACT-ADD：契约 §4.2 只定义了 `.value(String)`，但诊断类信息需要用
    /// 警示色（如「内置兜底词库」）提示异常，故追加一个可选的着色覆盖，
    /// 不改变既有调用点的行为。
    var valueTint: Color?

    init(
        icon: IconSpec? = nil,
        title: String,
        subtitle: String? = nil,
        accessory: Accessory = .none,
        isDestructive: Bool = false,
        valueTint: Color? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.isDestructive = isDestructive
        self.valueTint = valueTint
        self.onTap = onTap
    }

    var body: some View {
        Group {
            if let onTap, !hasToggleAccessory {
                Button(action: onTap) {
                    rowContent
                }
                .buttonStyle(SettingsRowPressStyle())
            } else {
                rowContent
            }
        }
    }

    /// 开关附件不能包在按钮里，否则点击会互相抢事件。
    private var hasToggleAccessory: Bool {
        if case .toggle = accessory { return true }
        return false
    }

    /// 行内容。
    private var rowContent: some View {
        HStack(spacing: AppMetrics.rowGap) {
            if let icon {
                iconTile(icon)
            }

            VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                Text(title)
                    .font(AppFont.headline.weight(.regular))
                    .foregroundColor(isDestructive ? Theme.danger : Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.footnote)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: AppMetrics.tightGap)

            accessoryView
        }
        .padding(.horizontal, AppMetrics.cardPadding)
        .frame(minHeight: subtitle == nil ? AppMetrics.rowHeightSingle : AppMetrics.rowHeightSubtitle)
        .contentShape(Rectangle())
    }

    /// 28×28 圆角色块 + 15pt 符号。
    private func iconTile(_ spec: IconSpec) -> some View {
        RoundedRectangle(cornerRadius: AppMetrics.iconTileRadius, style: .continuous)
            .fill(spec.background)
            .frame(width: AppMetrics.iconTileSize, height: AppMetrics.iconTileSize)
            .overlay(
                IconGlyph(
                    symbol: spec.symbol,
                    fallback: "",
                    size: AppMetrics.glyphSizeSmall,
                    weight: .semibold,
                    tint: spec.tint
                )
            )
    }

    /// 右侧附件。
    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .chevron:
            IconGlyph(
                symbol: "chevron.right",
                fallback: "›",
                size: AppMetrics.glyphSizeSmall - AppMetrics.hairGap,
                weight: .semibold,
                tint: Theme.textTertiary
            )
        case .toggle(let binding):
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(Theme.accent)
                .accessibilityLabel(Text(title))
        case .value(let text):
            Text(text)
                .font(AppFont.headline.weight(.regular))
                .foregroundColor(valueTint ?? Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .checkmark(let isOn):
            if isOn {
                IconGlyph(
                    symbol: "checkmark",
                    fallback: "✓",
                    size: AppMetrics.glyphSize,
                    weight: .semibold,
                    tint: Theme.accent
                )
            }
        case .status(let dot):
            StatusDotView(dot: dot)
        }
    }
}

/// 状态点（自检 / 连接状态）。
struct StatusDotView: View {

    let dot: StatusDot

    var body: some View {
        Group {
            switch dot {
            case .testing:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.textSecondary))
                    .scaleEffect(0.6)
                    .frame(width: AppMetrics.statusDotSize, height: AppMetrics.statusDotSize)
            case .neutral:
                dotCircle(color: Theme.textTertiary, filled: false)
            case .success:
                dotCircle(color: Theme.success, filled: true)
            case .warning:
                dotCircle(color: Theme.warning, filled: true)
            case .danger:
                dotCircle(color: Theme.danger, filled: true)
            }
        }
        .frame(width: AppMetrics.statusDotSize, height: AppMetrics.statusDotSize)
        .accessibilityHidden(true)
    }

    /// 圆点；filled 为 false 时是空心环。
    private func dotCircle(color: Color, filled: Bool) -> some View {
        Circle()
            .strokeBorder(color, lineWidth: filled ? 0 : AppMetrics.hairline * 2)
            .background(
                Circle().fill(filled ? color : Color.clear)
            )
            .frame(width: AppMetrics.statusDotCore + AppMetrics.hairGap,
                   height: AppMetrics.statusDotCore + AppMetrics.hairGap)
    }
}

/// 行与行之间的分隔线：左缩进对齐文本起始位（有图标 56 / 无图标 16）。
struct RowDivider: View {

    var hasIcon: Bool = true

    var body: some View {
        Rectangle()
            .fill(AppColor.cardStroke)
            .frame(height: AppMetrics.hairline)
            .padding(.leading, hasIcon ? AppMetrics.settingsIconColumn : AppMetrics.cardPadding)
    }
}

/// 行按钮按压反馈。
private struct SettingsRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.surfaceElevated : Color.clear)
    }
}

#if DEBUG
struct SettingsRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: AppMetrics.sectionGap) {
            ListGroup(footer: "关闭后键盘不读取剪贴板。") {
                SettingsRow(
                    icon: IconSpec(symbol: "server.rack"),
                    title: "AI 服务",
                    accessory: .value("DeepSeek"),
                    onTap: {}
                )
                RowDivider()
                SettingsRow(
                    icon: IconSpec(symbol: "textformat", tint: Theme.textSecondary),
                    title: "默认语气",
                    accessory: .chevron,
                    onTap: {}
                )
                RowDivider()
                SettingsRow(
                    icon: IconSpec(symbol: "doc.on.clipboard", tint: Theme.success),
                    title: "剪贴板历史",
                    subtitle: "只在本机保存最近 20 条",
                    accessory: .toggle(.constant(false))
                )
                RowDivider()
                SettingsRow(
                    icon: IconSpec(symbol: "stethoscope", tint: Theme.warning),
                    title: "诊断",
                    accessory: .status(.success)
                )
                RowDivider()
                SettingsRow(
                    icon: IconSpec(symbol: "trash", tint: Theme.danger),
                    title: "重置所有设置",
                    accessory: .none,
                    isDestructive: true,
                    onTap: {}
                )
            }
        }
        .padding(AppMetrics.pageInset)
        .background(AppColor.pageBackground)
    }
}
#endif
