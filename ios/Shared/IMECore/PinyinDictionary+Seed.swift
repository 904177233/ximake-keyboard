//
//  PinyinDictionary+Seed.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：随包词库缺失时的内置兜底词表（50 条高频词）。
//            从 `PinyinDictionary.swift` 拆出来，一是让主文件回到 600 行以内，
//            二是这张表与主类的加载/索引逻辑无关，独立成文件更容易维护。
//  依赖：Foundation、DictionaryEntry（同模块）。
//  使用方：`PinyinDictionary.init(dictionaryURL:)` 在解析失败且候选路径全部落空时调用。
//

import Foundation

extension PinyinDictionary {

    /// 随包词库缺失时使用的极小词表（50 条），保证键盘不至于完全不可用。
    ///
    /// 采用"空格分隔"的紧凑写法（而非词库的 TAB 分隔），解析时按空白切分，
    /// 每行格式：`拼音 词 词频 flags`。这样内联字符串不会在源码里引入制表符
    /// （编码规范要求源文件不含 TAB）。
    /// - Returns: 词条数组。
    static func builtinSeedEntries() -> [DictionaryEntry] {
        let seed = """
        wo 我 900000 core
        ni 你 850000 core
        de 的 830000 core
        le 了 800000 core
        shi 是 780000 core
        bu 不 700000 core
        zai 在 690000 core
        you 有 620000 core
        he 和 600000 core
        ren 人 580000 core
        zhe 这 560000 core
        na 那 540000 core
        hao 好 520000 core
        ma 吗 500000 core
        ba 吧 480000 core
        a 啊 460000 core
        women 我们 300000 core
        nimen 你们 180000 core
        tamen 他们 160000 core
        zhongguo 中国 129470 core
        keyi 可以 70958 core
        shenme 什么 59317 core
        zenme 怎么 27339 core
        yiqi 一起 15976 core
        pengyou 朋友 9200 core
        mingtian 明天 3264 core
        xiexie 谢谢 5000 chat,bless
        bukeqi 不客气 4200 chat,bless
        duibuqi 对不起 3800 chat
        meiguanxi 没关系 3600 chat
        zaijian 再见 3400 chat
        wanan 晚安 3200 chat,bless
        zaoshanghao 早上好 3000 chat,bless
        haode 好的 6500 chat
        shoudao 收到 4000 chat
        haha 哈哈 6800 chat
        hahaha 哈哈哈 5000 chat
        jiayou 加油 4100 chat,bless
        xinku 辛苦 2800 chat
        shengrikuaile 生日快乐 2600 chat,bless
        xiangni 想你 2700 chat
        xihuan 喜欢 5600 chat
        ai 爱 9000 core
        shuijiao 睡觉 3000 chat
        chifan 吃饭 3200 chat
        gongzuo 工作 5000 chat
        xuexiao 学校 4200 core
        shouji 手机 4789 core
        dianhua 电话 3600 core
        weixin 微信 4400 chat
        """

        var result: [DictionaryEntry] = []
        for rawLine in seed.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3 else { continue }
            let pinyin = normalize(String(fields[0]))
            let word = String(fields[1])
            let frequency = Int(fields[2]) ?? 0
            let flags = fields.count >= 4 ? String(fields[3]) : ""
            guard !pinyin.isEmpty, !word.isEmpty else { continue }
            result.append(DictionaryEntry(pinyin: pinyin,
                                          text: word,
                                          frequency: frequency,
                                          flags: flags))
        }
        return result
    }
}
