//
//  AboutView.swift
//  墨语 · 宿主 App
//
//  模块职责：关于页（图标、版本、隐私立场、开源许可、反馈、签名说明）。
//  依赖：SwiftUI、AppState、SurfaceCard / ListGroup / SectionHeader / SettingsRow。
//  使用方：SettingsView。
//

import SwiftUI

/// 关于墨语。
struct AboutView: View {

    @EnvironmentObject private var appState: AppState

    /// 是否已复制反馈邮箱。
    @State private var didCopyMail = false

    /// 反馈邮箱（占位，仓库里可改）。
    private static let feedbackMail = "moyu.feedback@example.com"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                heroCard
                infoGroup
                supportGroup
                statementCard
                footer
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 图标区

    private var heroCard: some View {
        VStack(spacing: AppMetrics.blockGap) {
            RoundedRectangle(cornerRadius: AppMetrics.appIconShowcaseRadius, style: .continuous)
                // v2：**不用渐变**。这里是 App 图标的衬托底，图标本身已有层次，
                // 再加一层对角渐变会让「图标 + 底」两层都在渐变，视觉打架。
                .fill(Theme.accentSoft)
                .frame(width: AppMetrics.appIconShowcase, height: AppMetrics.appIconShowcase)
                .overlay(
                    IconGlyph(
                        symbol: "keyboard.badge.ellipsis",
                        fallback: "⌨️",
                        size: AppMetrics.onboardingIconSize,
                        weight: .regular,
                        tint: AppColor.onAccent
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppMetrics.appIconShowcaseRadius, style: .continuous)
                        .strokeBorder(AppColor.highlightTop, lineWidth: AppMetrics.hairline)
                )
                .accessibilityHidden(true)

            Text(AppInfo.displayName)
                .font(AppFont.largeTitle)
                .foregroundColor(Theme.textPrimary)

            Text(AppInfo.slogan)
                .font(AppFont.footnote)
                .foregroundColor(Theme.textSecondary)

            Text("版本 \(AppInfo.version) (\(AppInfo.build)) · \(AppInfo.minimumIOS)+")
                .font(AppFont.caption)
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppMetrics.blockGap)
    }

    // MARK: - 信息

    private var infoGroup: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "信息")
            ListGroup {
                SettingsRow(
                    icon: IconSpec(symbol: "lock.shield", tint: Theme.success),
                    title: "隐私立场",
                    subtitle: "无后端、无账号、数据不出本机",
                    accessory: .value("本地优先")
                )

                RowDivider()

                SettingsRow(
                    icon: IconSpec(symbol: "shippingbox", tint: Theme.accent),
                    title: "开源许可",
                    subtitle: "零第三方依赖，仅使用 Apple 系统框架",
                    accessory: .value("无第三方")
                )

                RowDivider()

                SettingsRow(
                    icon: IconSpec(symbol: "envelope", tint: Theme.accent),
                    title: "反馈",
                    subtitle: didCopyMail ? "已复制邮箱" : Self.feedbackMail,
                    accessory: .chevron
                ) {
                    UIPasteboard.general.string = Self.feedbackMail
                    didCopyMail = true
                    Haptics.success()
                    appState.showToast(
                        ToastMessage(kind: .success, text: "已复制反馈邮箱", detail: Self.feedbackMail)
                    )
                }

                RowDivider()

                SettingsRow(
                    icon: IconSpec(symbol: "keyboard", tint: Theme.textSecondary),
                    title: "键盘设置路径",
                    subtitle: AppInfo.keyboardSettingsPath,
                    accessory: .none
                )
            }
        }
    }

    // MARK: - 支持

    private var supportGroup: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "支持")
            ListGroup {
                NavigationLink {
                    InstallGuideView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "book", tint: Theme.accent),
                        title: "安装与续签指南",
                        accessory: .chevron
                    )
                }
                .buttonStyle(PlainButtonStyle())

                RowDivider()

                NavigationLink {
                    DiagnosticsView()
                } label: {
                    SettingsRow(
                        icon: IconSpec(symbol: "stethoscope", tint: Theme.warning),
                        title: "诊断",
                        accessory: .chevron
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - 特别说明

    private var statementCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                Text("关于免费签名")
                    .font(AppFont.headline)
                    .foregroundColor(Theme.textPrimary)

                Text("用免费 Apple ID 签名安装的 App，Apple 只给 7 天有效期，到期后需要重新安装一次才能继续用。这是 Apple 的规则，与墨语无关。")
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(SignatureClock.summary)
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 页脚

    private var footer: some View {
        VStack(spacing: AppMetrics.hairGap) {
            Text("本 App 不含任何统计 SDK，不会上传任何输入内容。")
                .font(AppFont.caption)
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
            Text("用 SwiftUI 手写，为中文输入而生。")
                .font(AppFont.caption)
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppMetrics.blockGap)
    }
}

#if DEBUG
struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            AboutView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
