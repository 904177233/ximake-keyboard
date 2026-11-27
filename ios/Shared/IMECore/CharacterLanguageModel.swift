import Foundation

/// MCC1，小端定长记录。字符使用 BMP 码位，1/2 是句首和句末，0 是空历史。
final class CharacterLanguageModel {
    private let data: NSData
    private let bytes: UnsafeRawPointer
    private let bigrams: Int
    private let trigrams: Int
    private let biStart = 16 + 65536 * 4
    private let triStart: Int

    init?(url: URL?) {
        guard let url, let file = try? NSData(contentsOf: url, options: .alwaysMapped), file.length >= 16 else { return nil }
        let p = file.bytes
        guard p.load(as: UInt32.self) == 0x3143434d,
              p.load(fromByteOffset: 4, as: UInt32.self) == 65536 else { return nil }
        let b = Int(p.load(fromByteOffset: 8, as: UInt32.self))
        let t = Int(p.load(fromByteOffset: 12, as: UInt32.self))
        guard file.length == 16 + 65536 * 4 + (b + t) * 8 else { return nil }
        bigrams = b
        trigrams = t
        triStart = 16 + 65536 * 4 + b * 8
        data = file
        bytes = p
    }

    private func bi(_ key: UInt32) -> Int? {
        var low = 0, high = bigrams
        while low < high {
            let mid = (low + high) / 2
            let offset = biStart + mid * 8
            let value = bytes.load(fromByteOffset: offset, as: UInt32.self)
            if value == key { return offset }
            if value < key { low = mid + 1 } else { high = mid }
        }
        return nil
    }

    private func tri(_ key: UInt64) -> Int {
        var low = 0, high = trigrams
        while low < high {
            let mid = (low + high) / 2
            let record = bytes.load(fromByteOffset: triStart + mid * 8, as: UInt64.self)
            let value = record >> 16
            if value == key { return Int(record & 65535) }
            if value < key { low = mid + 1 } else { high = mid }
        }
        return 0
    }

    struct State {
        var pair: UInt32 = 1
        var backoff = 0
    }

    @inline(__always) private func q(_ offset: Int) -> Int {
        Int(bytes.load(fromByteOffset: offset, as: Int16.self))
    }

    private func advance(_ state: inout State, _ char: UInt32) -> Int {
        let prev = state.pair & 65535
        let pair = prev << 16 | char
        let entry = bi(pair)
        let lift = entry.map { q($0 + 4) } ?? 0
        let key = UInt64(state.pair) << 16 | UInt64(char)
        let score = q(16 + Int(char) * 4) + q(18 + Int(prev) * 4) + state.backoff + lift + tri(key)
        state.pair = pair
        state.backoff = entry.map { q($0 + 6) } ?? 0
        return score
    }

    /// 键是最近三个码位，每次转换结束后释放。词模型已有一元先验，
    /// 全拼只保留半份字频；稀疏的历史最多在一元底分上再扣 2 个自然对数单位。
    struct Step {
        let state: State
        let conditional: Int
        let residual: Double
    }

    func append(_ text: String, final: Bool, state: inout State, cache: inout [UInt64: Step],
                residual: Bool) -> Double {
        var score = 0.0
        func consume(_ c: UInt32) {
            let key = UInt64(state.pair) << 16 | UInt64(c)
            let step: Step
            if let cached = cache[key] {
                step = cached
            } else {
                let logP = advance(&state, c)
                let unigram = q(16 + Int(c) * 4)
                let bounded = max(unigram - 512, logP)
                step = Step(state: state, conditional: logP, residual: Double(bounded) - 0.5 * Double(unigram))
                cache[key] = step
            }
            state = step.state
            score += residual ? step.residual : Double(step.conditional)
        }
        for scalar in text.unicodeScalars { consume(min(scalar.value, 65535)) }
        if final { consume(2) }
        return score / 256
    }
}
