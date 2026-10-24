//
//  SectionHeader.swift
//  墨语 · 宿主 App 组件
//
//  分组标题与分组容器（契约：design/组件库.md §4.6）。
//
import SwiftUI

/// 分组标题：左侧小字标题，右侧可放补充说明。
struct SectionHeader: View {

    let title: String
    var footnote: String?
    var trailing: String?

    init(title: String, footnote: String? = nil, trailing: String? = nil) {
        self.title = title
        self.footnote = footnote
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppMetrics.tightGap) {
            Text(title)
                .font(AppFont.footnoteStrong)
                .foregroundColor(Theme.textSecondary)
            if let footnote {
                Text(footnote)
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(.horizontal, AppMetrics.cardPadding)
        .frame(height: AppMetrics.sectionHeaderHeight, alignment: .bottom)
    }
}

/// 分组容器：一张 `SurfaceCard(.plain)` 里放若干行，底部可带脚注。
///
/// 用法：
///      ListGroup(footer: "API Key 只存在本机钥匙串。") {
///          SettingsRow(...)
///          RowDivider()
///          SettingsRow(...)
///      }
struct ListGroup<Content: View>: View {

    private let footer: String?
    private let content: Content

    init(footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.tightGap) {
            SurfaceCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
            }
            .clipped()

            if let footer {
                Text(footer)
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppMetrics.cardPadding)
                    .padding(.top, AppMetrics.hairGap)
            }
        }
    }
}

#if DEBUG
struct SectionHeader_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "AI 设置", trailing: "2 项")
            ListGroup(footer: "这只是脚注说明。") {
                SettingsRow(icon: IconSpec(symbol: "server.rack"), title: "AI 服务", accessory: .chevron, onTap: {})
                RowDivider()
                SettingsRow(icon: IconSpec(symbol: "textformat"), title: "默认语气", accessory: .value("自然"), onTap: {})
            }
        }
        .padding(.vertical, AppMetrics.pageInset)
        .background(AppColor.pageBackground)
    }
}
#endif
