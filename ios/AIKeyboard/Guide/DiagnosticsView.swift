//
//  DiagnosticsView.swift
//  墨语 · 宿主 App
//
//  模块职责：环境自检页（9 项）—— 键盘扩展是否已添加、完全访问、AI 服务配置、
//            API 连通性、钥匙串可写、本地词库、存储模式、配置快照、网络连接。
//            顶部「全部重测」，底部「导出诊断报告」（复制纯文本，不含密钥）。
//  依赖：SwiftUI、AppState、SharedBridge（ConnectivityProbe / ConfigExporter /
//        DictionaryInfo / ExtensionTelemetry）、Shared（SharedStore / ConfigSnapshot）、
//        SignatureClock、DiagnosticsFormat / DiagnosticsChecklist。
//  使用方：SettingsView / KeyboardHomeView。
//

import SwiftUI

/// 环境自检。
struct DiagnosticsView: View {

    @EnvironmentObject var appState: AppState

    /// 一项自检的状态。
    enum CheckState: Equatable {
        /// 通过。
        case ok
        /// 需要注意。
        case warning
        /// 失败。
        case failure
        /// 纯信息。
        case info
        /// 正在检查。
        case running

        /// 状态图标。
        var symbol: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .failure: return "xmark.octagon.fill"
            case .info: return "info.circle.fill"
            case .running: return "clock"
            }
        }

        /// 状态兜底字符。
        var fallback: String {
            switch self {
            case .ok: return "✓"
            case .warning: return "!"
            case .failure: return "✕"
            case .info: return "i"
            case .running: return "…"
            }
        }

        /// 状态颜色。
        var tint: Color {
            switch self {
            case .ok: return Theme.success
            case .warning: return Theme.warning
            case .failure: return Theme.danger
            case .info: return Theme.textSecondary
            case .running: return Theme.accent
            }
        }
    }

    /// 单项目检结果。
    struct CheckItem: Identifiable {
        /// 稳定 ID（用于报告与列表）。
        var id: String
        /// 名称。
        var title: String
        /// 状态。
        var state: CheckState
        /// 说明。
        var detail: String
        /// 可选操作标题。
        var actionTitle: String?
        /// 可选操作。
        var action: (() -> Void)?
    }

    // MARK: - 状态（DiagnosticsChecklist.swift 里的扩展会读写这些字段）

    @State var checks: [CheckItem] = []
    @State var isRefreshing = false
    @State var isTestingProvider = false
    @State var providerTestDetail = "还没有测试"
    @State var providerTestState: CheckState = .info
    @State var networkDetail = "还没有检测"
    @State var networkState: CheckState = .info

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                summaryCard
                checkList
                signatureCard
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle("诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    exportReport()
                } label: {
                    Text("导出报告")
                        .font(AppFont.footnote)
                }
            }
        }
        .task {
            rebuildChecks()
        }
    }

    // MARK: - 汇总

    private var summaryCard: some View {
        SurfaceCard(style: .elevated) {
            VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                HStack(spacing: AppMetrics.rowGap) {
                    ZStack {
                        Circle()
                            .fill(overallState.tint.opacity(0.16))
                            .frame(width: AppMetrics.emptyIconBox, height: AppMetrics.emptyIconBox)
                        IconGlyph(
                            symbol: overallState.symbol,
                            fallback: overallState.fallback,
                            size: AppMetrics.glyphSizeLarge,
                            weight: .semibold,
                            tint: overallState.tint
                        )
                    }

                    VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                        Text(overallTitle)
                            .font(AppFont.pageTitle)
                            .foregroundColor(Theme.textPrimary)
                        Text(overallDetail)
                            .font(AppFont.footnote)
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                PrimaryButton(
                    title: "全部重测",
                    systemImage: "arrow.clockwise",
                    tone: .neutral,
                    size: .medium,
                    isLoading: isRefreshing,
                    fullWidth: true
                ) {
                    refreshAll()
                }
            }
        }
    }

    /// 总体状态。
    private var overallState: CheckState {
        if checks.contains(where: { $0.state == .failure }) { return .failure }
        if checks.contains(where: { $0.state == .warning }) { return .warning }
        return .ok
    }

    private var overallTitle: String {
        switch overallState {
        case .ok: return "环境看起来没问题"
        case .warning: return "有几项需要你看一眼"
        case .failure: return "有项目检查没通过"
        case .info: return "自检信息"
        case .running: return "正在检查…"
        }
    }

    private var overallDetail: String {
        let problems = checks.filter { $0.state == .failure || $0.state == .warning }.count
        if problems == 0 {
            return "共检查 \(checks.count) 项，全部通过。遇到问题可以把右上角的报告复制给我们。"
        }
        return "共检查 \(checks.count) 项，其中 \(problems) 项需要注意，逐条看下面的说明。"
    }

    // MARK: - 检查列表

    private var checkList: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "自检项", footnote: "从上到下逐条排查")

            SurfaceCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(checks.enumerated()), id: \.element.id) { index, item in
                        checkRow(item)
                        if index < checks.count - 1 {
                            RowDivider(hasIcon: true)
                        }
                    }
                }
            }
        }
    }

    private func checkRow(_ item: CheckItem) -> some View {
        HStack(alignment: .top, spacing: AppMetrics.rowGap) {
            ZStack {
                RoundedRectangle(cornerRadius: AppMetrics.iconTileRadius, style: .continuous)
                    .fill(item.state.tint.opacity(0.14))
                    .frame(width: AppMetrics.iconTileSize, height: AppMetrics.iconTileSize)

                if item.state == .running {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: item.state.tint))
                        .scaleEffect(0.6)
                } else {
                    IconGlyph(
                        symbol: item.state.symbol,
                        fallback: item.state.fallback,
                        size: AppMetrics.glyphSizeSmall,
                        weight: .semibold,
                        tint: item.state.tint
                    )
                }
            }

            VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                Text(item.title)
                    .font(AppFont.headline.weight(.regular))
                    .foregroundColor(Theme.textPrimary)

                Text(item.detail)
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                if let actionTitle = item.actionTitle, let action = item.action {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(AppFont.footnoteStrong)
                            .foregroundColor(Theme.accent)
                            .frame(minHeight: AppMetrics.minTapHeight, alignment: .leading)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppMetrics.cardPadding)
        .padding(.vertical, AppMetrics.rowVPadding)
    }

    // MARK: - 签名

    private var signatureCard: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "签名有效期", footnote: "估算值，仅供参考")

            SurfaceCard {
                VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                    Text(SignatureClock.summary)
                        .font(AppFont.body)
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("iOS 没有提供「当前签名还剩几天」的接口，这里按首次安装日期估算。真正是否过期，以系统是否提示「不受信任的开发者」为准。")
                        .font(AppFont.caption)
                        .foregroundColor(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    SecondaryButton(
                        title: "打开续签指南",
                        systemImage: "arrow.clockwise",
                        tone: .neutral,
                        size: .small
                    ) {
                        appState.showToast(
                            ToastMessage(
                                kind: .info,
                                text: "请到「设置 › 安装与续签指南」",
                                detail: "里面有可复制的续签清单。"
                            )
                        )
                    }
                }
            }
        }
    }

    // MARK: - 导出报告

    /// 复制纯文本诊断报告。
    private func exportReport() {
        let report = buildReport()
        UIPasteboard.general.string = report
        appState.showToast(
            ToastMessage(
                kind: .success,
                text: "诊断报告已复制",
                detail: "可以粘贴给开发者，里面不含 API 密钥。"
            )
        )
        Haptics.success()
    }

    /// 组装纯文本报告。
    private func buildReport() -> String {
        var lines: [String] = []
        lines.append("墨语 · 诊断报告")
        lines.append("时间：\(DiagnosticsFormat.dateFormatter.string(from: Date()))")
        lines.append("版本：\(AppInfo.version) (\(AppInfo.build)) · \(AppInfo.minimumIOS)+")
        lines.append("设备：\(DiagnosticsFormat.deviceDescription)")
        lines.append("")
        lines.append("== 自检结果 ==")
        for item in checks {
            lines.append("[\(Self.stateLabel(item.state))] \(item.title)：\(item.detail)")
        }
        lines.append("")
        lines.append("== 环境 ==")
        lines.append("App Group：\(ConfigExporter.isAppGroupAvailable ? "可用" : "不可用（免费账号常见）")")
        lines.append("存储：\(SharedStore.shared.storageStatusDescription)")
        lines.append("钥匙串：\(appState.isKeychainAvailable ? "可用" : "不可用")")
        if let info = appState.dictionaryInfo {
            lines.append("词库：v\(info.version) · \(info.wordCount) 词")
        } else {
            lines.append("词库：未加载")
        }
        lines.append("签名：\(SignatureClock.summary)")
        lines.append("")
        lines.append("== 配置快照（不含 API 密钥）==")
        lines.append(DiagnosticsFormat.snapshotJSON(appState.snapshot))
        return lines.joined(separator: "\n")
    }

    /// 自检状态的中文名（报告用）。
    private static func stateLabel(_ state: CheckState) -> String {
        switch state {
        case .ok: return "通过"
        case .warning: return "注意"
        case .failure: return "失败"
        case .info: return "信息"
        case .running: return "检测中"
        }
    }
}

#if DEBUG
struct DiagnosticsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            DiagnosticsView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
