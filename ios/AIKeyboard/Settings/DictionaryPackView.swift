//
//  DictionaryPackView.swift
//  墨语（Moyu）宿主 App · 在线词库包
//
//  模块职责：展示当前词库来源 / 版本 / 条数，手动检查更新，开关自动检查，
//            改清单地址，回滚到内置词库。
//  设计依据：design/06 §7.5（设置页只保留"一张纸 + 发丝线"，不做花活）。
//  约束：本页**不下载**词库（免费签名没有 App Group，宿主 App 下载的扩展读不到），
//        真正的下载发生在键盘扩展里。本页的作用是"看见 + 触发 + 兜底"。
//

import SwiftUI

/// 在线词库包设置页。
struct DictionaryPackView: View {

    /// 全局状态。
    @EnvironmentObject private var appState: AppState

    /// 在线词库包存储（单例）。
    private let store = DictionaryPackStore.shared

    /// 已安装信息（nil 表示当前用安装包内置词库）。
    @State private var installed: DictionaryPackInfo?

    /// 是否正在检查。
    @State private var isChecking = false

    /// 检查结果一句话。
    @State private var resultMessage: String = ""

    /// 清单地址草稿。
    @State private var manifestDraft: String = ""

    /// 自动检查开关镜像。
    @State private var autoUpdate = true

    /// 上次检查时间的展示文案。
    @State private var lastCheckText: String = "从未检查"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                statusSection
                actionSection
                autoSection
                manifestSection
                footnoteSection
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(Theme.surfaceGrouped.ignoresSafeArea())
        .navigationTitle("词库")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
    }

    // MARK: - 状态

    /// 当前词库来源与版本。
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "当前词库", footnote: "在线词库包只会更新词表，不会上传你输入的任何内容")

            ListGroup {
                SettingsRow(
                    icon: IconSpec(symbol: "character.book.closed.fill", tint: Theme.accent),
                    title: "来源",
                    subtitle: installed == nil ? "安装包内置" : "在线词库包"
                )
                RowDivider()
                SettingsRow(
                    icon: IconSpec(symbol: "number", tint: Theme.accent),
                    title: "版本",
                    subtitle: versionText
                )
                RowDivider()
                SettingsRow(
                    icon: IconSpec(symbol: "list.bullet", tint: Theme.accent),
                    title: "词条数",
                    subtitle: entryCountText
                )
                RowDivider()
                SettingsRow(
                    icon: IconSpec(symbol: "clock", tint: Theme.accent),
                    title: "上次检查",
                    subtitle: lastCheckText
                )
            }

            if !resultMessage.isEmpty {
                Text(resultMessage)
                    .font(Theme.fontFootnote)
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, AppMetrics.cardPadding)
            }
        }
    }

    // MARK: - 操作

    /// 检查更新 / 回滚。
    private var actionSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "更新", footnote: "更新在键盘里完成：打开任意输入框 > 切换墨语键盘 > 等几秒（需开完全访问）")

            ListGroup {
                SettingsRow(
                    icon: IconSpec(symbol: "arrow.triangle.2.circlepath", tint: Theme.accent),
                    title: "检查更新",
                    subtitle: isChecking ? "正在检查…" : "从 jsDelivr 拉取最新词库清单",
                    accessory: isChecking ? .none : .chevron
                ) {
                    guard !isChecking else { return }
                    Task { await checkNow() }
                }

                if installed != nil {
                    RowDivider()
                    SettingsRow(
                        icon: IconSpec(symbol: "arrow.uturn.backward", tint: Theme.accent),
                        title: "回滚到内置词库",
                        subtitle: "删掉已下载的词库，恢复安装包自带的那份",
                        accessory: .chevron
                    ) {
                        rollback()
                    }
                }
            }
        }
    }

    // MARK: - 自动检查

    /// 自动检查开关。
    private var autoSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "自动检查", footnote: "每 24 小时最多查一次，失败完全静默")

            ListGroup {
                SettingsRow(
                    icon: IconSpec(symbol: "clock.arrow.circlepath", tint: Theme.accent),
                    title: "自动检查更新",
                    subtitle: autoUpdate ? "已开启" : "已关闭",
                    accessory: .toggle(Binding(
                        get: { autoUpdate },
                        set: { newValue in
                            autoUpdate = newValue
                            store.isAutoUpdateEnabled = newValue
                            Haptics.selection()
                        }
                    ))
                )
            }
        }
    }

    // MARK: - 清单地址

    /// 自定义清单地址（自建服务器时用）。
    private var manifestSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "清单地址", footnote: "留空用默认地址；自建词库服务器时改成你的 https 地址")

            ListGroup {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    TextField("https://…/dict_manifest.json", text: $manifestDraft)
                        .font(Theme.fontBody)
                        .foregroundColor(Theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .onSubmit(applyManifest)

                    HStack(spacing: Theme.Spacing.lg) {
                        Button("保存地址", action: applyManifest)
                            .font(Theme.fontChip)
                            .foregroundColor(Theme.accent)
                        Button("恢复默认") {
                            manifestDraft = DictionaryPackStore.defaultManifestURL
                            applyManifest()
                        }
                        .font(Theme.fontChip)
                        .foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, AppMetrics.cardPadding)
                .padding(.vertical, Theme.Spacing.lg)
            }
        }
    }

    // MARK: - 脚注

    /// 隐私与限制说明。
    private var footnoteSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("为什么在键盘里下载：免费签名没有 App Group，宿主 App 与键盘扩展是两个独立沙盒，宿主下载的那份扩展读不到。")
            Text("校验方式：字节数 + SHA-256 + 词条数三层校验，任何一层不过就整体放弃并保留旧词库。")
        }
        .font(Theme.fontFootnote)
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, AppMetrics.cardPadding)
    }

    // MARK: - 文案

    /// 版本文案。
    private var versionText: String {
        guard let installed else { return "内置 v\(appState.dictionaryInfo?.version ?? "未知")" }
        return "v\(installed.version)"
    }

    /// 词条数文案。
    private var entryCountText: String {
        guard let installed, installed.entryCount > 0 else {
            return "\(appState.dictionaryInfo?.wordCount ?? 0) 条"
        }
        return "\(installed.entryCount) 条"
    }

    // MARK: - 动作

    /// 刷新页面状态。
    private func refresh() {
        installed = store.installedInfo
        autoUpdate = store.isAutoUpdateEnabled
        manifestDraft = store.manifestURLString
        resultMessage = store.lastResult
        lastCheckText = Self.format(store.lastCheckAt)
    }

    /// 手动检查更新。
    private func checkNow() async {
        isChecking = true
        resultMessage = ""
        defer { isChecking = false }
        do {
            let message = try await store.checkAndInstall(forced: true)
            resultMessage = message
            Haptics.success()
        } catch let error as DictionaryPackError {
            resultMessage = [error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: "。")
            Haptics.warning()
        } catch {
            resultMessage = error.localizedDescription
            Haptics.warning()
        }
        installed = store.installedInfo
        lastCheckText = Self.format(store.lastCheckAt)
    }

    /// 回滚到内置词库。
    private func rollback() {
        do {
            try store.rollback()
            resultMessage = "已回滚到内置词库"
            Haptics.success()
        } catch let error as DictionaryPackError {
            resultMessage = error.errorDescription ?? "回滚失败"
            Haptics.warning()
        } catch {
            resultMessage = error.localizedDescription
            Haptics.warning()
        }
        installed = store.installedInfo
    }

    /// 保存清单地址。
    private func applyManifest() {
        let trimmed = manifestDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        store.manifestURLString = trimmed.isEmpty ? DictionaryPackStore.defaultManifestURL : trimmed
        manifestDraft = store.manifestURLString
        resultMessage = "清单地址已保存"
        Haptics.selection()
    }

    /// 时间戳 → 「N 分钟前」。
    private static func format(_ timestamp: TimeInterval) -> String {
        guard timestamp > 0 else { return "从未检查" }
        let interval = Date().timeIntervalSince1970 - timestamp
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        return "\(Int(interval / 86400)) 天前"
    }
}

#if DEBUG
struct DictionaryPackView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            DictionaryPackView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
