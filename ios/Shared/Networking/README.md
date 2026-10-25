# ios/Shared/Networking — 网络层说明

> 模块职责：把「服务商配置 + API Key」变成可用的 `LLMClient` / `ImageGenerating`，
> 覆盖 4 类协议（OpenAI 兼容 / Anthropic / Gemini / 生图三路由）。
> 使用方：`ios/AIKeyboard/`（设置页连通性测试、生图预览）、`ios/AIKeyboardExtension/`（键盘内 AI 调用）。
> 依赖：**纯 Foundation**（`URLSession` + `AsyncThrowingStream`，iOS 16 可用）。
> 全目录**不出现** `import UIKit` / `import SwiftUI`，扩展 target 可直接编译。

---

## 1. 协议与工厂

```swift
public protocol LLMClient: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatDelta, Error>
    func complete(_ request: ChatRequest) async throws -> ChatResult
}

public protocol ImageGenerating: Sendable {
    func generate(_ request: ImageRequest) async throws -> [GeneratedImage]
}

public enum AIClientFactory {
    public static func makeLLM(config: AIProviderConfig, apiKey: String) -> LLMClient
    public static func makeImage(config: AIProviderConfig, apiKey: String) -> ImageGenerating
}
```

`makeLLM` 按 `config.kind` 分派：

| `ProviderKind` | 实现类 | 说明 |
| --- | --- | --- |
| `.openAICompatible` | `OpenAICompatibleClient` | DeepSeek / 通义千问兼容模式 / Kimi / 智谱 / 火山方舟 / OpenRouter / 硅基流动 / OpenAI |
| `.anthropic` | `AnthropicClient` | Claude 官方 Messages API |
| `.gemini` | `GeminiClient` | 实验性，`generateContent` / `streamGenerateContent` |
| `.custom` | `OpenAICompatibleClient` | 生图预设也是 `.custom`，但 `makeLLM` 不会被用于它们（见 §5） |

`makeImage` 交给 `ImageClientRouter` 二次路由，**签名与 `docs/02` §4.2 完全一致**，
生图与文本对话可以使用不同的 Provider（`ConfigSnapshot.imageProviderID`）。

---

## 2. URL 路径总表

`resolvedURL(path:)` 的拼接规则（保守，不做域名猜测）：

- base 末段是版本段（`v1` / `v2` / `v3` / `v4` / `v1beta` / `v1alpha` / `v1beta1`）→ **直接拼 path**；
- base 不带版本段 → **中间补 `/v1`**。

| 客户端 | 方法与完整路径 | 关键 Header |
| --- | --- | --- |
| `OpenAICompatibleClient` | `POST {base}/chat/completions` | `Authorization: Bearer <key>`、`Content-Type: application/json` |
| `AnthropicClient` | `POST {base}/v1/messages` | `x-api-key: <key>`、`anthropic-version: 2023-06-01`、`content-type: application/json` |
| `GeminiClient` | `POST {base}/v1beta/models/{model}:streamGenerateContent?alt=sse&key=<key>`（流式）<br>`POST {base}/v1beta/models/{model}:generateContent?key=<key>`（非流式） | 无鉴权头（key 在 query） |
| `OpenAICompatibleImageClient` | `POST {base}/images/generations` | `Authorization: Bearer <key>` |
| `SeedreamImageClient` | `POST {base}/images/generations`（`base` = `https://ark.cn-beijing.volces.com/api/v3`） | `Authorization: Bearer <ARK_API_KEY>` |
| `WanxImageClient`（创建） | `POST {base}/api/v1/services/aigc/text2image/image-synthesis`（`base` = `https://dashscope.aliyuncs.com`） | `Authorization: Bearer <DASHSCOPE_API_KEY>`、`X-DashScope-Async: enable` |
| `WanxImageClient`（轮询） | `GET {base}/api/v1/tasks/{task_id}` | 同上但不带 `X-DashScope-Async` |

各预设拼出来的实际 URL：

| 预设 id | LLM URL | 生图 URL |
| --- | --- | --- |
| `preset-deepseek` | `https://api.deepseek.com/v1/chat/completions` | — |
| `preset-qwen` | `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions` | — |
| `preset-kimi` | `https://api.moonshot.cn/v1/chat/completions` | — |
| `preset-glm` | `https://open.bigmodel.cn/api/paas/v4/chat/completions` | — |
| `preset-ark` | `https://ark.cn-beijing.volces.com/api/v3/chat/completions` | 同 base + `/images/generations` |
| `preset-openrouter` | `https://openrouter.ai/api/v1/chat/completions` | — |
| `preset-siliconflow` | `https://api.siliconflow.cn/v1/chat/completions` | — |
| `preset-openai` | `https://api.openai.com/v1/chat/completions` | `https://api.openai.com/v1/images/generations` |
| `preset-anthropic` | `https://api.anthropic.com/v1/messages` | — |
| `preset-seedream` | —（仅生图） | `https://ark.cn-beijing.volces.com/api/v3/images/generations` |
| `preset-wanx` | —（仅生图） | `https://dashscope.aliyuncs.com/api/v1/services/aigc/text2image/image-synthesis` |

---

## 3. 请求 / 响应示例

### 3.1 OpenAI 兼容（`POST {base}/chat/completions`，`stream: true`）

请求：

```json
{
  "model": "deepseek-chat",
  "messages": [
    {"role": "system", "content": "你是聊天输入法内的改写助手……"},
    {"role": "user", "content": "帮我改得更礼貌一点"}
  ],
  "temperature": 0.3,
  "max_tokens": 1024,
  "stream": true
}
```

> **注意：不要加 `stream_options`。**
> 它是 OpenAI 专有参数，大量「OpenAI 兼容」端点不认识：DeepSeek 部分版本、通义
> compatible-mode、Kimi、智谱 GLM、硅基流动、部分 OpenRouter 模型都会直接返回
> `400 Unrecognized request argument supplied: stream_options`。
> 流式侧的 usage 本来也不参与展示（只有 `complete()` 的非流式响应会解析 usage），
> 去掉它对功能零损失，换来的是对所有兼容端点可用。
>
> 流式请求的 `Accept` 头会由 `HTTPTransport.makeJSONRequest(accept:)` 设成
> `text/event-stream`，非流式仍是 `application/json`。
>
> **推理模型的 `max_tokens` 会自动兜底到 4096。** 当 `request.maxTokens` 为 `nil`
> （调用方不指定）且模型名命中推理模型特征（`reasoner` / `-r1` / `o1` / `o3` / `qwq` /
> `thinking` / 以 `-r` 结尾）时，实际发出的是 `max(config.maxTokens, 4096)` —— 思维链会
> 先吃掉 token 预算，预算不够时正文一个字都吐不出来。调用方**显式**给了 `maxTokens`
> 时一律尊重（探活探针只发 `"hi"`，要的就是小预算快返回）。

响应（SSE，每个 `data:` 一行一个 JSON）：

```
data: {"id":"1","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"1","choices":[{"index":0,"delta":{"content":"好的"},"finish_reason":null}]}

data: {"id":"1","choices":[{"index":0,"delta":{"content":"，马上处理。"},"finish_reason":"stop"}]}

data: {"id":"1","choices":[],"usage":{"prompt_tokens":38,"completion_tokens":9,"total_tokens":47}}

data: [DONE]
```

非流式（`complete(_:)`）响应：

```json
{
  "id": "chatcmpl-1",
  "choices": [{"index": 0, "message": {"role": "assistant", "content": "好的，马上处理。"}, "finish_reason": "stop"}],
  "usage": {"prompt_tokens": 38, "completion_tokens": 9, "total_tokens": 47}
}
```

错误体（401 / 429 / 5xx 都走这段解析）：

```json
{"error": {"message": "Incorrect API key provided", "type": "invalid_request_error", "code": "invalid_api_key"}}
```

`HTTPTransport.extractErrorMessage(from:)` 依次尝试 `error.message` → `error`（字符串）→
`message` / `msg` / `detail` / `error_msg` → 数组首项，最后回退到截断 200 字的纯文本。

### 3.2 Anthropic（`POST {base}/v1/messages`）

请求：

```json
{
  "model": "claude-3-5-sonnet-latest",
  "max_tokens": 1024,
  "temperature": 0.3,
  "stream": true,
  "system": "你是聊天输入法内的改写助手……",
  "messages": [{"role": "user", "content": "帮我改得更礼貌一点"}]
}
```

响应（SSE，事件名在 `event:` 行）：

```
event: message_start
data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":38,"output_tokens":1}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"好的"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"，马上处理。"}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}

event: message_stop
data: {"type":"message_stop"}
```

- 只取 `content_block_delta.delta.text`；
- `message_stop` → yield `ChatDelta(text: "", isFinal: true)` 并结束；
- `event: error` → 抛 `AIError.server(code: 200, message: "<error.message>")`；
- `messages` 只保留 `user` / `assistant`（system 走顶层 `system` 字段），为空时补 `"请继续。"`。

### 3.3 Gemini（实验性）

请求：

```json
{
  "contents": [
    {"role": "user", "parts": [{"text": "帮我改得更礼貌一点"}]}
  ],
  "generationConfig": {"temperature": 0.3, "maxOutputTokens": 1024},
  "systemInstruction": {"parts": [{"text": "你是聊天输入法内的改写助手……"}]}
}
```

响应（`alt=sse` 时同样是 SSE）：

```
data: {"candidates":[{"content":{"parts":[{"text":"好的"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":38,"candidatesTokenCount":9,"totalTokenCount":47}}
```

- 逐片拼接 `candidates[0].content.parts[].text`；
- `promptFeedback.blockReason` 非空 → `AIError.contentRejected(reason)`；
- 结构完全无法识别 → `AIError.decoding("Gemini 返回结构无法识别，请把协议类型改为「OpenAI 兼容」或换用其它服务商")`。

### 3.4 即梦 / 火山方舟（`POST {base}/images/generations`）

请求：

```json
{
  "model": "doubao-seedream-3-0-t2i-250415",
  "prompt": "a calico cat sitting on a wooden desk, warm afternoon light",
  "size": "1024x1024",
  "response_format": "url",
  "watermark": false
}
```

响应：

```json
{
  "model": "doubao-seedream-3-0-t2i-250415",
  "created": 1730000000,
  "data": [{"url": "https://ark-content.volces.com/xxx.png", "size": "1024x1024"}],
  "usage": {"generated_images": 1}
}
```

- 尺寸白名单：`1024x1024` / `864x1152` / `1152x864` / `1280x720` / `720x1280`（其它值自动回退 `1024x1024`）；
- 拿到 `url` 后**立即下载**为 `Data`（≤ 4 MB，超出抛 `AIError.server(code: 413, …)`），同时把 `url` 留在 `GeneratedImage.remoteURL`；
- URL 有效期约 24 小时。

### 3.5 通义万相（DashScope 异步任务）

**创建任务** `POST {base}/api/v1/services/aigc/text2image/image-synthesis`：

```json
{
  "model": "wanx2.1-t2i-turbo",
  "input": {"prompt": "一只橘猫趴在木质书桌上，午后暖光"},
  "parameters": {"size": "1024*1024", "n": 1}
}
```

```json
{"output": {"task_id": "86ecf553-1c3f-4dbb-9a37-xxxx", "task_status": "PENDING"}, "request_id": "xxxx"}
```

**轮询** `GET {base}/api/v1/tasks/{task_id}`：

```json
{"output": {"task_status": "RUNNING"}}
{"output": {"task_status": "SUCCEEDED", "results": [{"url": "https://dashscope-result.oss-cn-beijing.aliyuncs.com/xxx.png"}]}}
{"output": {"task_status": "FAILED", "message": "DataInspectionFailed: 输入内容可能不符合规范"}}
```

- 尺寸用**星号**分隔（`1024*1024`），`ImageRequest.size` 里的 `x` / `X` / `×` 会自动转成 `*`；
- 轮询间隔从 1.5s 起每次 ×1.5，封顶 3s；总超时 90s 抛 `AIError.timeout`；
- `Task.isCancelled` 时立即停止轮询并抛 `AIError.cancelled`。

### 3.6 OpenAI 兼容生图（`POST {base}/images/generations`）

```json
{"model": "gpt-image-1", "prompt": "...", "n": 1, "size": "1024x1024", "quality": "standard", "response_format": "b64_json"}
```

- 响应兼容两种形态：`data[].b64_json`（直接解码）或 `data[].url`（下载，同 4 MB 限制）；
- `gpt-image-1` 不接受 `response_format`：`modelRejectsResponseFormat(_:)` 命中 `gpt-image` 前缀时**直接不发送**该字段；
  其它服务商若返回 400 且消息含 `unknown` / `unrecognized` / `response_format` / `extra fields` / `unsupported`，
  自动**去字段重试一次**；
- 仅幂等重试 ≤ 2 次，指数退避 1s / 2s。

---

## 4. SSE 解析（`SSEParser`）

```swift
public struct SSEEvent: Equatable, Sendable {
    public let event: String?      // event: 字段
    public let data: String        // 多行 data: 用 "\n" 拼接
    public let id: String?
    public let retry: Int?
    public var isDone: Bool        // data == "[DONE]"
    public var isJSONPayload: Bool
}

public struct SSEParser {
    public mutating func feed(_ data: Data) -> [SSEEvent]   // 增量喂入，返回本次凑齐的事件
    public mutating func flush() -> [SSEEvent]              // 流结束时冲刷缓冲区
    public mutating func reset()
}
```

### 样例字节流（含跨 chunk 半行）

假设网络一次只给 40 字节，真实字节流会被切成多段。`feed` 会自己缓存半行：

```
chunk 1:  "data: {\"choices\":[{\"delta\":{\"cont"
chunk 2:  "ent\":\"好\"}}]}\n\n"
```

- chunk 1 结束时没有换行 → `feed` 返回 `[]`，内部 `buffer` 留半行；
- chunk 2 补上 `\n\n` → 返回 1 个事件，`data == {"choices":[{"delta":{"content":"好"}}]}`。

兼容的边界情况：

| 情况 | 处理 |
| --- | --- |
| `\r\n` 换行（部分网关用 CRLF） | 识别为行尾，事件正常派发 |
| 跨 chunk 半行 | 留在 `buffer`，等下一段 `feed` |
| 孤立 `\r`（老式 Mac 换行） | 当作行尾；若 `\r` 正好在 chunk 末尾，保守等下一段再判断 |
| `:` 开头的注释行（如 `: keep-alive`） | 忽略 |
| 多个 `data:` 行属于同一事件 | 用 `\n` 拼接（符合 SSE 规范） |
| `data: [DONE]` | `event.isDone == true` |
| 未知字段（`retry:` / `id:` 之外的） | 忽略 |
| 冒号后只允许去一个空格 | `data:  x` → `" x"`（保留用户内容里的空格） |

实现细节：`OpenAICompatibleClient` 用 `URLSession.bytes(for:)` + `for try await line in bytes.lines`
逐行拿到文本，再拼回 `"\n"` 喂给 `SSEParser`；由于 `bytes.lines` 已按 `\n` 切好，
这里主要受益于统一的 `[DONE]` / 多行 data / 注释处理逻辑。若将来换成裸 `Data` 分片，
`SSEParser` 的跨 chunk 能力可以直接复用。

---

## 5. 设计决策

### 5.1 不新增 `ProviderKind.seedream` / `.wanx` 枚举值

**决策**：两个生图预设（即梦 / 通义万相）的 `AIProviderConfig.kind` 保持为 `.custom`，
由 `ImageClientRouter` 在运行时按 `baseURL` + `model` 路由到 `SeedreamImageClient` /
`WanxImageClient`，**不在 `ProviderKind` 里加新 case**。

**理由**：

1. **不破坏其它 agent 的穷尽 switch**。`ProviderKind` 已在 `docs/02` §4.1 冻结为 4 个 case；
   宿主 App 与键盘里有多处 `switch provider.kind`（图标、协议说明、连通性测试分支）。
   本机没有 Xcode、无法编译，新增 case 会让所有穷尽 switch 立刻编译失败，
   而且失败点分散在别人的文件里、无法自测——风险远大于收益。
2. **路由信息本来就够用**。`AIProviderConfig` 已有 `baseURL` + `model` + `imageModel` 三个字段，
   `ark.cn-beijing.volces.com` / `dashscope.aliyuncs.com` / `seedream` / `wanx` 都能唯一识别，
   Router 的路由表是纯函数、可单测，比枚举更适合「服务商持续增加」的场景。
3. **`kind` 的语义是「文本协议族」**，不是「服务商」。即梦与万相都不是标准 OpenAI 兼容
   （万相是异步任务、即梦要下载 url），把它们塞进 `.openAICompatible` 会误导「协议类型」下拉框。
   保持 `.custom` + Router 既准确又不影响 LLM 侧分派。

**误用防护**（`docs/02` 之外的补充，供 UI 使用）：

```swift
AIProviderConfig.supportsChat          // 能否用于文本对话
AIProviderConfig.supportsImage         // 能否用于生图
AIProviderConfig.unsupportedChatReason // 不能对话时的中文原因
PresetProviders.isImageOnly(id:)       // preset-seedream / preset-wanx → true
```

生图预设的 `model` 是空串、只有 `imageModel`，`supportsChat` 因此为 `false`；
用户在「默认对话服务商」下拉里选中它们时，UI 用 `unsupportedChatReason` 提示
「该服务仅支持生图，不能用于文本对话。请改选 DeepSeek / 通义千问 / Kimi 等对话服务商。」

两个生图预设用**固定 id**（`preset-seedream` / `preset-wanx`）而不是 UUID，
这样 `ConfigSnapshot.imageProviderID` 指向预设时跨设备、跨次启动都稳定；
用户在编辑器里「另存为自定义」时才生成新 UUID。

### 5.2 推理模型的 `reasoning_content`（思维链）

DeepSeek `deepseek-reasoner` / o1 / o3 / QwQ 等推理模型会**先在 `delta.reasoning_content`
里长时间输出思维链，之后才开始输出 `content`**。本客户端的处理：

- **始终**解析 `reasoning_content`，通过 `ChatDelta.reasoning` 单独交给上层；
  **不**拼进 `ChatDelta.text`（否则打字机会把「让我想想……」这种内心独白当答案打在输入框里）；
- 推理模型的 `max_tokens` 兜底 4096（见 §3.1 的说明），避免预算被思维链吃光、正文为空；
- 正文为空时按优先级抛 `AIError.contentRejected`：
  1. `finish_reason == "length"` → 「输出被「最大回复长度」截断了……」；
  2. 只收到过思维链 → 「这是推理模型，本次回复全部用在思维链上了……」；
  3. 两者都不是 → 保持原来的「服务商没有返回内容」（不抛错，由 UI 文案兜底）。

UI 侧建议：`ChatDelta.reasoning` 只用于「思考中…」这类状态提示，不要把它当正文展示。

### 5.3 取消传播

`stream(_:)` 返回的 `AsyncThrowingStream` 在 `onTermination` 里 `task.cancel()`，
UI 层只要不持有 stream（如用户关掉结果卡片），底层 `URLSession.bytes` 立刻断开；
`complete(_:)` / `generate(_:)` 直接响应 `Task` 取消，不吞 `CancellationError`。

### 5.4 为什么没有实现自动重试（LLM 侧）

对话请求**不是幂等的**：重试会导致同一段文字被生成两次、或重复计费。
LLM 侧只在 UI 层由用户手动「重试」；只有生图（幂等、单次成本明确）做 ≤2 次指数退避。

---

## 6. UI 侧典型调用（5–10 行）

```swift
// 1) 从配置拿到默认对话 Provider 与 Keychain 里的 Key
let snapshot = configStore.load()
guard let provider = snapshot.defaultProvider else { throw AIError.notConfigured }
let apiKey = KeychainStore.shared.apiKey(for: provider.id) ?? ""

// 2) 造客户端（生图同理：AIClientFactory.makeImage(config: provider, apiKey: apiKey)）
let client = AIClientFactory.makeLLM(config: provider, apiKey: apiKey)

// 3) 用内置模板渲染消息（replyCount 只对「回复建议」生效）
let messages = PromptLibrary.render(
    feature: .polish, text: selectedText, tone: snapshot.defaultTone,
    targetLanguage: "英文", replyCount: snapshot.replyCount
)
let request = ChatRequest(messages: messages, temperature: nil, maxTokens: nil, stream: true)

// 4) 流式消费
for try await delta in client.stream(request) {
    if delta.isFinal { break }
    buffer += delta.text        // 追加到结果卡片
}
```

错误展示统一走 `AIError`：

```swift
catch let error as AIError {
    toast(error.errorDescription ?? "请求失败")
    detailLabel.text = error.recoverySuggestion ?? ""
}
```
