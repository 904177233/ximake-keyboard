import Foundation

/// MLM1 的 ID 是 UTF-8 指纹在排序表中的下标。所有定长数组的起始地址自然对齐。
final class LibimeLanguageModel {
    private let storage: NSData
    private let base: UnsafeRawPointer
    private let words: Int
    private let unknown: Int
    private let tails: Int
    private let biRows: Int
    private let triRows: Int
    private let last: Int
    private let unigram: Int
    private let uniBack: Int
    private let bigram: Int
    private let biBack: Int
    private let trigram: Int

    init?(url: URL?) {
        guard let url, let file = try? NSData(contentsOf: url, options: .alwaysMapped),
              file.length >= 32 else { return nil }
        let p = file.bytes
        func field(_ offset: Int) -> Int { Int(p.load(fromByteOffset: offset, as: UInt32.self)) }
        let n = field(4), b = field(8), t = field(12), unk = field(16)
        guard field(0) == 0x314D4C4D, field(20) == 21, field(24) == 16, field(28) == 0,
              unk < n, n < (1 << 21), file.length == 40 + 18 * n + 6 * b + 9 * t else { return nil }
        words = n
        unknown = unk
        storage = file
        base = p
        tails = 32 + 8 * n
        biRows = tails + 8 * t
        triRows = biRows + 4 * (n + 1)
        last = triRows + 4 * (n + 1)
        unigram = last + 4 * b
        uniBack = unigram + n
        bigram = uniBack + n
        biBack = bigram + b
        trigram = biBack + b
        guard field(biRows) == 0, field(triRows) == 0,
              field(biRows + 4 * n) == b, field(triRows + 4 * n) == t else { return nil }
    }

    /// 每个词块在进入搜索前查一次 ID，多个前驱共用。
    func id(_ word: String) -> Int {
        var hash: UInt64 = 14695981039346656037
        for byte in word.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        var lo = 0, hi = words
        while lo < hi {
            let mid = (lo + hi) / 2
            let value = base.load(fromByteOffset: 32 + mid * 8, as: UInt64.self)
            if value == hash { return mid }
            if value < hash { lo = mid + 1 } else { hi = mid }
        }
        return unknown
    }

    @inline(__always) private func find<T: FixedWidthInteger>(_ key: T, row: Int, rows: Int, keys: Int, count: Int) -> Int? {
        var lo = Int(base.load(fromByteOffset: rows + 4 * row, as: UInt32.self))
        var hi = Int(base.load(fromByteOffset: rows + 4 * (row + 1), as: UInt32.self))
        guard hi <= count else { return nil }
        while lo < hi {
            let mid = (lo + hi) / 2
            let value = base.load(fromByteOffset: keys + MemoryLayout<T>.stride * mid, as: T.self)
            if value == key { return mid }
            if value < key { lo = mid + 1 } else { hi = mid }
        }
        return nil
    }

    @inline(__always) private func q(_ offset: Int) -> Double {
        Double(base.load(fromByteOffset: offset, as: Int8.self)) / 16
    }

    struct History {
        let older: Int
        let previous: Int
        let backoff: Double
    }

    /// 同一个前驱的所有出边共用历史二元的回退值。
    func history(_ older: Int, _ previous: Int) -> History {
        var backoff = 0.0
        if older >= 0, previous >= 0,
           let i = find(UInt32(previous), row: older, rows: biRows, keys: last, count: biBack - bigram) {
            backoff = q(biBack + i)
        }
        return History(older: older, previous: previous, backoff: backoff)
    }

    /// 剪掉的三元项回退到历史二元的权重和较短条件概率，二元同理。
    func probability(_ history: History, _ word: Int) -> Double {
        let previous = history.previous
        guard previous >= 0 else { return q(unigram + word) }
        if history.older >= 0 {
            let key = UInt64(previous) << 21 | UInt64(word)
            if let i = find(key, row: history.older, rows: triRows, keys: tails, count: (biRows - tails) / 8) {
                return q(trigram + i)
            }
        }
        if let i = find(UInt32(word), row: previous, rows: biRows, keys: last, count: biBack - bigram) {
            return history.backoff + q(bigram + i)
        }
        return history.backoff + q(uniBack + previous) + q(unigram + word)
    }

    /// 词典已经给出无上下文词频。限制高频搭配的提升，保留部分语言模型的一元先验。
    func feature(_ history: History, _ word: Int) -> Double {
        guard history.previous >= 0 else { return 0 }
        let uni = q(unigram + word)
        return min(2.5, probability(history, word) - uni) + 0.25 * (uni + 4)
    }
}
