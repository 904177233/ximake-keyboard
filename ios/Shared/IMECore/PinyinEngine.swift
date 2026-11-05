//
//  PinyinEngine.swift
//  墨语 · 输入法内核
//
//  把拼音串变成候选。26 键和九宫格共用一套流程：
//
//    1. 在输入串上做动态规划，找一条分数最高的切法，得到整句候选。
//       一块「词块」的分数 = log(词频) - 每块固定代价 + 每多一个音节的奖励。
//       固定代价防止长句被切成一堆高频单字。
//    2. 再列出整串能对上的词、还没打完的词、简拼词，以及只吃掉开头几个字母的词。
//       选了只吃开头的词后，剩下的拼音接着转换，这就是逐词选词。
//
//  分数公式和 tools/dict/build_binary.py 的评测代码保持一致，改一边要同步另一边。
//

import Foundation

/// 拼音转换引擎。
public final class PinyinEngine {

    // MARK: - 打分常量

    /// 每块词的固定代价。
    static let tilePenalty = 14.0
    /// 词块每多一个音节的奖励：同样的拼音，宁可一个长词，不要两个短词。
    static let syllableBonus = 2.0
    /// 两个词连在一起很常见时的奖励（我想 > 我向）。
    static let bigramBonus = 3.0
    /// 还没打完的词（nih -> 你好）额外代价。
    static let partialPenalty = 1.5
    /// 单个首字母代表一个字（x -> 下）的额外代价。
    static let singleInitialPenalty = 10.0
    /// 多个首字母代表一个词（xh -> 喜欢）的额外代价。
    static let initialsPenalty = 3.0
    /// 简拼每一段试几个词（tools/dict/build_binary.py 的 INITIAL_TOP_K 要一起改）。
    static let initialTopK = 3
    /// 简拼每多一个字母加的分：一下对上四个字母的词比拆成两段可信得多。
    static let initialsLengthBonus = 3.0
    /// 前一个词的最后一个字和这个词的第一个字连起来是个常用词（吃 + 过了 -> 吃过），加分。
    static let junctionBonus = 2.0
    /// 嗯、呣这类只有声母的音节，放在句子中间基本是错的。
    static let unlikelySyllables: Set<String> = ["n", "m", "ng", "hm", "hng"]
    static let unlikelyPenalty = 20.0
    /// 单个词块最长的拼音长度。
    static let maxTileLength = 24
    /// 候选总数上限。
    static let maxCandidates = 120

    /// 整句最后一个音是这些时，换成语气词。
    ///
    /// 我们没有上下文模型，句尾的 ma 按词频会选「嘛」、ba 会选「把」。
    /// 这条规则只动整句候选的最后一个字，普通候选不受影响。
    static let endingParticles: [String: String] = [
        "ma": "吗", "ba": "吧", "ne": "呢", "a": "啊", "ya": "呀", "la": "啦", "le": "了"
    ]

    // MARK: - 依赖

    private let dictionary: MoyuDictionary?
    private let learning: UserLearningStore
    private let suggestions: PhraseSuggestionIndex
    private let nextWords: NextWordIndex

    /// 九宫格：数字串 -> 能打出的音节。
    private static let syllablesByDigits: [String: [String]] = {
        var table: [String: [String]] = [:]
        for syllable in PinyinSyllables.all {
            table[MoyuDictionary.t9Digits(syllable), default: []].append(syllable)
        }
        return table
    }()

    public init(dictionary: MoyuDictionary?, learning: UserLearningStore, nextWords: NextWordIndex? = nil) {
        self.dictionary = dictionary
        self.learning = learning
        self.suggestions = PhraseSuggestionIndex()
        self.nextWords = nextWords ?? NextWordIndex()
    }

    /// 键盘上相邻的字母，用来猜打错的字。
    private static let adjacentKeys: [UInt8: [UInt8]] = {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { Array($0.utf8) }
        var table: [UInt8: [UInt8]] = [:]
        for (rowIndex, row) in rows.enumerated() {
            for (column, byte) in row.enumerated() {
                var neighbors: [UInt8] = []
                if column > 0 { neighbors.append(row[column - 1]) }
                if column + 1 < row.count { neighbors.append(row[column + 1]) }
                for other in [rowIndex - 1, rowIndex + 1] where rows.indices.contains(other) {
                    // 上下两行错开半个键，取正下方和斜下方
                    let offset = other > rowIndex ? -1 : 0
                    for candidate in [column + offset, column + offset + 1] where rows[other].indices.contains(candidate) {
                        neighbors.append(rows[other][candidate])
                    }
                }
                table[byte] = neighbors
            }
        }
        return table
    }()

    // MARK: - 词块

    /// DP 里的一块词。
    private struct Tile {
        let end: Int
        let text: String
        let key: String
        let score: Double
        /// 给人看的拼音，nil 表示按原始输入显示（简拼、没打完的词）。
        let syllables: [String]?
        let lastSyllable: String?
        /// 简拼或没打完的词：拼音不是完整对上的。
        var isLoose = false
    }

    /// 取一个键下最适合用来拼句子的词：词频最高的正常词，学过的词优先。
    private func bestWord(key index: Int, dictionary: MoyuDictionary, previous: String? = nil) -> MoyuDictionary.Entry? {
        var best: MoyuDictionary.Entry?
        var bestScore = -Double.infinity
        for entry in dictionary.entries(key: index, limit: 8) where entry.isWord {
            let count = learning.count(of: entry.text)
            var score = log(Double(entry.frequency) * (1.0 + Double(count) * 4.0) + 1)
            if let previous, nextWords.isCommonPair(previous, entry.text) {
                score += Self.bigramBonus
            }
            if score > bestScore {
                bestScore = score
                best = entry
            }
        }
        return best
    }

    /// 前一个词的最后一个字和这个词的第一个字连起来是不是个常用词。
    private func junctionBonus(previous: String?, previousSyllable: String?, text: String,
                               firstSyllable: String?, dictionary: MoyuDictionary) -> Double {
        guard let previous, let last = previous.last, let first = text.first,
              let previousSyllable, let firstSyllable else { return 0 }
        let pair = String(last) + String(first)
        for index in dictionary.exactRange(Array((previousSyllable + firstSyllable).utf8)) {
            for entry in dictionary.entries(key: index, limit: 8) where entry.text == pair && entry.frequency >= 200 {
                return Self.junctionBonus
            }
        }
        return 0
    }

    /// 个人词库里的词：比词库里很常用的词还高一点，选得越多越高。
    private static func userWordScore(syllables: Int, chosen: Int) -> Double {
        log(200_000.0) - tilePenalty + syllableBonus * Double(max(syllables - 1, 0)) + 1.5 * log2(Double(chosen) + 1)
    }

    private func scoreWord(frequency: Int, syllableCount: Int, text: String, previous: String? = nil) -> Double {
        let learned = learning.count(of: text)
        var score = log(Double(frequency) + 1)
            - Self.tilePenalty
            + Self.syllableBonus * Double(max(syllableCount - 1, 0))
            + 1.2 * log2(Double(learned) + 1)
        if let previous, nextWords.isCommonPair(previous, text) {
            score += Self.bigramBonus
        }
        return score
    }

    /// 26 键：从 start 开始的所有词块。
    private func qwertyTiles(query: IMEQuery, start: Int, previous: String?, previousSyllable: String?,
                             dictionary: MoyuDictionary) -> [Tile] {
        var tiles: [Tile] = []
        let input = query.input
        let count = input.count
        var range = 0..<dictionary.keyCount
        var position = start
        var tailHasExact = false

        while position < min(count, start + Self.maxTileLength) {
            let depth = position - start
            range = dictionary.narrow(range, depth: depth, byte: input[position])
            position += 1
            if range.isEmpty { break }

            let sub = Array(input[start..<position])
            let subString = String(decoding: sub, as: UTF8.self)
            var matchedExact = false
            var cursor = range.lowerBound
            while cursor < range.upperBound, dictionary.keyLength(key: cursor) == sub.count {
                if let entry = bestWord(key: cursor, dictionary: dictionary, previous: previous) {
                    matchedExact = true
                    let syllables = dictionary.syllables(key: cursor)
                    var score = scoreWord(frequency: entry.frequency,
                                          syllableCount: dictionary.syllableCount(key: cursor),
                                          text: entry.text,
                                          previous: previous)
                    // 嗯、呣开头的词（包括 nhao -> 嗯好）放在句子中间基本是错的
                    if let first = syllables.first, Self.unlikelySyllables.contains(first) {
                        score -= Self.unlikelyPenalty
                    }
                    tiles.append(Tile(end: position, text: entry.text, key: subString, score: score,
                                      syllables: syllables, lastSyllable: syllables.last))
                }
                cursor += 1
            }

            for phrase in learning.phrases(forKey: subString) {
                matchedExact = true
                let score = log(60000.0) - Self.tilePenalty + 1.2 * log2(Double(learning.count(of: phrase)) + 1)
                tiles.append(Tile(end: position, text: phrase, key: subString, score: score,
                                  syllables: nil, lastSyllable: nil))
            }

            // 个人词库：这个拼音下选过的词。两个音节以上才进整句；单字只调候选顺序，免得句子里到处是它
            if let syllables = PinyinSyllables.segment(subString), syllables.count >= 2 {
                for word in learning.userWords(forKey: subString).prefix(2) {
                    matchedExact = true
                    tiles.append(Tile(end: position, text: word.text, key: subString,
                                      score: Self.userWordScore(syllables: syllables.count, chosen: word.count),
                                      syllables: syllables, lastSyllable: syllables.last))
                }
            }

            // 简拼：这一段没有全拼能对上时才试
            if !matchedExact, sub.count <= 6 {
                let penalty = sub.count == 1 ? Self.singleInitialPenalty : Self.initialsPenalty
                for index in dictionary.initialKeys(sub, limit: Self.initialTopK) {
                    guard let entry = bestWord(key: index, dictionary: dictionary) else { continue }
                    let syllables = dictionary.syllables(key: index)
                    let score = scoreWord(frequency: entry.frequency, syllableCount: 1, text: entry.text, previous: previous)
                        - penalty
                        + Self.initialsLengthBonus * Double(sub.count - 1)
                        + junctionBonus(previous: previous, previousSyllable: previousSyllable,
                                        text: entry.text, firstSyllable: syllables.first, dictionary: dictionary)
                    tiles.append(Tile(end: position, text: entry.text, key: dictionary.keyString(key: index),
                                      score: score, syllables: nil, lastSyllable: syllables.last, isLoose: true))
                }
            }
            tailHasExact = matchedExact
            if query.breaks.contains(position) { return tiles }
        }

        // 还没打完的词（只在末尾）：nih -> 你好。
        // 末尾已经是完整的词就不补，否则 jintianhenmang 会变成「今天很忙完」，多出一个没打的字。
        // 末尾能切成完整音节时也不补：huiba 是 hui'ba，不是没打完的 huibao。
        // 这种词还会出现在候选列表里，只是不进整句。
        if position == count, count - start >= 2, !range.isEmpty, !tailHasExact,
           !isCompleteSyllables(input[start..<count]),
           !hasBreak(query, after: start, before: count),
           let top = bestPrefixKey(range: range, depth: count - start, dictionary: dictionary),
           let entry = bestWord(key: top, dictionary: dictionary) {
            // 没打的音节不算奖励，否则越长的词越占便宜
            let score = scoreWord(frequency: entry.frequency,
                                  syllableCount: 1,
                                  text: entry.text) - Self.partialPenalty
            tiles.append(Tile(end: count, text: entry.text, key: dictionary.keyString(key: top),
                              score: score, syllables: nil, lastSyllable: nil, isLoose: true))
        }
        return tiles
    }

    /// 这段字母能不能切成完整的音节（嗯、呣这种不算）。
    private func isCompleteSyllables(_ letters: ArraySlice<UInt8>) -> Bool {
        guard let parts = PinyinSyllables.segment(String(decoding: letters, as: UTF8.self)) else { return false }
        return !parts.contains { Self.unlikelySyllables.contains($0) }
    }

    private func hasBreak(_ query: IMEQuery, after start: Int, before end: Int) -> Bool {
        query.breaks.contains { $0 > start && $0 < end }
    }

    /// range 内比当前输入更长的键里，词频最高的那个。
    private func bestPrefixKey(range: Range<Int>, depth: Int, dictionary: MoyuDictionary) -> Int? {
        var best: Int?
        var bestFrequency = -1
        var scanned = 0
        for index in range where dictionary.keyLength(key: index) > depth {
            scanned += 1
            if scanned > 8000 { break }
            let frequency = dictionary.maxFrequency(key: index)
            if frequency > bestFrequency {
                bestFrequency = frequency
                best = index
            }
        }
        return best
    }

    private func matchesLocks(keyBytes: [UInt8], at start: Int, locks: [Int: UInt8]) -> Bool {
        guard !locks.isEmpty else { return true }
        for (offset, byte) in keyBytes.enumerated() {
            if let lock = locks[start + offset], lock != byte {
                return false
            }
        }
        return true
    }

    /// 九宫格：从 start 开始的所有词块。
    private func t9Tiles(query: IMEQuery, start: Int, previous: String?, previousSyllable: String?,
                         dictionary: MoyuDictionary) -> [Tile] {
        var tiles: [Tile] = []
        let input = query.input
        let count = input.count
        var position = start + 1
        var tailHasExact = false
        while position <= min(count, start + Self.maxTileLength) {
            let digits = Array(input[start..<position])
            for keyIndex in dictionary.t9Keys(digits, limit: 48) {
                let key = dictionary.keyString(key: keyIndex)
                guard matchesLocks(keyBytes: Array(key.utf8), at: start, locks: query.locks) else { continue }
                let syllables = dictionary.syllables(key: keyIndex)
                if let first = syllables.first, Self.unlikelySyllables.contains(first) { continue }
                guard let entry = bestWord(key: keyIndex, dictionary: dictionary, previous: previous) else { continue }
                let score = scoreWord(frequency: entry.frequency,
                                      syllableCount: dictionary.syllableCount(key: keyIndex),
                                      text: entry.text,
                                      previous: previous)
                tiles.append(Tile(end: position, text: entry.text, key: key, score: score,
                                  syllables: syllables, lastSyllable: syllables.last))
                if position == count {
                    tailHasExact = true
                }
                break
            }
            let digitString = String(decoding: digits, as: UTF8.self)
            for phrase in learning.phrases(forT9: digitString) {
                let score = log(60000.0) - Self.tilePenalty + 1.2 * log2(Double(learning.count(of: phrase.text)) + 1)
                if matchesLocks(keyBytes: Array(phrase.key.utf8), at: start, locks: query.locks) {
                    tiles.append(Tile(end: position, text: phrase.text, key: phrase.key, score: score,
                                      syllables: nil, lastSyllable: nil))
                }
            }
            for word in learning.userWords(forT9: digitString).prefix(3) {
                guard let syllables = PinyinSyllables.segment(word.key), syllables.count >= 2,
                      matchesLocks(keyBytes: Array(word.key.utf8), at: start, locks: query.locks) else { continue }
                tiles.append(Tile(end: position, text: word.text, key: word.key,
                                  score: Self.userWordScore(syllables: syllables.count, chosen: word.count),
                                  syllables: syllables, lastSyllable: syllables.last))
            }
            if query.locks.isEmpty, digits.count >= 2, digits.count <= 6 {
                for index in dictionary.t9InitialKeys(digits, limit: Self.initialTopK) {
                    guard let entry = bestWord(key: index, dictionary: dictionary) else { continue }
                    let syllables = dictionary.syllables(key: index)
                    let score = scoreWord(frequency: entry.frequency, syllableCount: 1, text: entry.text, previous: previous)
                        - Self.initialsPenalty - 1
                        + Self.initialsLengthBonus * Double(digits.count - 1)
                        + junctionBonus(previous: previous, previousSyllable: previousSyllable,
                                        text: entry.text, firstSyllable: syllables.first, dictionary: dictionary)
                    tiles.append(Tile(end: position, text: entry.text, key: dictionary.keyString(key: index),
                                      score: score, syllables: nil, lastSyllable: syllables.last, isLoose: true))
                }
            }
            if query.breaks.contains(position) { return tiles }
            position += 1
        }

        // 还没打完的词。末尾已经对得上完整的词就不补，免得多出没打的字。
        if count - start >= 2, !tailHasExact, !hasBreak(query, after: start, before: count) {
            let digits = Array(input[start..<count])
            var best: Int?
            var bestFrequency = -1
            for keyIndex in dictionary.t9PrefixKeys(digits, limit: 2000)
            where dictionary.keyLength(key: keyIndex) > digits.count {
                let frequency = dictionary.maxFrequency(key: keyIndex)
                if frequency > bestFrequency,
                   matchesLocks(keyBytes: Array(dictionary.keyString(key: keyIndex).utf8), at: start, locks: query.locks) {
                    bestFrequency = frequency
                    best = keyIndex
                }
            }
            if let best, let entry = bestWord(key: best, dictionary: dictionary) {
                let score = scoreWord(frequency: entry.frequency,
                                      syllableCount: 1,
                                      text: entry.text) - Self.partialPenalty
                tiles.append(Tile(end: count, text: entry.text, key: dictionary.keyString(key: best),
                                  score: score, syllables: dictionary.syllables(key: best), lastSyllable: nil, isLoose: true))
            }
        }
        return tiles
    }

    /// 动态规划求最优切法。
    private func solve(query: IMEQuery, dictionary: MoyuDictionary) -> [Tile]? {
        let count = query.input.count
        guard count > 0 else { return nil }
        var best = [Double](repeating: -.infinity, count: count + 1)
        var back = [(from: Int, tile: Tile)?](repeating: nil, count: count + 1)
        best[0] = 0
        for start in 0..<count where best[start] > -.infinity {
            let previous = back[start]?.tile.text
            let previousSyllable = back[start]?.tile.lastSyllable
            let tiles = query.mode == .qwerty
                ? qwertyTiles(query: query, start: start, previous: previous, previousSyllable: previousSyllable, dictionary: dictionary)
                : t9Tiles(query: query, start: start, previous: previous, previousSyllable: previousSyllable, dictionary: dictionary)
            for tile in tiles {
                let value = best[start] + tile.score
                if value > best[tile.end] {
                    best[tile.end] = value
                    back[tile.end] = (start, tile)
                }
            }
        }
        guard back[count] != nil else { return nil }
        var path: [Tile] = []
        var cursor = count
        while cursor > 0, let step = back[cursor] {
            path.append(step.tile)
            cursor = step.from
        }
        return Array(path.reversed())
    }

    // MARK: - 转换

    /// 把输入转换成候选。
    /// - Parameters:
    ///   - query: 输入。
    ///   - rawText: 用户打的原文（保留大小写），放在候选最后。九宫格传 nil。
    ///   - fuzzy: 模糊音设置。
    ///   - typoCorrection: 是否打开纠错。
    public func convert(_ query: IMEQuery,
                        rawText: String?,
                        fuzzy: FuzzyPinyinOptions = .off,
                        typoCorrection: Bool = true) -> IMEConversion {
        guard !query.input.isEmpty else { return .empty }
        guard let dictionary else {
            let raw = rawText.map { [IMECandidate(text: $0, key: "", consumed: query.input.count, kind: .raw)] } ?? []
            return IMEConversion(candidates: raw, spelling: rawText ?? "")
        }

        var builder = CandidateBuilder(limit: Self.maxCandidates)
        let count = query.input.count
        let path = solve(query: query, dictionary: dictionary)

        // 打头的是整句（或一整个词）
        // 两个字母的简拼（wq、nh）歧义太大，首选交给按聊天习惯排的候选；三个字母以上用整句算出来的
        let singleAbbreviation = path?.count == 1 && path?.first?.syllables == nil && count <= 2
        let typedString = String(decoding: query.input, as: UTF8.self)
        let onlyUnlikely = query.mode == .qwerty && Self.unlikelySyllables.contains(typedString)
        if let path, !singleAbbreviation, !onlyUnlikely {
            builder.add(IMECandidate(text: sentenceText(path),
                                     key: path.map(\.key).joined(),
                                     consumed: count,
                                     kind: path.count > 1 ? .sentence : .word))
        }

        if query.mode == .qwerty {
            addQwertyLists(query: query, dictionary: dictionary, into: &builder)
        } else {
            addT9Lists(query: query, dictionary: dictionary, into: &builder)
        }

        // 个人词库：这串拼音选过的词放第一个
        let typed = String(decoding: query.input, as: UTF8.self)
        if query.mode == .qwerty {
            if let favorite = learning.userWords(forKey: typed).first {
                builder.promote(IMECandidate(text: favorite.text, key: typed, consumed: count), to: 0)
            }
        } else if let favorite = learning.userWords(forT9: typed).first(where: {
            matchesLocks(keyBytes: Array($0.key.utf8), at: 0, locks: query.locks)
        }) {
            builder.promote(IMECandidate(text: favorite.text, key: favorite.key, consumed: count), to: 0)
        }

        if query.mode == .qwerty {
            let inputString = String(decoding: query.input, as: UTF8.self)
            if fuzzy.isActive {
                addFuzzy(input: inputString, query: query, rules: fuzzy.activeRules,
                         dictionary: dictionary, into: &builder)
            }
            if typoCorrection, builder.wordCount < 3 {
                addCorrections(input: inputString, query: query, dictionary: dictionary, into: &builder)
            }
        }

        // 打错一个字母（wozhem -> wozhen）：排在第二个，标上「纠错」
        if query.mode == .qwerty, typoCorrection {
            for (offset, candidate) in adjacentCorrections(query: query, path: path, dictionary: dictionary).enumerated() {
                builder.insert(candidate, at: 1 + offset)
            }
        }

        if let rawText, !rawText.isEmpty {
            builder.add(IMECandidate(text: rawText, key: "", consumed: count, kind: .raw))
        }

        return IMEConversion(
            candidates: builder.candidates,
            spelling: spelling(path: path, query: query, rawText: rawText),
            pinyinChoices: query.mode == .t9 ? pinyinChoices(query: query, dictionary: dictionary) : []
        )
    }

    private func sentenceText(_ path: [Tile]) -> String {
        var pieces = path.map(\.text)
        if pieces.count >= 2, let last = path.last?.key, let particle = Self.endingParticles[last] {
            pieces[pieces.count - 1] = particle
        }
        return pieces.joined()
    }

    /// 26 键的候选列表。
    private func addQwertyLists(query: IMEQuery, dictionary: MoyuDictionary, into builder: inout CandidateBuilder) {
        let input = query.input
        let count = input.count
        let inputString = String(decoding: input, as: UTF8.self)

        for phrase in learning.phrases(forKey: inputString) {
            builder.add(IMECandidate(text: phrase, key: inputString, consumed: count))
        }

        // 单独一个 m、n：先给 m 开头的常用字（没、吗、们），嗯、呣排后面
        if Self.unlikelySyllables.contains(inputString) {
            addInitials(input: input, dictionary: dictionary, into: &builder)
        }

        // 整串对得上的词
        addEntries(of: dictionary.exactRange(input), consumed: count, limit: 40, dictionary: dictionary, into: &builder)

        // 还没打完的词
        if count >= 2 {
            let range = dictionary.prefixRange(input)
            let longer = topKeys(in: range, depth: count, limit: 10, dictionary: dictionary)
            for index in longer {
                if let entry = bestWord(key: index, dictionary: dictionary) {
                    builder.add(IMECandidate(text: entry.text, key: dictionary.keyString(key: index), consumed: count))
                }
            }
            for phrase in learning.phrases(withPrefix: inputString, limit: 4) {
                builder.add(IMECandidate(text: phrase.text, key: phrase.key, consumed: count))
            }
        }

        // 简拼：聊天词优先（wq 先给「我去」）
        if count <= 8 {
            addInitials(input: input, dictionary: dictionary, into: &builder)
        }

        // 只吃掉开头几个字母的词，长的在前
        var end = count - 1
        while end >= 1 {
            if !query.breaks.contains(where: { $0 > 0 && $0 < end }) {
                let range = dictionary.exactRange(Array(input[0..<end]))
                let limit = end <= 2 ? (end == count - 1 ? 8 : 30) : 5
                addEntries(of: range, consumed: end, limit: limit, dictionary: dictionary, into: &builder)
            }
            end -= 1
        }
    }

    private func addEntries(of range: Range<Int>, consumed: Int, limit: Int,
                            dictionary: MoyuDictionary, into builder: inout CandidateBuilder) {
        var rows: [(entry: MoyuDictionary.Entry, key: String)] = []
        for index in range {
            let key = dictionary.keyString(key: index)
            for entry in dictionary.entries(key: index, limit: limit) {
                rows.append((entry, key))
            }
        }
        // 学过的词排前面
        rows.sort { left, right in
            let leftScore = Double(left.entry.frequency) * (1 + Double(learning.count(of: left.entry.text)) * 4)
            let rightScore = Double(right.entry.frequency) * (1 + Double(learning.count(of: right.entry.text)) * 4)
            return leftScore > rightScore
        }
        for row in rows.prefix(limit) where !row.entry.isPunctuation {
            builder.add(IMECandidate(text: row.entry.text, key: row.key, consumed: consumed,
                                     kind: row.entry.isEmoji ? .emoji : .word))
        }
    }

    private func topKeys(in range: Range<Int>, depth: Int, limit: Int, dictionary: MoyuDictionary) -> [Int] {
        var rows: [(index: Int, frequency: Int)] = []
        var scanned = 0
        for index in range where dictionary.keyLength(key: index) > depth {
            scanned += 1
            if scanned > 8000 { break }
            rows.append((index, dictionary.maxFrequency(key: index)))
        }
        rows.sort { $0.frequency > $1.frequency }
        return rows.prefix(limit).map { $0.index }
    }

    private func addInitials(input: [UInt8], dictionary: MoyuDictionary, into builder: inout CandidateBuilder) {
        var rows: [(text: String, key: String, score: Double)] = []
        for index in dictionary.initialKeys(input, limit: 60) {
            for entry in dictionary.entries(key: index, limit: 3) where entry.isWord {
                let learned = Double(learning.count(of: entry.text))
                let score = log(Double(entry.frequency) + 1) * (1 + 0.35 * entry.chatWeight) + 3 * log2(learned + 1)
                rows.append((entry.text, dictionary.keyString(key: index), score))
            }
        }
        rows.sort { $0.score > $1.score }
        for row in rows.prefix(20) {
            builder.add(IMECandidate(text: row.text, key: row.key, consumed: input.count))
        }
    }

    /// 九宫格的候选列表。
    private func addT9Lists(query: IMEQuery, dictionary: MoyuDictionary, into builder: inout CandidateBuilder) {
        let input = query.input
        let count = input.count
        let digitString = String(decoding: input, as: UTF8.self)
        for phrase in learning.phrases(forT9: digitString) {
            if matchesLocks(keyBytes: Array(phrase.key.utf8), at: 0, locks: query.locks) {
                builder.add(IMECandidate(text: phrase.text, key: phrase.key, consumed: count))
            }
        }

        addT9Keys(digits: input, consumed: count, keyLimit: 12, entryLimit: 6, query: query,
                  dictionary: dictionary, into: &builder)

        if query.locks.isEmpty, count >= 2, count <= 6 {
            var rows: [(text: String, key: String, score: Double)] = []
            for index in dictionary.t9InitialKeys(input, limit: 30) {
                if let entry = bestWord(key: index, dictionary: dictionary) {
                    rows.append((entry.text, dictionary.keyString(key: index),
                                 log(Double(entry.frequency) + 1) * (1 + 0.35 * entry.chatWeight)))
                }
            }
            rows.sort { $0.score > $1.score }
            for row in rows.prefix(12) {
                builder.add(IMECandidate(text: row.text, key: row.key, consumed: count))
            }
        }

        var end = count - 1
        while end >= 1 {
            if !query.breaks.contains(where: { $0 > 0 && $0 < end }) {
                addT9Keys(digits: Array(input[0..<end]), consumed: end, keyLimit: 6,
                          entryLimit: end <= 3 ? 8 : 3, query: query, dictionary: dictionary, into: &builder)
            }
            end -= 1
        }
    }

    private func addT9Keys(digits: [UInt8], consumed: Int, keyLimit: Int, entryLimit: Int, query: IMEQuery,
                           dictionary: MoyuDictionary, into builder: inout CandidateBuilder) {
        var used = 0
        for keyIndex in dictionary.t9Keys(digits, limit: 48) {
            let key = dictionary.keyString(key: keyIndex)
            guard matchesLocks(keyBytes: Array(key.utf8), at: 0, locks: query.locks) else { continue }
            if Self.unlikelySyllables.contains(key) { continue }
            for entry in dictionary.entries(key: keyIndex, limit: entryLimit) where !entry.isPunctuation {
                builder.add(IMECandidate(text: entry.text, key: key, consumed: consumed,
                                         kind: entry.isEmoji ? .emoji : .word))
            }
            used += 1
            if used >= keyLimit { break }
        }
    }

    /// 模糊音：zong -> 中。排在精确结果后面。
    private func addFuzzy(input: String, query: IMEQuery, rules: Set<FuzzyPinyinRule>,
                          dictionary: MoyuDictionary, into builder: inout CandidateBuilder) {
        let variants = FuzzyPinyin.expand(input, rules: rules, limit: 8).dropFirst()
        var usedSentence = false
        for variant in variants {
            let bytes = Array(variant.utf8)
            let range = dictionary.exactRange(bytes)
            for index in range {
                for entry in dictionary.entries(key: index, limit: 4) where entry.isWord {
                    builder.add(IMECandidate(text: entry.text, key: variant, consumed: query.input.count, kind: .fuzzy))
                }
            }
            if !usedSentence, range.isEmpty {
                let variantQuery = IMEQuery(mode: .qwerty, input: bytes)
                if let path = solve(query: variantQuery, dictionary: dictionary),
                   path.count >= 2, path.allSatisfy({ $0.syllables != nil }) {
                    usedSentence = true
                    builder.add(IMECandidate(text: sentenceText(path), key: variant,
                                             consumed: query.input.count, kind: .fuzzy))
                }
            }
        }
    }

    /// 猜打错的字母：拼音末尾对不上时，试着换成键盘上相邻的字母，或者交换相邻两个字母。
    ///
    /// 只看末尾这几个字母，换完必须每一段都是完整的拼音才算。不做「删最后一个字母」，
    /// 那只是用户打字的上一步，不算纠错。
    private func adjacentCorrections(query: IMEQuery, path: [Tile]?, dictionary: MoyuDictionary) -> [IMECandidate] {
        guard query.breaks.isEmpty else { return [] }
        let tiles = path ?? []
        if path != nil, !tiles.contains(where: { $0.isLoose }) { return [] }
        let looseIndex = tiles.firstIndex { $0.isLoose } ?? 0
        // 从上一块开始看：wo|zhe|m 要连 zhe 一起看，才能改成 zhen
        let head = Array(tiles.prefix(max(looseIndex - 1, 0)))
        let tail = Array(query.input[(head.last?.end ?? 0)...])
        let vowels = Array("aeiouv".utf8)
        guard tail.count >= 2, tail.count <= 14, tail.contains(where: { vowels.contains($0) }) else { return [] }

        var rows: [(path: [Tile], score: Double, key: String)] = []
        var seen: Set<[UInt8]> = [tail]
        func consider(_ variant: [UInt8]) {
            guard seen.insert(variant).inserted,
                  let solved = solve(query: IMEQuery(mode: .qwerty, input: variant), dictionary: dictionary),
                  !solved.contains(where: { $0.isLoose }) else { return }
            rows.append((solved, solved.reduce(0) { $0 + $1.score }, String(decoding: variant, as: UTF8.self)))
        }
        let window = max(tail.count - 5, 0)
        for position in window..<tail.count {
            for neighbor in Self.adjacentKeys[tail[position]] ?? [] {
                var variant = tail
                variant[position] = neighbor
                consider(variant)
            }
            if position + 1 < tail.count, tail[position] != tail[position + 1] {
                var variant = tail
                variant.swapAt(position, position + 1)
                consider(variant)
            }
        }
        rows.sort { $0.score > $1.score }
        return rows.prefix(2).map { row in
            IMECandidate(text: sentenceText(head + row.path),
                         key: head.map { $0.key }.joined() + row.key,
                         consumed: query.input.count,
                         kind: .corrected)
        }
    }

    /// 打错一个字母：候选很少时试一下。
    private func addCorrections(input: String, query: IMEQuery, dictionary: MoyuDictionary,
                                into builder: inout CandidateBuilder) {
        let corrections = TypoCorrector.correct(input, knownInitials: { dictionary.hasKey($0) }, limit: 3)
        for correction in corrections {
            for index in dictionary.exactRange(Array(correction.corrected.utf8)) {
                for entry in dictionary.entries(key: index, limit: 3) where entry.isWord {
                    builder.add(IMECandidate(text: entry.text, key: correction.corrected,
                                             consumed: query.input.count, kind: .corrected))
                }
            }
        }
    }

    // MARK: - 显示用的拼音

    private func spelling(path: [Tile]?, query: IMEQuery, rawText: String?) -> String {
        guard let path else {
            return rawText ?? String(decoding: query.input, as: UTF8.self)
        }
        var parts: [String] = []
        var position = 0
        for tile in path {
            if let syllables = tile.syllables {
                parts.append(contentsOf: syllables)
            } else if query.mode == .qwerty {
                parts.append(String(decoding: query.input[position..<tile.end], as: UTF8.self))
            } else {
                parts.append(String(tile.key.prefix(tile.end - position)))
            }
            position = tile.end
        }
        return parts.joined(separator: "'")
    }

    /// 九宫格左栏：开头这串数字能打出哪些音节，长的在前。
    private func pinyinChoices(query: IMEQuery, dictionary: MoyuDictionary) -> [String] {
        var result: [String] = []
        let input = query.input
        var length = min(6, input.count)
        while length >= 1 {
            let digits = String(decoding: input[0..<length], as: UTF8.self)
            let syllables = (Self.syllablesByDigits[digits] ?? [])
                .filter { matchesLocks(keyBytes: Array($0.utf8), at: 0, locks: query.locks) }
                .filter { !Self.unlikelySyllables.contains($0) }
                .map { syllable -> (String, Int) in
                    let range = dictionary.exactRange(Array(syllable.utf8))
                    return (syllable, range.map { dictionary.maxFrequency(key: $0) }.max() ?? 0)
                }
                .sorted { $0.1 > $1.1 }
            result.append(contentsOf: syllables.map { $0.0 })
            length -= 1
        }
        return Array(result.prefix(24))
    }

    // MARK: - 学习与联想

    /// 记录一次上屏。
    /// - Parameter segments: 这次上屏由哪几段组成（词 + 拼音）。
    public func learn(segments: [(text: String, key: String)]) {
        learning.record(segments: segments)
    }

    /// 上屏后的下一个词：用户习惯 > 手工整理的常用搭配 > 内置短语 > 从词库推的后半截。
    public func predictions(after text: String, limit: Int) -> [String] {
        var result: [String] = []
        func add(_ words: [String]) {
            for word in words where result.count < limit && word != text && !result.contains(word) {
                result.append(word)
            }
        }
        add(learning.next(after: text, limit: limit))
        add(nextWords.authoredWords(after: text))
        add(suggestions.suggestions(after: text, limit: limit).map { $0.text })
        add(nextWords.compoundWords(after: text))
        return result
    }
}

/// 候选去重收集器。
private struct CandidateBuilder {
    private(set) var candidates: [IMECandidate] = []
    private var seen: Set<String> = []
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    /// 非原文候选的数量。
    var wordCount: Int { candidates.filter { $0.kind != .raw }.count }

    /// 插到指定位置；已经有同样的词就不动。
    mutating func insert(_ candidate: IMECandidate, at index: Int) {
        guard !candidate.text.isEmpty, seen.insert(candidate.text).inserted else { return }
        candidates.insert(candidate, at: min(index, candidates.count))
    }

    /// 挪到指定位置；还没有就插进去。
    mutating func promote(_ candidate: IMECandidate, to index: Int) {
        guard !candidate.text.isEmpty else { return }
        if let existing = candidates.firstIndex(where: { $0.text == candidate.text }) {
            let item = candidates.remove(at: existing)
            candidates.insert(item, at: min(index, candidates.count))
        } else {
            seen.insert(candidate.text)
            candidates.insert(candidate, at: min(index, candidates.count))
        }
    }

    mutating func add(_ candidate: IMECandidate) {
        guard candidates.count < limit, !candidate.text.isEmpty else { return }
        if seen.insert(candidate.text).inserted {
            candidates.append(candidate)
        }
    }
}
