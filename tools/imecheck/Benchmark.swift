import Foundation

private struct BenchRow: Codable {
    let category: String
    let input: String
    let left: String
    let expected: String
    let rank: Int
    let naturalRank: Int
    let top: [String]
    let kinds: [String]
    let correctedAtTarget: Bool
}

/// 三版共用此驱动；基线只编译当时引擎已实现的公开接口。
func runBenchmark(dictionary: MoyuDictionary, resources: URL, corpus: URL, blind: URL, output: URL) throws {
    let engine = PinyinEngine(dictionary: dictionary, learning: UserLearningStore(store: SharedStore(forceMemory: true)),
                              nextWords: NextWordIndex(url: resources.appendingPathComponent("next.tsv")))
    engine.hotWords = HotWordStore(url: resources.appendingPathComponent("hot_words.tsv"))
    #if !HISTORICAL
    engine.english = EnglishLexicon(url: resources.appendingPathComponent("en_words.tsv"))
    #endif
    var results: [BenchRow] = []
    for file in [corpus, blind] {
        let source = try String(contentsOf: file, encoding: .utf8)
        for line in source.components(separatedBy: .newlines) where !line.isEmpty && !line.hasPrefix("#") {
            let f = line.components(separatedBy: "\t")
            guard f.count == 5 else { throw CocoaError(.fileReadCorruptFile) }
            let category = file == blind ? "冻结长句盲集" : f[0]
            let digits = f[0] == "九宫格" || f[0] == "t9"
            let left = f[2] == "-" ? "" : f[2]
            var bytes: [UInt8] = [], breaks: Set<Int> = []
            for byte in f[1].utf8 {
                if byte == 39 { breaks.insert(bytes.count) } else { bytes.append(byte) }
            }
            var query = IMEQuery(mode: digits ? .t9 : .qwerty, input: bytes, breaks: breaks)
            #if !LEGACY_QUERY
            query.leftContext = left.isEmpty ? nil : left
            #endif
            let raw = digits ? nil : String(decoding: bytes, as: UTF8.self)
            func run(_ enable: Bool) -> [IMECandidate] {
                engine.convert(query, rawText: raw, fuzzy: .off, typoCorrection: enable).candidates
            }
            func rank(_ list: [IMECandidate]) -> Int {
                guard let index = list.firstIndex(where: {
                    $0.text == f[3] && $0.consumed == bytes.count
                }) else { return 0 }
                return index + 1
            }
            let on = run(true)
            let hit = rank(on)
            results.append(BenchRow(category: category, input: f[1], left: left, expected: f[3],
                                    rank: hit, naturalRank: digits ? hit : rank(run(false)),
                                    top: on.prefix(5).map(\.text), kinds: on.prefix(5).map { $0.kind.rawValue },
                                    correctedAtTarget: hit > 0 && on[hit - 1].kind == .corrected))
        }
    }
    let groups = Dictionary(grouping: results, by: \.category)
    for name in groups.keys.sorted() {
        let rows = groups[name] ?? []
        let first = rows.filter { $0.rank == 1 }.count
        let second = rows.filter { $0.rank == 2 }.count
        let three = rows.filter { (1...3).contains($0.rank) }.count
        print("\(name) 共 \(rows.count)，首选 \(first)，恰在第二 \(second)，前三 \(three)")
        for row in rows.filter({ $0.rank != 1 }).prefix(15) {
            print("  \(row.left) | \(row.input) → \(row.expected)，名次 \(row.rank)，前五 \(row.top)")
        }
    }
    try JSONEncoder().encode(results).write(to: output, options: .atomic)
}
