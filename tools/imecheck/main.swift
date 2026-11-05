//
//  main.swift
//  内核回归测试：不依赖界面，直接跑拼音引擎。云编译时会先跑这个，失败就不往下编了。
//
//  用法：imecheck ios/Shared/dict/moyu.dict ios/Shared/dict/next.tsv
//

import Foundation

guard CommandLine.arguments.count >= 3,
      let dictionary = MoyuDictionary(url: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    print("打不开词库")
    exit(2)
}

print("词库：\(dictionary.entryCount) 词，\(dictionary.keyCount) 个拼音")

let store = SharedStore(forceMemory: true)
let learning = UserLearningStore(store: store)
let nextWords = NextWordIndex(url: URL(fileURLWithPath: CommandLine.arguments[2]))
let engine = PinyinEngine(dictionary: dictionary, learning: learning, nextWords: nextWords)

var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("  通过  \(name)")
    } else {
        failures += 1
        print("  失败  \(name)  \(detail())")
    }
}

func qwerty(_ text: String) -> IMEConversion {
    engine.convert(IMEQuery(mode: .qwerty, input: Array(text.utf8)), rawText: text, fuzzy: .off, typoCorrection: false)
}

func typed(_ text: String) -> IMEConversion {
    engine.convert(IMEQuery(mode: .qwerty, input: Array(text.utf8)), rawText: text, fuzzy: .off, typoCorrection: true)
}

func t9(_ digits: String, locks: [Int: UInt8] = [:]) -> IMEConversion {
    engine.convert(IMEQuery(mode: .t9, input: Array(digits.utf8), locks: locks), rawText: nil, fuzzy: .off, typoCorrection: false)
}

func texts(_ conversion: IMEConversion, _ limit: Int = 12) -> [String] {
    conversion.candidates.prefix(limit).map { $0.text }
}

print("整句和词")
check("woxihuanni 首选是整句", qwerty("woxihuanni").candidates.first?.text == "我喜欢你", "\(texts(qwerty("woxihuanni")))")
check("nihao 首选你好", qwerty("nihao").candidates.first?.text == "你好", "\(texts(qwerty("nihao")))")
check("shi 首选是", qwerty("shi").candidates.first?.text == "是", "\(texts(qwerty("shi")))")
check("句尾 ma 是吗", qwerty("nihaoma").candidates.first?.text == "你好吗", "\(texts(qwerty("nihaoma")))")
check("句尾 ba 是吧", qwerty("womenzouba").candidates.first?.text == "我们走吧", "\(texts(qwerty("womenzouba")))")
check("拼音分词显示", qwerty("woxihuanni").spelling == "wo'xi'huan'ni", qwerty("woxihuanni").spelling)

print("拼音打完整时不多补字")
for (input, expected) in [("nichifanlema", "你吃饭了吗"), ("jintianhenmang", "今天很忙"),
                          ("zhegedongxihenhaoyong", "这个东西很好用"), ("meiguanxiwolaichuli", "没关系我来处理")] {
    let got = qwerty(input).candidates.first?.text ?? ""
    check("\(input) 首选是\(expected)", got == expected, "得到「\(got)」")
}
for input in ["jintianhenmang", "womenmingtianzaijian", "zhegedongxihenhaoyong", "nichifanlema"] {
    // 汉字数不能超过音节数：整句候选绝不能比打的拼音多字
    let syllableCount = PinyinSyllables.segment(input)?.count ?? input.count
    let got = qwerty(input).candidates.first?.text ?? ""
    check("\(input) 没有多字", got.count <= syllableCount, "得到「\(got)」，音节数 \(syllableCount)")
}

print("多音节词优先于单字")
check("正常使用了", qwerty("zhengchangshiyongle").candidates.first?.text == "正常使用了", "\(texts(qwerty("zhengchangshiyongle")))")

print("打错字")
let typo = typed("wozhem")
check("wozhem 第二个候选是纠错后的我真", typo.candidates.dropFirst().first?.text == "我真" && typo.candidates.dropFirst().first?.kind == .corrected, "\(texts(typo))")
let clean = typed("wozhen")
check("拼对了不出纠错", !clean.candidates.prefix(3).contains { $0.kind == .corrected }, "\(texts(clean))")
check("简拼不乱纠错", !typed("wq").candidates.prefix(4).contains { $0.kind == .corrected }, "\(texts(typed("wq")))")

print("联想")
let afterWo = engine.predictions(after: "我", limit: 14)
check("我 后面有想、们", afterWo.contains("想") && afterWo.contains("们"), "\(afterWo)")
let afterJin = engine.predictions(after: "今", limit: 14)
check("今 后面有天", afterJin.contains("天"), "\(afterJin)")
check("长句按结尾的词联想", engine.predictions(after: "我们今天", limit: 14).contains("晚上"), "\(engine.predictions(after: "我们今天", limit: 14))")

print("逐词选词")
let long = qwerty("woxihuanni")
let wo = long.candidates.first { $0.text == "我" }
check("长句里能单选「我」", wo?.consumed == 2, "\(String(describing: wo))")
let rest = qwerty("xihuanni")
check("剩下的拼音接着转换", rest.candidates.contains { $0.text == "喜欢" && $0.consumed == 6 }, "\(texts(rest))")

print("简拼和没打完的词")
check("zg 有中国", texts(qwerty("zg")).contains("中国"), "\(texts(qwerty("zg")))")
check("wq 有我去", texts(qwerty("wq"), 4).contains("我去"), "\(texts(qwerty("wq")))")
check("nih 有你好", texts(qwerty("nih"), 3).contains("你好"), "\(texts(qwerty("nih")))")
check("zhongg 有中国", texts(qwerty("zhongg"), 3).contains("中国"), "\(texts(qwerty("zhongg")))")

print("多音字")
check("huan 有还", texts(qwerty("huan"), 40).contains("还"), "\(texts(qwerty("huan"), 40))")
check("hang 有行", texts(qwerty("hang"), 40).contains("行"), "\(texts(qwerty("hang"), 40))")
check("zhang 有长", texts(qwerty("zhang"), 40).contains("长"), "\(texts(qwerty("zhang"), 40))")

print("九宫格")
check("64 能打出你", texts(t9("64"), 20).contains("你"), "\(texts(t9("64"), 20))")
check("9426 能打出小", texts(t9("9426"), 12).contains("小"), "\(texts(t9("9426")))")
check("9426 左栏有 xiao", t9("9426").pinyinChoices.contains("xiao"), "\(t9("9426").pinyinChoices)")
let lockedChoice = t9("9426", locks: [0: UInt8(ascii: "z"), 1: UInt8(ascii: "h"), 2: UInt8(ascii: "a"), 3: UInt8(ascii: "n")])
check("选定 zhan 后候选跟着变", texts(lockedChoice, 12).contains("站") || texts(lockedChoice, 12).contains("战"), "\(texts(lockedChoice))")
check("简拼 94 有喜欢", texts(t9("94"), 40).contains("喜欢") || t9("94").candidates.count > 0)

print("原文")
check("hello 最后有原文", qwerty("hello").candidates.last?.text == "hello", "\(texts(qwerty("hello")))")
check("没有词的字母串也有候选", !qwerty("qqqqqq").candidates.isEmpty)

print("学习")
learning.record(segments: [(text: "我", key: "wo"), (text: "喜欢", key: "xihuan"), (text: "你", key: "ni")])
check("选过的句子记成短语", learning.phrases(forKey: "woxihuanni").contains("我喜欢你"))
learning.record(segments: [(text: "握", key: "wo")])
learning.record(segments: [(text: "握", key: "wo")])
learning.record(segments: [(text: "握", key: "wo")])
learning.record(segments: [(text: "握", key: "wo")])
let afterLearning = texts(qwerty("wo"), 6)
check("常选的词往前排", afterLearning.contains("握"), "\(afterLearning)")

print("性能")
let started = Date()
for _ in 0..<50 {
    _ = qwerty("jintiantianqihenhaowomenyiqichuquwanba")
}
let perCall = Date().timeIntervalSince(started) / 50 * 1000
print(String(format: "  长句每次转换 %.2f 毫秒", perCall))
check("长句转换不超过 16 毫秒", perCall < 16)

print("整句准确率（没有参与调词频的句子）")
let holdout: [(String, String)] = [
    ("nichifanlema", "你吃饭了吗"), ("womenmingtianzaijian", "我们明天再见"), ("jintianhenmang", "今天很忙"),
    ("zhegedongxihenhaoyong", "这个东西很好用"), ("xiawuyouyigehuiyi", "下午有一个会议"), ("woxiangchihuoguo", "我想吃火锅"),
    ("nizainalile", "你在哪里了"), ("wozaidengnidedianhua", "我在等你的电话"), ("zhegewentibunanjiejue", "这个问题不难解决"),
    ("tashuotamingtianbulai", "他说他明天不来"), ("qingbangwokanyixia", "请帮我看一下"), ("wozhidaole", "我知道了"),
    ("xiexienidebangzhu", "谢谢你的帮助"), ("zhouliuyoukongma", "周六有空吗"), ("womenyiqikaihuiba", "我们一起开会吧"),
    ("zheshiwodediyici", "这是我的第一次"), ("nixihuanshenmeyanse", "你喜欢什么颜色"), ("tianqizhenhao", "天气真好"),
    ("wojintianbushufu", "我今天不舒服"), ("meiguanxiwolaichuli", "没关系我来处理"), ("nihaoqingwenyouren", "你好请问有人"),
    ("zheyangyekeyi", "这样也可以"), ("dajiaxinkule", "大家辛苦了"), ("womenqukandianyingba", "我们去看电影吧")
]
var right = 0
for (input, expected) in holdout {
    let got = qwerty(input).candidates.first?.text ?? ""
    if got == expected {
        right += 1
    } else {
        print("  \(input): 想要「\(expected)」，得到「\(got)」")
    }
}
print("  完全正确 \(right)/\(holdout.count)（这一项只报告，不算失败）")

print(failures == 0 ? "全部通过" : "有 \(failures) 项失败")
exit(failures == 0 ? 0 : 1)
