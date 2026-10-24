//
//  ProviderRow.swift
//  墨语 · 宿主 App 组件
//
//  AI 服务商列表行（契约：design/组件库.md §4.7）。
//
import SwiftUI

/// 连接状态。
enum ConnectionStatus: Equatable {
    /// 还没测过。
    case untested
    /// 正在测试。
    case testing
    /// 连接成功，附带往返毫秒数。
    case ok(latencyMs: Int)
    /// 连接失败，附带中文原因。
    case failed(String)

    /// 是否成功。
    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

/// 服务商行：字母标 + 名称 + 协议·模型 + 状态 + 箭头。
struct ProviderRow: View {

    private let name: String
    private let kindTitle: String
    private let model: String
    private let isDefault: Bool
    private let status: ConnectionStatus
    private let onTap: () -> Void
    private let onTest: (() -> Void)?

    init(
        name: String,
        kindTitle: String,
        model: String,
        isDefault: Bool,
        status: ConnectionStatus = .untested,
        onTap: @escaping () -> Void,
        onTest: (() -> Void)? = nil
    ) {
        self.name = name
        self.kindTitle = kindTitle
        self.model = model
        self.isDefault = isDefault
        self.status = status
        self.onTap = onTap
        self.onTest = onTest
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AppMetrics.rowGap) {
                avatar

                VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                    HStack(spacing: AppMetrics.tightGap) {
                        Text(name)
                            .font(AppFont.headline)
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        if isDefault {
                            PillChip("默认", style: .tag, action: {})
                                .allowsHitTesting(false)
                        }
                    }
                    Text(subtitle)
                        .font(AppFont.footnote)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: AppMetrics.tightGap)

                statusView

                IconGlyph(
                    symbol: "chevron.right",
                    fallback: "›",
                    size: AppMetrics.glyphSizeSmall - AppMetrics.hairGap,
                    weight: .semibold,
                    tint: Theme.textTertiary
                )
            }
            .padding(.horizontal, AppMetrics.cardPadding)
            .frame(minHeight: AppMetrics.providerRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(ProviderRowPressStyle())
    }

    /// 40×40 字母头像。
    private var avatar: some View {
        RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
            .fill(AppColor.accentWash)
            .frame(width: AppMetrics.providerAvatar, height: AppMetrics.providerAvatar)
            .overlay(
                Text(String(name.prefix(1)))
                    .font(.system(size: AppMetrics.glyphSize + AppMetrics.hairGap, weight: .bold))
                    .foregroundColor(Theme.accent)
            )
            .accessibilityHidden(true)
    }

    /// 副标题：协议 · 模型。
    private var subtitle: String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedModel.isEmpty {
            return "\(kindTitle) · 未选择模型"
        }
        return "\(kindTitle) · \(trimmedModel)"
    }

    /// 右侧状态。
    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .untested:
            Text("未测试")
                .font(AppFont.caption)
                .foregroundColor(Theme.textTertiary)
        case .testing:
            HStack(spacing: AppMetrics.hairGap) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.textSecondary))
                    .scaleEffect(0.55)
                    .frame(width: AppMetrics.statusDotSize, height: AppMetrics.statusDotSize)
                Text("测试中")
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        case .ok(let latencyMs):
            Text("已连接 · \(latencyMs)ms")
                .font(AppFont.caption)
                .foregroundColor(Theme.success)
        case .failed:
            Text("连接失败")
                .font(AppFont.caption)
                .foregroundColor(Theme.danger)
        }
    }
}

/// 行按压反馈。
private struct ProviderRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.surfaceElevated : Color.clear)
    }
}

#if DEBUG
struct ProviderRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            ProviderRow(name: "DeepSeek 深度求索", kindTitle: "OpenAI 兼容", model: "deepseek-chat", isDefault: true, status: .ok(latencyMs: 820), onTap: {})
            RowDivider()
            ProviderRow(name: "通义千问", kindTitle: "OpenAI 兼容", model: "qwen-plus", isDefault: false, status: .failed("API Key 无效"), onTap: {})
            RowDivider()
            ProviderRow(name: "即梦 · 火山方舟", kindTitle: "自定义", model: "seedream-3.0", isDefault: false, status: .untested, onTap: {})
        }
        .background(Theme.surface)
        .padding(.vertical)
        .background(AppColor.pageBackground)
    }
}
#endif
