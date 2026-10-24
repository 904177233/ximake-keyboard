# -*- coding: utf-8 -*-
"""从 tools/dict/syllable_table.py 生成 Swift 音节表。

用法：
    python tools/dict/gen_swift_syllables.py

输出：
    ios/Shared/IMECore/PinyinSyllables.swift

为什么要生成而不是手写：421 个音节手抄极易出错，音节表的唯一真相源是
`tools/dict/syllable_table.py`（词库生成器与 Swift 引擎共用同一份），
本脚本负责把它翻译成 Swift 常量，保证两端永远一致。
"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from syllable_table import SYLLABLES  # noqa: E402

OUT_PATH = os.path.join(ROOT, "ios", "Shared", "IMECore", "PinyinSyllables.swift")

HEADER = '''//
//  PinyinSyllables.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：无声调拼音音节表（{count} 个）与音节切分 DP，供词库加载时建立首字母索引、
//            以及引擎做多音节切分使用。
//            本文件由 tools/dict/gen_swift_syllables.py 从 tools/dict/syllable_table.py
//            自动生成，请勿手工编辑；修改音节表请改 Python 源后重新生成。
//  依赖：Foundation
//  使用方：PinyinDictionary（首字母索引）、PinyinEngine（多音节 DP 切分）
//

import Foundation

/// 无声调拼音音节表。
///
/// 约定：全部小写、无声调，`ü` 统一写作 `v`（`lv`/`nv`/`lve`），
/// 并收录口语叹词 `n`/`ng`/`hm`/`hng`/`yo`/`lo` 等。
public enum PinyinSyllables {{

    /// 最长音节长度（`zhuang`/`chuang` 等 6 个字母）。
    public static let maxLength = {max_len}

    /// 全部合法音节（{count} 个）。
    public static let all: Set<String> = [
{items}
    ]

    /// 按首字母分组（供引擎按首字母缩小检索范围）。
    public static let groupedByInitial: [Character: [String]] = Dictionary(
        grouping: all.sorted(),
        by: {{ $0.first ?? "?" }}
    )

    /// 判断一个字符串是否是合法音节。
    /// - Parameter text: 待判断的小写字母串。
    /// - Returns: 是合法音节返回 `true`。
    public static func isSyllable(_ text: String) -> Bool {{
        all.contains(text)
    }}

    /// 把连写全拼切分成音节序列（最少音节优先）。
    ///
    /// 例：`zhongguo` → `["zhong", "guo"]`；`xian` → `["xian"]`；
    /// 无法切分（含非拼音片段）返回 `nil`。
    /// - Parameters:
    ///   - pinyin: 连写全拼，小写字母。
    ///   - maxSegments: 最多允许切出的音节数（防御性上限，默认 12）。
    /// - Returns: 音节数组；不可切分时为 `nil`。
    public static func segment(_ pinyin: String, maxSegments: Int = 12) -> [String]? {{
        let chars = Array(pinyin)
        let count = chars.count
        guard count > 0, count <= maxSegments * maxLength else {{ return nil }}
        var best: [[String]?] = Array(repeating: nil, count: count + 1)
        var bestCount = [Int](repeating: Int.max, count: count + 1)
        best[0] = []
        bestCount[0] = 0
        var index = 0
        while index < count {{
            if let prefix = best[index] {{
                let remain = count - index
                var length = min(maxLength, remain)
                while length >= 1 {{
                    let seg = String(chars[index..<(index + length)])
                    if all.contains(seg) {{
                        let next = index + length
                        let candidateCount = bestCount[index] + 1
                        if candidateCount < bestCount[next] {{
                            bestCount[next] = candidateCount
                            best[next] = prefix + [seg]
                        }}
                    }}
                    length -= 1
                }}
            }}
            index += 1
        }}
        return best[count]
    }}

    /// 把连写全拼切分成**恰好** `segments` 个音节（用于还原"词有几个字"）。
    ///
    /// 词库里的全拼是逐字生成的，因此"汉字个数 == 音节个数"是硬约束：
    /// `zhongguo`（2 字）→ `["zhong", "guo"]`；`xian`（1 字）→ `["xian"]`；
    /// 若不存在恰好 `segments` 个音节的切法则返回 `nil`。
    /// - Parameters:
    ///   - pinyin: 连写全拼，小写字母。
    ///   - segments: 期望的音节个数（应等于词的汉字个数）。
    /// - Returns: 音节数组；无解时为 `nil`。
    public static func segment(_ pinyin: String, exactly segments: Int) -> [String]? {{
        let chars = Array(pinyin)
        let count = chars.count
        guard segments > 0, count > 0, count <= segments * maxLength else {{ return nil }}
        // dp[i][k] = 前缀 i 个字母切成 k 个音节时的首个可行切法
        var dp = [[[String]?]](repeating: [[String]?](repeating: nil, count: segments + 1), count: count + 1)
        dp[0][0] = []
        var index = 0
        while index < count {{
            var used = 0
            while used < segments {{
                if let prefix = dp[index][used] {{
                    let remain = count - index
                    var length = min(maxLength, remain)
                    while length >= 1 {{
                        let seg = String(chars[index..<(index + length)])
                        if all.contains(seg), dp[index + length][used + 1] == nil {{
                            dp[index + length][used + 1] = prefix + [seg]
                        }}
                        length -= 1
                    }}
                }}
                used += 1
            }}
            index += 1
        }}
        return dp[count][segments]
    }}
}}
'''


def build_items() -> str:
    """把音节表排成 Swift 数组字面量，每行 8 个。"""
    items = sorted(SYLLABLES)
    lines = []
    per_line = 8
    for i in range(0, len(items), per_line):
        chunk = items[i : i + per_line]
        lines.append("        " + ", ".join('"%s"' % s for s in chunk) + ",")
    return "\n".join(lines)


def main() -> int:
    text = HEADER.format(
        count=len(SYLLABLES),
        max_len=max(len(s) for s in SYLLABLES),
        items=build_items(),
    )
    text = text.replace("\r\n", "\n")
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print("已生成 %s（%d 个音节，%d 字节）" % (OUT_PATH, len(SYLLABLES), len(text.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
