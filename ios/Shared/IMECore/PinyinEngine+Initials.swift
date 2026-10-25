import Foundation

/// 简拼（首字母）候选：聊天权重 + 同结构去重 + 第一页兜底。
///
/// 从 `PinyinEngine.swift` 拆出来的原因很实际——主文件已经贴在 600 行上限上，
/// 再往里堆就要破「单文件 ≤600 行」的硬约束。
///
/// 三条策略各自解决一个具体问题：
/// 1. **聊天权重**：`wq` 按语料词频给出「完全/武器/晚期」，用户要「我去」。权重只
///    乘在简拼路径的最终分上（见 `appendInitialsCandidates` 里的注释）。
/// 2. **同结构去重**：`nh` 会一次刷出「嗯哈/嗯还/嗯好」三个同构词，`zm` 会给出
///    「在吗/在嘛/在么」，`sm` 会给出「声明/声名」。同一「首字 + 长度」最多留 2 条。
/// 3. **第一页兜底**：简拼命中的词条全在 5k–30k 词频区间，偶尔整屏都是书面词；
///    此时把最靠前的聊天词提到第 5 位，保证第一页一定有个能用的。
extension PinyinEngine {

    // MARK: - 策略常量

    /// 最多展开多少个全拼键。
    static let initialsKeyLimit = 12

    /// 每个全拼键先取多少条再筛（取多了没用，同键最多留 2 条）。
    static let initialsEntryLimit = 12

    /// 同一个全拼键最多保留几条。
    static let initialsPerKey = 2

    /// 同一个首字母串下，同「首字 + 长度」结构最多保留几条。
    ///
    /// 为什么配额按「首字 + 长度」而不是只按长度：n 个字母的简拼**只能**命中 n 音节词，
    /// 也就是 n 字词，所以任何一条简拼查询的候选长度全相同（实测 `wq`/`nh`/`zm`/`sm`/`xq`
    /// 的候选长度分布都是 `{2: N}`）。按长度设硬配额等于「每个简拼只给 2 个候选」，
    /// 会把候选栏直接打空。真正让用户觉得「三个同构词」的，是**首字也相同**的一串词
    /// （嗯好/嗯哈/嗯还、在吗/在嘛/在么、声明/声名），所以配额按「首字 + 长度」算。
    static let initialsSameStructure = 2

    /// 同结构第 2 条候选的扣分（保留但压一档，保证还能选到）。
    static let initialsStructurePenalty = 0.12

    /// 第一页（候选栏默认 5 列）兜底窗口。
    static let initialsFirstPage = 5

    // MARK: - 简拼候选

    /// 收集简拼候选（`wq` -> 我去、`zg` -> 中国）。
    /// - Parameters:
    ///   - normalized: 归一化后的输入串（小写、无空格）。
    ///   - pool: 候选池（按文本去重，同文本取更优者）。
    func appendInitialsCandidates(normalized: String, into pool: inout [String: Scored]) {
        guard normalized.count >= dictionary.minimumInitialsLength,
              normalized.count <= dictionary.maximumInitialsLength,
              normalized.count <= Self.maxInitialsQueryLength
        else { return }

        // 1) 把命中的全拼键连同词条一起取出，键内先按「聊天权重 × 词频」排序。
        var buckets: [InitialsBucket] = []
        for key in dictionary.pinyinKeys(initials: normalized, limit: Self.initialsKeyLimit) {
            let entries = dictionary.exactEntries(pinyin: key, limit: Self.initialsEntryLimit)
            guard !entries.isEmpty else { continue }
            let ranked = entries
                .map { entry in
                    InitialsEntry(entry: entry,
                                  rank: Self.initialsRank(frequency: entry.frequency,
                                                          chatPriority: dictionary.chatPriority(for: entry.text)))
                }
                .sorted { lhs, rhs in
                    if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
                    return lhs.entry.text < rhs.entry.text
                }
            buckets.append(InitialsBucket(key: key, entries: ranked))
        }
        // 键之间也按「聊天权重 × 词频」排，避免整屏被语料高频的书面词占满。
        buckets.sort { lhs, rhs in
            let left = lhs.entries.first?.rank ?? 0
            let right = rhs.entries.first?.rank ?? 0
            if left != right { return left > right }
            return lhs.key < rhs.key
        }

        // 2) 按桶依次取：同一个全拼键最多 2 条，同一个「首字 + 长度」最多 2 条。
        var structureCount: [String: Int] = [:]
        for (offset, bucket) in buckets.enumerated() {
            var used = 0
            for item in bucket.entries {
                guard used < Self.initialsPerKey else { break }
                let entry = item.entry
                let stem = Self.structureKey(for: entry.text)
                let seen = structureCount[stem] ?? 0
                guard seen < Self.initialsSameStructure else { continue }
                structureCount[stem] = seen + 1
                used += 1

                var base = 0.6 - Double(offset) * 0.05
                if seen > 0 { base -= Self.initialsStructurePenalty }
                // 聊天权重乘子 = 1 + chatPriority(词)。**只在简拼路径**叠加：
                //   · 全拼（`woqu`）和精确命中已经有用户明确打出的完整音节，词本身是谁
                //     一目了然，不该再被先验表改写排序；
                //   · 简拼只给了首字母，歧义天然大，正是需要「聊天先验」补足信息的地方；
                //   · 用户学习权重（`learning.weight`）仍然乘在最终分外面，选过几次之后
                //     个人习惯会盖过这张静态表。
                let multiplier = 1.0 + dictionary.chatPriority(for: entry.text)
                insert(
                    text: entry.text,
                    pinyin: bucket.key,
                    frequency: entry.frequency,
                    base: base,
                    kind: Self.kind(for: entry),
                    chatMultiplier: multiplier,
                    into: &pool
                )
            }
        }
    }

    /// 简拼候选的排序值：与最终得分同形（对数词频 + 首槽 base）× 聊天乘子。
    static func initialsRank(frequency: Int, chatPriority: Double) -> Double {
        (logScore(frequency) + 0.6) * (1.0 + chatPriority)
    }

    /// 同构判定键：首字 + 词长（`嗯好` 与 `嗯哈` 同键，`在吗` 与 `在嘛` 同键）。
    static func structureKey(for text: String) -> String {
        String(text.prefix(1)) + "|" + String(text.count)
    }

    // MARK: - 第一页兜底

    /// 第一页聊天词兜底：前 5 条一条聊天词都没有时，把最靠前的那条提到第 5 位。
    ///
    /// 只在「输入被判定为简拼」时生效；已经在前 5 里出现聊天词就原样返回，不乱动排序。
    /// - Parameters:
    ///   - results: 已按得分降序排好的候选。
    ///   - query: 归一化后的输入串。
    /// - Returns: 可能被调整过的候选数组。
    func promoteChatToFirstPage(_ results: [IMECandidate], query: String) -> [IMECandidate] {
        guard query.count >= dictionary.minimumInitialsLength,
              query.count <= dictionary.maximumInitialsLength,
              query.count <= Self.maxInitialsQueryLength
        else { return results }
        let window = min(Self.initialsFirstPage, results.count)
        guard window > 0, window < results.count else { return results }
        if results.prefix(window).contains(where: { dictionary.chatPriority(for: $0.text) > 0 }) {
            return results
        }
        guard let index = results[window...].firstIndex(where: { dictionary.chatPriority(for: $0.text) > 0 })
        else { return results }
        var promoted = results
        let candidate = promoted.remove(at: index)
        promoted.insert(candidate, at: window - 1)
        return promoted
    }
}

/// 简拼命中的一个全拼键，及其按键内排序好的词条。
struct InitialsBucket {
    /// 全拼键（如 `woqu`）。
    let key: String
    /// 键内词条（已按 `rank` 降序）。
    let entries: [InitialsEntry]
}

/// 简拼命中的单条词条 + 排序值。
struct InitialsEntry {
    /// 词库词条。
    let entry: DictionaryEntry
    /// 排序值（聊天权重 × 词频）。
    let rank: Double
}
