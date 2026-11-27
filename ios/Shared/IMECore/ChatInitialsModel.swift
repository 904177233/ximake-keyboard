import Foundation

/// MCB1：排序的简拼词表、整数词 ID 二元组、UTF-8 字符串池。只访问命中的页。
final class ChatInitialsModel {
    private let data: NSData
    private let words: Int
    private let edges: Int
    private let edgeStart: Int
    private let blob: Int

    init?(url: URL?) {
        guard let url, let data = try? NSData(contentsOf: url, options: .alwaysMapped),
              data.length >= 16 else { return nil }
        let p = data.bytes
        guard p.load(as: UInt32.self) == 0x3142434D else { return nil }
        words = Int(p.load(fromByteOffset: 4, as: UInt32.self))
        edges = Int(p.load(fromByteOffset: 8, as: UInt32.self))
        edgeStart = 16 + words * 12
        blob = edgeStart + edges * 12
        guard blob + Int(p.load(fromByteOffset: 12, as: UInt32.self)) == data.length else { return nil }
        self.data = data
    }

    private func id(_ position: Int) -> Int {
        Int(data.bytes.load(fromByteOffset: position, as: UInt32.self))
    }

    private func byte(_ position: Int) -> Int {
        Int(data.bytes.load(fromByteOffset: position, as: UInt8.self))
    }

    private func compare(_ row: Int, _ key: ArraySlice<UInt8>) -> Int {
        let record = 16 + row * 12
        let length = byte(record + 10)
        let offset = blob + id(record)
        guard offset + length < data.length else { return 1 }
        for i in 0..<min(length, key.count) {
            let difference = byte(offset + i) - Int(key[key.startIndex + i])
            if difference != 0 { return difference }
        }
        return length - key.count
    }

    private func lift(_ left: Int, _ right: Int) -> Int {
        var lo = 0, hi = edges
        while lo < hi {
            let mid = (lo + hi) / 2
            let p = edgeStart + 12 * mid
            let a = id(p), b = id(p + 4)
            if a == left && b == right { return Int(data.bytes.load(fromByteOffset: p + 8, as: Int8.self)) }
            if a < left || (a == left && b < right) { lo = mid + 1 } else { hi = mid }
        }
        return -36
    }

    func candidates(_ input: [UInt8], languageModel: LibimeLanguageModel?) -> [IMECandidate] {
        struct Path {
            let score: Int
            let id: Int
            let segments: [IMEWordSegment]
        }
        var states = [[Path]](repeating: [], count: input.count + 1)
        states[0] = [Path(score: 0, id: 0, segments: [])]
        let buffer = UnsafeRawBufferPointer(start: data.bytes, count: data.length)
        for start in input.indices where !states[start].isEmpty {
            for end in (start + 1)...min(start + 8, input.count) {
                let key = input[start..<end]
                var lo = 0, hi = words
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if compare(mid, key) < 0 { lo = mid + 1 } else { hi = mid }
                }
                var row = lo
                while row < words && compare(row, key) == 0 {
                    let record = 16 + row * 12
                    row += 1
                    let wid = id(record + 4)
                    let q = Int(data.bytes.load(fromByteOffset: record + 8, as: Int16.self))
                    let first = blob + id(record) + key.count
                    let last = first + byte(record + 11)
                    guard last < buffer.count,
                          let nul = buffer[last..<min(buffer.count, last + 50)].firstIndex(of: 0) else { continue }
                    let segment = IMEWordSegment(text: String(decoding: buffer[first..<last], as: UTF8.self),
                                                 key: String(decoding: buffer[last..<nul], as: UTF8.self), consumed: key.count)
                    let ending = end == input.count ? lift(wid, 0) : 0
                    for path in states[start] {
                        // 公分母 48，以整数比较 log P(w) + log P(w|前词)/P(w)。
                        let score = path.score + 3 * q + 4 * (lift(path.id, wid) + ending)
                        let limit = end == input.count ? 24 : 8
                        if states[end].count == limit, let worst = states[end].last, score <= worst.score { continue }
                        let pos = states[end].firstIndex { $0.score < score } ?? states[end].count
                        states[end].insert(Path(score: score, id: wid, segments: path.segments + [segment]), at: pos)
                        if states[end].count > limit { states[end].removeLast() }
                    }
                }
            }
        }
        let original = states[input.count]
        var finalists = original
        if let model = languageModel {
            // 原模型保留口语召回池；只对最终的 24 条路径查通用三元概率。
            finalists = finalists.enumerated().map { item -> (Int, Double, Path) in
                var older = -1, previous = -1
                var score = Double(item.element.score)
                for segment in item.element.segments {
                    let id = model.id(segment.text)
                    score += 48 * model.feature(model.history(older, previous), id)
                    older = previous
                    previous = id
                }
                return (item.offset, score, item.element)
            }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.map { $0.2 }
        }
        let ordered: [Path]
        if languageModel != nil {
            var naturalTexts: Set<String> = []
            let natural = original.filter { naturalTexts.insert($0.segments.map(\.text).joined()).inserted }
            ordered = Array(finalists.prefix(1)) + Array(natural.prefix(2)) + Array(finalists.dropFirst())
        } else {
            ordered = finalists
        }
        var seen: Set<String> = []
        var result: [IMECandidate] = []
        for path in ordered {
            let text = path.segments.map(\.text).joined()
            if seen.insert(text).inserted {
                result.append(IMECandidate(text: text, key: path.segments.map(\.key).joined(), consumed: input.count,
                                           kind: .sentence, segments: path.segments))
                if result.count == 3 { break }
            }
        }
        return result
    }
}
