import Foundation
import CoreGraphics
import Dispatch

/// 固定 SplitMix64 和 Box–Muller，旧、新键区收到逐点相同的轨迹。
private struct TouchNoise {
    var state: UInt64 = 87
    mutating func uniform() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return (Double(z >> 11) + 0.5) / 9_007_199_254_740_992
    }

    mutating func pair() -> (Double, Double) {
        let radius = sqrt(-2 * log(uniform()))
        let angle = 2 * Double.pi * uniform()
        return (radius * cos(angle), radius * sin(angle))
    }
}

func runTouchBenchmark(dictionary: MoyuDictionary, resources: URL, corpus: URL) throws {
    let engine = PinyinEngine(dictionary: dictionary, learning: UserLearningStore(store: SharedStore(forceMemory: true)),
                              nextWords: NextWordIndex(url: resources.appendingPathComponent("next.tsv")))
    engine.hotWords = HotWordStore(url: resources.appendingPathComponent("hot_words.tsv"))
    let source = try String(contentsOf: corpus, encoding: .utf8)
    var sentences: [(String, String)] = []
    for line in source.components(separatedBy: .newlines) {
        let f = line.components(separatedBy: "\t")
        if f.count == 5, f[0] == "短句" || f[0] == "长句" {
            sentences.append((f[1], f[3]))
        }
    }
    check("触点回放覆盖全部短句和长句", sentences.count == 83)
    let zh = KeyHitContext(input: Array("zh".utf8))
    check("zh 可接 a、不可接 s", zh.permits("a") && !zh.permits("s"))
    check("分隔后从新音节起算", KeyHitContext(input: Array("zh".utf8), breaks: [2]).letters == 0)
    check("轻点漂移 15 pt 保留按下的键", !KeyHitResolver.canSlide(from: .zero, to: CGPoint(x: 9, y: 12), keyWidth: 34))
    check("滑过半个键宽可以换键", KeyHitResolver.canSlide(from: .zero, to: CGPoint(x: 20, y: 0), keyWidth: 34))

    func matches(_ bytes: [UInt8], _ expected: String, interrupted: Bool) -> Int {
        if interrupted { return 0 }
        let query = IMEQuery(mode: .qwerty, input: bytes)
        let raw = String(decoding: bytes, as: UTF8.self)
        let top = engine.convert(query, rawText: raw).candidates.first
        return top?.consumed == bytes.count && top?.text == expected ? 1 : 0
    }
    let metrics = KeyboardMetrics(height: .standard, isLandscape: false)
    var rng = TouchNoise()
    var total = 0, oldErrors = 0, newErrors = 0, oldHits = 0, newHits = 0
    var hitTimes: [UInt64] = [], contextTimes: [UInt64] = []
    for (wi, width) in [390, 393, 430].enumerated() {
        let size = CGSize(width: CGFloat(width), height: metrics.surfaceHeight)
        let keys = KeyLayoutBuilder.build(state: KeyboardVisualState(), size: size, metrics: metrics).keys
        var caps: [UInt8: CGRect] = [:]
        var centersOK = true
        for i in keys.indices {
            let f = keys[i].frame
            if case let .letter(c) = keys[i].action, let b = c.asciiValue { caps[b] = f }
            let point = CGPoint(x: f.midX, y: f.midY)
            if KeyHitResolver.resolve(point, keys: keys, gaps: metrics.keyGaps, context: zh, protectsEnglish: { _ in false }) != i {
                centersOK = false
            }
        }
        check("全部键中心按几何命中（\(width) pt）", centersOK)
        guard let a = caps[97], let s = caps[115] else { throw CocoaError(.fileReadCorruptFile) }
        let edge = CGPoint(x: (a.maxX + s.minX) / 2 + 0.3, y: s.midY)
        func picked(_ context: KeyHitContext, _ protect: (String) -> Bool) -> KeyAction? {
            guard let i = KeyHitResolver.resolve(edge, keys: keys, gaps: metrics.keyGaps,
                                                 context: context, protectsEnglish: protect) else { return nil }
            return keys[i].action
        }
        check("中文边界 zh 选择 a", picked(zh, engine.english.hasWordPrefix) == .letter("a"))
        check("英文模式边界走几何", picked(.empty, engine.english.hasWordPrefix) == .letter("s"))
        let afterB = KeyHitContext(input: Array("b".utf8))
        check("拼音 b 后边界偏向 a", picked(afterB, { _ in false }) == .letter("a"))
        check("可续英文 bsc 时保留 s", picked(afterB, engine.english.hasWordPrefix) == .letter("s"))
        var before = 0, after = 0, oldRight = 0, newRight = 0, letters = 0
        for (ri, row) in sentences.enumerated() {
            let sigma = [0.25, 0.30, 0.35][(ri + wi) % 3]
            var old: [UInt8] = [], new: [UInt8] = []
            var oldInterrupted = false, newInterrupted = false
            for b in row.0.utf8 {
                guard let f = caps[b] else { throw CocoaError(.fileReadCorruptFile) }
                let noise = rng.pair()
                let deviation = f.width * CGFloat(sigma)
                let point = CGPoint(x: f.midX + CGFloat(noise.0) * deviation,
                                    y: f.midY + CGFloat(noise.1) * deviation + 3)
                let oi = KeyHitResolver.geometric(point, keys: keys)
                let prepare = DispatchTime.now().uptimeNanoseconds
                let context = KeyHitContext(input: new)
                let begin = DispatchTime.now().uptimeNanoseconds
                let ni = KeyHitResolver.resolve(point, keys: keys, gaps: metrics.keyGaps, context: context,
                                                protectsEnglish: engine.english.hasWordPrefix)
                let end = DispatchTime.now().uptimeNanoseconds
                hitTimes.append(end - begin)
                contextTimes.append(begin - prepare)
                func append(_ i: Int?, _ input: inout [UInt8], _ interrupted: inout Bool) -> Int {
                    guard let i, case let .letter(c) = keys[i].action, let byte = c.asciiValue else {
                        interrupted = true
                        input.removeAll(keepingCapacity: true)
                        return 1
                    }
                    input.append(byte)
                    return byte == b ? 0 : 1
                }
                before += append(oi, &old, &oldInterrupted)
                after += append(ni, &new, &newInterrupted)
                letters += 1
            }
            oldRight += matches(old, row.1, interrupted: oldInterrupted)
            newRight += matches(new, row.1, interrupted: newInterrupted)
        }
        print("  \(width) pt 字母错误 \(before) → \(after) / \(letters)，整句首选 \(oldRight) → \(newRight) / \(sentences.count)")
        total += letters
        oldErrors += before
        newErrors += after
        oldHits += oldRight
        newHits += newRight
    }
    print(String(format: "  触点合计 字母错误率 %.2f%% → %.2f%%，整句首选率 %.2f%% → %.2f%%",
                 100 * Double(oldErrors) / Double(total), 100 * Double(newErrors) / Double(total),
                 100 * Double(oldHits) / Double(sentences.count * 3), 100 * Double(newHits) / Double(sentences.count * 3)))
    guard total > 0 else { throw CocoaError(.fileReadCorruptFile) }
    let p95 = (total * 95 + 99) / 100 - 1
    hitTimes.sort()
    contextTimes.sort()
    let hitP95 = Double(hitTimes[p95]) / 1000
    let contextP95 = Double(contextTimes[p95]) / 1000
    print(String(format: "  按下命中 P95 %.2f 微秒，组字前缀准备 P95 %.2f 微秒", hitP95, contextP95))
    check("按下命中 P95 在 50 微秒内", hitP95 < 50)
    check("含噪触点的字母错误数不增加", newErrors <= oldErrors)
    check("含噪触点的整句首选数不减少", newHits >= oldHits)
}
