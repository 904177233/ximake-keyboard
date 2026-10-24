//
//  InstallGuideView.swift
//  墨语 · 宿主 App
//
//  模块职责：安装与续签指南（**无 Mac 主线**）。
//            顶部决策卡告诉用户该走哪条路；下面是 5 张 StepCard：
//            ①云编译出 ipa ②Sideloadly 安装 ③添加键盘+完全访问 ④配置 AI+同步 ⑤7 天续签。
//            每个能复制的东西都给「复制」按钮；底部有可复制的续签清单。
//  依赖：SwiftUI、AppState、StepCard / StepConnector / SurfaceCard / SectionHeader /
//        PrimaryButton / SecondaryButton / ErrorBanner、SignatureClock / AppInfo。
//  使用方：SettingsView / KeyboardHomeView / OnboardingView / AboutView。
//

import SwiftUI

/// 签名路线。
enum SigningRoute: String, CaseIterable, Identifiable {
    /// 有 Mac：Xcode 直接 Run（推荐给有 Mac 的人）。
    case xcode
    /// 只有 Windows：GitHub Actions 云编译 + Sideloadly。
    case cloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xcode: return "我有 Mac"
        case .cloud: return "我只有 Windows / 没装 Xcode"
        }
    }

    var subtitle: String {
        switch self {
        case .xcode: return "Xcode 打开工程 → 改 Bundle ID/Team → 真机 Run"
        case .cloud: return "GitHub Actions 云端编译出 ipa → Sideloadly 装到 iPhone"
        }
    }

    var systemImage: String {
        switch self {
        case .xcode: return "laptopcomputer"
        case .cloud: return "cloud"
        }
    }

    var badge: String? {
        switch self {
        case .xcode: return nil
        case .cloud: return "推荐"
        }
    }
}

/// 安装与续签指南。
struct InstallGuideView: View {

    @EnvironmentObject private var appState: AppState

    /// 初始高亮的步骤（1-based）；由键盘主页「添加键盘」入口传入。
    var initialStep: Int = 1

    /// 当前路线（默认云编译，因为大多数人是 Windows）。
    @State private var route: SigningRoute = .cloud

    /// 已完成步骤集合。
    @State private var completedSteps: Set<Int> = []

    /// 展开的「我需要什么」。
    @State private var showsRequirements = false

    init(initialStep: Int = 1) {
        self.initialStep = initialStep
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                warningCard
                routeCard
                stepsSection
                renewalChecklist
                if route == .cloud {
                    requirementsCard
                }
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle("安装与续签")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 根据入口高亮：从「添加键盘」进来时把第 3 步先标成已知位置。
            if initialStep >= 1 {
                completedSteps.formUnion(Array(1..<min(initialStep, 5)))
            }
        }
    }

    // MARK: - 顶部警告

    private var warningCard: some View {
        ErrorBanner(
            severity: .warning,
            title: "免费签名 7 天过期是 Apple 的限制，不是 App 的问题",
            message: "\(SignatureClock.summary)。到期后重新走一次安装流程即可。"
        )
    }

    // MARK: - 路线决策卡

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "我应该走哪条路？", footnote: "看你有没有 Mac")

            SurfaceCard {
                VStack(spacing: AppMetrics.blockGap) {
                    ForEach(SigningRoute.allCases) { item in
                        routeOption(item)
                    }
                }
            }
        }
    }

    private func routeOption(_ item: SigningRoute) -> some View {
        Button {
            withAnimation(Theme.Motion.spring) {
                route = item
                completedSteps.removeAll()
            }
            Haptics.selection()
        } label: {
            HStack(alignment: .top, spacing: AppMetrics.rowGap) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                        .fill(route == item ? AppColor.accentWash : Theme.surfaceElevated)
                        .frame(width: AppMetrics.providerAvatar, height: AppMetrics.providerAvatar)
                    IconGlyph(
                        symbol: item.systemImage,
                        fallback: "•",
                        size: AppMetrics.glyphSize,
                        weight: .semibold,
                        tint: route == item ? Theme.accent : Theme.textSecondary
                    )
                }

                VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                    HStack(spacing: AppMetrics.tightGap) {
                        Text(item.title)
                            .font(AppFont.headline)
                            .foregroundColor(Theme.textPrimary)
                        if let badge = item.badge {
                            PillChip(badge, style: .tag, action: {})
                                .allowsHitTesting(false)
                        }
                    }
                    Text(item.subtitle)
                        .font(AppFont.footnote)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                IconGlyph(
                    symbol: route == item ? "checkmark.circle.fill" : "circle",
                    fallback: route == item ? "✓" : "○",
                    size: AppMetrics.glyphSize,
                    tint: route == item ? Theme.accent : Theme.textTertiary
                )
            }
            .padding(AppMetrics.tightGap)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                    .fill(route == item ? AppColor.accentWash.opacity(0.6) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityAddTraits(route == item ? [.isSelected] : [])
    }

    // MARK: - 五个步骤

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(
                title: "5 个步骤",
                footnote: route == .cloud ? "Windows 全程可完成，不需要 Mac" : "有 Mac 时最快"
            )

            VStack(spacing: 0) {
                ForEach(Array(stepModels.enumerated()), id: \.offset) { index, model in
                    StepCard(
                        index: model.index,
                        title: model.title,
                        detail: model.detail,
                        icon: model.icon,
                        codeSnippet: model.codeSnippet,
                        isDone: completedSteps.contains(model.index),
                        actionTitle: model.actionTitle
                    ) {
                        toggleStep(model.index)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: AppMetrics.cardRadius, style: .continuous)
                            .strokeBorder(
                                initialStep == model.index ? Theme.accent.opacity(0.5) : Color.clear,
                                lineWidth: AppMetrics.hairline * 2
                            )
                    )

                    if index < stepModels.count - 1 {
                        StepConnector()
                    }
                }
            }
        }
    }

    /// 步骤数据。
    private struct StepModel {
        var index: Int
        var title: String
        var detail: String
        var icon: String
        var codeSnippet: String?
        var actionTitle: String?
    }

    /// 按路线生成步骤。
    private var stepModels: [StepModel] {
        switch route {
        case .cloud:
            return cloudSteps
        case .xcode:
            return xcodeSteps
        }
    }

    /// 云编译路线（无 Mac 主线）。
    private var cloudSteps: [StepModel] {
        [
            StepModel(
                index: 1,
                title: "把工程推到 GitHub，跑「Build Unsigned IPA」",
                detail: "Fork / 上传本工程到你的私有仓库 → 打开仓库的 Actions 页 → 选「Build Unsigned IPA」→ Run workflow。跑完后在 Artifacts 里下载 AIKeyboard-unsigned.ipa（不需要改任何代码，也不需要 Mac）。",
                icon: "hammer",
                codeSnippet: "仓库 → Actions → Build Unsigned IPA → Run workflow → 下载 Artifacts 里的 AIKeyboard-unsigned.ipa",
                actionTitle: "标记为已完成"
            ),
            StepModel(
                index: 2,
                title: "在 Windows 上用 Sideloadly 安装",
                detail: "先用微软商店装 iTunes（提供 iPhone 驱动），再装 Sideloadly。手机用数据线连电脑并点「信任此电脑」，把 ipa 拖进 Sideloadly，填你的 Apple ID，点 Start，按提示输入 2FA 验证码。",
                icon: "arrow.down.to.line",
                codeSnippet: "microsoft.com/store → 搜 iTunes 安装\nsideloadly.io → 下载并安装 Sideloadly\nSideloadly：拖入 ipa → 填 Apple ID → Start → 输入 2FA",
                actionTitle: "标记为已完成"
            ),
            StepModel(
                index: 3,
                title: "信任开发者 + 添加键盘 + 开完全访问",
                detail: "第一次安装后打开 App 会提示「不受信任的开发者」，去「设置 › 通用 › VPN与设备管理」里点你的 Apple ID → 信任。然后去「设置 › 通用 › 键盘 › 键盘 › 添加新键盘」选墨语；再点墨语 → 打开「允许完全访问」。",
                icon: "checkmark.shield",
                codeSnippet: AppInfo.trustPath + "\n" + AppInfo.keyboardSettingsPath + "\n" + AppInfo.openAccessPath,
                actionTitle: "打开系统设置"
            ),
            StepModel(
                index: 4,
                title: "配置 AI 服务并同步到键盘",
                detail: "在本 App 里添加一个对话服务商（如 DeepSeek）并填 API Key，点「测试连接」确认可用；然后去「设置 › 同步到键盘」，写入剪贴板，再打开键盘点 ⚙️ → 从 App 导入。",
                icon: "sparkles",
                codeSnippet: "设置 › AI 服务 → 添加服务商\n设置 › 同步到键盘 → 写入配置到剪贴板",
                actionTitle: "标记为已完成"
            ),
            StepModel(
                index: 5,
                title: "7 天续签：重新跑一次步骤 2",
                detail: "免费 Apple ID 的签名 7 天过期。到期前用 Sideloadly 重新装一次同一个 ipa 就行，配置与 API Key 都保留（它们不在 App 包里）。续签清单在页面底部，可以复制。",
                icon: "arrow.clockwise",
                codeSnippet: "1. 打开 Sideloadly，连上 iPhone\n2. 重新拖入同一个 ipa\n3. 填同一个 Apple ID，Start\n4. 手机上确认图标已恢复（配置不会丢）",
                actionTitle: "标记为已完成"
            )
        ]
    }

    /// Xcode 路线（有 Mac 的人）。
    private var xcodeSteps: [StepModel] {
        [
            StepModel(
                index: 1,
                title: "用 Xcode 打开工程",
                detail: "双击 ios/ 目录下的 .xcodeproj（或 .xcworkspace），等待 Xcode 完成索引。本工程没有任何第三方依赖，不需要 pod install。",
                icon: "laptopcomputer",
                codeSnippet: "ios/AIKeyboard.xcodeproj",
                actionTitle: "标记为已完成"
            ),
            StepModel(
                index: 2,
                title: "改 Bundle ID 与 Team",
                detail: "在 Xcode 左侧选项目 → Targets → Signing & Capabilities：把 App 与键盘扩展的 Bundle Identifier 改成你自己的（如 com.你的名字.moyu），Team 选你的免费 Apple ID，勾上 Automatically manage signing。",
                icon: "signature",
                codeSnippet: "Project → Targets → Signing & Capabilities\nBundle Identifier: com.你的名字.moyu\nTeam: 你的 Apple ID",
                actionTitle: "标记为已完成"
            ),
            StepModel(
                index: 3,
                title: "连真机 Run",
                detail: "数据线连 iPhone，在 Xcode 顶部选择你的设备，点 Run。首次运行需要在手机「设置 › 通用 › VPN与设备管理」里信任你的开发者证书。",
                icon: "play.rectangle",
                codeSnippet: AppInfo.trustPath,
                actionTitle: "标记为已完成"
            ),
            StepModel(
                index: 4,
                title: "添加键盘并开启完全访问",
                detail: "「设置 › 通用 › 键盘 › 键盘 › 添加新键盘」里选墨语；点墨语 → 打开「允许完全访问」。AI 需要联网，不开这个键盘里就用不了 AI。",
                icon: "keyboard",
                codeSnippet: AppInfo.keyboardSettingsPath + "\n" + AppInfo.openAccessPath,
                actionTitle: "打开系统设置"
            ),
            StepModel(
                index: 5,
                title: "配置 AI 服务 + 7 天续签",
                detail: "在 App 里添加对话服务商并填 API Key。免费签名 7 天过期，到期前用 Xcode 重新 Run 一次即可，配置不丢。",
                icon: "arrow.clockwise",
                codeSnippet: "Xcode → 选设备 → Run（每 7 天一次）",
                actionTitle: "标记为已完成"
            )
        ]
    }

    /// 步骤行内按钮。
    private func toggleStep(_ index: Int) {
        if index == 3 {
            // 第 3 步的按钮是「打开系统设置」。
            openSystemSettings()
            return
        }
        withAnimation(Theme.Motion.normalAnimation) {
            if completedSteps.contains(index) {
                completedSteps.remove(index)
            } else {
                completedSteps.insert(index)
            }
        }
        Haptics.selection()
    }

    /// 打开系统设置（跳本 App 设置页）。
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        appState.showToast(
            ToastMessage(
                kind: .info,
                text: "已打开系统设置",
                detail: "系统不允许直接跳到键盘列表，请按页面上的路径手动进入。"
            )
        )
        Haptics.light()
    }

    // MARK: - 续签清单

    private var renewalChecklist: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "续签清单", footnote: "复制后照着做，约 3 分钟")

            SurfaceCard {
                VStack(alignment: .leading, spacing: AppMetrics.rowVPadding) {
                    Text(Self.renewalChecklistText)
                        .font(AppFont.monospacedFootnote)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SecondaryButton(
                        title: "复制清单",
                        systemImage: "doc.on.doc",
                        tone: .neutral,
                        size: .small
                    ) {
                        UIPasteboard.general.string = Self.renewalChecklistText
                        appState.showToast(ToastMessage(kind: .success, text: "续签清单已复制"))
                        Haptics.success()
                    }
                }
            }

            Text("当前估算：\(SignatureClock.summary)。")
                .font(AppFont.caption)
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 可复制的续签清单纯文本。
    private static let renewalChecklistText = """
    墨语 · 7 天续签清单
    [ ] 1. 电脑上打开 Sideloadly（或 Xcode）
    [ ] 2. 数据线连上 iPhone，手机点「信任此电脑」
    [ ] 3. 把同一个 AIKeyboard-unsigned.ipa 重新拖进去
    [ ] 4. 填同一个 Apple ID，点 Start，输入 2FA
    [ ] 5. 等进度条走完，手机上确认图标可用
    [ ] 6. 打开 App，确认「设置」里 API Key 与配置还在
    [ ] 7. 如提示不受信任：设置 › 通用 › VPN与设备管理 › 信任

    说明：配置与 API Key 不在安装包里，重装不会丢；只有 App 会被替换。
    """

    // MARK: - 环境要求

    private var requirementsCard: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SurfaceCard(padding: 0) {
                VStack(spacing: 0) {
                    SettingsRow(
                        icon: IconSpec(symbol: "checklist", tint: Theme.accent),
                        title: "我需要在 Windows 上准备什么",
                        subtitle: "iTunes / Sideloadly / 数据线 / Apple ID",
                        accessory: .chevron
                    ) {
                        withAnimation(Theme.Motion.spring) {
                            showsRequirements.toggle()
                        }
                    }

                    if showsRequirements {
                        RowDivider()
                        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                            requirementLine("一台 Windows 电脑", "Windows 10 及以上")
                            requirementLine("iTunes（微软商店版）", "提供 iPhone 驱动，Sideloadly 需要它")
                            requirementLine("Sideloadly", "免费，官网 sideloadly.io 下载")
                            requirementLine("数据线", "第一次安装必须连线；续签也要连")
                            requirementLine("Apple ID", "免费账号即可，不需要开发者账号")
                            requirementLine("GitHub 账号", "用来跑云端编译（公开/私有仓库都可以）")
                        }
                        .padding(AppMetrics.cardPadding)
                    }
                }
            }
        }
    }

    private func requirementLine(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: AppMetrics.tightGap) {
            IconGlyph(
                symbol: "checkmark",
                fallback: "✓",
                size: AppMetrics.glyphSizeSmall,
                weight: .semibold,
                tint: Theme.success
            )
            VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                Text(title)
                    .font(AppFont.footnoteStrong)
                    .foregroundColor(Theme.textPrimary)
                Text(detail)
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#if DEBUG
struct InstallGuideView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            InstallGuideView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
