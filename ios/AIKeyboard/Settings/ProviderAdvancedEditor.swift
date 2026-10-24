//
//  ProviderAdvancedEditor.swift
//  墨语 · 宿主 App
//
//  模块职责：服务商编辑页的「高级参数」折叠区 —— 温度滑杆、最大回复长度、
//            超时、生图模型、自定义请求头，以及跳转服务商控制台的入口。
//            从 ProviderEditorView 拆出，避免单文件超过 600 行（docs/02 §3）。
//  依赖：SwiftUI、AppModels（无）、SurfaceCard / SettingsRow / RowDivider /
//        FormFieldRow / IconGlyph、Shared（AIProviderConfig）。
//  使用方：ProviderEditorView。
//

import SwiftUI

/// 服务商编辑页的高级参数区。
struct ProviderAdvancedEditor: View {

    /// 编辑中的配置（双向绑定）。
    @Binding var draft: AIProviderConfig

    /// 当前预设的控制台地址（没有预设时为 nil）。
    var consoleURL: URL?

    /// 是否展开。
    @Binding var isExpanded: Bool

    /// 新增 Header 的临时输入。
    @State private var newHeaderKey = ""
    @State private var newHeaderValue = ""

    var body: some View {
        SurfaceCard(padding: 0) {
            VStack(spacing: 0) {
                SettingsRow(
                    icon: IconSpec(symbol: "slider.horizontal.3", tint: Theme.accent),
                    title: "高级参数",
                    subtitle: "温度 / 最大回复长度 / 超时 / 生图模型 / 自定义 Header",
                    accessory: .chevron
                ) {
                    withAnimation(Theme.Motion.spring) {
                        isExpanded.toggle()
                    }
                }

                if isExpanded {
                    RowDivider()

                    VStack(alignment: .leading, spacing: AppMetrics.rowVPadding) {
                        temperatureRow
                        RowDivider(hasIcon: false)
                        maxTokensRow
                        RowDivider(hasIcon: false)
                        timeoutRow
                        RowDivider(hasIcon: false)
                        imageModelRow
                        RowDivider(hasIcon: false)
                        headerEditor

                        if let url = consoleURL {
                            RowDivider(hasIcon: false)
                            consoleLink(url)
                        }
                    }
                    .padding(AppMetrics.cardPadding)
                }
            }
        }
    }

    // MARK: - 温度

    private var temperatureRow: some View {
        VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
            HStack {
                Text("温度")
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text(String(format: "%.1f", draft.temperature))
                    .font(AppFont.monospaced)
                    .foregroundColor(Theme.textPrimary)
            }
            Slider(
                value: Binding(
                    get: { draft.temperature },
                    set: { draft.temperature = AIProviderConfig.clampTemperature($0) }
                ),
                in: 0...2,
                step: 0.1
            )
            .tint(Theme.accent)
            Text("越低越稳定，越高越发散。润色建议 0.3–0.5，创意写作 0.8 以上。")
                .font(AppFont.caption)
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 最大 Token

    private var maxTokensRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                Text("最大回复长度")
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.textSecondary)
                Text("\(draft.maxTokens) 个词元")
                    .font(AppFont.monospaced)
                    .foregroundColor(Theme.textPrimary)
            }
            Spacer()
            Stepper(
                "",
                value: Binding(
                    get: { draft.maxTokens },
                    set: { draft.maxTokens = AIProviderConfig.clampMaxTokens($0) }
                ),
                in: 128...4096,
                step: 128
            )
            .labelsHidden()
        }
    }

    // MARK: - 超时

    private var timeoutRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
                Text("超时")
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.textSecondary)
                Text("\(Int(draft.timeout)) 秒")
                    .font(AppFont.monospaced)
                    .foregroundColor(Theme.textPrimary)
            }
            Spacer()
            Stepper(
                "",
                value: Binding(
                    get: { draft.timeout },
                    set: { draft.timeout = min(max($0, 10), 120) }
                ),
                in: 10...120,
                step: 5
            )
            .labelsHidden()
        }
    }

    // MARK: - 生图模型

    private var imageModelRow: some View {
        VStack(alignment: .leading, spacing: AppMetrics.hairGap) {
            Text("生图模型（可选）")
                .font(AppFont.footnote)
                .foregroundColor(Theme.textSecondary)
            inputField(
                placeholder: "例如 doubao-seedream-3-0-t2i-250415",
                text: imageModelBinding
            )
            Text("填了才可以在「AI 试验场」里生图；即梦 / 通义万相预设已自动填好。")
                .font(AppFont.caption)
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `imageModel` 是可选字符串，这里包一层绑定。
    private var imageModelBinding: Binding<String> {
        Binding(
            get: { draft.imageModel ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.imageModel = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    // MARK: - 自定义 Header

    private var headerEditor: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            Text("自定义请求头（中转站鉴权用）")
                .font(AppFont.footnote)
                .foregroundColor(Theme.textSecondary)

            ForEach(Array(draft.extraHeaders.keys.sorted()), id: \.self) { key in
                HStack(spacing: AppMetrics.tightGap) {
                    Text(key)
                        .font(AppFont.monospacedFootnote)
                        .foregroundColor(Theme.textPrimary)
                    Text("=")
                        .font(AppFont.monospacedFootnote)
                        .foregroundColor(Theme.textTertiary)
                    Text(draft.extraHeaders[key] ?? "")
                        .font(AppFont.monospacedFootnote)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        draft.extraHeaders.removeValue(forKey: key)
                        Haptics.light()
                    } label: {
                        IconGlyph(
                            symbol: "minus.circle",
                            fallback: "−",
                            size: AppMetrics.glyphSizeSmall,
                            tint: Theme.danger
                        )
                        .frame(width: AppMetrics.minTapHeight, height: AppMetrics.minTapHeight)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel(Text("删除请求头 \(key)"))
                }
            }

            HStack(spacing: AppMetrics.tightGap) {
                TextField("Header 名", text: $newHeaderKey)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(AppFont.caption)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(.horizontal, AppMetrics.hairGap)
                    .frame(minHeight: AppMetrics.buttonSmallHeight)
                    .background(
                        RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )

                TextField("值", text: $newHeaderValue)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(AppFont.caption)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(.horizontal, AppMetrics.hairGap)
                    .frame(minHeight: AppMetrics.buttonSmallHeight)
                    .background(
                        RoundedRectangle(cornerRadius: AppMetrics.smallRadius, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )

                Button("添加") {
                    addHeader()
                }
                .font(AppFont.caption)
                .foregroundColor(Theme.accent)
                .disabled(newHeaderKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - 控制台入口

    private func consoleLink(_ url: URL) -> some View {
        Button {
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: AppMetrics.tightGap) {
                IconGlyph(
                    symbol: "safari",
                    fallback: "🔗",
                    size: AppMetrics.glyphSizeSmall,
                    tint: Theme.accent
                )
                Text("去服务商控制台申请 API Key")
                    .font(AppFont.footnote)
                    .foregroundColor(Theme.accent)
                Spacer(minLength: 0)
            }
            .frame(minHeight: AppMetrics.minTapHeight)
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 工具

    /// 统一的输入框样式。
    private func inputField(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(PlainTextFieldStyle())
            .font(AppFont.monospacedFootnote)
            .foregroundColor(Theme.textPrimary)
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .padding(.horizontal, AppMetrics.tightGap)
            .frame(minHeight: AppMetrics.fieldHeight)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.controlRadius, style: .continuous)
                    .fill(Theme.surfaceElevated)
            )
    }

    /// 追加一条自定义 Header。
    private func addHeader() {
        let key = newHeaderKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = newHeaderValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        draft.extraHeaders[key] = value
        newHeaderKey = ""
        newHeaderValue = ""
        Haptics.light()
    }
}

#if DEBUG
struct ProviderAdvancedEditor_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            ProviderAdvancedEditor(
                draft: .constant(PresetProviders.preset(id: "preset-deepseek")?.makeProvider()
                    ?? AIProviderConfig(name: "自定义")),
                consoleURL: URL(string: "https://platform.deepseek.com/api_keys"),
                isExpanded: .constant(true)
            )
            .padding()
        }
        .background(AppColor.pageBackground)
    }
}
#endif
