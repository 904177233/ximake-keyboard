//
//  ProviderEditorView.swift
//  墨语 · 宿主 App
//
//  模块职责：新增 / 编辑一个 AI 服务商（Sheet）。
//            预设 chips（9 家对话 + 2 家生图）→ 自动填接口地址与默认模型 → 可手动改；
//            API 密钥走钥匙串（SecureField + 保存到钥匙串）；温度 / 最大回复长度 / 超时
//            在「高级参数」折叠区（已拆到 ProviderAdvancedEditor.swift）；
//            底部「测试连接」走 ConnectionTester 的探活流。
//  依赖：SwiftUI、AppState、PillChip / SurfaceCard / SecondaryButton / FormFieldRow、
//        ProviderAdvancedEditor、ConnectionTester / ConnectionTestBanner。
//  使用方：ProviderListView / SettingsView / OnboardingView。
//

import SwiftUI

/// 服务商编辑页。
struct ProviderEditorView: View {

    /// 编辑中的配置（nil 表示新建）。
    @State private var draft: AIProviderConfig

    /// 是否已有 Key（编辑已有配置时）。
    @State private var hasStoredKey: Bool

    /// API 密钥输入框内容（编辑时不回填明文）。
    @State private var apiKeyInput: String = ""

    /// 是否显示 API 密钥明文。
    @State private var showsAPIKey = false

    /// 是否展开「高级参数」。
    @State private var showsAdvanced = false

    /// 是否正在保存。
    @State private var isSaving = false

    /// 连接测试器。
    @StateObject private var tester = ConnectionTester()

    /// 当前选中的预设 ID（nil = 自定义）。
    @State private var selectedPresetID: String?

    /// 已存在的服务商（编辑模式）与保存回调。
    private let existingProvider: AIProviderConfig?
    private let onSave: (AIProviderConfig) -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// - Parameters:
    ///   - provider: 传入 nil 表示新建；传入已有配置表示编辑。
    ///   - onSave: 保存回调（已经完成 upsert 与 Keychain 写入后调用）。
    init(provider: AIProviderConfig?, onSave: @escaping (AIProviderConfig) -> Void) {
        self.existingProvider = provider
        self.onSave = onSave
        let initial = provider ?? PresetProviders.preset(id: "preset-deepseek")?.makeProvider()
            ?? AIProviderConfig(name: "自定义服务商")
        _draft = State(initialValue: initial)
        _hasStoredKey = State(initialValue: false)
        _selectedPresetID = State(initialValue: provider == nil ? "preset-deepseek" : nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                presetSection
                basicSection
                keySection
                modelSection
                advancedSection
                testSection
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.vertical, AppMetrics.cardPadding)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle(existingProvider == nil ? "添加服务商" : "编辑服务商")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消") { dismiss() }
                    .foregroundColor(Theme.textSecondary)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") { save() }
                    .font(AppFont.footnoteStrong)
                    .foregroundColor(canSave ? Theme.accent : Theme.textTertiary)
                    .disabled(!canSave || isSaving)
            }
        }
        .onAppear {
            hasStoredKey = existingProvider.map { appState.hasAPIKey(for: $0.id) } ?? false
        }
    }

    // MARK: - 预设

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "服务商预设", footnote: "选中后会自动填好接口地址与默认模型")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppMetrics.blockGap) {
                    ForEach(PresetProviders.all) { preset in
                        PillChip(
                            preset.isImageOnly ? "\(preset.name) · 仅生图" : preset.name,
                            style: .provider,
                            isSelected: selectedPresetID == preset.id,
                            action: { applyPreset(preset) }
                        )
                    }
                    PillChip(
                        "自定义",
                        systemImage: "slider.horizontal.3",
                        style: .provider,
                        isSelected: selectedPresetID == nil,
                        action: { applyCustom() }
                    )
                }
                .padding(.vertical, AppMetrics.hairGap)
            }
            .padding(.horizontal, -AppMetrics.pageInset)
            .padding(.leading, AppMetrics.pageInset)

            if let note = currentPresetNote {
                Text(note)
                    .font(AppFont.caption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let reason = ProviderKindHint.unsupportedChatReason(draft), draft.supportsImage {
                ErrorBanner(
                    severity: .warning,
                    title: "这是生图专用服务",
                    message: reason
                )
            }
        }
    }

    /// 当前预设的说明文案。
    private var currentPresetNote: String? {
        guard let id = selectedPresetID, let preset = PresetProviders.preset(id: id) else {
            return "自定义：手动填写接口地址与模型名，兼容 OpenAI / Anthropic 协议。"
        }
        if preset.isImageOnly {
            return "\(preset.note)（该服务只能生图，不能用于对话）"
        }
        return preset.note
    }

    // MARK: - 基本信息

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "基本信息")

            SurfaceCard {
                VStack(alignment: .leading, spacing: AppMetrics.rowVPadding) {
                    FormFieldRow(title: "名称", isRequired: true) {
                        TextField("例如 DeepSeek", text: $draft.name)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(AppFont.body)
                            .foregroundColor(Theme.textPrimary)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }

                    RowDivider(hasIcon: false)

                    FormFieldRow(title: "调用协议") {
                        SegmentedTabs(
                            tabs: protocolTabs,
                            selection: protocolBinding,
                            style: .plain
                        )
                    }

                    RowDivider(hasIcon: false)

                    FormFieldRow(title: "接口地址", isRequired: true, hint: "Base URL") {
                        TextField("https://api.deepseek.com/v1", text: $draft.baseURL)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(AppFont.monospacedFootnote)
                            .foregroundColor(Theme.textPrimary)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
            }
        }
    }

    /// 协议 tab 数据。
    private var protocolTabs: [SegmentedTabs.Tab] {
        ProviderKind.allCases.map { SegmentedTabs.Tab(id: $0.rawValue, title: $0.title) }
    }

    /// 协议绑定。
    private var protocolBinding: Binding<String> {
        Binding(
            get: { draft.kind.rawValue },
            set: { raw in draft.kind = ProviderKind.tolerant(rawValue: raw) }
        )
    }

    // MARK: - API 密钥

    private var keySection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(
                title: "API 密钥",
                footnote: "只保存在本机钥匙串，不会写进配置，也不会随「导出配置」一起复制"
            )

            SurfaceCard {
                VStack(alignment: .leading, spacing: AppMetrics.rowVPadding) {
                    HStack(spacing: AppMetrics.blockGap) {
                        if showsAPIKey {
                            TextField("sk-…", text: $apiKeyInput)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(AppFont.monospacedFootnote)
                                .foregroundColor(Theme.textPrimary)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        } else {
                            SecureField("sk-…", text: $apiKeyInput)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(AppFont.monospacedFootnote)
                                .foregroundColor(Theme.textPrimary)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }

                        Button {
                            showsAPIKey.toggle()
                        } label: {
                            IconGlyph(
                                symbol: showsAPIKey ? "eye.slash" : "eye",
                                fallback: showsAPIKey ? "隐藏" : "显示",
                                size: AppMetrics.glyphSizeSmall,
                                tint: Theme.textSecondary
                            )
                            .frame(width: AppMetrics.minTapHeight, height: AppMetrics.minTapHeight)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel(Text(showsAPIKey ? "隐藏密钥" : "显示密钥"))
                    }
                    .padding(.horizontal, AppMetrics.tightGap)
                    .frame(minHeight: AppMetrics.fieldHeight)
                    .background(
                        RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )

                    HStack(spacing: AppMetrics.blockGap) {
                        SecondaryButton(
                            title: hasStoredKey && apiKeyInput.isEmpty ? "已保存到钥匙串" : "保存到钥匙串",
                            systemImage: hasStoredKey && apiKeyInput.isEmpty ? "checkmark" : "key",
                            tone: .neutral,
                            size: .small,
                            isEnabled: !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ) {
                            saveKey()
                        }

                        if hasStoredKey {
                            SecondaryButton(title: "删除密钥", tone: .destructive, size: .small) {
                                deleteKey()
                            }
                        }

                        Spacer(minLength: 0)
                    }

                    Text(hasStoredKey ? "已保存 · 输入框留空表示不修改" : "填写后点「保存到钥匙串」，再点右上角保存。")
                        .font(AppFont.caption)
                        .foregroundColor(hasStoredKey ? Theme.success : Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 模型

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "模型", footnote: "对话模型必填；生图模型只在高级参数里配置")

            SurfaceCard {
                VStack(alignment: .leading, spacing: AppMetrics.rowVPadding) {
                    FormFieldRow(title: "对话模型", isRequired: draft.supportsImage == false) {
                        TextField("deepseek-chat", text: $draft.model)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(AppFont.monospacedFootnote)
                            .foregroundColor(Theme.textPrimary)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }

                    if let models = currentPresetModels, !models.isEmpty {
                        RowDivider(hasIcon: false)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: AppMetrics.tightGap) {
                                ForEach(models) { model in
                                    PillChip(
                                        model.title,
                                        style: .tool,
                                        isSelected: draft.model == model.modelID,
                                        action: {
                                            draft.model = model.modelID
                                            Haptics.selection()
                                        }
                                    )
                                }
                            }
                            .padding(.vertical, AppMetrics.hairGap)
                        }
                    }
                }
            }
        }
    }

    /// 当前预设的可选模型。
    private var currentPresetModels: [ModelRef]? {
        guard let id = selectedPresetID, let preset = PresetProviders.preset(id: id) else { return nil }
        return preset.availableModels
    }

    // MARK: - 高级参数

    private var advancedSection: some View {
        ProviderAdvancedEditor(
            draft: $draft,
            consoleURL: currentConsoleURL,
            isExpanded: $showsAdvanced
        )
    }

    /// 当前预设的服务商控制台地址。
    private var currentConsoleURL: URL? {
        guard let id = selectedPresetID else { return nil }
        return PresetProviders.preset(id: id)?.consoleURL
    }

    // MARK: - 测试连接

    private var testSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SecondaryButton(
                title: "测试连接",
                systemImage: "bolt.horizontal",
                tone: .neutral,
                size: .medium,
                isEnabled: !tester.state.isTesting,
                fullWidth: true
            ) {
                Haptics.light()
                tester.test(provider: draft, apiKey: resolvedKeyForTest())
            }

            ConnectionTestBanner(state: tester.state)

            Text("测试会向该服务商发一条「hi」的流式请求（最多 8 个词元），不会消耗多少额度。")
                .font(AppFont.caption)
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 逻辑

    /// 保存按钮是否可用。
    private var canSave: Bool {
        let nameOK = !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let urlOK = !draft.normalizedBaseURL.isEmpty
        let keyOK = hasStoredKey || !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let modelOK = draft.supportsImage || !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return nameOK && urlOK && keyOK && modelOK
    }

    /// 测试时使用的密钥：优先输入框，其次钥匙串。
    private func resolvedKeyForTest() -> String {
        let typed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            return typed
        }
        return appState.apiKey(for: draft.id) ?? ""
    }

    /// 应用一个预设。
    private func applyPreset(_ preset: PresetProviders.Preset) {
        Haptics.selection()
        let wasNew = existingProvider == nil
        var provider = preset.makeProvider(isDefault: draft.isDefault)
        if !wasNew {
            // 编辑已有条目时保留原 ID，避免钥匙串里的密钥对不上。
            provider.id = draft.id
        }
        draft = provider
        selectedPresetID = preset.id
        hasStoredKey = appState.hasAPIKey(for: provider.id)
        tester.reset()
    }

    /// 切换成「自定义」。
    private func applyCustom() {
        Haptics.selection()
        selectedPresetID = nil
        draft.kind = .custom
        tester.reset()
    }

    /// 保存 API 密钥到钥匙串。
    private func saveKey() {
        let typed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        if appState.saveAPIKey(typed, for: draft.id) {
            hasStoredKey = true
            apiKeyInput = ""
            showsAPIKey = false
        }
    }

    /// 删除 API 密钥。
    private func deleteKey() {
        appState.deleteAPIKey(for: draft.id)
        hasStoredKey = false
        apiKeyInput = ""
    }

    /// 保存整个表单。
    private func save() {
        guard canSave else { return }
        isSaving = true

        let typed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            if !appState.saveAPIKey(typed, for: draft.id) {
                isSaving = false
                return
            }
            hasStoredKey = true
            apiKeyInput = ""
        }

        var result = draft
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = result.normalizedBaseURL
        result.model = result.model.trimmingCharacters(in: .whitespacesAndNewlines)

        onSave(result)
        Haptics.success()
        isSaving = false
        dismiss()
    }
}

#if DEBUG
struct ProviderEditorView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ProviderEditorView(provider: nil) { _ in }
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
