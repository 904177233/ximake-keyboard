//
//  AIServicesView.swift
//  墨语 App · AI 服务
//

import SwiftUI
import UIKit

@MainActor
struct AIServicesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @State private var editing: ProviderEditTarget?
    @State private var showsAdd = false

    private var chatProviders: [AIProviderConfig] { model.snapshot.providers.filter { $0.supportsChat } }
    /// 豆包这种写字画图都行的，正拿来画图时也列在这里。
    private var imageProviders: [AIProviderConfig] {
        model.snapshot.providers.filter { provider in
            provider.supportsImage && (!provider.supportsChat || model.snapshot.imageProvider?.id == provider.id)
        }
    }

    var body: some View {
        AppPage(title: "AI", subtitle: "选一家，把 Key 粘贴进去就能用。地址和模型都预设好了。") {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "写字用哪家")
                ForEach(chatProviders) { provider in
                    row(provider, detail: provider.model, isDefault: model.snapshot.defaultProvider?.id == provider.id)
                }
                SectionLabel(text: "画图用哪家")
                ForEach(imageProviders) { provider in
                    row(provider, detail: provider.imageModel ?? "", isDefault: model.snapshot.imageProvider?.id == provider.id)
                }
                PrimaryButton(title: "添加服务") { showsAdd = true }
                    .padding(.top, 16)

                SectionLabel(text: "默认语气")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["自然", "简洁", "礼貌", "正式", "热情", "幽默"], id: \.self) { tone in
                            Button {
                                model.update { $0.defaultTone = tone }
                            } label: {
                                Text(tone)
                                    .font(.system(size: 14, weight: model.snapshot.defaultTone == tone ? .semibold : .regular))
                                    .foregroundColor(model.snapshot.defaultTone == tone ? palette.onAccent.color : palette.text.color)
                                    .padding(.horizontal, 13)
                                    .frame(height: 34)
                                    .background(model.snapshot.defaultTone == tone ? palette.accent.color : palette.surface.color)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                SectionLabel(text: "打字时")
                LineRow(title: "AI 猜下一句", detail: "打完一句后，根据输入框里的话猜你接下来想说什么。会用掉一点额度。") {
                    Toggle("", isOn: Binding(get: { model.snapshot.enableAISuggestion },
                                             set: { value in model.update { $0.enableAISuggestion = value } }))
                        .labelsHidden()
                        .tint(palette.accent.color)
                }
                LineRow(title: "回复给几条") {
                    Stepper("\(model.snapshot.replyCount) 条",
                            value: Binding(get: { model.snapshot.replyCount },
                                           set: { value in model.update { $0.replyCount = value } }),
                            in: 1...5)
                        .font(.system(size: 14))
                        .fixedSize()
                }
                if !model.isSharedWithKeyboard {
                    SecondaryButton(title: "把这些配置发给键盘") { model.sendConfigToKeyboard() }
                        .padding(.top, 16)
                }
            }
        }
        .sheet(item: $editing) { target in
            ProviderEditorView(target: target)
                .environmentObject(model)
                .environment(\.palette, palette)
        }
        .sheet(isPresented: $showsAdd) {
            AddServiceView { target in
                showsAdd = false
                // 等这一页收起来再弹下一页
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editing = target }
            }
            .environmentObject(model)
            .environment(\.palette, palette)
        }
    }

    private func row(_ provider: AIProviderConfig, detail: String, isDefault: Bool) -> some View {
        Button {
            editing = ProviderEditTarget(config: provider, isNew: false, preset: PresetProviders.preset(id: provider.id))
        } label: {
            LineRow(title: provider.name, detail: detail) {
                if !model.hasKey(provider) {
                    StateText(text: "没填 Key")
                } else if isDefault {
                    StateText(text: "正在用", isGood: true)
                } else {
                    StateText(text: "已填")
                }
                Chevron()
            }
        }
        .buttonStyle(.plain)
    }
}

/// 选一家服务。
@MainActor
struct AddServiceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let onPick: (ProviderEditTarget) -> Void

    private func available(_ presets: [PresetProviders.Preset]) -> [PresetProviders.Preset] {
        presets.filter { preset in !model.snapshot.providers.contains { $0.id == preset.id } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let chat = available(PresetProviders.chatPresetTemplates)
                    if !chat.isEmpty {
                        SectionLabel(text: "写字和聊天")
                        ForEach(chat) { choice($0) }
                    }
                    let image = available(PresetProviders.imagePresetTemplates)
                    if !image.isEmpty {
                        SectionLabel(text: "画图")
                        ForEach(image) { choice($0) }
                    }
                    SectionLabel(text: "其它")
                    Button {
                        onPick(ProviderEditTarget(config: AIProviderConfig(name: "自定义服务"), isNew: true, preset: nil))
                    } label: {
                        LineRow(title: "自定义", detail: "中转站、自建服务，地址和模型自己填") { Chevron() }
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
            .background(palette.page.color.ignoresSafeArea())
            .navigationTitle("添加服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func choice(_ preset: PresetProviders.Preset) -> some View {
        Button {
            onPick(ProviderEditTarget(config: preset.makeProvider(), isNew: true, preset: preset))
        } label: {
            LineRow(title: PresetProviders.shortName(id: preset.id), detail: PresetProviders.tagline(id: preset.id)) { Chevron() }
        }
        .buttonStyle(.plain)
    }
}

/// 正在编辑的服务。
struct ProviderEditTarget: Identifiable {
    let id = UUID()
    let config: AIProviderConfig
    let isNew: Bool
    let preset: PresetProviders.Preset?
}

/// 编辑一个服务。
@MainActor
struct ProviderEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let target: ProviderEditTarget

    @State private var draft = AIProviderConfig()
    @State private var key = ""
    @State private var headers = ""
    @State private var testMessage: String?
    @State private var testFailed = false
    @State private var isTesting = false
    @State private var didLoad = false
    @State private var showsAdvanced = false
    /// 查出来的这家现在的模型。
    @State private var liveModels: [String] = []

    private var isImageOnly: Bool { PresetProviders.isImageOnly(id: draft.id) }
    /// 内置服务只露 Key 和模型，其余收进「高级设置」。
    private var isPreset: Bool { target.preset != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let note = target.preset?.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 13))
                            .foregroundColor(palette.secondary.color)
                            .lineSpacing(2)
                            .padding(.bottom, 6)
                    }
                    if let url = target.preset?.consoleURL {
                        Link("去申请 Key", destination: url)
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.bottom, 8)
                    }
                    keyField
                    modelChoices
                    if isPreset {
                        Button {
                            showsAdvanced.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Text("高级设置")
                                Image(systemName: showsAdvanced ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 11))
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 13.5))
                            .foregroundColor(palette.secondary.color)
                            .frame(height: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                    }
                    if !isPreset || showsAdvanced {
                        advancedFields
                    }

                    PrimaryButton(title: isTesting ? "正在试…" : "试一下并保存") { testAndSave() }
                        .disabled(isTesting)
                        .padding(.top, 18)
                    if let testMessage {
                        Text(testMessage)
                            .font(.system(size: 13.5))
                            .foregroundColor(testFailed ? palette.text.color : palette.accentText.color)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .padding(.top, 10)
                    }
                    if !target.isNew, !isCurrent, model.hasKey(draft) {
                        SecondaryButton(title: isImageOnly ? "用它画图" : "用它写字") { useThis() }
                            .padding(.top, 10)
                    }
                    if !target.isNew {
                        Button(role: .destructive) {
                            delete()
                        } label: {
                            Text("删除这个服务")
                                .font(.system(size: 14.5))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(palette.page.color.ignoresSafeArea())
            .navigationTitle(target.isNew ? "添加服务" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draft = target.config
            key = KeychainStore.shared.apiKey(for: target.config.id) ?? ""
            headers = target.config.extraHeaders
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
        }
    }

    @ViewBuilder
    private var advancedFields: some View {
        field("名字", text: $draft.name, placeholder: "随便起")
        field("地址", text: $draft.baseURL, placeholder: "https://api.example.com/v1", isURL: true)
        if !isImageOnly {
            field("模型", text: $draft.model, placeholder: "模型名", isURL: true)
        }
        if isImageOnly || draft.supportsImage {
            field("画图模型", text: Binding(get: { draft.imageModel ?? "" },
                                        set: { draft.imageModel = $0 }), placeholder: "", isURL: true)
        }
        SectionLabel(text: "额外请求头（中转站要的话才填，一行一个 名字: 值）")
        TextField("HTTP-Referer: https://example.com", text: $headers, axis: .vertical)
            .font(.system(size: 14))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(2...5)
            .padding(10)
            .background(palette.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var isCurrent: Bool {
        isImageOnly ? model.snapshot.imageProvider?.id == draft.id : model.snapshot.defaultProvider?.id == draft.id
    }

    private func useThis() {
        let id = draft.id
        let image = isImageOnly
        model.update { snapshot in
            if image {
                snapshot.imageProviderID = id
            } else {
                snapshot.defaultProviderID = id
            }
        }
        model.showToast("已切换")
        dismiss()
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, isURL: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundColor(palette.secondary.color)
            TextField(placeholder, text: text)
                .font(.system(size: 15.5))
                .textInputAutocapitalization(isURL ? TextInputAutocapitalization.never : TextInputAutocapitalization.sentences)
                .autocorrectionDisabled(isURL)
                .keyboardType(isURL ? .URL : .default)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            palette.line.color.frame(height: 0.5)
        }
    }

    /// 现在选中的模型。画图服务选的是画图模型。
    private var currentModel: String { isImageOnly ? (draft.imageModel ?? "") : draft.model }

    private func selectModel(_ name: String) {
        if isImageOnly {
            draft.imageModel = name
        } else {
            draft.model = name
        }
    }

    /// 要给人选的模型：查到的优先，没查过就用预设。当前选中的总在里面。
    private var modelNames: [String] {
        let preset = target.preset?.availableModels.map(\.modelID) ?? PresetProviders.knownModels(forBaseURL: draft.baseURL)
        var names = liveModels.isEmpty ? preset : liveModels
        if !currentModel.isEmpty, !names.contains(currentModel) {
            names.insert(currentModel, at: 0)
        }
        return names
    }

    @ViewBuilder
    private var modelChoices: some View {
        let models = modelNames
        if !models.isEmpty {
            Text("模型")
                .font(.system(size: 12.5))
                .foregroundColor(palette.secondary.color)
                .padding(.top, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(models, id: \.self) { name in
                        Button {
                            selectModel(name)
                        } label: {
                            Text(name)
                                .font(.system(size: 12.5))
                                .foregroundColor(currentModel == name ? palette.onAccent.color : palette.text.color)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(currentModel == name ? palette.accent.color : palette.surface.color)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API Key")
                .font(.system(size: 12.5))
                .foregroundColor(palette.secondary.color)
            HStack(spacing: 10) {
                SecureField("sk-…", text: $key)
                    .font(.system(size: 15.5))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("粘贴") {
                    if let text = UIPasteboard.general.string {
                        key = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .font(.system(size: 14, weight: .semibold))
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            palette.line.color.frame(height: 0.5)
        }
    }

    private func parsedHeaders() -> [String: String] {
        var result: [String: String] = [:]
        for line in headers.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                result[name] = value
            }
        }
        return result
    }

    /// 真发一次。通了就保存；不通留在这页，把原因写出来。
    private func testAndSave() {
        var config = draft
        config.extraHeaders = parsedHeaders()
        isTesting = true
        testMessage = nil
        let apiKey = key
        Task {
            let result = await ProviderCheck.run(config: config, apiKey: apiKey)
            isTesting = false
            draft = result.config
            liveModels = result.models
            testFailed = !result.isUsable
            testMessage = result.message
            if result.isUsable {
                save(toast: result.message)
            }
        }
    }

    private func save(toast: String = "已保存") {
        draft.extraHeaders = parsedHeaders()
        let saved = draft
        let apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var partner: AIProviderConfig?
        model.update { snapshot in
            partner = PresetProviders.adopt(saved, keyIsSet: !apiKey.isEmpty, isNew: target.isNew, into: &snapshot) {
                KeychainStore.shared.hasAPIKey(for: $0)
            }
        }
        do {
            if apiKey.isEmpty {
                try KeychainStore.shared.deleteAPIKey(for: saved.id)
            } else {
                try KeychainStore.shared.setAPIKey(apiKey, for: saved.id)
            }
            if let partner {
                try KeychainStore.shared.setAPIKey(apiKey, for: partner.id)
                model.showToast("已保存。同一个 Key 也配好了\(PresetProviders.shortName(id: partner.id))")
            } else {
                model.showToast(toast)
            }
        } catch {
            model.showToast("Key 没存上：\(error.localizedDescription)")
        }
        dismiss()
    }

    private func delete() {
        let id = draft.id
        model.update { snapshot in
            snapshot.providers.removeAll { $0.id == id }
            if snapshot.defaultProviderID == id {
                snapshot.defaultProviderID = snapshot.providers.first { $0.supportsChat }?.id
            }
            if snapshot.imageProviderID == id {
                snapshot.imageProviderID = snapshot.providers.first { $0.supportsImage }?.id
            }
        }
        try? KeychainStore.shared.deleteAPIKey(for: id)
        dismiss()
    }
}
