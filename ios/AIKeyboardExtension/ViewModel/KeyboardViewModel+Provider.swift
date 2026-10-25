//
//  KeyboardViewModel+Provider.swift
//  AIKeyboardExtension
//
//  模块职责：在**键盘内**完成 AI 服务商的增删改与 API Key 存取。
//
//  为什么必须做在键盘里（v2.0 的关键修复）：
//  免费 Apple ID 签名无法为键盘扩展配置 App Group，`SharedStore` 会降级成
//  `UserDefaults.standard`，而 App 与扩展是两个独立进程、两个独立沙盒——
//  用户在宿主 App 里配好的服务商与 Key，键盘**物理读不到**。
//  旧版键盘设置页只提供「选择服务商」，文案还写着「编辑请到『墨语』App」，
//  于是用户配好 API 却永远提示「还没有配置 AI 服务」，这是「API 配置好也没有
//  办法正常使用」的真正原因。
//
//  依赖：Shared 层的 `ConfigStore` / `KeychainStore` / `AIProviderConfig` /
//        `PresetProviders`。本文件只做「读写 + 校验」，UI 在
//        `Views/KMProviderEditorSheet.swift`。
//

import Foundation

extension KeyboardViewModel {

    // MARK: - 读取

    /// 键盘可见的服务商列表（来自本进程的配置快照）。
    var providerList: [AIProviderConfig] {
        snapshot.providers
    }

    /// 某个服务商是否已有 API Key（Keychain，本进程沙盒内）。
    /// - Parameter providerID: 服务商 ID。
    /// - Returns: 有非空 Key 时为 true。
    func hasAPIKey(forProviderID providerID: String) -> Bool {
        guard let key = KeychainStore.shared.apiKey(for: providerID) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 读取某个服务商的 API Key（用于编辑页回填与探活）。
    /// - Parameter providerID: 服务商 ID。
    /// - Returns: Key；没有时返回空串。
    func apiKeyForEditing(providerID: String) -> String {
        KeychainStore.shared.apiKey(for: providerID) ?? ""
    }

    /// 当前默认服务商是否「配齐了」（地址 + 模型 + Key）。
    ///
    /// 用于键盘 AI 条上的提示：配不齐时不该让用户点进去等一个必然失败的请求。
    var defaultProviderIsReady: Bool {
        guard let provider = snapshot.defaultProvider else { return false }
        guard provider.isChatConfigured else { return false }
        return hasAPIKey(forProviderID: provider.id)
    }

    // MARK: - 写入

    /// 新增一个服务商（默认取推荐预设，用户可再改）。
    /// - Returns: 新服务商的 ID。
    @discardableResult
    func addProviderFromPreset() -> String {
        let isFirst = snapshot.providers.isEmpty
        var provider = PresetProviders.recommended?.makeProvider(isDefault: isFirst)
            ?? AIProviderConfig(name: "自定义服务", isDefault: isFirst)
        // 同一预设被加过多次时给名字加序号，否则界面上会出现两个「DeepSeek」
        var index = 2
        let baseName = provider.name
        while snapshot.providers.contains(where: { $0.name == provider.name }) {
            provider.name = "\(baseName) \(index)"
            index += 1
        }
        var updated = snapshot
        updated.providers.append(provider)
        if updated.defaultProviderID == nil {
            updated.defaultProviderID = provider.id
        }
        applyConfig(updated)
        return provider.id
    }

    /// 保存一个服务商（按 id 覆盖；id 不存在则追加）。
    /// - Parameter provider: 编辑后的服务商。
    func saveProvider(_ provider: AIProviderConfig) {
        var updated = snapshot
        if let index = updated.providers.firstIndex(where: { $0.id == provider.id }) {
            updated.providers[index] = provider
        } else {
            updated.providers.append(provider)
        }
        if updated.defaultProviderID == nil {
            updated.defaultProviderID = provider.id
        }
        applyConfig(updated)
    }

    /// 删除一个服务商（连同它的 API Key）。
    /// - Parameter providerID: 服务商 ID。
    func deleteProvider(id providerID: String) {
        var updated = snapshot
        updated.providers.removeAll { $0.id == providerID }
        if updated.defaultProviderID == providerID {
            updated.defaultProviderID = updated.providers.first(where: { $0.supportsChat })?.id
        }
        if updated.imageProviderID == providerID {
            updated.imageProviderID = nil
        }
        // Key 必须一起删：否则用户在界面里删掉了服务商，Keychain 里还留着密钥，
        // 后面用同一个 id 重建服务商时会出现「没填 Key 却能连通」的怪现象。
        try? KeychainStore.shared.deleteAPIKey(for: providerID)
        applyConfig(updated)
    }

    /// 保存 API Key。
    /// - Parameters:
    ///   - apiKey: Key 原文（会被 trim）。
    ///   - providerID: 服务商 ID。
    /// - Returns: 去掉首尾空白后是否非空（空则删除已有 Key 并返回 false）。
    @discardableResult
    func saveAPIKey(_ apiKey: String, forProviderID providerID: String) -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? KeychainStore.shared.deleteAPIKey(for: providerID)
            return false
        }
        do {
            try KeychainStore.shared.setAPIKey(trimmed, for: providerID)
            return true
        } catch {
            showToast("API Key 保存失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 用给定的草稿配置发一次「hi」探活，返回中文结果文案。
    ///
    /// 为什么不复用宿主 App 的 `ConnectivityProbe`：它编译在 App target 里，
    /// 键盘扩展 target 看不到（两个 target 只共享 `ios/Shared`）。
    /// 这里直接用 Shared 层的 `AIClientFactory` + `ChatRequest`，逻辑同源。
    ///
    /// - Parameters:
    ///   - config: 待测试的服务商配置（草稿，未保存也能测）。
    ///   - apiKey: 待测试的 Key。
    /// - Returns: `(是否失败, 中文文案)`。
    func probeProvider(
        config: AIProviderConfig,
        apiKey: String
    ) async -> (failed: Bool, message: String) {
        let started = Date()
        var buffer = ""
        var sawReasoning = false
        let request = ChatRequest(
            messages: [ChatMessage.user("hi")],
            temperature: 0,
            // 256 而不是 8：推理模型（deepseek-reasoner 等）对 "hi" 的思维链本身就要
            // 一百多个 token，给太小会让正文还没开始就撞上 max_tokens，
            // 客户端按「正文为空」报错，用户会以为 Key 配错了。
            maxTokens: 256,
            stream: true
        )
        do {
            let client = AIClientFactory.makeLLM(config: config, apiKey: apiKey)
            let stream = client.stream(request)
            for try await delta in stream {
                if !delta.text.isEmpty { buffer += delta.text }
                if let reasoning = delta.reasoning, !reasoning.isEmpty { sawReasoning = true }
                if delta.isFinal { break }
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let sample = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sample.isEmpty {
                return (false, "连通（\(ms) ms）：\(String(sample.prefix(40)))")
            }
            if sawReasoning {
                // 推理模型的正常表现：探活能看到思维链，正文要在聊天里长问才出。
                return (false, "连通（\(ms) ms）。这是推理模型，探活只收到思维链，聊天时会正常出正文。")
            }
            return (false, "连通（\(ms) ms），但服务商返回空内容。")
        } catch {
            let wrapped = AIError.wrap(error)
            if sawReasoning, case AIError.contentRejected = wrapped {
                return (false, "连通。这是推理模型，探活只收到思维链。")
            }
            return (true, wrapped.errorDescription ?? "测试失败：\(error.localizedDescription)")
        }
    }

    /// 把编辑结果写回配置存储并刷新内存快照。
    ///
    /// 单点收口：所有增删改都走这里，保证「落盘」与「快照」永不失步。
    /// - Parameter updated: 新快照。
    private func applyConfig(_ updated: ConfigSnapshot) {
        configStore.save(updated)
        snapshot = updated
        refreshAvailability()
    }
}
