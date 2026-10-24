//
//  ProviderListView.swift
//  墨语 · 宿主 App
//
//  模块职责：AI 服务商列表（设置 › AI 服务）。支持新增、编辑、删除、设为默认、测试连接。
//  依赖：SwiftUI、AppState、ProviderRow / EmptyState / ErrorBanner、ProviderEditorView。
//  使用方：SettingsView / KeyboardHomeView / OnboardingView。
//

import SwiftUI

/// 服务商列表。
struct ProviderListView: View {

    /// 是否只展示"生图服务商"（true 时列表过滤为 supportsImage）。
    var showImageProviders: Bool = false

    @EnvironmentObject private var appState: AppState

    /// 正在编辑的服务商（nil 表示不展示编辑页）。
    @State private var editingProvider: AIProviderConfig?

    /// 是否新建。
    @State private var isCreating = false

    /// 待删除的服务商（二次确认）。
    @State private var pendingDelete: AIProviderConfig?

    /// 各服务商的连接状态。
    @State private var statuses: [String: ConnectionStatus] = [:]

    private var providers: [AIProviderConfig] {
        showImageProviders ? appState.providers.filter { $0.supportsImage } : appState.providers
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                infoBanner

                if providers.isEmpty {
                    emptyView
                } else {
                    listSection
                }

                addButton
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle(showImageProviders ? "生图服务商" : "AI 服务")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    startCreating()
                } label: {
                    IconGlyph(symbol: "plus", fallback: "＋", size: AppMetrics.glyphSize, weight: .semibold, tint: Theme.accent)
                }
                .accessibilityLabel(Text("添加服务商"))
            }
        }
        .sheet(item: $editingProvider) { provider in
            NavigationStack {
                ProviderEditorView(provider: provider) { saved in
                    appState.upsertProvider(saved)
                    if saved.supportsChat, appState.snapshot.defaultProviderID == nil {
                        appState.setDefaultChatProvider(id: saved.id)
                    }
                    if saved.supportsImage, appState.snapshot.imageProviderID == nil {
                        appState.setDefaultImageProvider(id: saved.id)
                    }
                    editingProvider = nil
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack {
                ProviderEditorView(provider: nil) { saved in
                    appState.upsertProvider(saved)
                    if saved.supportsChat, appState.snapshot.defaultProviderID == nil {
                        appState.setDefaultChatProvider(id: saved.id)
                    }
                    if saved.supportsImage, appState.snapshot.imageProviderID == nil {
                        appState.setDefaultImageProvider(id: saved.id)
                    }
                    isCreating = false
                }
            }
        }
        .alert(item: $pendingDelete) { provider in
            Alert(
                title: Text("删除「\(provider.name)」？"),
                message: Text("删除后该服务商的 API Key 也会从钥匙串移除。"),
                primaryButton: .destructive(Text("删除")) {
                    appState.deleteProvider(id: provider.id)
                    statuses[provider.id] = nil
                    Haptics.warning()
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .onAppear(perform: seedStatuses)
    }

    // MARK: - 顶部说明

    private var infoBanner: some View {
        ErrorBanner(
            severity: .info,
            title: "API Key 只存在本机钥匙串",
            message: "不会上传到任何服务器，也不会写进配置导出。"
        )
    }

    // MARK: - 列表

    private var listSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: showImageProviders ? "生图服务商" : "对话服务商")

            if showImageProviders {
                // 生图服务商列表：选中即设为默认生图服务商。
                imageProviderCards
            } else {
                chatProviderList
            }
        }
    }

    /// 对话服务商列表。
    private var chatProviderList: some View {
        ListGroup {
            ForEach(Array(chatProviderCandidates.enumerated()), id: \.element.id) { index, provider in
                ProviderRow(
                    name: provider.name,
                    kindTitle: provider.kind.title,
                    model: provider.model,
                    isDefault: provider.id == appState.snapshot.defaultProviderID,
                    status: statuses[provider.id] ?? statusFor(provider)
                ) {
                    editingProvider = provider
                }
                .contextMenu {
                    Button("设为默认对话服务商") {
                        appState.setDefaultChatProvider(id: provider.id)
                    }
                    Button("测试连接") {
                        testConnection(provider)
                    }
                    Button("删除", role: .destructive) {
                        pendingDelete = provider
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = provider
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }

                if index < chatProviderCandidates.count - 1 {
                    RowDivider()
                }
            }
        }
    }

    /// 生成生图服务商卡片（复用 SurfaceCard + 明确的"设为默认"按钮）。
    private var imageProviderCards: some View {
        VStack(spacing: AppMetrics.blockGap) {
            ForEach(imageProviderCandidates) { provider in
                SurfaceCard {
                    VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                        HStack(spacing: AppMetrics.rowGap) {
                            RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                                .fill(AppColor.warningWash)
                                .frame(width: AppMetrics.providerAvatar, height: AppMetrics.providerAvatar)
                                .overlay(
                                    IconGlyph(
                                        symbol: "photo.on.rectangle.angled",
                                        fallback: "🎨",
                                        size: AppMetrics.glyphSize,
                                        weight: .semibold,
                                        tint: Theme.warning
                                    )
                                )

                            VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                                HStack(spacing: AppMetrics.tightGap) {
                                    Text(provider.name)
                                        .font(AppFont.headline)
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)
                                    if provider.id == appState.snapshot.imageProviderID {
                                        PillChip("默认", style: .tag, action: {})
                                            .allowsHitTesting(false)
                                    }
                                }
                                Text("\(provider.kind.title) · \(provider.imageModel ?? "未填写生图模型")")
                                    .font(AppFont.footnote)
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 0)
                        }

                        HStack(spacing: AppMetrics.blockGap) {
                            SecondaryButton(title: "编辑", tone: .neutral, size: .small) {
                                editingProvider = provider
                            }
                            SecondaryButton(title: "设默认", tone: .neutral, size: .small) {
                                appState.setDefaultImageProvider(id: provider.id)
                            }
                            Spacer(minLength: 0)
                            Text(appState.hasAPIKey(for: provider.id) ? "已存 Key" : "未填 Key")
                                .font(AppFont.caption)
                                .foregroundColor(appState.hasAPIKey(for: provider.id) ? Theme.success : Theme.warning)
                        }
                    }
                }
            }
        }
    }

    /// 对话候选：有模型的都要展示，但仅生图的会标注不可用。
    private var chatProviderCandidates: [AIProviderConfig] {
        appState.providers.filter { !$0.model.isEmpty || !$0.supportsChat }
    }

    /// 生图候选。
    private var imageProviderCandidates: [AIProviderConfig] {
        providers.filter { $0.supportsImage }
    }

    // MARK: - 空态

    private var emptyView: some View {
        SurfaceCard {
            EmptyState(
                symbol: "server.rack",
                fallbackEmoji: "🛠️",
                title: showImageProviders ? "还没有生图服务商" : "还没有 AI 服务",
                message: showImageProviders
                    ? "添加「即梦 · 火山方舟」或「通义万相」，就能在试验场画图。"
                    : "添加一个服务商，键盘里的 AI 才能用。",
                actionTitle: "添加服务",
                action: { startCreating() }
            )
        }
    }

    private var addButton: some View {
        PrimaryButton(
            title: showImageProviders ? "添加生图服务商" : "添加服务商",
            systemImage: "plus",
            tone: .accent,
            size: .medium,
            fullWidth: true
        ) {
            startCreating()
        }
    }

    // MARK: - 状态与操作

    private func statusFor(_ provider: AIProviderConfig) -> ConnectionStatus {
        if !appState.hasAPIKey(for: provider.id) {
            return .untested
        }
        return .untested
    }

    private func seedStatuses() {
        for provider in appState.providers where statuses[provider.id] == nil {
            statuses[provider.id] = .untested
        }
    }

    private func startCreating() {
        Haptics.light()
        isCreating = true
    }

    /// 就地测试连接：发一条 hi 的流式请求，统计耗时。
    private func testConnection(_ provider: AIProviderConfig) {
        guard let key = appState.apiKey(for: provider.id), !key.isEmpty else {
            appState.showToast(
                ToastMessage(kind: .warning, text: "还没有填写 API Key", detail: "请先编辑该服务商并保存 Key。")
            )
            return
        }

        statuses[provider.id] = .testing
        let startedAt = Date()

        Task {
            var received = ""
            do {
                let stream = ConnectivityProbe.makeHelloStream(config: provider, apiKey: key)
                for try await delta in stream {
                    if !delta.text.isEmpty {
                        received += delta.text
                    }
                    if delta.isFinal {
                        break
                    }
                }
                let latency = Int(Date().timeIntervalSince(startedAt) * 1000)
                await MainActor.run {
                    statuses[provider.id] = .ok(latencyMs: latency)
                    Haptics.success()
                    appState.showToast(
                        ToastMessage(
                            kind: .success,
                            text: "连接成功 · \(provider.model)",
                            detail: received.isEmpty ? "服务商已响应" : "返回：\(received.prefix(40))"
                        )
                    )
                }
            } catch {
                let message = ErrorPresenter.message(error)
                await MainActor.run {
                    statuses[provider.id] = .failed(message)
                    Haptics.warning()
                    appState.showToast(
                        ToastMessage(
                            kind: .failure,
                            text: message,
                            detail: ErrorPresenter.suggestion(error)
                        )
                    )
                }
            }
        }
    }
}

#if DEBUG
struct ProviderListView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ProviderListView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
