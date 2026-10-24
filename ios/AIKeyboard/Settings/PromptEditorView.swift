//
//  PromptEditorView.swift
//  墨语 · 宿主 App
//
//  模块职责：新建 / 编辑自定义 Prompt 模板（Sheet）。
//  依赖：SwiftUI、AppState、SurfaceCard / SectionHeader / PrimaryButton / SecondaryButton / PillChip、
//        PromptCatalog。
//  使用方：PromptLibraryView / PlaygroundView。
//

import SwiftUI

/// Prompt 模板编辑页。
struct PromptEditorView: View {

    /// 编辑中的模板；nil 表示新建。
    private let original: PromptTemplate?

    /// 保存回调。
    private let onSave: (PromptTemplate) -> Void

    @State private var title: String = ""
    @State private var systemImage: String = "text.bubble"
    @State private var feature: AIFeature = .polish
    @State private var systemPrompt: String = ""
    @State private var userTemplate: String = "{{text}}"
    @State private var temperature: Double = 0.3

    @Environment(\.dismiss) private var dismiss

    /// 可选的图标（12 个）。
    private static let iconCandidates: [String] = [
        "text.bubble", "wand.and.stars", "text.append", "character.bubble",
        "globe", "bubble.left.and.bubble.right", "photo.on.rectangle.angled",
        "slider.horizontal.3", "sparkles", "pencil", "doc.text", "quote.bubble"
    ]

    init(template: PromptTemplate?, onSave: @escaping (PromptTemplate) -> Void) {
        self.original = template
        self.onSave = onSave
        let initial = template ?? PromptTemplate(
            id: UUID().uuidString,
            title: "",
            systemImage: "text.bubble",
            feature: .polish,
            systemPrompt: "你是聊天输入法内的改写助手，只输出改写后的文字。",
            userTemplate: "{{text}}",
            temperature: 0.3,
            isBuiltIn: false
        )
        _title = State(initialValue: initial.title)
        _systemImage = State(initialValue: initial.systemImage)
        _feature = State(initialValue: initial.feature)
        _systemPrompt = State(initialValue: initial.systemPrompt)
        _userTemplate = State(initialValue: initial.userTemplate)
        _temperature = State(initialValue: initial.temperature)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                basicSection
                iconSection
                featureSection
                promptSection
                temperatureSection
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.vertical, AppMetrics.cardPadding)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle(original == nil ? "新建模板" : "编辑模板")
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
                    .disabled(!canSave)
            }
        }
    }

    // MARK: - 基本信息

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "基本信息")
            SurfaceCard {
                VStack(alignment: .leading, spacing: AppMetrics.rowVPadding) {
                    VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                        Text("名称")
                            .font(AppFont.footnote)
                            .foregroundColor(Theme.textSecondary)
                        TextField("例如 微信回消息", text: $title)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(AppFont.body)
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, AppMetrics.tightGap)
                            .frame(minHeight: AppMetrics.fieldHeight)
                            .background(
                                RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                                    .fill(Theme.surfaceElevated)
                            )
                    }
                }
            }
        }
    }

    // MARK: - 图标

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "图标")
            SurfaceCard {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: AppMetrics.blockGap), count: 6),
                    spacing: AppMetrics.blockGap
                ) {
                    ForEach(Self.iconCandidates, id: \.self) { symbol in
                        Button {
                            systemImage = symbol
                            Haptics.selection()
                        } label: {
                            RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                                .fill(systemImage == symbol ? AppColor.accentWash : Theme.surfaceElevated)
                                .frame(height: AppMetrics.minTapHeight)
                                .overlay(
                                    IconGlyph(
                                        symbol: symbol,
                                        fallback: "•",
                                        size: AppMetrics.glyphSize,
                                        tint: systemImage == symbol ? Theme.accent : Theme.textSecondary
                                    )
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel(Text("选择图标 \(symbol)"))
                    }
                }
            }
        }
    }

    // MARK: - 能力

    private var featureSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "能力", footnote: "决定模板出现在哪个入口")
            SurfaceCard {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppMetrics.blockGap) {
                        ForEach(AIFeature.allCases, id: \.rawValue) { item in
                            PillChip(
                                item.title,
                                systemImage: item.systemImage,
                                style: .tool,
                                isSelected: feature == item,
                                action: {
                                    feature = item
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

    // MARK: - 提示词

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "系统提示词", footnote: "描述角色与输出要求")
            SurfaceCard {
                PromptTextEditor(text: $systemPrompt, minHeight: AppMetrics.textEditorMinHeight)
            }

            SectionHeader(
                title: "用户模板",
                footnote: "支持 {{text}} {{context}} {{tone}} {{target_language}}"
            )
            SurfaceCard {
                PromptTextEditor(text: $userTemplate, minHeight: AppMetrics.textEditorMinHeight / 2)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppMetrics.tightGap) {
                    ForEach(["{{text}}", "{{context}}", "{{tone}}", "{{target_language}}"], id: \.self) { token in
                        PillChip(
                            token,
                            style: .tag,
                            action: {
                                userTemplate += token
                                Haptics.light()
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 温度

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(title: "温度", footnote: "沿用模板默认值即可，试验场里可临时覆盖")
            SurfaceCard {
                VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                    HStack {
                        Text("当前")
                            .font(AppFont.footnote)
                            .foregroundColor(Theme.textSecondary)
                        Spacer()
                        Text(String(format: "%.1f", temperature))
                            .font(AppFont.monospaced)
                            .foregroundColor(Theme.textPrimary)
                    }
                    Slider(
                        value: Binding(
                            get: { temperature },
                            set: { temperature = AIProviderConfig.clampTemperature($0) }
                        ),
                        in: 0...2,
                        step: 0.1
                    )
                    .tint(Theme.accent)
                }
            }
        }
    }

    // MARK: - 逻辑

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !userTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard canSave else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = PromptTemplate(
            id: original?.id ?? UUID().uuidString,
            title: cleanTitle,
            systemImage: systemImage,
            feature: feature,
            systemPrompt: systemPrompt,
            userTemplate: userTemplate,
            temperature: temperature,
            isBuiltIn: false
        )
        onSave(template)
        Haptics.success()
        dismiss()
    }
}

// MARK: - 多行文本编辑

/// 带占位符的多行输入。
private struct PromptTextEditor: View {

    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("在这里输入…")
                    .font(AppFont.body)
                    .foregroundColor(Theme.textPlaceholder)
                    .padding(.top, AppMetrics.blockGap)
                    .padding(.leading, AppMetrics.tightGap)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(AppFont.body)
                .foregroundColor(Theme.textPrimary)
                .scrollContentBackgroundHiddenCompat()
                .frame(minHeight: minHeight)
        }
    }
}

#if DEBUG
struct PromptEditorView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PromptEditorView(template: nil) { _ in }
        }
    }
}
#endif
