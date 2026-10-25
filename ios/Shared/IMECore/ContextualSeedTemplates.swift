//
//  ContextualSeedTemplates.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：内置「上下文触发词 -> 下一句候选」模板表，供 LocalSuggestionIndex（L1 本地联想）
//            在用户尚未积累上屏历史时直接冷启动，保证第一时间就有贴合的候选。
//  依赖：Foundation（只用字符串与数组，无 I/O、无网络）
//  使用方：LocalSuggestionIndex（同模块）
//

import Foundation

/// 内置上下文联想模板（内部类型，不直接对 UI 暴露）。
enum ContextualSeedTemplates {

    /// 一条模板：命中上下文**尾部**的触发词，给出若干"下一句"候选。
    struct Rule {
        /// 触发词（必须命中上下文末句的结尾才生效）。
        let trigger: String
        /// 候选文本（完整短句，点一下整条上屏）。
        let texts: [String]
        /// 基础置信度（0...1）。
        let confidence: Double
    }

    /// 全部模板（88 组规则、179 条候选短句）。
    ///
    /// 编写约定（改这张表前先读，`tools/dict/_eval_suggestion.py` 会逐条体检）：
    /// 1. 触发词必须是**聊天里真的会收到的上一句**，长度 ≥ 2 字。绝不收 `嗯`/`可以`/
    ///    `明天`/`怎么样` 这类裸高频词——它们会命中任意长句的结尾，把无关候选塞进候选栏，
    ///    这正是「联想太垃圾」的根源。
    /// 2. 候选必须是**用户下一句真会打的完整短句**，不是对上文的复述。`晚安 -> 晚安`
    ///    `好久不见 -> 是啊，好久不见` 这类一律删掉，宁可这一条静默不显示。
    /// 3. 候选里不要编造具体事实（时间、金额、地点）。`几点 -> 大概十点吧` 会被骂，
    ///    换成 `我看看时间` 这种谁都能用的话。
    /// 4. 同一组内不要出现意思几乎相同的句子（浪费候选位，一屏只有 2 个位置）。
    /// 5. 末句尾部的语气词（啊/呀/呢/吧/嘛/哦/啦…）由匹配逻辑统一剥掉再比对，
    ///    因此**不需要**为 `谢谢` / `谢谢啊` 各写一条。
    static let rules: [Rule] = [
        // ---- 问候与寒暄 ----
        Rule(trigger: "在吗", texts: ["在的", "在呢，怎么了", "在，你说"], confidence: 0.82),
        Rule(trigger: "在干嘛", texts: ["没干嘛，你呢", "刚下班，在家躺着", "刷手机呢"], confidence: 0.78),
        Rule(trigger: "干嘛呢", texts: ["没干嘛，你呢", "刚忙完"], confidence: 0.76),
        Rule(trigger: "最近怎么样", texts: ["还行，就是有点忙", "挺好的，你呢"], confidence: 0.72),
        Rule(trigger: "好久不见", texts: ["是啊，好久没聊了", "最近忙啥呢"], confidence: 0.74),
        Rule(trigger: "你好", texts: ["你好呀", "在的，你说"], confidence: 0.66),
        Rule(trigger: "早上好", texts: ["早呀", "早，今天这么早"], confidence: 0.76),
        Rule(trigger: "早安", texts: ["早呀", "早，今天也加油"], confidence: 0.76),
        Rule(trigger: "晚安", texts: ["好梦", "早点休息"], confidence: 0.82),
        Rule(trigger: "睡了吗", texts: ["还没，怎么了", "准备睡了"], confidence: 0.78),
        Rule(trigger: "拜拜", texts: ["回聊", "明天聊"], confidence: 0.78),
        Rule(trigger: "回聊", texts: ["好嘞", "明天聊"], confidence: 0.76),
        Rule(trigger: "吃了吗", texts: ["刚吃完，你呢", "还没呢，一会儿去吃"], confidence: 0.74),
        Rule(trigger: "吃饭了吗", texts: ["刚吃完", "还没，正准备吃"], confidence: 0.74),
        Rule(trigger: "辛苦了", texts: ["不辛苦", "应该的"], confidence: 0.78),
        Rule(trigger: "注意身体", texts: ["你也是", "谢谢关心"], confidence: 0.76),
        Rule(trigger: "路上小心", texts: ["好的，你也注意", "知道啦"], confidence: 0.78),
        Rule(trigger: "早点休息", texts: ["好的，你也早点睡", "嗯嗯，晚安"], confidence: 0.80),
        Rule(trigger: "到家了吗", texts: ["到了，刚到家", "还在路上"], confidence: 0.80),
        Rule(trigger: "我到家了", texts: ["好，早点休息", "路上辛苦啦"], confidence: 0.74),
        Rule(trigger: "到家了", texts: ["好，早点休息"], confidence: 0.72),
        Rule(trigger: "刚到公司", texts: ["好，那你先忙", "这么早"], confidence: 0.68),

        // ---- 感谢、道歉、回应 ----
        Rule(trigger: "谢谢你", texts: ["不客气", "不用谢"], confidence: 0.84),
        Rule(trigger: "谢谢", texts: ["不客气", "客气啦", "没事"], confidence: 0.84),
        Rule(trigger: "多谢", texts: ["客气了", "小事"], confidence: 0.78),
        Rule(trigger: "对不起", texts: ["没事的", "没关系，别放心上"], confidence: 0.82),
        Rule(trigger: "不好意思", texts: ["没事没事", "不要紧"], confidence: 0.80),
        Rule(trigger: "抱歉", texts: ["没关系", "别在意"], confidence: 0.78),
        Rule(trigger: "麻烦你了", texts: ["不麻烦", "应该的"], confidence: 0.78),
        Rule(trigger: "麻烦了", texts: ["不麻烦", "有事你说"], confidence: 0.74),
        Rule(trigger: "收到", texts: ["好的", "辛苦你了"], confidence: 0.70),
        Rule(trigger: "好的", texts: ["嗯嗯", "那我先忙了"], confidence: 0.64),
        Rule(trigger: "那就这样", texts: ["好的", "行，回头聊"], confidence: 0.70),
        Rule(trigger: "好的我看看", texts: ["好，不急", "看完跟我说声"], confidence: 0.66),

        // ---- 祝福、鼓励 ----
        Rule(trigger: "生日快乐", texts: ["谢谢！", "谢谢你还记得"], confidence: 0.82),
        Rule(trigger: "恭喜", texts: ["谢谢谢谢", "同喜同喜"], confidence: 0.78),
        Rule(trigger: "新年快乐", texts: ["谢谢，也祝你顺利", "新的一年一起加油"], confidence: 0.78),
        Rule(trigger: "加油", texts: ["谢谢，一起加油", "我会的"], confidence: 0.76),
        Rule(trigger: "考试", texts: ["加油，你可以的", "别紧张，正常发挥"], confidence: 0.70),

        // ---- 邀约、时间、地点 ----
        Rule(trigger: "有空吗", texts: ["有啊，怎么了", "看时间，什么事"], confidence: 0.76),
        Rule(trigger: "周末有空吗", texts: ["应该有，去哪", "可能有点事，怎么了"], confidence: 0.76),
        Rule(trigger: "在忙吗", texts: ["有点忙，怎么了", "不忙，你说"], confidence: 0.76),
        Rule(trigger: "在开会", texts: ["那晚点说", "好的，你先忙"], confidence: 0.74),
        Rule(trigger: "在上班", texts: ["那下班聊", "好的，忙你的"], confidence: 0.70),
        Rule(trigger: "下班了吗", texts: ["刚下班", "还没，快了"], confidence: 0.76),
        Rule(trigger: "几点", texts: ["我看看时间", "我确认一下"], confidence: 0.70),
        Rule(trigger: "几点到", texts: ["我大概十点到", "可能晚一点"], confidence: 0.76),
        Rule(trigger: "什么时候", texts: ["我查一下", "我确认下再回你"], confidence: 0.68),
        Rule(trigger: "多久", texts: ["还得一会儿", "我看看"], confidence: 0.66),
        Rule(trigger: "到哪了", texts: ["快到了", "还有十分钟"], confidence: 0.76),
        Rule(trigger: "改天", texts: ["好啊", "行，到时候说"], confidence: 0.66),
        Rule(trigger: "我明天有事", texts: ["那就改天", "没事，你先忙"], confidence: 0.70),

        // ---- 吃饭、生活、天气 ----
        Rule(trigger: "吃什么", texts: ["随便，你定", "要不点外卖", "想吃火锅"], confidence: 0.76),
        Rule(trigger: "点外卖", texts: ["好，你想吃什么", "我来点吧"], confidence: 0.74),
        Rule(trigger: "喝奶茶吗", texts: ["喝！", "好啊，我三分糖"], confidence: 0.76),
        Rule(trigger: "一起吃饭吧", texts: ["好啊，几点", "行，你定地方"], confidence: 0.76),
        Rule(trigger: "下雨了", texts: ["记得带伞", "是啊，雨挺大的"], confidence: 0.74),
        Rule(trigger: "好热", texts: ["是啊，热死了", "开空调吧"], confidence: 0.72),
        Rule(trigger: "好冷", texts: ["多穿点", "是啊，降温了"], confidence: 0.72),
        Rule(trigger: "好累", texts: ["早点休息", "辛苦了，注意身体"], confidence: 0.76),
        Rule(trigger: "好困", texts: ["早点睡吧", "我也想睡"], confidence: 0.74),
        Rule(trigger: "感冒了", texts: ["多喝热水，早点睡", "吃药了吗"], confidence: 0.74),
        Rule(trigger: "堵车", texts: ["那你慢点", "我这边也堵"], confidence: 0.70),
        Rule(trigger: "加班", texts: ["辛苦了", "又要加班啊"], confidence: 0.68),

        // ---- 工作、沟通 ----
        Rule(trigger: "开会", texts: ["几点开", "好的，我准备一下"], confidence: 0.66),
        Rule(trigger: "发你了", texts: ["好的，我看看", "收到了，谢谢"], confidence: 0.76),
        Rule(trigger: "可以吗", texts: ["可以的", "我再想想"], confidence: 0.66),
        Rule(trigger: "帮我", texts: ["好的没问题", "你说"], confidence: 0.68),
        Rule(trigger: "怎么办", texts: ["先别急，想想办法", "要不问问别人"], confidence: 0.70),
        Rule(trigger: "为什么", texts: ["我也不太清楚", "可能是这样"], confidence: 0.62),
        Rule(trigger: "在哪", texts: ["我发定位给你", "在公司附近"], confidence: 0.66),
        Rule(trigger: "多少钱", texts: ["我看看账单", "这个得问一下"], confidence: 0.64),

        // ---- 情绪、气氛 ----
        Rule(trigger: "哈哈哈", texts: ["笑死", "你也太逗了"], confidence: 0.72),
        Rule(trigger: "笑死", texts: ["哈哈哈哈", "真的绝了"], confidence: 0.72),
        Rule(trigger: "绝了", texts: ["真的绝", "哈哈哈哈"], confidence: 0.70),
        Rule(trigger: "真的吗", texts: ["我骗你干嘛", "真的，不骗你"], confidence: 0.70),
        Rule(trigger: "不会吧", texts: ["真的，没骗你", "我也没想到"], confidence: 0.68),
        Rule(trigger: "太好了", texts: ["是呀", "恭喜恭喜"], confidence: 0.68),
        Rule(trigger: "难过", texts: ["怎么了", "抱抱，别难过"], confidence: 0.74),
        Rule(trigger: "生气", texts: ["别气了", "谁惹你了"], confidence: 0.70),
        Rule(trigger: "开心", texts: ["那就好", "看出来了哈哈"], confidence: 0.66),

        // ---- 亲密、游戏、娱乐 ----
        Rule(trigger: "么么哒", texts: ["么么", "爱你"], confidence: 0.78),
        Rule(trigger: "爱你", texts: ["我也爱你", "么么哒"], confidence: 0.78),
        Rule(trigger: "想你", texts: ["我也想你", "怎么了"], confidence: 0.76),
        Rule(trigger: "开黑吗", texts: ["来，我上号", "等我五分钟"], confidence: 0.78),
        Rule(trigger: "打游戏吗", texts: ["来啊，等我一下", "几点开黑"], confidence: 0.76),
        Rule(trigger: "看剧", texts: ["看什么剧", "推荐一下"], confidence: 0.66),
        Rule(trigger: "去哪玩", texts: ["还没想好", "你有推荐吗"], confidence: 0.66)
    ]
}
