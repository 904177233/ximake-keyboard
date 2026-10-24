# ios/Shared/Prompts —— Prompt 模板与渲染

> 模块职责：定义墨语「聊天场景」的全部 AI 提示词（内置 + 用户自定义），并把模板渲染成
> `[ChatMessage]` 供 `LLMClient.stream(_:)` 直接使用。
> 依赖：`Foundation` + `ios/Shared/Models/`（`ChatMessage` / `ChatRequest` / `AIFeature`）+ `ios/Shared/Storage/SharedStore`（只用于自定义模板持久化）。
> 使用方：`ios/AIKeyboard`（Prompt 库、AI 试验场）、`ios/AIKeyboardExtension`（AI 工具条）。

## 1. 文件

| 文件 | 内容 |
| --- | --- |
| `PromptTemplate.swift` | 模板数据结构 + 占位符渲染（`{{text}}` `{{context}}` `{{tone}}` `{{target_language}}` `{{reply_count}}`） |
| `BuiltInPrompts.swift` | 14 条内置模板 + 共用系统提示词片段 + 目标语言清单 |
| `PromptLibrary.swift` | 查询 / 渲染 / 请求构造 / 自定义模板增删改查 |

## 2. 内置模板（14 条）

| 静态常量 | `id` | 标题 | SF Symbol | `feature` | 温度 |
| --- | --- | --- | --- | --- | --- |
| `polish` | `builtin.polish` | 润色 | `wand.and.stars` | `.polish` | 0.3 |
| `polite` | `builtin.polite` | 更礼貌 | `hand.raised` | `.polish` | 0.3 |
| `shorter` | `builtin.shorter` | 更简短 | `arrow.down.right.and.arrow.up.left` | `.polish` | 0.3 |
| `formal` | `builtin.formal` | 更正式 | `briefcase` | `.polish` | 0.3 |
| `casual` | `builtin.casual` | 更口语 | `bubble.left.and.bubble.right` | `.polish` | 0.4 |
| `toneShift` | `builtin.tone` | 调整语气 | `slider.horizontal.3` | `.polish` | 0.5 |
| `proofread` | `builtin.proofread` | 纠错 | `checkmark.circle` | `.polish` | 0.1 |
| `expand` | `builtin.expand` | 扩写 | `text.append` | `.expand` | 0.5 |
| `translate` | `builtin.translate` | 翻译 | `character.book.closed` | `.translate` | 0.2 |
| `replySuggestion` | `builtin.reply` | 回复建议 | `arrowshape.turn.up.left` | `.replySuggestion` | 0.7 |
| `quickReply` | `builtin.reply.quick` | 简短回复 | `bolt` | `.replySuggestion` | 0.7 |
| `imagePrompt` | `builtin.image.prompt` | 生图提示词 | `photo.on.rectangle.angled` | `.image` | 0.6 |
| `stickerCaption` | `builtin.sticker.caption` | 表情包文案 | `face.smiling` | `.image` | 0.9 |
| `custom` | `builtin.custom` | 自定义 | `square.and.pencil` | `.custom` | 0.4 |

- 翻译用一个模板 + `{{target_language}}` 覆盖中→英 / 英→中 / 中→日 / 中→韩：
  `BuiltInPrompts.targetLanguages = ["英文","中文","日文","韩文","法文","德文","西班牙文","俄文"]`。
- `AIFeature.defaultTemplateID` 与上表 id 一一对应（`.polish → builtin.polish`、`.image → builtin.image.prompt` …）。

## 3. 系统提示词的硬约束

所有改写类模板共用 `BuiltInPrompts.baseRewriteSystemPrompt`，逐条声明：

1. 你是「墨语」聊天输入法内的改写助手，不是聊天机器人；
2. 只输出可以直接发送的正文，不要解释、不要 Markdown、不要引号、不要前缀；
3. 保持原语言（原文是外语就用该语言输出）；
4. 不编造原文没有的事实（时间、地点、金额、承诺）；
5. 长度不超过原文 1.5 倍且不超过 200 字；
6. 单段输出，不换行、不加列表符号；
7. 原文为空或只有标点时，原样返回。

## 4. 「回复建议」输出格式（UI 契约，不可改）

`BuiltInPrompts.baseReplySystemPrompt` 把格式**定死**，UI 按行切分即可：

```
1. 好呀，那就这么定了
2. 我这边时间有点紧，晚点再约？
3. 具体几点？我看看能不能赶上
```

规则：

- **恰好 `{{reply_count}}` 条**，不多不少；
- **每条占一行**，行首依次是 `1.` `2.` `3.`（数字 + 英文句点 + 一个空格）；
- 每条 ≤ 30 字，口语化，立场/语气要有区分度；
- 不要解释、不要 Markdown、不要引号、行首之外不加任何文字。

UI 侧解析建议：`output.split(separator: "\n")` 后对每行用正则 `^\d+\.\s*` 去前缀，
再 `trimmingCharacters(in: .whitespaces)`；空行与非数字开头的行直接丢弃。

> 条数由 `PromptLibrary.render(..., replyCount:)` 注入，`PromptTemplate.placeholderValues`
> 会把 `replyCount` clamp 到 `1...5`，**任何模板里都不允许硬编码 3**。

## 5. 渲染 API

```swift
// 按能力用默认模板
let messages = PromptLibrary.render(
    feature: .polish, text: draft, tone: "自然", targetLanguage: "英文", replyCount: 3
)

// 指定模板 id（找不到回退到该能力的默认模板）
let messages = PromptLibrary.render(
    feature: .replySuggestion, templateID: "builtin.reply",
    text: lastMessage, context: history, tone: "轻松", replyCount: 3
)

// 直接渲染指定模板（可覆盖温度）
let messages = PromptLibrary.render(
    template, text: draft, context: "", tone: "自然", targetLanguage: "英文",
    replyCount: 3, temperature: 0.2
)

// 一步得到可直接喂给 LLMClient 的请求（自动带模板温度与 maxTokens）
let request = PromptLibrary.makeRequest(template, text: draft, tone: "自然")
for try await delta in client.stream(request) { /* 追加 delta.text */ }
```

## 6. 生图提示词增强（中文 → 英文 prompt）

```swift
let enhance = PromptLibrary.imagePromptEnhanceRequest("一只戴墨镜的柴犬在沙滩上")
let prompt = try await client.complete(enhance).text      // 只拿到英文 prompt
let images = try await imageClient.generate(ImageRequest(prompt: prompt, size: "1024x1024"))
```

- `imagePromptEnhanceRequest` 返回非流式请求（`stream: false`、`temperature 0.6`、`maxTokens 400`），
  聊天侧想逐步显示打字机效果时用 `imagePromptEnhanceStreamRequest`。
- 增强模板只输出英文关键词串（60~180 词），不含解释、不含负向提示词。

## 7. 自定义模板持久化

| API | 说明 |
| --- | --- |
| `PromptLibrary.loadCustom() -> [PromptTemplate]` | 读 `SharedStore`（key `moyu.prompts.custom.v1`），解码失败返回 `[]`，永不抛错 |
| `PromptLibrary.saveCustom(_:)` | 整体覆盖保存，自动过滤 `isBuiltIn == true` 的模板 |
| `PromptLibrary.upsertCustom(_:)` | 按 id 覆盖或追加，强制 `isBuiltIn = false` |
| `PromptLibrary.removeCustom(id:)` | 按 id 删除 |
| `PromptLibrary.duplicateAsCustom(_:newTitle:)` | 内置模板「另存为自定义」，生成新 UUID |
| `PromptTemplate.duplicatedAsCustom(newTitle:)` | 同上，纯结构层方法 |

`PromptLibrary.templates(feature:)` = 该能力的内置模板 + 该能力的自定义模板；`template(id:)` 先查内置再查自定义。

## 8. 环境说明

- 与 `TargetLanguageOption.code`（`"英语"/"中文"/"日语"/"韩语"`）是两套命名：UI 直接把用户选择的值
  传给 `targetLanguage`，模板只做占位符替换，不做枚举映射，因此两套并存不冲突。
- 模板里的多行字符串使用 Swift `"""` 语法，缩进由 Swift 自动去除公共前导空白；修改时保持 4 空格缩进。
