# ios/Shared — UI 接入指南（可直接抄的 Swift 片段）

> 模块职责：把共享层（Models / Networking / Storage / Prompts / Theme）的典型调用路径整理成
> 可直接复制粘贴的 Swift 代码片段，覆盖 **键盘扩展（流式 AI）**、**宿主 App（配置管理 / 生图）**、
> **自定义模板** 三类场景，并统一错误展示与流式取消的写法。
> 依赖：`ios/Shared/**` 全部公开 API（签名见各模块 README）。
> 使用方：`ios/AIKeyboard/**`（宿主 App）、`ios/AIKeyboardExtension/**`（键盘扩展）。
> 适用目标：iOS 16.0+ / Swift 5 / 零第三方依赖。

**阅读顺序建议**：先看 §0 公共约定，再按你的场景跳到 §A（键盘流式改写）/ §B（宿主 App 生图）/
§C（自定义模板与配置搬运）。所有片段都是**完整可编译**的写法（省略了外部类型如 `AppState`
的成员定义，但 Shared 侧的调用是逐行可抄的）。

---

## 0. 公共约定（三个地方都要注意）

### 0.1 import 语句

共享层的模块纯度是硬约束：

| 层 | 允许 import | 说明 |
| --- | --- | --- |
| `Models` / `Networking` / `Prompts` | **仅 `import Foundation`** | 纯逻辑，扩展与 App 都能用 |
| `Storage` | `Foundation` + `Security`（Keychain）/ `UIKit`（仅 `UIPasteboard`） | 无 `UIApplication.shared` |
| `Theme` | `SwiftUI` + `UIKit`（仅 `UIColor`） | 只能在 UI 层被引用 |

因此 UI 侧统一这样写：

```swift
// 键盘扩展 / 宿主 App 的 SwiftUI 视图文件
import SwiftUI
import Foundation
// 同一个 target 内无需 import 自己模块；若将来拆成独立 framework 才需要 import MoyuShared
```

> 本项目所有 Shared 文件直接编译进 App target 与 Extension target（无独立 framework），
> 所以**不需要** `import MoyuShared` 这类语句，直接引用类型名即可。

### 0.2 错误展示：永远是「一句话现象 + 一句话动作」

`AIError` 是 `LocalizedError`，`errorDescription` 只描述现象、`recoverySuggestion` 是可执行动作。
UI 不要自己拼错误文案，统一用这两个属性：

```swift
/// 把任意错误转成「标题 + 副标题」两行中文文案。
func presentError(_ error: Error) -> (title: String, detail: String) {
    let aiError = AIError.wrap(error)          // 非 AIError 也会被归一到 AIError
    return (
        title: aiError.errorDescription ?? "出错了",
        detail: aiError.recoverySuggestion ?? "稍后重试。"
    )
}
```

`AIError.wrap(_:)` 会把 `CancellationError` 映射为 `.cancelled`，把 `NSURLError*` 映射为
`.network` / `.timeout`，因此**直接 catch 任意 `Error` 再 wrap** 是安全的。

### 0.3 取配置与 API Key（每次都走同一套）

```swift
let store = ConfigStore()                        // 内部用 SharedStore.shared，key = "moyu.config.snapshot"
let snapshot = store.load()                      // 永不抛错；无数据/损坏时返回 ConfigSnapshot.defaultValue()

guard let provider = snapshot.defaultProvider else {
    // 没有可用服务商 → 提示去设置页添加
    throw AIError.notConfigured
}
guard let apiKey = KeychainStore.shared.apiKey(for: provider.id), !apiKey.isEmpty else {
    throw AIError.missingAPIKey
}
```

> **不要**把 API Key 写进 `ConfigSnapshot` / `UserDefaults` / 日志。
> `AIProviderConfig.apiKeyRef` 只是计算属性（返回 `provider.id`），配置 JSON 里永远不含 Key。

---

## A. 键盘扩展：流式 AI 改写（最核心的路径）

键盘里的 AI 面板点「润色」→ 取上文 → 渲染 prompt → 流式出字 → 可随时取消。

### A.1 一个可取消的流式调用（ViewModel 里最实用的形态）

```swift
import SwiftUI          // 提供 ObservableObject / @Published / @MainActor 的常用组合
import Foundation

/// 键盘 AI 面板的状态机（片段：只保留与 Shared 交互的部分）。
@MainActor
final class AIStreamController: ObservableObject {
    /// 当前正在流的文本（UI 直接绑定，每来一片就追加）。
    @Published var streamingText: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorTitle: String?
    @Published var errorDetail: String?

    /// 保存当前任务的引用，用于「用户点取消 / 键盘收起」时中断。
    private var currentTask: Task<Void, Never>?

    /// 发起一次流式改写。
    /// - Parameters:
    ///   - feature: 能力（.polish / .expand / .translate / .replySuggestion / .custom）
    ///   - text: 要处理的正文（通常是 `textDocumentProxy.documentContextBeforeInput`）
    ///   - context: 上下文（回复建议用，传对方上一条消息）
    func start(
        feature: AIFeature,
        text: String,
        context: String = "",
        tone: String = "自然",
        targetLanguage: String = "英文",
        replyCount: Int = 3
    ) {
        cancel()                                  // 同一时刻只允许一个流
        streamingText = ""
        errorTitle = nil
        errorDetail = nil

        let snapshot = ConfigStore().load()
        guard let provider = snapshot.defaultProvider, provider.supportsChat else {
            present(AIError.notConfigured)
            return
        }
        guard let apiKey = KeychainStore.shared.apiKey(for: provider.id), !apiKey.isEmpty else {
            present(AIError.missingAPIKey)
            return
        }

        // 1) 渲染成 ChatRequest（systemPrompt + user 消息，温度用模板值）
        let request = PromptLibrary.makeRequest(
            PromptLibrary.defaultTemplate(for: feature) ?? BuiltInPrompts.custom,
            text: text,
            context: context,
            tone: tone,
            targetLanguage: targetLanguage,
            replyCount: replyCount
        )

        // 2) 建客户端（工厂按 provider.kind 自动选 OpenAI 兼容 / Anthropic / Gemini）
        let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey)

        isStreaming = true
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 3) 消费流：每片 delta.text 追加；isFinal 为 true 表示正常结束
                for try await delta in client.stream(request) {
                    if Task.isCancelled { break }
                    if !delta.text.isEmpty {
                        self.streamingText += delta.text
                    }
                    if delta.isFinal { break }
                }
                self.isStreaming = false
            } catch is CancellationError {
                self.isStreaming = false           // 用户主动取消，不弹错误
            } catch {
                self.isStreaming = false
                self.present(error)
            }
        }
    }

    /// 用户点「取消」/ 键盘收起 / 切到别的 tab —— 必须调用，否则流会继续跑。
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
    }

    private func present(_ error: Error) {
        let aiError = AIError.wrap(error)
        errorTitle = aiError.errorDescription ?? "出错了"
        errorDetail = aiError.recoverySuggestion ?? "稍后重试。"
    }
}
```

**关键点**：

1. `client.stream(request)` 返回 `AsyncThrowingStream<ChatDelta, Error>`，
   **取消 `Task` 会自动终止底层 `URLSession` 连接**（客户端内部用 `onTermination` 把取消传给 URLSession task）。
   所以 `currentTask?.cancel()` 就够了，不需要额外持有 `URLSessionTask`。
2. 流的**正常结束**一定会来一片 `ChatDelta(text: "", isFinal: true)`；**出错**时流会 `throw`，
   并且 throw 之后不会再有 `isFinal`。
3. 每片 delta 都可能很小（1~3 个字），UI 直接 `+=` 即可；不必节流（SSE 本身频率受服务端控制）。
4. 键盘扩展内存只有 ~40–60MB，**不要缓存历史消息**：`ChatRequest.messages` 每次只放
   「system + 当前这一条」，不要累积聊天记录。

### A.2 一次性调用（不需要流式时：测试连接 / 短文本）

```swift
/// 测试服务商是否可用（设置页「测试连接」按钮）。
func testConnection(provider: AIProviderConfig, apiKey: String) async -> Bool {
    do {
        let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey)
        let request = ChatRequest(
            messages: [.user("hi")],
            temperature: 0,
            maxTokens: 8,
            stream: false
        )
        let result = try await client.complete(request)
        return !result.isEmpty
    } catch {
        return false
    }
}
```

### A.3 翻译（带目标语言）

```swift
// 翻译模板是同一个，靠 targetLanguage 占位符切换方向
let messages = PromptLibrary.render(
    feature: .translate,
    text: "明天上午十点开会",
    targetLanguage: "英文"        // BuiltInPrompts.targetLanguages 里的值
)
// messages == [system: "你是翻译助手…目标语言：英文…", user: "明天上午十点开会"]
```

### A.4 回复建议（UI 必须按行切分）

模板的 `systemPrompt` 已经**定死输出格式**：恰好 N 条、每条一行、行首 `1.` `2.` `3.`。
UI 侧解析：

```swift
/// 把流式结果切成回复建议列表（也用于一次性结果）。
func parseReplies(_ text: String) -> [String] {
    text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { line in
            line.replacingOccurrences(
                of: "^\\s*\\d+[.、)]\\s*",       // 去掉 "1. " / "2、" / "3) " 前缀
                with: "",
                options: .regularExpression
            )
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}
```

> 条数通过 `replyCount` 传入（clamp 到 1...5），**不要硬编码 3**；
> 模板里的 `{{reply_count}}` 会同步替换到 systemPrompt 的「恰好 N 条」说明中。

---

## B. 宿主 App：生图（三种服务商自动路由）

生图与对话可以是**不同 Provider**：`ConfigSnapshot.imageProviderID` 指定生图服务商，
`defaultProviderID` 指定对话服务商。

### B.1 生成一张图并显示

```swift
import SwiftUI

@MainActor
final class ImageGenController: ObservableObject {
    @Published var image: UIImage?
    @Published var isGenerating = false
    @Published var errorTitle: String?
    @Published var errorDetail: String?

    func generate(prompt: String, size: String = "1024x1024") async {
        isGenerating = true
        defer { isGenerating = false }
        errorTitle = nil
        errorDetail = nil

        let snapshot = ConfigStore().load()
        guard let provider = snapshot.imageProvider ?? snapshot.providers.first(where: { $0.supportsImage }) else {
            present(AIError.notConfigured)
            return
        }
        guard let apiKey = KeychainStore.shared.apiKey(for: provider.id), !apiKey.isEmpty else {
            present(AIError.missingAPIKey)
            return
        }

        do {
            // 工厂内部按 baseURL / model 自动选择 Seedream(即梦) / Wanx(通义万相) / OpenAI 兼容
            let client = AIClientFactory.makeImage(config: provider, apiKey: apiKey)
            let images = try await client.generate(
                ImageRequest(prompt: prompt, size: size, quality: "standard", count: 1)
            )
            guard let first = images.first, !first.isEmpty else {
                present(AIError.contentRejected("服务端没有返回图片"))
                return
            }
            image = UIImage(data: first.data)
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        let aiError = AIError.wrap(error)
        errorTitle = aiError.errorDescription ?? "生图失败"
        errorDetail = aiError.recoverySuggestion ?? "稍后重试。"
    }
}
```

**路由规则**（`ImageClientRouter.route(for:)`，无需 UI 关心）：

| 条件 | 走的客户端 | 服务商 |
| --- | --- | --- |
| baseURL 含 `ark.cn-beijing.volces.com` 或 model 含 `seedream` / `doubao` | `SeedreamImageClient` | 即梦 · 火山方舟 |
| baseURL 含 `dashscope.aliyuncs.com` 或 model 含 `wanx` | `WanxImageClient` | 通义万相 · DashScope |
| 其它 | `OpenAICompatibleImageClient` | OpenAI / 硅基流动 / OpenRouter 等 |

`AIClientFactory.makeImage(config:apiKey:)` 签名固定，UI 不需要 switch。

### B.2 提示词增强（中文 → 英文生图 prompt）

生图模型对中文 prompt 效果一般。推荐两步：
先用**文本模型**把中文扩写成英文 prompt，再调生图客户端。

```swift
/// 中文需求 → 英文生图提示词（流式，可展示给用户看）。
func enhancePrompt(_ chinese: String, provider: AIProviderConfig, apiKey: String) async throws -> String {
    let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey)
    let request = PromptLibrary.imagePromptEnhanceRequest(chinese)   // 一次性，stream = false
    let result = try await client.complete(request)
    return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

> 若想让用户**看到**增强过程，用 `PromptLibrary.imagePromptEnhanceStreamRequest(_:)`
> 配 `client.stream(_:)` 消费即可（模板温度 0.6，输出 60~180 个英文单词）。

### B.3 把生成的图放进剪贴板

```swift
if let uiImage = UIImage(data: generated.data) {
    UIPasteboard.general.image = uiImage          // 用户可直接粘贴到微信
}
```

> 生图客户端返回的 `GeneratedImage.data` 已经**下载完成**（`remoteURL` 只是原始链接，
> 有效期约 24 小时，不要依赖它）。单张图上限 4MB，超限会抛
> `.server(code: 413, ...)`。

---

## C. 自定义模板与配置搬运

### C.1 读取 / 保存自定义模板

```swift
// 读：内置 + 自定义（同 feature 的合并列表，UI 用来渲染模板选择器）
let templates = PromptLibrary.templates(feature: .polish)
let builtInOnly = PromptLibrary.builtIn
let customs = PromptLibrary.loadCustom()

// 增 / 改（自动写 SharedStore，key = "moyu.prompts.custom.v1"）
// PromptTemplate 的属性全是 let（值语义），要改就用 replacing(...) 生成新值：
var template = BuiltInPrompts.polish.duplicatedAsCustom(newTitle: "我的润色")  // 新 UUID、isBuiltIn = false
template = template.replacing(systemPrompt: "只输出改写后的正文。", temperature: 0.2)
PromptLibrary.upsertCustom(template)

// 删
PromptLibrary.removeCustom(id: template.id)
```

> `saveCustom(_:)` 会**过滤掉 isBuiltIn 的模板**，只持久化自定义的；
> 想从内置模板派生，用 `duplicatedAsCustom(newTitle:)`（会换新 UUID 并置 `isBuiltIn = false`）。

### C.2 渲染自定义模板

```swift
let request = PromptLibrary.makeRequest(
    template,
    text: "这个方案我觉得还行",
    tone: "正式",
    targetLanguage: "英文",
    replyCount: 3
)
// 等价于手写：
// ChatRequest(messages: template.renderMessages(text:context:tone:targetLanguage:replyCount:),
//             temperature: template.temperature, maxTokens: nil, stream: true)
```

支持 4 个占位符：`{{text}}` / `{{context}}` / `{{tone}}` / `{{target_language}}`
（外加 `{{reply_count}}`）；未提供的占位符会被兜底值替换（空 text → "请继续。"，
空 tone → "自然"，空语言 → "英文"），**不会留下 `{{...}}` 原文**。

### C.3 配置导出 / 导入（跨设备搬运）

免费 Apple ID 没有 App Group，App 与键盘的数据**各自独立**，所以跨设备/跨目标必须靠剪贴板搬运：

```swift
// 导出（在 App 的设置页）：默认不含 API Key
do {
    try PasteboardBridge.export(snapshot, includeAPIKeys: false)
    // 已写入命名剪贴板 UIPasteboard.Name("com.moyu.config")
} catch {
    let aiError = AIError.wrap(error)
    // aiError.errorDescription / recoverySuggestion 展示给用户
}

// 导入（在键盘的 ⚙️ 页）：读取并校验（magic / 版本 / FNV-1a 校验和）
if let imported = PasteboardBridge.importSnapshot() {
    var next = imported
    next.version = ConfigSnapshot.currentVersion
    ConfigStore().save(next)
}
```

> 四行载荷格式：`MOYU_CONFIG_V1` / `envelope:<v> snapshot:<v>` / `fnv1a64:<16hex>` / JSON。
> `includeAPIKeys: true` 时 API Key 会**明文**进剪贴板（不加密），UI 必须二次确认；
> 导入后用 `ExportPayload.applyAPIKeys()` 批量写回 Keychain。

### C.4 主题：只用 Theme 的公开常量

```swift
import SwiftUI

struct ResultCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.fontResult)
            .foregroundColor(Theme.textPrimary)
            .padding(Theme.Spacing.md)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .shadow(
                color: Theme.keyShadow,
                radius: Theme.Shadow.card.blur,
                x: 0,
                y: Theme.Shadow.card.y
            )
            .animation(Theme.Motion.spring, value: text)
    }
}
```

**规则**：禁止在 UI 文件里写 `Color(hex:)` 裸色值或魔法数字；
深色模式**自动跟随**（`Theme` 的颜色都是 `UIColor { traits in }` 动态色），
不要写 `@Environment(\.colorScheme)` 分支。

---

## D. 常见问题（UI 接入时最容易踩的 8 个坑）

| 现象 | 原因 | 正确做法 |
| --- | --- | --- |
| 键盘里点 AI 没反应 | 键盘未开「允许完全访问」，扩展无法联网 | catch `.network` 时展示 `recoverySuggestion`，它会提示去开启完全访问 |
| 流一直不结束 | 没有处理 `isFinal` 就 `await` 了整条流；或 Task 未被 cancel | 循环里判断 `delta.isFinal` 就 `break`；页面消失/键盘收起时 `task.cancel()` |
| 取消后仍收到 delta | 只 cancel 了外层 `Task`，没等流终止 | 我们的客户端已在 `onTermination` 里取消 URLSession task，等 `for try await` 循环退出即可 |
| 报 `.unauthorized` | API Key 复制不完整 / 已失效 | 展示 `recoverySuggestion`，引导去设置页重填 |
| 报 `.server(code: 404)` | baseURL 写错（少了 `/v1`）或模型名不对 | 提示检查 baseURL（一般以 `/v1` 结尾）与模型名 |
| 生图返回 413 | 单图超过 4MB 上限 | 提示换更小的尺寸或换服务商 |
| 回复建议解析出空行 / 带序号 | 没按行切分或没去前缀 | 用 §A.4 的 `parseReplies(_:)` |
| 配置导入失败 | 剪贴板内容被覆盖 / 校验和不匹配 | `PasteboardBridge.importSnapshot()` 返回 nil 时提示「剪贴板里没有可导入的墨语配置」 |

---

## E. 快速索引：Shared 层对外 API 一览

| 需求 | 调用 | 文件 |
| --- | --- | --- |
| 读配置 | `ConfigStore().load()` | `ios/Shared/Storage/ConfigStore.swift` |
| 存配置 | `ConfigStore().save(snapshot)` | 同上 |
| 取/存 API Key | `KeychainStore.shared.apiKey(for:)` / `setAPIKey(_:for:)` | `ios/Shared/Storage/KeychainStore.swift` |
| 跨目标共享数据 | `SharedStore.shared.string/set/data/setData` | `ios/Shared/Storage/SharedStore.swift` |
| 导出/导入配置 | `PasteboardBridge.export/importSnapshot` | `ios/Shared/Storage/PasteboardBridge.swift` |
| 建文本客户端 | `AIClientFactory.makeLLM(config:apiKey:)` | `ios/Shared/Networking/AIClientFactory.swift` |
| 建生图客户端 | `AIClientFactory.makeImage(config:apiKey:)` | 同上 |
| 流式对话 | `client.stream(request)` | `ios/Shared/Networking/LLMClient.swift` |
| 一次性对话 | `client.complete(request)` | 同上 |
| 渲染提示词 | `PromptLibrary.render / makeRequest` | `ios/Shared/Prompts/PromptLibrary.swift` |
| 内置模板 | `BuiltInPrompts.all` / `templates(for:)` | `ios/Shared/Prompts/BuiltInPrompts.swift` |
| 颜色/字体/间距 | `Theme.*` | `ios/Shared/Theme/Theme.swift` |
| 预设服务商 | `PresetProviders.chatPresets()` / `imagePresets()` | `ios/Shared/Models/PresetProviders.swift` |
| 错误文案 | `AIError.errorDescription` / `recoverySuggestion` | `ios/Shared/Networking/AIError.swift` |
