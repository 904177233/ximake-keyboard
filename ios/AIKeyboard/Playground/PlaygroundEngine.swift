//
//  PlaygroundEngine.swift
//  墨语 · 宿主 App
//
//  模块职责：「AI 试验场」的执行引擎 —— 组装 Prompt、发起流式对话 / 生图请求、
//            驱动结果卡的五种状态（含生图阶段与计时）。
//  依赖：SwiftUI（ObservableObject）、Shared（AIClientFactory / ChatRequest / AIError /
//        PromptLibrary / AIClientFactory.makeImage）、SharedBridge（ConnectivityProbe / ErrorPresenter）。
//  使用方：PlaygroundView。
//

import SwiftUI

/// 试验场执行引擎。
@MainActor
final class PlaygroundEngine: ObservableObject {

    /// 结果卡状态；nil 表示还没有发起过请求。
    @Published private(set) var state: AIResultCard.ResultState?

    /// 是否正在执行（流式或绘制中）。
    @Published private(set) var isRunning = false

    /// 最近一次请求的参数快照，供「重试」使用。
    @Published private(set) var lastRunDescription: String?

    /// 当前生图阶段索引的推进任务。
    private var stageTask: Task<Void, Never>?

    /// 当前请求的取消令牌。
    private var runToken = UUID()

    /// 取消挂起的任务。
    func cancel() {
        stageTask?.cancel()
        stageTask = nil
        runToken = UUID()
        isRunning = false
        state = nil
    }

    /// 清空结果。
    func clear() {
        cancel()
        lastRunDescription = nil
    }

    // MARK: - 文本能力

    /// 发起一次文本能力请求（润色 / 扩写 / 翻译 / 回复 / 自定义）。
    /// - Parameters:
    ///   - feature: 能力。
    ///   - template: 使用哪个模板；nil 表示该能力的默认模板。
    ///   - input: 用户输入。
    ///   - tone: 语气。
    ///   - targetLanguage: 翻译目标语言。
    ///   - provider: 服务商配置。
    ///   - apiKey: 该服务商的 API Key。
    func runText(
        feature: AIFeature,
        template: PromptTemplate?,
        input: String,
        tone: String,
        targetLanguage: String,
        provider: AIProviderConfig,
        apiKey: String
    ) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failed(AIErrorViewData(title: "还没有输入内容", message: "先写一段话，再点生成。"))
            return
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed(
                AIErrorViewData(
                    title: "还没有填写 API Key",
                    message: "请到「设置 › AI 服务」里给这个服务商填 Key。",
                    suggestion: "API Key 只保存在本机钥匙串。"
                )
            )
            return
        }
        guard provider.supportsChat else {
            state = .failed(
                AIErrorViewData(
                    title: "该服务仅支持生图",
                    message: provider.unsupportedChatReason,
                    suggestion: "请换一个对话服务商，例如 DeepSeek / 通义千问 / Kimi。"
                )
            )
            return
        }

        let token = UUID()
        runToken = token
        isRunning = true
        state = .streaming("")

        let resolvedTemplate = template ?? PromptLibrary.defaultTemplate(for: feature)
        let messages: [ChatMessage]
        if let resolvedTemplate {
            messages = PromptCatalog.render(
                resolvedTemplate,
                text: trimmed,
                context: "",
                tone: tone,
                targetLanguage: targetLanguage
            )
        } else {
            messages = [ChatMessage.user(trimmed)]
        }

        let temperature = resolvedTemplate?.temperature ?? provider.temperature
        let request = ChatRequest(
            messages: messages,
            temperature: temperature,
            maxTokens: provider.maxTokens,
            stream: true
        )
        let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey)
        lastRunDescription = "\(feature.title) · \(provider.name)"

        Task {
            var buffer = ""
            do {
                let stream = client.stream(request)
                for try await delta in stream {
                    if Task.isCancelled || runToken != token {
                        return
                    }
                    if !delta.text.isEmpty {
                        buffer += delta.text
                        state = .streaming(buffer)
                    }
                    if delta.isFinal {
                        break
                    }
                }
                guard runToken == token else { return }
                let finalText = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if finalText.isEmpty {
                    state = .failed(
                        AIErrorViewData(
                            title: "服务商没有返回内容",
                            message: "可以换个模型，或稍后重试。"
                        )
                    )
                } else {
                    state = .done(finalText)
                }
                isRunning = false
            } catch {
                guard runToken == token else { return }
                if case AIError.cancelled = AIError.wrap(error) {
                    state = nil
                    isRunning = false
                    return
                }
                state = .failed(Self.errorData(from: error))
                isRunning = false
            }
        }
    }

    // MARK: - 生图

    /// 发起一次生图请求。
    /// - Parameters:
    ///   - prompt: 用户描述。
    ///   - size: 尺寸，如 "1024x1024"。
    ///   - provider: 生图服务商配置。
    ///   - apiKey: 该服务商的 API Key。
    ///   - providerName: 展示名。
    func runImage(
        prompt: String,
        size: String,
        provider: AIProviderConfig,
        apiKey: String,
        providerName: String
    ) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failed(AIErrorViewData(title: "还没有输入描述", message: "描述一下想画什么，再点生成。"))
            return
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed(
                AIErrorViewData(
                    title: "还没有填写 API Key",
                    message: "请到「设置 › AI 服务」里给生图服务商填 Key。",
                    suggestion: "即梦 / 通义万相的 Key 分别在火山引擎与阿里云百炼控制台申请。"
                )
            )
            return
        }
        guard provider.supportsImage else {
            state = .failed(
                AIErrorViewData(
                    title: "这个服务商没有配置生图模型",
                    message: "请在「AI 服务 › 生图服务商」里添加即梦或通义万相。",
                    suggestion: "生图需要单独配置生图服务商。"
                )
            )
            return
        }

        let token = UUID()
        runToken = token
        isRunning = true
        lastRunDescription = "生图 · \(providerName)"
        state = .imageGenerating(ImageProgress(prompt: trimmed, stage: .queued))
        startStageTicker(token: token)

        Task {
            do {
                let images = try await ConnectivityProbe.generateImage(
                    config: provider,
                    apiKey: apiKey,
                    prompt: trimmed,
                    size: size
                )
                guard runToken == token else { return }
                stageTask?.cancel()
                stageTask = nil

                guard let first = images.first else {
                    state = .failed(
                        AIErrorViewData(
                            title: "没有拿到图片",
                            message: "服务商返回了空结果，换个描述再试一次。"
                        )
                    )
                    isRunning = false
                    return
                }
                let dimensions = ImageRequest.dimensions(from: size)
                let sizeText = dimensions.map { "\($0.width)×\($0.height)" } ?? size
                state = .image(
                    ImageResultViewData(image: first, prompt: trimmed, sizeDescription: sizeText)
                )
                isRunning = false
                Haptics.success()
            } catch {
                guard runToken == token else { return }
                stageTask?.cancel()
                stageTask = nil
                if case AIError.cancelled = AIError.wrap(error) {
                    state = nil
                    isRunning = false
                    return
                }
                state = .failed(Self.errorData(from: error))
                isRunning = false
                Haptics.warning()
            }
        }
    }

    /// 生图阶段推进：排队 → 绘制 → 下载。
    private func startStageTicker(token: UUID) {
        stageTask?.cancel()
        stageTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, self.runToken == token else { return }
            self.updateStage(.drawing, token: token)

            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, self.runToken == token else { return }
            self.updateStage(.enhancing, token: token)

            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, self.runToken == token else { return }
            self.updateStage(.downloading, token: token)
        }
    }

    /// 更新生图阶段（只有处于生图中才生效）。
    private func updateStage(_ stage: ImageProgress.Stage, token: UUID) {
        guard runToken == token else { return }
        guard case .imageGenerating(var progress) = state else { return }
        progress.stage = stage
        state = .imageGenerating(progress)
    }

    // MARK: - 工具

    /// 把任意错误转成失败态数据。
    static func errorData(from error: Error) -> AIErrorViewData {
        if let aiError = error as? AIError {
            return AIErrorViewData(error: aiError)
        }
        return AIErrorViewData(
            title: ErrorPresenter.message(error),
            suggestion: ErrorPresenter.suggestion(error)
        )
    }
}
