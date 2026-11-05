//
//  AIPanelModel.swift
//  墨语键盘 · AI 面板的逻辑
//
//  润色、翻译、扩写、回复、画图。点一下就读输入框里的字，结果流式显示。
//
//  和旧版不同的地方：
//  - 「替换」真的会替换原文。旧版结果只是接在原文后面，变成两段。
//  - 每次打开都重新读输入框。旧版会一直用第一次读到的内容。
//  - 回复：输入框空着时读你复制的那句话。旧版这时候直接报错。
//  - 翻译：自动判断方向，也可以自己选语言。旧版永远翻成英文。
//

import Combine
import Foundation
import UIKit

/// 面板里的功能。
enum AIPanelFeature: String, CaseIterable, Identifiable {
    case polish, translate, reply, expand, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .polish: return "润色"
        case .translate: return "翻译"
        case .reply: return "回复"
        case .expand: return "扩写"
        case .image: return "画图"
        }
    }

    var feature: AIFeature {
        switch self {
        case .polish: return .polish
        case .translate: return .translate
        case .reply: return .replySuggestion
        case .expand: return .expand
        case .image: return .image
        }
    }
}

@MainActor
final class AIPanelModel: ObservableObject {

    /// 面板状态。
    enum Phase: Equatable {
        /// 没开完全访问。
        case needsFullAccess
        /// 没配 AI 服务。
        case needsProvider
        /// 输入框没有内容。
        case needsSource
        /// 请求中，还没有字。
        case waiting(String)
        /// 正在出字。
        case streaming
        /// 完成。
        case done
        /// 用户点了停止，一个字都还没出来。
        case stopped
        /// 失败。
        case failed(title: String, detail: String, suggestsSettings: Bool)
    }

    static let tones = ["自然", "简洁", "礼貌", "正式", "热情", "幽默"]
    static let replyTones = ["自然", "答应", "婉拒", "追问", "安慰", "幽默", "礼貌"]
    static let languages = ["英文", "中文", "日语", "韩语", "法语"]

    @Published private(set) var feature: AIPanelFeature = .polish
    @Published private(set) var phase: Phase = .needsSource
    @Published private(set) var source = ""
    @Published private(set) var output = ""
    @Published private(set) var replies: [String] = []
    @Published private(set) var image: UIImage?
    @Published var tone = "自然"
    @Published var targetLanguage = "英文"
    @Published private(set) var sourceIsClipboard = false

    private unowned let session: KeyboardSession
    private var task: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var imageData: Data?
    /// 「重写」「换一批」时不要和这些重复。
    private var avoidTexts: [String] = []

    /// 替换原文要删掉多少。
    private var sourceBeforeCount = 0
    private var sourceAfterUTF16 = 0
    private var sourceAfterCount = 0
    private var sourceIsSelection = false

    init(session: KeyboardSession) {
        self.session = session
    }

    // MARK: - 打开与切换

    /// 打开某个功能。
    func open(_ feature: AIPanelFeature) {
        cancel()
        self.feature = feature
        tone = session.snapshot.defaultTone
        normalizeTone()
        sourceIsClipboard = false
        captureSource()
        if feature == .translate {
            targetLanguage = Self.containsChinese(source) ? "英文" : "中文"
        }
        run()
    }

    /// 切页签：继续用已经读到的内容，语气不变。
    func switchTo(_ feature: AIPanelFeature) {
        guard feature != self.feature else { return }
        cancel()
        self.feature = feature
        if !sourceIsClipboard {
            captureSource()
        }
        if feature == .translate {
            targetLanguage = Self.containsChinese(source) ? "英文" : "中文"
        }
        normalizeTone()
        run()
    }

    /// 回复和润色的语气选项不同，切页签时选项里没有当前语气就回到「自然」。
    private func normalizeTone() {
        let options = feature == .reply ? Self.replyTones : Self.tones
        if !options.contains(tone) {
            tone = "自然"
        }
    }

    func setTone(_ value: String) {
        guard value != tone else { return }
        tone = value
        run()
    }

    func setTargetLanguage(_ value: String) {
        guard value != targetLanguage else { return }
        targetLanguage = value
        run()
    }

    /// 读输入框：有选中用选中，没选中用全部。
    private func captureSource() {
        guard let proxy = session.host?.documentProxy else { return }
        sourceIsClipboard = false
        if let selected = proxy.selectedText, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = selected
            sourceIsSelection = true
            sourceBeforeCount = 0
            sourceAfterCount = 0
            sourceAfterUTF16 = 0
            return
        }
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        source = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
        sourceIsSelection = false
        sourceBeforeCount = before.count
        sourceAfterCount = after.count
        sourceAfterUTF16 = after.utf16.count
    }

    /// 读剪贴板（用户点了按钮才读，系统可能问一次「允许粘贴」）。
    func useClipboard() {
        guard UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            session.showToast("剪贴板里没有文字，先去复制一句")
            return
        }
        source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceIsClipboard = true
        sourceIsSelection = false
        sourceBeforeCount = 0
        sourceAfterCount = 0
        sourceAfterUTF16 = 0
        run()
    }

    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    // MARK: - 请求

    /// 再来一次，并且要求和刚才的结果不一样。
    func regenerate() {
        let previous = feature == .reply ? replies : (output.isEmpty ? [] : [output])
        run(avoiding: previous)
    }

    /// 发起请求（打开、切换语气、重写都走这里）。
    func run(avoiding previous: [String] = []) {
        cancel()
        avoidTexts = previous
        output = ""
        replies = []
        image = nil
        imageData = nil

        switch session.aiBlocker {
        case .noFullAccess:
            phase = .needsFullAccess
            return
        case .notConfigured:
            phase = .needsProvider
            return
        case nil:
            break
        }

        guard !source.isEmpty else {
            phase = .needsSource
            return
        }

        if feature == .image {
            runImage()
        } else {
            runText()
        }
    }

    private func runText() {
        let snapshot = session.snapshot
        guard let provider = snapshot.defaultProvider,
              let apiKey = KeychainStore.shared.apiKey(for: provider.id), !apiKey.isEmpty else {
            phase = .needsProvider
            return
        }
        let template = PromptLibrary.defaultTemplate(for: feature.feature) ?? BuiltInPrompts.custom
        var request = PromptLibrary.makeRequest(template,
                                                text: source,
                                                context: "",
                                                tone: tone,
                                                targetLanguage: targetLanguage,
                                                replyCount: max(snapshot.replyCount, 1))
        if let last = request.messages.indices.last, let extra = extraInstruction() {
            request.messages[last].content += "\n\n" + extra
        }
        if !avoidTexts.isEmpty {
            request.temperature = 0.95
        }
        let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey)
        phase = .waiting("正在想…")

        task = Task { [weak self] in
            do {
                var accumulated = ""
                for try await delta in client.stream(request) {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    if !delta.text.isEmpty {
                        accumulated += delta.text
                        self.output = accumulated
                        self.phase = .streaming
                    } else if delta.reasoning?.isEmpty == false, accumulated.isEmpty {
                        self.phase = .waiting("模型在推理，可能要十几秒…")
                    }
                    if delta.isFinal { break }
                }
                guard let self, !Task.isCancelled else { return }
                self.finishText(accumulated)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    /// 语气和「别重复」的要求。内置模板里没有语气这一项，要在这里补上，否则切语气结果不会变。
    private func extraInstruction() -> String? {
        var parts: [String] = []
        if feature == .reply {
            let descriptions = [
                "答应": "全部是爽快答应对方，说法各不相同",
                "婉拒": "全部是委婉拒绝对方，理由各不相同，不伤感情",
                "追问": "全部是追问细节，问的角度各不相同",
                "安慰": "全部是关心和安慰对方，语气温柔",
                "幽默": "全部幽默俏皮，让人想笑",
                "礼貌": "全部客气有礼貌"
            ]
            if let description = descriptions[tone] {
                parts.append("这次的要求（优先于上面说的立场要有区分）：\(description)。")
            }
        } else if feature == .polish || feature == .expand {
            let descriptions = [
                "简洁": "简短利落，能省的字都省掉",
                "礼貌": "客气有礼貌，可以用「您」「请」",
                "正式": "正式、书面，适合工作场合",
                "热情": "热情有活力",
                "幽默": "幽默俏皮，让人想笑"
            ]
            if let description = descriptions[tone] {
                parts.append("语气要求：\(description)。")
            }
        }
        if !avoidTexts.isEmpty {
            parts.append("不要和下面这些重复，换完全不同的说法：" + avoidTexts.joined(separator: " / "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func finishText(_ text: String) {
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            fail(AIError.unknown("模型没有返回内容"))
            return
        }
        output = result
        if feature == .reply {
            replies = Self.splitReplies(result)
        }
        phase = .done
    }

    private func fail(_ error: Error) {
        let mapped = AIError.wrap(error)
        if mapped == .cancelled { return }
        let suggestsSettings: Bool
        switch mapped {
        case .notConfigured, .missingAPIKey, .unauthorized:
            suggestsSettings = true
        default:
            suggestsSettings = false
        }
        phase = .failed(title: mapped.errorDescription ?? "出错了",
                        detail: mapped.recoverySuggestion ?? "",
                        suggestsSettings: suggestsSettings)
    }

    private func runImage() {
        let snapshot = session.snapshot
        guard let provider = snapshot.imageProvider ?? snapshot.providers.first(where: { $0.supportsImage }),
              let apiKey = KeychainStore.shared.apiKey(for: provider.id), !apiKey.isEmpty else {
            phase = .failed(title: "还没配画图服务",
                            detail: "到设置里选一个能画图的服务（即梦、通义万相），填上 Key。",
                            suggestsSettings: true)
            return
        }
        let prompt = source
        let size = snapshot.imageSize
        let chatProvider = snapshot.defaultProvider
        let chatKey = chatProvider.flatMap { KeychainStore.shared.apiKey(for: $0.id) }
        let client = AIClientFactory.makeImage(config: provider, apiKey: apiKey)
        phase = .waiting("正在画，一般要 5 到 20 秒…")
        startImageProgress()

        task = Task { [weak self] in
            do {
                var finalPrompt = prompt
                if let chatProvider, let chatKey, !chatKey.isEmpty {
                    let llm = AIClientFactory.makeLLM(config: chatProvider, apiKey: chatKey)
                    if let enhanced = try? await llm.complete(PromptLibrary.imagePromptEnhanceRequest(prompt)) {
                        let text = enhanced.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { finalPrompt = text }
                    }
                }
                if Task.isCancelled { return }
                let images = try await client.generate(ImageRequest(prompt: finalPrompt, size: size, quality: "standard", count: 1))
                guard let self, !Task.isCancelled else { return }
                guard let first = images.first, !first.isEmpty, let picture = Self.thumbnail(from: first.data) else {
                    self.progressTask?.cancel()
                    self.fail(AIError.unknown("没有拿到图片"))
                    return
                }
                self.progressTask?.cancel()
                self.imageData = first.data
                self.image = picture
                self.phase = .done
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.progressTask?.cancel()
                self.fail(error)
            }
        }
    }

    private func startImageProgress() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            var seconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                seconds += 1
                if case .waiting = self.phase {
                    self.phase = .waiting("正在画，已经等了 \(seconds) 秒…")
                }
            }
        }
    }

    /// 键盘内存紧，只留缩略图显示。
    private static func thumbnail(from data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let side: CGFloat = 400
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// 停止当前请求。
    func cancel() {
        task?.cancel()
        task = nil
        progressTask?.cancel()
        progressTask = nil
        if case .waiting = phase {
            phase = output.isEmpty ? .stopped : .done
        } else if phase == .streaming {
            phase = .done
        }
    }

    // MARK: - 用结果

    /// 用结果替换原文。
    func replace() {
        let text = output
        guard !text.isEmpty, let proxy = session.host?.documentProxy else { return }
        if sourceIsSelection {
            // 有选中时 insertText 会直接盖掉选区
            proxy.insertText(text)
        } else {
            if sourceAfterUTF16 > 0 {
                proxy.adjustTextPosition(byCharacterOffset: sourceAfterUTF16)
            }
            for _ in 0..<(sourceBeforeCount + sourceAfterCount) {
                proxy.deleteBackward()
            }
            proxy.insertText(text)
        }
        session.closePanel()
        session.showToast(sourceIsClipboard ? "已放进输入框" : "已替换")
    }

    /// 接在光标后面（不删原文）。
    func insertResult() {
        guard !output.isEmpty else { return }
        session.host?.documentProxy.insertText(output)
        session.closePanel()
        session.showToast("已放进输入框")
    }

    /// 选一条回复。
    func chooseReply(_ text: String) {
        guard let proxy = session.host?.documentProxy else { return }
        // 输入框里是对方的话时不留原文；读的是剪贴板就直接写
        if !sourceIsClipboard, !sourceIsSelection {
            if sourceAfterUTF16 > 0 {
                proxy.adjustTextPosition(byCharacterOffset: sourceAfterUTF16)
            }
            for _ in 0..<(sourceBeforeCount + sourceAfterCount) {
                proxy.deleteBackward()
            }
        }
        proxy.insertText(text)
        session.closePanel()
        session.showToast("已放进输入框")
    }

    func copyResult() {
        guard !output.isEmpty else { return }
        UIPasteboard.general.string = output
        session.showToast("已复制")
    }

    func copyImage() {
        guard let imageData, let picture = UIImage(data: imageData) else {
            session.showToast("图片已释放，重新画一张吧")
            return
        }
        UIPasteboard.general.image = picture
        session.showToast("已复制，到聊天框长按粘贴")
    }

    // MARK: - 解析回复

    /// 把模型输出拆成几条回复。
    static func splitReplies(_ text: String) -> [String] {
        var lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.count < 2 {
            lines = lines.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: "；;")) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        var result: [String] = []
        for line in lines {
            let cleaned = stripNumbering(line)
            if !cleaned.isEmpty, !result.contains(cleaned) {
                result.append(cleaned)
            }
            if result.count == 5 { break }
        }
        return result
    }

    private static func stripNumbering(_ line: String) -> String {
        let pattern = "^\\s*[0-9一二三四五六七八九十]+\\s*[.、)）:：]\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return regex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
