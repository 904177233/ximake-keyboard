//
//  SettingsPanelView.swift
//  墨语键盘 · 键盘里的设置
//
//  App 和键盘的配置打不通时，AI 服务也能在这里直接配好。
//  键盘里不能放系统输入框，要填字时进入 FieldEditView，用自己的键区往里打。
//

import Combine
import SwiftUI
import UIKit

/// 设置页路由。
enum SettingsRoute: Equatable {
    case home, providers, provider
}

/// 设置页的数据和动作。
@MainActor
final class SettingsModel: ObservableObject {

    @Published var draft = AIProviderConfig()
    @Published var keyDraft = ""
    @Published var isNew = false
    @Published var testMessage: String?
    @Published var testFailed = false
    @Published var isTesting = false

    private unowned let session: KeyboardSession
    private var testTask: Task<Void, Never>?

    init(session: KeyboardSession) {
        self.session = session
    }

    var providers: [AIProviderConfig] { session.snapshot.providers }

    func hasKey(_ provider: AIProviderConfig) -> Bool {
        KeychainStore.shared.hasAPIKey(for: provider.id)
    }

    /// 编辑已有的服务。
    func edit(_ provider: AIProviderConfig) {
        draft = provider
        keyDraft = KeychainStore.shared.apiKey(for: provider.id) ?? ""
        isNew = false
        testMessage = nil
        session.settingsRoute = .provider
    }

    /// 从预设新建。
    func add(preset: PresetProviders.Preset?) {
        var provider = preset?.makeProvider() ?? AIProviderConfig(name: "自定义服务")
        if session.snapshot.providers.contains(where: { $0.id == provider.id }) {
            provider.id = UUID().uuidString
        }
        draft = provider
        keyDraft = ""
        isNew = true
        testMessage = nil
        session.settingsRoute = .provider
    }

    /// 保存。
    func save() {
        var snapshot = session.snapshot
        if let index = snapshot.providers.firstIndex(where: { $0.id == draft.id }) {
            snapshot.providers[index] = draft
        } else {
            snapshot.providers.append(draft)
        }
        if snapshot.defaultProvider == nil || snapshot.defaultProviderID == nil, draft.supportsChat {
            snapshot.defaultProviderID = draft.id
        }
        if snapshot.imageProviderID == nil, draft.supportsImage {
            snapshot.imageProviderID = draft.id
        }
        session.saveConfig(snapshot)
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            try? KeychainStore.shared.deleteAPIKey(for: draft.id)
        } else {
            do {
                try KeychainStore.shared.setAPIKey(key, for: draft.id)
            } catch {
                session.showToast("Key 没存上：\(error.localizedDescription)")
                return
            }
        }
        session.showToast("已保存")
        session.settingsRoute = .providers
    }

    /// 删除。
    func delete() {
        var snapshot = session.snapshot
        snapshot.providers.removeAll { $0.id == draft.id }
        if snapshot.defaultProviderID == draft.id {
            snapshot.defaultProviderID = snapshot.providers.first { $0.supportsChat }?.id
        }
        if snapshot.imageProviderID == draft.id {
            snapshot.imageProviderID = snapshot.providers.first { $0.supportsImage }?.id
        }
        try? KeychainStore.shared.deleteAPIKey(for: draft.id)
        session.saveConfig(snapshot)
        session.settingsRoute = .providers
    }

    /// 设为默认。
    func setDefault(_ provider: AIProviderConfig) {
        var snapshot = session.snapshot
        if provider.supportsChat {
            snapshot.defaultProviderID = provider.id
        } else if provider.supportsImage {
            snapshot.imageProviderID = provider.id
        }
        session.saveConfig(snapshot)
    }

    /// 测试：非流式发一句 hi。通不通当场说清楚，不通就把服务器原话显示出来。
    func test() {
        testTask?.cancel()
        let config = draft
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            testFailed = true
            testMessage = "先填 Key"
            return
        }
        isTesting = true
        testMessage = nil
        testTask = Task { [weak self] in
            let started = Date()
            let request = ChatRequest(messages: [.user("hi")], temperature: 0, maxTokens: 1024, stream: false)
            do {
                let result = try await AIClientFactory.makeLLM(config: config, apiKey: key).complete(request)
                guard let self, !Task.isCancelled else { return }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                self.isTesting = false
                self.testFailed = false
                let sample = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.testMessage = sample.isEmpty
                    ? "连上了（\(ms) 毫秒），但模型没有返回文字，换个模型名试试。"
                    : "能用（\(ms) 毫秒）：\(String(sample.prefix(40)))"
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isTesting = false
                self.testFailed = true
                self.testMessage = AIError.wrap(error).errorDescription ?? error.localizedDescription
            }
        }
    }

    /// 导入 App 发来的配置。
    func importFromApp() {
        guard let payload = PasteboardBridge.importEnvelope() else {
            session.showToast("没找到配置。先在墨语 App 里点「把配置发给键盘」")
            return
        }
        session.saveConfig(payload.snapshot)
        for (id, key) in payload.apiKeys ?? [:] {
            try? KeychainStore.shared.setAPIKey(key, for: id)
        }
        session.showToast("配置已导入")
    }
}

/// 设置面板。
@MainActor
struct SettingsPanelView: View {
    @ObservedObject var session: KeyboardSession
    @ObservedObject var settings: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    switch session.settingsRoute {
                    case .home:
                        homeRows
                    case .providers:
                        providerRows
                    case .provider:
                        providerEditor
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            if session.settingsRoute != .home {
                Button {
                    session.settingsRoute = session.settingsRoute == .provider ? .providers : .home
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15))
                        .foregroundColor(palette.text.color)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(palette.text.color)
                .padding(.leading, session.settingsRoute == .home ? 14 : 0)
            Spacer(minLength: 0)
            PanelCloseButton { session.setPage(.keys) }
                .padding(.trailing, 4)
        }
        .frame(height: 44)
    }

    private var title: String {
        switch session.settingsRoute {
        case .home: return "设置"
        case .providers: return "AI 服务"
        case .provider: return settings.draft.name.isEmpty ? "服务" : settings.draft.name
        }
    }

    // MARK: - 首页

    private var homeRows: some View {
        VStack(spacing: 0) {
            Button {
                session.settingsRoute = .providers
            } label: {
                row("AI 服务") {
                    HStack(spacing: 4) {
                        Text(providerSummary)
                            .font(.system(size: 13))
                            .foregroundColor(palette.secondary.color)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundColor(palette.secondary.color)
                    }
                }
            }
            .buttonStyle(.plain)

            row("主题") {
                HStack(spacing: 7) {
                    ForEach(MoyuThemeID.allCases) { theme in
                        Button {
                            session.updatePrefs { $0.theme = theme }
                        } label: {
                            Circle()
                                .fill(MoyuPalette(theme: theme, dark: session.isDark).accent.color)
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(palette.text.color, lineWidth: session.prefs.theme == theme ? 1.5 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(theme.title)
                    }
                }
            }

            row("键盘布局") {
                segmented(KeyboardPrefs.Layout.allCases.map { ($0.title, session.prefs.layout == $0) }) { index in
                    session.updatePrefs { $0.layout = KeyboardPrefs.Layout.allCases[index] }
                }
            }
            row("键盘高度") {
                segmented(KeyboardPrefs.Height.allCases.map { ($0.title, session.prefs.height == $0) }) { index in
                    session.updatePrefs { $0.height = KeyboardPrefs.Height.allCases[index] }
                }
            }
            toggleRow("模糊音", isOn: session.prefs.fuzzyPinyin) { value in
                _ = FuzzyPinyinSettings.shared.setEnabled(value)
                session.updatePrefs { $0.fuzzyPinyin = value }
            }
            row("按键震动") {
                segmented(KeyboardPrefs.HapticLevel.allCases.map { ($0.title, session.prefs.haptics == $0) }) { index in
                    session.updatePrefs { $0.haptics = KeyboardPrefs.HapticLevel.allCases[index] }
                }
            }
            toggleRow("按键声音", isOn: session.prefs.keySound) { value in
                session.updatePrefs { $0.keySound = value }
            }
            toggleRow("AI 猜下一句", isOn: session.snapshot.enableAISuggestion) { value in
                var snapshot = session.snapshot
                snapshot.enableAISuggestion = value
                session.saveConfig(snapshot)
            }
            toggleRow("剪贴板历史", isOn: session.snapshot.enableClipboardHistory) { value in
                var snapshot = session.snapshot
                snapshot.enableClipboardHistory = value
                session.saveConfig(snapshot)
                session.kit.clipboard.setEnabled(value)
            }
            toggleRow("记住我打过的词", isOn: session.snapshot.enableLearning) { value in
                var snapshot = session.snapshot
                snapshot.enableLearning = value
                session.saveConfig(snapshot)
            }
            Button {
                session.kit.learning.reset()
                session.showToast("已清除")
            } label: {
                row("清除我打过的词") {
                    Text("\(session.kit.learning.learnedWordCount) 个")
                        .font(.system(size: 13))
                        .foregroundColor(palette.secondary.color)
                }
            }
            .buttonStyle(.plain)
            row("版本") {
                Text(Self.versionText)
                    .font(.system(size: 13))
                    .foregroundColor(palette.secondary.color)
            }
        }
    }

    /// 版本号。「改了看不到效果」时先看这里，iOS 会缓存键盘进程。
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var providerSummary: String {
        guard let provider = session.snapshot.defaultProvider else { return "还没配" }
        return settings.hasKey(provider) ? provider.name : "\(provider.name) · 没填 Key"
    }

    // MARK: - 服务列表

    private var providerRows: some View {
        VStack(spacing: 0) {
            ForEach(settings.providers) { provider in
                HStack(spacing: 8) {
                    Button {
                        settings.setDefault(provider)
                    } label: {
                        Image(systemName: isDefault(provider) ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 18))
                            .foregroundColor(isDefault(provider) ? palette.accentText.color : palette.secondary.color)
                            .frame(width: 30, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isDefault(provider) ? "正在用" : "设为默认")

                    Button {
                        settings.edit(provider)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(provider.name)
                                    .font(.system(size: 14.5))
                                    .foregroundColor(palette.text.color)
                                Text(provider.supportsChat ? provider.model : "画图")
                                    .font(.system(size: 12))
                                    .foregroundColor(palette.secondary.color)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(settings.hasKey(provider) ? "" : "没填 Key")
                                .font(.system(size: 12))
                                .foregroundColor(palette.secondary.color)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11))
                                .foregroundColor(palette.secondary.color)
                        }
                        .frame(height: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .overlay(alignment: .bottom) {
                    palette.line.color.frame(height: 0.5)
                }
            }

            Text("添加")
                .font(.system(size: 12))
                .foregroundColor(palette.secondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PresetProviders.all.filter { preset in
                        !settings.providers.contains { $0.id == preset.id }
                    }) { preset in
                        PanelChip(title: preset.name, isSelected: false) { settings.add(preset: preset) }
                    }
                    PanelChip(title: "自定义", isSelected: false) { settings.add(preset: nil) }
                }
            }
            HStack {
                Spacer(minLength: 0)
                PanelButton(title: "导入 App 里的配置") { settings.importFromApp() }
            }
            .padding(.top, 10)
        }
    }

    private func isDefault(_ provider: AIProviderConfig) -> Bool {
        provider.supportsChat
            ? session.snapshot.defaultProvider?.id == provider.id
            : session.snapshot.imageProvider?.id == provider.id
    }

    // MARK: - 编辑

    private var providerEditor: some View {
        VStack(spacing: 0) {
            fieldRow("名字", value: settings.draft.name, preferEnglish: false) { settings.draft.name = $0 }
            fieldRow("地址", value: settings.draft.baseURL, preferEnglish: true) { settings.draft.baseURL = $0 }
            if settings.draft.supportsImage || PresetProviders.isImageOnly(id: settings.draft.id) {
                fieldRow("画图模型", value: settings.draft.imageModel ?? "", preferEnglish: true) { settings.draft.imageModel = $0 }
            }
            if !PresetProviders.isImageOnly(id: settings.draft.id) {
                fieldRow("模型", value: settings.draft.model, preferEnglish: true) { settings.draft.model = $0 }
                modelChips
            }
            keyRow

            if let message = settings.testMessage {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(settings.testFailed ? palette.text.color : palette.accentText.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }

            HStack(spacing: 8) {
                PanelButton(title: settings.isTesting ? "测试中…" : "测试") { settings.test() }
                if !settings.isNew {
                    PanelButton(title: "删除") { settings.delete() }
                }
                Spacer(minLength: 0)
                PanelButton(title: "保存", isPrimary: true) { settings.save() }
            }
            .padding(.top, 10)
        }
    }

    private var modelChips: some View {
        let models = PresetProviders.knownModels(forBaseURL: settings.draft.baseURL)
        return Group {
            if !models.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(models, id: \.self) { model in
                            PanelChip(title: model, isSelected: settings.draft.model == model) {
                                settings.draft.model = model
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func fieldRow(_ title: String, value: String, preferEnglish: Bool,
                          onDone: @escaping (String) -> Void) -> some View {
        Button {
            session.beginField(title: title, value: value, isSecret: false, preferEnglish: preferEnglish, onDone: onDone)
        } label: {
            row(title) {
                Text(value.isEmpty ? "点这里填" : value)
                    .font(.system(size: 13))
                    .foregroundColor(value.isEmpty ? palette.secondary.color : palette.text.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
    }

    private var keyRow: some View {
        Button {
            session.beginField(title: "API Key", value: settings.keyDraft, isSecret: true, preferEnglish: true) { value in
                settings.keyDraft = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } label: {
            row("API Key") {
                Text(maskedKey)
                    .font(.system(size: 13))
                    .foregroundColor(settings.keyDraft.isEmpty ? palette.secondary.color : palette.text.color)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private var maskedKey: String {
        let key = settings.keyDraft
        guard !key.isEmpty else { return "点这里粘贴" }
        return "••••••" + String(key.suffix(4))
    }

    // MARK: - 小部件

    private func row<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14.5))
                .foregroundColor(palette.text.color)
            Spacer(minLength: 8)
            accessory()
        }
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            palette.line.color.frame(height: 0.5)
        }
        .contentShape(Rectangle())
    }

    private func toggleRow(_ title: String, isOn: Bool, action: @escaping (Bool) -> Void) -> some View {
        row(title) {
            Toggle("", isOn: Binding(get: { isOn }, set: { action($0) }))
                .labelsHidden()
                .tint(palette.accent.color)
                .scaleEffect(0.85)
        }
    }

    private func segmented(_ items: [(String, Bool)], action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { pair in
                Button {
                    action(pair.offset)
                } label: {
                    Text(pair.element.0)
                        .font(.system(size: 12.5, weight: pair.element.1 ? .semibold : .regular))
                        .foregroundColor(pair.element.1 ? palette.text.color : palette.secondary.color)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(pair.element.1 ? palette.key.color : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(palette.function.color)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 填写设置项：上面是内容，下面是键盘自己的键区。
@MainActor
struct FieldEditView: View {
    @ObservedObject var session: KeyboardSession
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(session.fieldEdit?.title ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(palette.text.color)
                Spacer(minLength: 0)
                smallButton("粘贴") { session.pasteIntoDraft() }
                smallButton("清空") { session.clearDraft() }
                smallButton("取消") { session.finishField(save: false) }
            }
            HStack(spacing: 0) {
                Text(display)
                    .font(.system(size: 14.5))
                    .foregroundColor(palette.text.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                palette.accent.color.frame(width: 1.5, height: 17)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(palette.key.color)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var display: String {
        if session.fieldEdit?.isSecret == true, session.draft.count > 8 {
            return String(repeating: "•", count: 6) + String(session.draft.suffix(4))
        }
        return session.draft.isEmpty ? " " : session.draft
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundColor(palette.text.color)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(palette.function.color)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 语音输入面板。
@MainActor
struct VoicePanelView: View {
    @ObservedObject var session: KeyboardSession
    @ObservedObject var voice: KMVoiceInput
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("语音输入")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(palette.text.color)
                    .padding(.leading, 14)
                Spacer(minLength: 0)
                PanelCloseButton { session.setPage(.keys) }
                    .padding(.trailing, 4)
            }
            .frame(height: 44)

            ScrollView(.vertical, showsIndicators: false) {
                Text(bodyText)
                    .font(.system(size: 16))
                    .foregroundColor(isPlaceholder ? palette.secondary.color : palette.text.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.key.color)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.horizontal, 8)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                switch voice.state {
                case let .finished(text):
                    PanelButton(title: "重说") {
                        voice.reset()
                        voice.start()
                    }
                    PanelButton(title: "放进输入框", isPrimary: true) {
                        session.host?.documentProxy.insertText(text)
                        voice.reset()
                        session.setPage(.keys)
                    }
                case .failed:
                    PanelButton(title: "再试一次", isPrimary: true) {
                        voice.reset()
                        voice.start()
                    }
                case .recording:
                    PanelButton(title: "说完了", isPrimary: true) { voice.stop() }
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 50)
        }
    }

    private var isPlaceholder: Bool {
        if case .finished = voice.state { return false }
        return voice.partialText.isEmpty
    }

    private var bodyText: String {
        switch voice.state {
        case let .finished(text):
            return text
        case let .failed(reason, _):
            return reason
        case .requestingPermission:
            return "正在准备…"
        case .transcribing:
            return voice.partialText.isEmpty ? "正在转文字…" : voice.partialText
        default:
            return voice.partialText.isEmpty ? "请说话…" : voice.partialText
        }
    }
}
