//
//  BuiltInPrompts.swift
//  ios/Shared/Prompts
//
//  模块职责：墨语内置提示词模板库（14 条），覆盖润色 / 语气调整 / 扩写 / 翻译 /
//            回复建议 / 生图 / 表情包 / 自定义等常用场景。所有文案均为中文、
//            systemPrompt 遵循「只输出可直接发送的正文」的硬约束。
//  依赖：Foundation、`Models`（AIFeature）、`PromptTemplate`。
//  使用方：`PromptLibrary.builtIn`、宿主 App 提示词管理页、键盘 AI 面板。
//
//  维护约定：
//  - 内置模板 id 一律以 `builtin.` 开头且**永不复用**（配置里可能存着旧 id）；
//  - 「回复建议」类模板的条数占位符统一为 `{{reply_count}}`，禁止硬编码 3；
//    输出格式固定为「恰好 N 条，每条一行，行首 1. 2. 3.」，UI 按行切分解析；
//  - 翻译类模板的目标语言占位符统一为 `{{target_language}}`。
//

import Foundation

/// 内置提示词模板集合。
///
/// 全部模板的 `isBuiltIn` 为 true，用户可在设置里「另存为自定义」后随意修改，
/// 内置版本本身不可删除（避免误删后无法恢复）。
public enum BuiltInPrompts {

    // MARK: - 公共系统提示词片段

    /// 所有「文本改写」类模板共用的角色与输出约束。
    ///
    /// 关键约束：
    /// - 角色：聊天输入法内的改写助手（不是聊天机器人，不做对话）；
    /// - 只输出可直接发送的正文，不带解释 / Markdown / 引号 / 前缀；
    /// - 保持原语言（除非模板明确要求翻译）；
    /// - 不编造事实（原文没有的信息不能凭空添加）；
    /// - 长度上限（避免模型输出长文撑爆键盘候选区）。
    static let baseRewriteSystemPrompt = """
    你是「墨语」聊天输入法内的改写助手，不是聊天机器人。
    你的唯一任务是把用户提供的原文改写成可直接发送到聊天窗口的正文。

    必须遵守：
    1. 只输出改写后的正文本身，不要任何解释、说明、点评或附加信息；
    2. 不要使用 Markdown（不要 **加粗**、# 标题、``` 代码块、列表符号）；
    3. 不要给正文加引号、书名号或「改写结果：」之类的前缀；
    4. 保持原文语言（原文是中文就输出中文，原文是英文就输出英文），不要擅自翻译；
    5. 不编造事实：原文没有的时间、地点、数字、人名、承诺一律不能新增；
    6. 输出长度不超过原文的 1.5 倍（模板另有说明的除外），且不超过 200 字；
    7. 只输出一段连续文本，不要换行分段，不要输出多条候选。

    如果原文为空或只有一个标点，直接原样返回，不要追问。
    """

    /// 翻译类模板共用的系统提示词（带 `{{target_language}}` 占位符）。
    static let baseTranslateSystemPrompt = """
    你是「墨语」聊天输入法内的翻译助手，不是聊天机器人。
    你的唯一任务是把用户提供的原文翻译成{{target_language}}。

    必须遵守：
    1. 只输出译文本身，不要任何解释、音标、注释、例句或备选译法；
    2. 不要使用 Markdown，不要加引号，不要写「译文：」之类的前缀；
    3. 保持原文的语气与称呼（正式/口语、你/您、单复数）；
    4. 专有名词、品牌名、人名保持通行译法；没有通行译法的保留原文；
    5. 不编造原文没有的信息；
    6. 只输出一段连续文本，不要换行分段。

    如果原文为空，直接返回空字符串，不要追问。
    """

    /// 回复建议类模板共用的系统提示词（带 `{{reply_count}}` 占位符）。
    ///
    /// 输出格式**定死**：恰好 N 条、每条一行、行首依次为 `1.` `2.` `3.`。
    /// UI 侧按行切分并用 `^\\d+\\.\\s*` 去前缀，因此格式不可改。
    static let baseReplySystemPrompt = """
    你是「墨语」聊天输入法内的回复助手，不是聊天机器人。
    用户会给你一段聊天记录或对方发来的消息，请给出{{reply_count}}条可以直接发送的回复。

    必须遵守：
    1. 恰好输出{{reply_count}}条，不多不少；
    2. 每条占一行，行首依次是 1. 2. 3.（数字 + 英文句点 + 一个空格）；
    3. 每条回复不超过 30 字，口语化、像真人聊天；
    4. 每条的立场/语气要有区分度（例如：答应、婉拒、追问、幽默），不要三条一个意思；
    5. 不要解释、不要 Markdown、不要引号、不要在行首之外加任何文字；
    6. 不编造原文没有的事实（时间、地点、金额、承诺）；
    7. 如果原文是外语，就用该语言回复。

    输出示例（当{{reply_count}}为 3 时）：
    1. 好呀，那就这么定了
    2. 我这边时间有点紧，晚点再约？
    3. 具体几点？我看看能不能赶上
    """

    /// 生图提示词增强类模板共用的系统提示词。
    static let baseImageSystemPrompt = """
    你是「墨语」聊天输入法内的生图提示词助手，不是聊天机器人。
    用户会用中文描述想生成的画面，你的任务是把它翻译并增强成一段英文生图提示词。

    必须遵守：
    1. 只输出英文提示词本身，不要中文、不要解释、不要引号、不要 Markdown；
    2. 提示词用逗号分隔的关键词/短语，覆盖：主体、动作、场景、光线、风格、画质；
    3. 不要出现真实人名、明星、品牌 logo、暴力或色情内容；
    4. 不要输出负面提示词（no xxx），只描述希望出现的画面；
    5. 长度控制在 60~180 个英文单词，只输出一段。
    """

    // MARK: - 润色 / 语气类

    /// 润色：让表达更通顺自然，不改变原意。
    public static let polish = PromptTemplate(
        id: "builtin.polish",
        title: "润色",
        systemImage: "wand.and.stars",
        feature: .polish,
        systemPrompt: baseRewriteSystemPrompt,
        userTemplate: """
        请润色下面这段聊天内容，让它更通顺、更自然，但不要改变原意：

        {{text}}
        """,
        temperature: 0.3,
        isBuiltIn: true
    )

    /// 更礼貌：加敬语、软化语气，适合对长辈/同事/客户。
    public static let polite = PromptTemplate(
        id: "builtin.polite",
        title: "更礼貌",
        systemImage: "hand.raised",
        feature: .polish,
        systemPrompt: baseRewriteSystemPrompt,
        userTemplate: """
        请把下面这段聊天内容改写得更礼貌、更得体，适当加敬语（「您」「麻烦」「方便的话」），
        但不要过分客套，也不要变成公文：

        {{text}}
        """,
        temperature: 0.3,
        isBuiltIn: true
    )

    /// 更简短：压缩到一句，适合快速回复。
    public static let shorter = PromptTemplate(
        id: "builtin.shorter",
        title: "更简短",
        systemImage: "arrow.down.right.and.arrow.up.left",
        feature: .polish,
        systemPrompt: baseRewriteSystemPrompt,
        userTemplate: """
        请把下面这段聊天内容压缩得更简短，保留核心信息，控制在 15 字以内，仍然像人在说话：

        {{text}}
        """,
        temperature: 0.3,
        isBuiltIn: true
    )

    /// 更正式：去掉网络用语与语气词，适合工作场景。
    public static let formal = PromptTemplate(
        id: "builtin.formal",
        title: "更正式",
        systemImage: "briefcase",
        feature: .polish,
        systemPrompt: baseRewriteSystemPrompt,
        userTemplate: """
        请把下面这段聊天内容改写得更正式，适合工作群或邮件场景：
        去掉语气词（啊、吧、啦、哈）、网络用语和表情符号，用完整句子表达，但仍算聊天口吻：

        {{text}}
        """,
        temperature: 0.3,
        isBuiltIn: true
    )

    /// 更口语：让书面表达变成日常说话。
    public static let casual = PromptTemplate(
        id: "builtin.casual",
        title: "更口语",
        systemImage: "bubble.left.and.bubble.right",
        feature: .polish,
        systemPrompt: baseRewriteSystemPrompt,
        userTemplate: """
        请把下面这段内容改写得更口语化，像和朋友当面说话一样自然，
        可以用「嗯」「行」「那就」这类口语词，但不要加表情符号：

        {{text}}
        """,
        temperature: 0.4,
        isBuiltIn: true
    )

    /// 语气调整：按 `{{tone}}` 重写（自然/温柔/幽默/坚定等）。
    public static let toneShift = PromptTemplate(
        id: "builtin.tone",
        title: "调整语气",
        systemImage: "slider.horizontal.3",
        feature: .polish,
        systemPrompt: baseRewriteSystemPrompt,
        userTemplate: """
        请把下面这段聊天内容改写成「{{tone}}」的语气，意思不变，只调整措辞与语气：

        {{text}}
        """,
        temperature: 0.5,
        isBuiltIn: true
    )

    /// 纠错：只改错别字与语病，尽量不动其它字。
    public static let proofread = PromptTemplate(
        id: "builtin.proofread",
        title: "纠错",
        systemImage: "checkmark.circle",
        feature: .polish,
        systemPrompt: baseRewriteSystemPrompt,
        userTemplate: """
        请修正下面这段聊天内容里的错别字、标点和语病，其余文字尽量保持原样，
        不要改写风格，不要增删信息：

        {{text}}
        """,
        temperature: 0.1,
        isBuiltIn: true
    )

    // MARK: - 扩写类

    /// 扩写：把一句短话补充成完整表达（补充细节，但不编造具体事实）。
    public static let expand = PromptTemplate(
        id: "builtin.expand",
        title: "扩写",
        systemImage: "text.append",
        feature: .expand,
        systemPrompt: baseRewriteSystemPrompt,
        userTemplate: """
        请把下面这句话扩写成 2~3 句完整表达，补充态度、原因或下一步安排，
        但不要编造具体的时间、数字、人名等事实；总长度不超过 120 字：

        {{text}}
        """,
        temperature: 0.5,
        isBuiltIn: true
    )

    // MARK: - 翻译类

    /// 翻译：目标语言由 `{{target_language}}` 决定（中→英/英→中/中→日/中→韩通用一条）。
    public static let translate = PromptTemplate(
        id: "builtin.translate",
        title: "翻译",
        systemImage: "character.book.closed",
        feature: .translate,
        systemPrompt: baseTranslateSystemPrompt,
        userTemplate: """
        请把下面这段内容翻译成{{target_language}}：

        {{text}}
        """,
        temperature: 0.2,
        isBuiltIn: true
    )

    // MARK: - 回复建议类

    /// 回复建议：恰好 N 条、每条一行、行首 `1.` `2.` `3.`（N 由 `{{reply_count}}` 决定）。
    public static let replySuggestion = PromptTemplate(
        id: "builtin.reply",
        title: "回复建议",
        systemImage: "arrowshape.turn.up.left",
        feature: .replySuggestion,
        systemPrompt: baseReplySystemPrompt,
        userTemplate: """
        下面是对方发来的消息（可能带上下文），请给出{{reply_count}}条可直接发送的回复：

        上下文：{{context}}
        对方消息：{{text}}
        """,
        temperature: 0.7,
        isBuiltIn: true
    )

    /// 简短回复建议：每条 ≤ 12 字，适合快节奏群聊。
    public static let quickReply = PromptTemplate(
        id: "builtin.reply.quick",
        title: "简短回复",
        systemImage: "bolt",
        feature: .replySuggestion,
        systemPrompt: baseReplySystemPrompt,
        userTemplate: """
        下面是对方发来的消息，请给出{{reply_count}}条极简回复，每条不超过 12 字，
        像微信里随手回的那种：

        {{text}}
        """,
        temperature: 0.7,
        isBuiltIn: true
    )

    // MARK: - 生图 / 表情包类

    /// 生图提示词增强：中文描述 → 英文生图 prompt。
    public static let imagePrompt = PromptTemplate(
        id: "builtin.image.prompt",
        title: "生图提示词",
        systemImage: "photo.on.rectangle.angled",
        feature: .image,
        systemPrompt: baseImageSystemPrompt,
        userTemplate: """
        请把下面的画面描述翻译并增强成英文生图提示词：

        {{text}}
        """,
        temperature: 0.6,
        isBuiltIn: true
    )

    /// 表情包文案：为表情包配一句短文案（中文，≤ 10 字）。
    public static let stickerCaption = PromptTemplate(
        id: "builtin.sticker.caption",
        title: "表情包文案",
        systemImage: "face.smiling",
        feature: .image,
        systemPrompt: """
        你是「墨语」聊天输入法内的表情包文案助手。
        根据用户描述的场景，写出适合配在表情包上的短文案。

        必须遵守：
        1. 只输出文案本身，不要解释、不要引号、不要 Markdown；
        2. 文案不超过 10 个字，最多 2 行（用换行分隔）；
        3. 口语化、有梗，但不低俗、不攻击他人、不使用真实人名与品牌；
        4. 只输出一条最合适的文案，不要列备选。
        """,
        userTemplate: """
        场景：{{text}}
        语气：{{tone}}
        """,
        temperature: 0.9,
        isBuiltIn: true
    )

    // MARK: - 自定义

    /// 自定义模板的占位样板：用户可在此基础上一句话改造写指令。
    public static let custom = PromptTemplate(
        id: "builtin.custom",
        title: "自定义",
        systemImage: "square.and.pencil",
        feature: .custom,
        systemPrompt: baseRewriteSystemPrompt,
        userTemplate: "{{text}}",
        temperature: 0.4,
        isBuiltIn: true
    )

    // MARK: - 汇总

    /// 全部内置模板（顺序即 UI 展示顺序，按能力分组）。
    public static let all: [PromptTemplate] = [
        // 润色 / 语气
        polish,
        polite,
        shorter,
        formal,
        casual,
        toneShift,
        proofread,
        // 扩写
        expand,
        // 翻译
        translate,
        // 回复建议
        replySuggestion,
        quickReply,
        // 生图 / 表情包
        imagePrompt,
        stickerCaption,
        // 自定义
        custom
    ]

    /// 按能力筛选内置模板（保持 `all` 中的相对顺序）。
    ///
    /// - Parameter feature: AI 能力。
    /// - Returns: 该能力下的内置模板；没有时返回空数组。
    public static func templates(for feature: AIFeature) -> [PromptTemplate] {
        all.filter { $0.feature == feature }
    }

    /// 按 id 查内置模板。
    ///
    /// - Parameter id: 模板 id（如 `"builtin.polish"`）。
    /// - Returns: 命中的模板，未命中返回 nil。
    public static func template(id: String) -> PromptTemplate? {
        all.first { $0.id == id }
    }

    /// 翻译模板支持的目标语言（供 UI 下拉选择）。
    public static let targetLanguages: [String] = [
        "英文",
        "中文",
        "日文",
        "韩文",
        "法文",
        "德文",
        "西班牙文",
        "俄文"
    ]
}
