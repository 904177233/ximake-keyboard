//
//  PromptLibraryView.swift
//  墨语 · 宿主 App
//
//  模块职责：Prompt 模板库（设置 › Prompt 模板）。内置模板只读、可复制为自定义；
//            自定义模板可编辑、删除。
//  依赖：SwiftUI、AppState、SegmentedTabs / ListGroup / SectionHeader / EmptyState、
//        PromptEditorView / PromptDetailView。
//  使用方：SettingsView / PlaygroundView。
//

import SwiftUI

/// Prompt 模板库。
struct PromptLibraryView: View {

    @EnvironmentObject private var appState: AppState

    /// 当前分类（"all" 或 AIFeature.rawValue）。
    @State private var selectedCategory = "all"

    /// 正在编辑的自定义模板。
    @State private var editingTemplate: PromptTemplate?

    /// 是否新建。
    @State private var isCreating = false

    /// 正在查看详情的模板。
    @State private var detailTemplate: PromptTemplate?

    /// 待删除的自定义模板。
    @State private var pendingDelete: PromptTemplate?

    /// 自定义模板（本地缓存，操作后刷新）。
    @State private var customTemplates: [PromptTemplate] = []

    private var builtInTemplates: [PromptTemplate] {
        PromptCatalog.builtIn.filter(matchesCategory)
    }

    private var filteredCustom: [PromptTemplate] {
        customTemplates.filter(matchesCategory)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                categoryTabs

                if builtInTemplates.isEmpty && filteredCustom.isEmpty {
                    SurfaceCard {
                        EmptyState(
                            symbol: "square.stack.3d.up",
                            fallbackEmoji: "🗂️",
                            title: "这个分类还没有模板",
                            message: "可以新建一个自定义模板，在试验场里试好再保存。",
                            actionTitle: "新建模板",
                            action: { isCreating = true }
                        )
                    }
                } else {
                    if !builtInTemplates.isEmpty {
                        builtInSection
                    }
                    if !filteredCustom.isEmpty {
                        customSection
                    }
                }

                newTemplateButton
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle("Prompt 模板")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isCreating = true
                } label: {
                    IconGlyph(symbol: "plus", fallback: "＋", size: AppMetrics.glyphSize, weight: .semibold, tint: Theme.accent)
                }
                .accessibilityLabel(Text("新建模板"))
            }
        }
        .sheet(item: $editingTemplate) { template in
            NavigationStack {
                PromptEditorView(template: template) { saved in
                    PromptLibrary.upsertCustom(saved)
                    editingTemplate = nil
                    reloadCustom()
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack {
                PromptEditorView(template: nil) { saved in
                    PromptLibrary.upsertCustom(saved)
                    isCreating = false
                    reloadCustom()
                }
            }
        }
        .sheet(item: $detailTemplate) { template in
            NavigationStack {
                PromptDetailView(
                    template: template,
                    onEdit: { editingTemplate = template.duplicatedAsCustom() },
                    onDelete: nil,
                    onClose: { detailTemplate = nil }
                )
            }
        }
        .alert(item: $pendingDelete) { template in
            Alert(
                title: Text("删除「\(template.title)」？"),
                message: Text("删除后无法恢复。"),
                primaryButton: .destructive(Text("删除")) {
                    PromptLibrary.removeCustom(id: template.id)
                    reloadCustom()
                    Haptics.warning()
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .onAppear(perform: reloadCustom)
    }

    // MARK: - 分类

    private var categoryTabs: some View {
        SegmentedTabs(tabs: categoryTabModels, selection: $selectedCategory, style: .capsule)
    }

    private var categoryTabModels: [SegmentedTabs.Tab] {
        var models: [SegmentedTabs.Tab] = [SegmentedTabs.Tab(id: "all", title: "全部")]
        for feature in AIFeature.allCases {
            models.append(SegmentedTabs.Tab(id: feature.rawValue, title: feature.title))
        }
        return models
    }

    private func matchesCategory(_ template: PromptTemplate) -> Bool {
        selectedCategory == "all" || template.feature.rawValue == selectedCategory
    }

    // MARK: - 内置

    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "内置模板", footnote: "只读，可复制为自定义后修改")
            ListGroup {
                ForEach(Array(builtInTemplates.enumerated()), id: \.element.id) { index, template in
                    templateRow(template, isBuiltIn: true)
                    if index < builtInTemplates.count - 1 {
                        RowDivider()
                    }
                }
            }
        }
    }

    // MARK: - 自定义

    private var customSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "我的模板", footnote: "可在试验场与键盘里选用")
            ListGroup {
                ForEach(Array(filteredCustom.enumerated()), id: \.element.id) { index, template in
                    templateRow(template, isBuiltIn: false)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = template
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                editingTemplate = template
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                        }
                    if index < filteredCustom.count - 1 {
                        RowDivider()
                    }
                }
            }
        }
    }

    /// 一行模板。
    private func templateRow(_ template: PromptTemplate, isBuiltIn: Bool) -> some View {
        SettingsRow(
            icon: IconSpec(
                symbol: template.systemImage,
                tint: isBuiltIn ? Theme.accent : Theme.success
            ),
            title: template.title,
            subtitle: previewText(template),
            accessory: .chevron
        ) {
            if isBuiltIn {
                detailTemplate = template
            } else {
                editingTemplate = template
            }
        }
    }

    /// 模板正文前 20 字预览。
    private func previewText(_ template: PromptTemplate) -> String {
        let raw = template.userTemplate.replacingOccurrences(of: "\n", with: " ")
        if raw.count <= 20 {
            return raw
        }
        let endIndex = raw.index(raw.startIndex, offsetBy: 20)
        return String(raw[..<endIndex]) + "…"
    }

    // MARK: - 新建

    private var newTemplateButton: some View {
        PrimaryButton(
            title: "新建模板",
            systemImage: "plus",
            tone: .accent,
            size: .medium,
            fullWidth: true
        ) {
            isCreating = true
        }
    }

    private func reloadCustom() {
        customTemplates = PromptCatalog.custom
    }
}

// MARK: - 模板详情（内置只读）

/// 内置模板详情页。
struct PromptDetailView: View {

    let template: PromptTemplate
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    let onClose: () -> Void

    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: template.title,
                subtitle: template.isBuiltIn ? "内置模板 · 只读" : "自定义模板",
                onClose: onClose
            )

            ScrollView {
                VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                            labeledText("能力", template.feature.title)
                            RowDivider(hasIcon: false)
                            labeledText("温度", String(format: "%.1f", template.temperature))
                        }
                    }

                    textCard(title: "系统提示词", body: template.systemPrompt)
                    textCard(title: "用户模板", body: template.userTemplate)

                    SurfaceCard {
                        VStack(alignment: .leading, spacing: AppMetrics.tightGap) {
                            Text("可用占位符")
                                .font(AppFont.footnoteStrong)
                                .foregroundColor(Theme.textPrimary)
                            // i18n-ignore：这里是模板占位符的字面量，不是英文 UI 文案。
                            Text("{{text}} {{context}} {{tone}} {{target_language}}")
                                .font(AppFont.monospacedFootnote)
                                .foregroundColor(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("依次代表：选中的文字、上下文、语气、目标语言。写模板时保留花括号即可。")
                                .font(AppFont.caption)
                                .foregroundColor(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(AppMetrics.pageInset)
            }

            bottomBar
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .presentationDetents([.large])
        .navigationBarTitleDisplayMode(.inline)
    }

    private var bottomBar: some View {
        VStack(spacing: AppMetrics.blockGap) {
            if template.isBuiltIn {
                PrimaryButton(title: "复制为自定义模板", systemImage: "square.on.square", tone: .accent, size: .medium, fullWidth: true) {
                    onEdit?()
                }
            } else {
                PrimaryButton(title: "编辑", systemImage: "pencil", tone: .accent, size: .medium, fullWidth: true) {
                    onEdit?()
                }
            }

            Button {
                appState.selectedTab = .playground
                onClose()
            } label: {
                Text("在试验场试用")
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.accent)
                    .frame(minHeight: AppMetrics.minTapHeight)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(AppMetrics.pageInset)
    }

    private func labeledText(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(AppFont.footnote)
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(AppFont.body)
                .foregroundColor(Theme.textPrimary)
        }
    }

    private func textCard(title: String, body: String) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
                Text(title)
                    .font(AppFont.footnoteStrong)
                    .foregroundColor(Theme.textPrimary)
                Text(body)
                    .font(AppFont.monospacedFootnote)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#if DEBUG
struct PromptLibraryView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PromptLibraryView()
        }
        .environmentObject(AppState(configStore: InMemoryConfigStore()))
    }
}
#endif
