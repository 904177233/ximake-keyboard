//
//  ErrorBanner.swift
//  墨语 · 宿主 App 组件
//
//  错误 / 警告 / 信息提示条（契约：design/组件库.md §4.5）。
//
import SwiftUI

/// 提示条。
struct ErrorBanner: View {

    /// 语义级别。
    enum Severity {
        case error
        case warning
        case info
    }

    private let severity: Severity
    private let title: String
    private let message: String?
    private let actionTitle: String?
    private let onAction: (() -> Void)?
    private let onDismiss: (() -> Void)?

    init(
        severity: Severity = .error,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.severity = severity
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppMetrics.rowGap) {
            IconGlyph(
                symbol: symbolName,
                fallback: "!",
                size: AppMetrics.glyphSize,
                weight: .semibold,
                tint: tintColor
            )
            .padding(.top, AppMetrics.hairGap)

            VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                Text(title)
                    .font(AppFont.body.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let message {
                    Text(message)
                        .font(AppFont.footnote)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let actionTitle, let onAction {
                    Button(action: onAction) {
                        Text(actionTitle)
                            .font(AppFont.footnoteStrong)
                            .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.top, AppMetrics.hairGap)
                }
            }

            Spacer(minLength: 0)

            if let onDismiss {
                Button(action: onDismiss) {
                    IconGlyph(
                        symbol: "xmark",
                        fallback: "×",
                        size: AppMetrics.glyphSizeSmall,
                        weight: .semibold,
                        tint: Theme.textTertiary
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel(Text("关闭提示"))
            }
        }
        .padding(AppMetrics.rowVPadding)
        .background(
            RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                .fill(backgroundColor)
        )
        .padding(.horizontal, AppMetrics.pageInset)
        .transition(.opacity.combined(with: .offset(y: -AppMetrics.tightGap)))
    }

    /// 图标名。
    private var symbolName: String {
        switch severity {
        case .error: return "exclamationmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    /// 图标与强调色。
    private var tintColor: Color {
        switch severity {
        case .error: return Theme.danger
        case .warning: return Theme.warning
        case .info: return Theme.accent
        }
    }

    /// 背景色。
    private var backgroundColor: Color {
        switch severity {
        case .error: return Theme.dangerSoft
        case .warning: return Theme.warningSoft
        case .info: return Theme.accentSoft
        }
    }
}

#if DEBUG
struct ErrorBanner_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: AppMetrics.blockGap) {
            ErrorBanner(
                severity: .error,
                title: "API Key 无效或已过期",
                message: "请到服务商控制台重新生成 Key 后再试。",
                actionTitle: "重新填写",
                onAction: {},
                onDismiss: {}
            )
            ErrorBanner(
                severity: .warning,
                title: "免费签名 7 天过期是 Apple 的限制",
                message: "到期后需要重新安装一次。"
            )
            ErrorBanner(
                severity: .info,
                title: "API Key 只存在本机钥匙串",
                message: "不会上传到任何服务器。"
            )
        }
        .padding(.vertical)
        .background(AppColor.pageBackground)
    }
}
#endif
