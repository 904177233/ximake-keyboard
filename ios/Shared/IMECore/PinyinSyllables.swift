//
//  PinyinSyllables.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：无声调拼音音节表（421 个）与音节切分 DP，供词库加载时建立首字母索引、
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
public enum PinyinSyllables {

    /// 最长音节长度（`zhuang`/`chuang` 等 6 个字母）。
    public static let maxLength = 6

    /// 全部合法音节（421 个）。
    public static let all: Set<String> = [
        "a", "ai", "an", "ang", "ao", "ba", "bai", "ban",
        "bang", "bao", "bei", "ben", "beng", "bi", "bian", "biang",
        "biao", "bie", "bin", "bing", "bo", "bu", "ca", "cai",
        "can", "cang", "cao", "ce", "cen", "ceng", "cha", "chai",
        "chan", "chang", "chao", "che", "chen", "cheng", "chi", "chong",
        "chou", "chu", "chua", "chuai", "chuan", "chuang", "chui", "chun",
        "chuo", "ci", "cong", "cou", "cu", "cuan", "cui", "cun",
        "cuo", "da", "dai", "dan", "dang", "dao", "de", "dei",
        "den", "deng", "di", "dia", "dian", "diao", "die", "ding",
        "diu", "dong", "dou", "du", "duan", "duang", "dui", "dun",
        "duo", "e", "ei", "en", "eng", "er", "fa", "fan",
        "fang", "fei", "fen", "feng", "fo", "fou", "fu", "ga",
        "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng",
        "gong", "gou", "gu", "gua", "guai", "guan", "guang", "gui",
        "gun", "guo", "ha", "hai", "han", "hang", "hao", "he",
        "hei", "hen", "heng", "hm", "hng", "hong", "hou", "hu",
        "hua", "huai", "huan", "huang", "hui", "hun", "huo", "ji",
        "jia", "jian", "jiang", "jiao", "jie", "jin", "jing", "jiong",
        "jiu", "ju", "juan", "jue", "jun", "ka", "kai", "kan",
        "kang", "kao", "ke", "ken", "keng", "kong", "kou", "ku",
        "kua", "kuai", "kuan", "kuang", "kui", "kun", "kuo", "la",
        "lai", "lan", "lang", "lao", "le", "lei", "leng", "li",
        "lia", "lian", "liang", "liao", "lie", "lin", "ling", "liu",
        "lo", "long", "lou", "lu", "luan", "lue", "lun", "luo",
        "lv", "lve", "m", "ma", "mai", "man", "mang", "mao",
        "me", "mei", "men", "meng", "mi", "mian", "miao", "mie",
        "min", "ming", "miu", "mo", "mou", "mu", "n", "na",
        "nai", "nan", "nang", "nao", "ne", "nei", "nen", "neng",
        "ng", "ni", "nian", "niang", "niao", "nie", "nin", "ning",
        "niu", "nong", "nou", "nu", "nuan", "nue", "nun", "nuo",
        "nv", "nve", "o", "ou", "pa", "pai", "pan", "pang",
        "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pie",
        "pin", "ping", "po", "pou", "pu", "qi", "qia", "qian",
        "qiang", "qiao", "qie", "qin", "qing", "qiong", "qiu", "qu",
        "quan", "que", "qun", "ran", "rang", "rao", "re", "ren",
        "reng", "ri", "rong", "rou", "ru", "rua", "ruan", "rui",
        "run", "ruo", "sa", "sai", "san", "sang", "sao", "se",
        "sen", "seng", "sha", "shai", "shan", "shang", "shao", "she",
        "shei", "shen", "sheng", "shi", "shou", "shu", "shua", "shuai",
        "shuan", "shuang", "shui", "shun", "shuo", "si", "song", "sou",
        "su", "suan", "sui", "sun", "suo", "ta", "tai", "tan",
        "tang", "tao", "te", "tei", "teng", "ti", "tian", "tiao",
        "tie", "ting", "tong", "tou", "tu", "tuan", "tui", "tun",
        "tuo", "wa", "wai", "wan", "wang", "wei", "wen", "weng",
        "wo", "wu", "xi", "xia", "xian", "xiang", "xiao", "xie",
        "xin", "xing", "xiong", "xiu", "xu", "xuan", "xue", "xun",
        "ya", "yan", "yang", "yao", "ye", "yi", "yin", "ying",
        "yo", "yong", "you", "yu", "yuan", "yue", "yun", "za",
        "zai", "zan", "zang", "zao", "ze", "zei", "zen", "zeng",
        "zha", "zhai", "zhan", "zhang", "zhao", "zhe", "zhei", "zhen",
        "zheng", "zhi", "zhong", "zhou", "zhu", "zhua", "zhuai", "zhuan",
        "zhuang", "zhui", "zhun", "zhuo", "zi", "zong", "zou", "zu",
        "zuan", "zui", "zun", "zuo", "ê",
    ]

    /// 按首字母分组（供引擎按首字母缩小检索范围）。
    public static let groupedByInitial: [Character: [String]] = Dictionary(
        grouping: all.sorted(),
        by: { $0.first ?? "?" }
    )

    /// 判断一个字符串是否是合法音节。
    /// - Parameter text: 待判断的小写字母串。
    /// - Returns: 是合法音节返回 `true`。
    public static func isSyllable(_ text: String) -> Bool {
        all.contains(text)
    }

    /// 把连写全拼切分成音节序列（最少音节优先）。
    ///
    /// 例：`zhongguo` → `["zhong", "guo"]`；`xian` → `["xian"]`；
    /// 无法切分（含非拼音片段）返回 `nil`。
    /// - Parameters:
    ///   - pinyin: 连写全拼，小写字母。
    ///   - maxSegments: 最多允许切出的音节数（防御性上限，默认 12）。
    /// - Returns: 音节数组；不可切分时为 `nil`。
    public static func segment(_ pinyin: String, maxSegments: Int = 12) -> [String]? {
        let chars = Array(pinyin)
        let count = chars.count
        guard count > 0, count <= maxSegments * maxLength else { return nil }
        var best: [[String]?] = Array(repeating: nil, count: count + 1)
        var bestCount = [Int](repeating: Int.max, count: count + 1)
        best[0] = []
        bestCount[0] = 0
        var index = 0
        while index < count {
            if let prefix = best[index] {
                let remain = count - index
                var length = min(maxLength, remain)
                while length >= 1 {
                    let seg = String(chars[index..<(index + length)])
                    if all.contains(seg) {
                        let next = index + length
                        let candidateCount = bestCount[index] + 1
                        if candidateCount < bestCount[next] {
                            bestCount[next] = candidateCount
                            best[next] = prefix + [seg]
                        }
                    }
                    length -= 1
                }
            }
            index += 1
        }
        return best[count]
    }

    /// 把连写全拼切分成**恰好** `segments` 个音节（用于还原"词有几个字"）。
    ///
    /// 词库里的全拼是逐字生成的，因此"汉字个数 == 音节个数"是硬约束：
    /// `zhongguo`（2 字）→ `["zhong", "guo"]`；`xian`（1 字）→ `["xian"]`；
    /// 若不存在恰好 `segments` 个音节的切法则返回 `nil`。
    /// - Parameters:
    ///   - pinyin: 连写全拼，小写字母。
    ///   - segments: 期望的音节个数（应等于词的汉字个数）。
    /// - Returns: 音节数组；无解时为 `nil`。
    public static func segment(_ pinyin: String, exactly segments: Int) -> [String]? {
        let chars = Array(pinyin)
        let count = chars.count
        guard segments > 0, count > 0, count <= segments * maxLength else { return nil }
        // dp[i][k] = 前缀 i 个字母切成 k 个音节时的首个可行切法
        var dp = [[[String]?]](repeating: [[String]?](repeating: nil, count: segments + 1), count: count + 1)
        dp[0][0] = []
        var index = 0
        while index < count {
            var used = 0
            while used < segments {
                if let prefix = dp[index][used] {
                    let remain = count - index
                    var length = min(maxLength, remain)
                    while length >= 1 {
                        let seg = String(chars[index..<(index + length)])
                        if all.contains(seg), dp[index + length][used + 1] == nil {
                            dp[index + length][used + 1] = prefix + [seg]
                        }
                        length -= 1
                    }
                }
                used += 1
            }
            index += 1
        }
        return dp[count][segments]
    }
}
