//
//  MoyuDictionary.swift
//  墨语 · 输入法内核
//
//  读取 tools/dict/build_binary.py 生成的 moyu.dict。
//
//  文件用内存映射打开：不解析、不建哈希表，读到哪页系统才加载哪页，而且这些页是干净页，
//  内存紧张时系统可以直接丢弃。所以词库扩到十万级也不会把键盘撑到被杀。
//  文件格式写在 build_binary.py 开头，两边改动必须同步。
//

import Foundation

/// 只读词库（线程安全：初始化后没有可变状态）。
public final class MoyuDictionary: @unchecked Sendable {

    /// 一条词。
    public struct Entry: Sendable, Equatable {
        public let text: String
        public let frequency: Int
        public let flags: UInt8

        public var isEmoji: Bool { flags & 1 != 0 }
        public var isPunctuation: Bool { flags & 2 != 0 }
        public var isChat: Bool { flags & 4 != 0 }
        public var isASCII: Bool { flags & 8 != 0 }

        /// 能不能用来拼句子（表情、标点、英文都不行）。
        public var isWord: Bool { flags & 0b1011 == 0 }

        /// 聊天权重 0...3，只影响简拼排序。
        public var chatWeight: Double { Double(flags >> 4) / 5.0 }
    }

    private static let keyRecordSize = 20
    private static let entryRecordSize = 12

    private let storage: NSData
    private let base: UnsafeRawPointer
    private let offKeys: Int
    private let offEntries: Int
    private let offT9Perm: Int
    private let offInitPerm: Int
    private let offT9InitPerm: Int
    private let offBlob: Int

    /// 词条总数。
    public let entryCount: Int
    /// 拼音键总数。
    public let keyCount: Int
    private let t9PermCount: Int
    private let initPermCount: Int
    private let t9InitPermCount: Int

    /// 九宫格映射：字母 -> 数字字符，下标是字母的 ASCII。
    private static let t9Table: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 128)
        let groups = ["abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"]
        for (index, group) in groups.enumerated() {
            for byte in group.utf8 {
                table[Int(byte)] = UInt8(ascii: "2") + UInt8(index)
            }
        }
        return table
    }()

    /// 进程内共享实例；词库文件缺失时为 nil（键盘仍能打英文和符号）。
    public static let shared: MoyuDictionary? = {
        for url in candidateURLs() {
            if let dictionary = MoyuDictionary(url: url) {
                return dictionary
            }
        }
        return nil
    }()

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        for bundle in [Bundle.main, Bundle(for: MoyuDictionary.self)] {
            if let url = bundle.url(forResource: "moyu", withExtension: "dict", subdirectory: "dict") {
                urls.append(url)
            }
            if let root = bundle.resourceURL {
                urls.append(root.appendingPathComponent("dict/moyu.dict"))
            }
        }
        return urls
    }

    /// 打开词库文件。
    /// - Parameter url: moyu.dict 的路径；文件不存在或格式不对时返回 nil。
    public init?(url: URL) {
        guard let data = try? NSData(contentsOf: url, options: .alwaysMapped), data.length >= 64 else {
            return nil
        }
        let pointer = data.bytes
        guard pointer.load(as: UInt32.self) == 0x3344_594D else { return nil } // "MYD3"
        func header(_ index: Int) -> Int {
            Int(pointer.load(fromByteOffset: 4 + index * 4, as: UInt32.self))
        }
        guard header(0) == 1 else { return nil }
        storage = data
        base = pointer
        entryCount = header(1)
        keyCount = header(2)
        offKeys = header(3)
        offEntries = header(4)
        offT9Perm = header(5)
        offInitPerm = header(6)
        offT9InitPerm = header(7)
        offBlob = header(8)
        t9PermCount = header(9)
        initPermCount = header(10)
        t9InitPermCount = header(11)
    }

    // MARK: - 键表字段

    @inline(__always) private func keyField32(_ index: Int, _ offset: Int) -> Int {
        Int(base.load(fromByteOffset: offKeys + index * Self.keyRecordSize + offset, as: UInt32.self))
    }

    /// 键的最高词频（键下标 -> 词频）。
    @inline(__always) public func maxFrequency(key index: Int) -> Int { keyField32(index, 8) }

    /// 音节起始位掩码。
    @inline(__always) public func syllableMask(key index: Int) -> UInt32 { UInt32(truncatingIfNeeded: keyField32(index, 12)) }

    @inline(__always) private func entryCount(key index: Int) -> Int {
        Int(base.load(fromByteOffset: offKeys + index * Self.keyRecordSize + 16, as: UInt16.self))
    }

    /// 拼音键的字节数。
    @inline(__always) public func keyLength(key index: Int) -> Int {
        Int(base.load(fromByteOffset: offKeys + index * Self.keyRecordSize + 18, as: UInt8.self))
    }

    /// 音节数。
    @inline(__always) public func syllableCount(key index: Int) -> Int {
        Int(base.load(fromByteOffset: offKeys + index * Self.keyRecordSize + 19, as: UInt8.self))
    }

    @inline(__always) private func keyByte(_ index: Int, _ position: Int) -> UInt8 {
        base.load(fromByteOffset: offBlob + keyField32(index, 0) + position, as: UInt8.self)
    }

    /// 取拼音键字符串。
    public func keyString(key index: Int) -> String {
        let pointer = base.advanced(by: offBlob + keyField32(index, 0))
        let buffer = UnsafeRawBufferPointer(start: pointer, count: keyLength(key: index))
        return String(decoding: buffer, as: UTF8.self)
    }

    /// 把拼音键切成音节（比如 wo'men）。
    public func syllables(key index: Int) -> [String] {
        let key = Array(keyString(key: index).utf8)
        let mask = syllableMask(key: index)
        guard mask != 0 else { return [String(decoding: key, as: UTF8.self)] }
        var result: [String] = []
        var start = 0
        for position in 1..<max(key.count, 1) + 1 {
            let isBoundary = position == key.count || (position < 32 && mask >> UInt32(position) & 1 == 1)
            if isBoundary {
                result.append(String(decoding: key[start..<position], as: UTF8.self))
                start = position
                if position == key.count { break }
            }
        }
        return result
    }

    // MARK: - 词条

    /// 取某个键下的第 i 条词（按词频降序）。
    public func entry(key index: Int, at position: Int) -> Entry? {
        guard position >= 0, position < entryCount(key: index) else { return nil }
        let record = offEntries + (keyField32(index, 4) + position) * Self.entryRecordSize
        let textOffset = Int(base.load(fromByteOffset: record, as: UInt32.self))
        let frequency = Int(base.load(fromByteOffset: record + 4, as: UInt32.self))
        let length = Int(base.load(fromByteOffset: record + 8, as: UInt8.self))
        let flags = base.load(fromByteOffset: record + 9, as: UInt8.self)
        let pointer = base.advanced(by: offBlob + textOffset)
        let text = String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
        return Entry(text: text, frequency: frequency, flags: flags)
    }

    /// 某个键下的词（按词频降序）。
    public func entries(key index: Int, limit: Int) -> [Entry] {
        let count = min(entryCount(key: index), limit)
        guard count > 0 else { return [] }
        return (0..<count).compactMap { entry(key: index, at: $0) }
    }

    // MARK: - 按拼音查

    /// 在 `range` 内按第 `depth` 个字母继续收窄。要求 range 内的键前 depth 个字母都相同。
    ///
    /// 逐字母收窄比每次从头二分快得多，还能在没有任何键匹配时立刻停止扩展。
    public func narrow(_ range: Range<Int>, depth: Int, byte: UInt8) -> Range<Int> {
        var low = range.lowerBound
        var high = range.upperBound
        while low < high {
            let middle = (low + high) / 2
            if keyLength(key: middle) <= depth || keyByte(middle, depth) < byte {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let start = low
        high = range.upperBound
        while low < high {
            let middle = (low + high) / 2
            if keyLength(key: middle) > depth, keyByte(middle, depth) > byte {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return start..<low
    }

    /// 所有以 `prefix` 开头的键。
    public func prefixRange(_ prefix: [UInt8]) -> Range<Int> {
        var range = 0..<keyCount
        for (depth, byte) in prefix.enumerated() {
            range = narrow(range, depth: depth, byte: byte)
            if range.isEmpty { return range }
        }
        return range
    }

    /// 和 `key` 完全相同的键（同一个串可能有多种音节切法，所以是个范围）。
    public func exactRange(_ key: [UInt8]) -> Range<Int> {
        let range = prefixRange(key)
        var end = range.lowerBound
        while end < range.upperBound, keyLength(key: end) == key.count {
            end += 1
        }
        return range.lowerBound..<end
    }

    /// 字符串版本的完全匹配，供模糊音和纠错用。
    public func hasKey(_ key: String) -> Bool {
        !exactRange(Array(key.utf8)).isEmpty
    }

    // MARK: - 按九宫格 / 首字母查

    /// 排列表的下标 -> 键下标。
    @inline(__always) private func perm(_ section: Int, _ position: Int) -> Int {
        Int(base.load(fromByteOffset: section + position * 4, as: UInt32.self))
    }

    /// 比较键的「投影」和目标串。投影由 projector 给出第 n 个字节，nil 表示结束。
    @inline(__always)
    private func compare(_ target: [UInt8], prefixOnly: Bool, project: (Int) -> UInt8?) -> Int {
        var position = 0
        while position < target.count {
            guard let byte = project(position) else { return -1 }
            if byte != target[position] { return byte < target[position] ? -1 : 1 }
            position += 1
        }
        if prefixOnly { return 0 }
        return project(position) == nil ? 0 : 1
    }

    private func t9Projection(_ keyIndex: Int, _ position: Int) -> UInt8? {
        guard position < keyLength(key: keyIndex) else { return nil }
        return Self.t9Table[Int(keyByte(keyIndex, position)) & 0x7F]
    }

    /// 第 n 个音节的首字母。
    private func initialProjection(_ keyIndex: Int, _ nth: Int, digits: Bool) -> UInt8? {
        var mask = syllableMask(key: keyIndex)
        var remaining = nth
        var position = 0
        let length = min(keyLength(key: keyIndex), 32)
        while position < length {
            if mask & 1 == 1 {
                if remaining == 0 {
                    let byte = keyByte(keyIndex, position)
                    return digits ? Self.t9Table[Int(byte) & 0x7F] : byte
                }
                remaining -= 1
            }
            mask >>= 1
            position += 1
        }
        return nil
    }

    private func search(section: Int, count: Int, target: [UInt8], prefixOnly: Bool,
                        project: (Int, Int) -> UInt8?) -> Range<Int> {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            let keyIndex = perm(section, middle)
            if compare(target, prefixOnly: prefixOnly, project: { project(keyIndex, $0) }) < 0 {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let start = low
        high = count
        while low < high {
            let middle = (low + high) / 2
            let keyIndex = perm(section, middle)
            if compare(target, prefixOnly: prefixOnly, project: { project(keyIndex, $0) }) > 0 {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return start..<low
    }

    /// 数字串正好等于这串数字的键，按词频降序。
    public func t9Keys(_ digits: [UInt8], limit: Int) -> [Int] {
        let range = search(section: offT9Perm, count: t9PermCount, target: digits, prefixOnly: false) {
            self.t9Projection($0, $1)
        }
        return range.prefix(limit).map { perm(offT9Perm, $0) }
    }

    /// 数字串以这串数字开头的键（顺序不保证，调用方自己挑最高词频）。
    public func t9PrefixKeys(_ digits: [UInt8], limit: Int) -> [Int] {
        let range = search(section: offT9Perm, count: t9PermCount, target: digits, prefixOnly: true) {
            self.t9Projection($0, $1)
        }
        return range.prefix(limit).map { perm(offT9Perm, $0) }
    }

    /// 首字母串正好等于 `initials` 的键，按词频降序（wq -> 我去、完全…）。
    public func initialKeys(_ initials: [UInt8], limit: Int) -> [Int] {
        let range = search(section: offInitPerm, count: initPermCount, target: initials, prefixOnly: false) {
            self.initialProjection($0, $1, digits: false)
        }
        return range.prefix(limit).map { perm(offInitPerm, $0) }
    }

    /// 首字母的数字串正好等于 `digits` 的键，按词频降序。
    public func t9InitialKeys(_ digits: [UInt8], limit: Int) -> [Int] {
        let range = search(section: offT9InitPerm, count: t9InitPermCount, target: digits, prefixOnly: false) {
            self.initialProjection($0, $1, digits: true)
        }
        return range.prefix(limit).map { perm(offT9InitPerm, $0) }
    }

    /// 把拼音转成九宫格数字串。
    public static func t9Digits(_ pinyin: String) -> String {
        var result = [UInt8]()
        result.reserveCapacity(pinyin.utf8.count)
        for byte in pinyin.utf8 where byte < 128 {
            let digit = t9Table[Int(byte)]
            if digit != 0 { result.append(digit) }
        }
        return String(decoding: result, as: UTF8.self)
    }
}
