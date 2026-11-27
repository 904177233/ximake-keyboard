import Foundation
import CoreGraphics

/// 对可达的音节尾部求并集。每次组字更新算一次，触摸时按位查询。
struct KeyHitContext {
    let letters: UInt32
    let englishPrefix: String?
    static let empty = KeyHitContext(letters: 0, englishPrefix: nil)

    private init(letters: UInt32, englishPrefix: String?) {
        self.letters = letters
        self.englishPrefix = englishPrefix
    }

    private struct Prefix {
        var next: UInt32 = 0
        var complete = false
    }

    private static let prefixes: [UInt32: Prefix] = {
        var table: [UInt32: Prefix] = [:]
        for word in PinyinSyllables.all where !PinyinEngine.unlikelySyllables.contains(word) {
            guard word.utf8.allSatisfy({ (97...122).contains($0) }) else { continue }
            var code: UInt32 = 0
            for byte in word.utf8 {
                let letter = UInt32(byte - 97)
                table[code, default: Prefix()].next |= 1 << letter
                code = (code << 5) | (letter + 1)
            }
            table[code, default: Prefix()].complete = true
        }
        return table
    }()

    init(input: [UInt8], breaks: Set<Int> = []) {
        let start = breaks.max() ?? 0
        guard start >= 0, start < input.count else { self = .empty; return }
        var reached = [Bool](repeating: false, count: input.count - start + 1)
        reached[0] = true
        var mask: UInt32 = 0
        for i in start..<input.count where reached[i - start] {
            var code: UInt32 = 0
            for j in i..<min(i + PinyinSyllables.maxLength, input.count) {
                let byte = input[j]
                guard (97...122).contains(byte) else { break }
                code = (code << 5) | UInt32(byte - 96)
                guard let prefix = Self.prefixes[code] else { break }
                if prefix.complete { reached[j + 1 - start] = true }
                if j + 1 == input.count { mask |= prefix.next }
            }
        }
        if reached[input.count - start] { mask |= Self.prefixes[0]?.next ?? 0 }
        letters = mask
        englishPrefix = breaks.isEmpty && input.count < 32 && mask != 0 ? String(decoding: input, as: UTF8.self) : nil
    }

    func permits(_ c: Character) -> Bool {
        guard let byte = c.asciiValue, (97...122).contains(byte) else { return false }
        return letters & (1 << UInt32(byte - 97)) != 0
    }
}

enum KeyHitResolver {
    static func geometric(_ point: CGPoint, keys: [KeyDef]) -> Int? {
        var best: Int?
        var distance = CGFloat.greatestFiniteMagnitude
        for i in keys.indices {
            let f = keys[i].frame
            if f.contains(point) { return i }
            let dx = max(f.minX - point.x, 0, point.x - f.maxX)
            let dy = max(f.minY - point.y, 0, point.y - f.maxY)
            let d = dx * dx + dy * dy
            if d < distance {
                distance = d
                best = i
            }
        }
        return best
    }

    static func resolve(_ point: CGPoint, keys: [KeyDef], gaps: CGSize, context: KeyHitContext,
                        protectsEnglish: (String) -> Bool) -> Int? {
        guard let old = geometric(point, keys: keys) else { return nil }
        let frame = keys[old].frame
        guard context.letters != 0, case let .letter(original) = keys[old].action,
              !frame.insetBy(dx: frame.width * 0.20, dy: frame.height * 0.20).contains(point)
        else { return old }

        // 在靠边的字母键之间，用键距归一化，避免横屏宽键改变纵向偏置。
        let pitchX = frame.width + gaps.width
        let pitchY = frame.height + gaps.height
        func distance(_ f: CGRect) -> CGFloat {
            let dx = (point.x - f.midX) / pitchX
            let dy = (point.y - 2 - f.midY) / pitchY
            return dx * dx + dy * dy
        }
        var best = old
        var lowest = distance(frame) - (context.permits(original) ? 0.24 : 0)
        for i in keys.indices where i != old {
            let f = keys[i].frame
            guard case let .letter(c) = keys[i].action,
                  abs(point.x - f.midX) <= pitchX * 0.78,
                  abs(point.y - f.midY) <= pitchY * 0.78 else { continue }
            let score = distance(f) - (context.permits(c) ? 0.24 : 0)
            if score < lowest {
                lowest = score
                best = i
            }
        }
        if best != old, let prefix = context.englishPrefix, protectsEnglish(prefix + String(original)) { return old }
        return best
    }

    static func canSlide(from start: CGPoint, to point: CGPoint, keyWidth: CGFloat) -> Bool {
        let dx = point.x - start.x, dy = point.y - start.y
        let threshold = max(16, min(24, keyWidth * 0.52))
        return dx * dx + dy * dy >= threshold * threshold
    }
}
