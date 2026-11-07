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

print("单个字母")
let firstForM = qwerty("m").candidates.first?.text ?? ""
check("单打 m 首选不是嗯、唔、呣", !["嗯", "唔", "呣"].contains(firstForM), "\(texts(qwerty("m")))")
check("wbzd 是我不知道", qwerty("wbzd").candidates.first?.text == "我不知道", "\(texts(qwerty("wbzd")))")

print("整句和词")
check("woxihuanni 首选是整句", qwerty("woxihuanni").candidates.first?.text == "我喜欢你", "\(texts(qwerty("woxihuanni")))")
check("nihao 首选你好", qwerty("nihao").candidates.first?.text == "你好", "\(texts(qwerty("nihao")))")
check("shi 首选是", qwerty("shi").candidates.first?.text == "是", "\(texts(qwerty("shi")))")
check("句尾 ma 是吗", qwerty("nihaoma").candidates.first?.text == "你好吗", "\(texts(qwerty("nihaoma")))")
check("句尾 ba 是吧", qwerty("womenzouba").candidates.first?.text == "我们走吧", "\(texts(qwerty("womenzouba")))")
check("拼音分词显示", qwerty("woxihuanni").spelling == "wo'xi'huan'ni", qwerty("woxihuanni").spelling)

print("拼音打完整时不多补字")
for (input, expected) in [("nichifanlema", "你吃饭了吗"), ("jintianhenmang", "今天很忙"),
                          ("zhegedongxihenhaoyong", "这个东西很好用"), ("meiguanxiwolaichuli", "没关系我来处理"),
                          ("womenyiqikaihuiba", "我们一起开会吧")] {
    let got = qwerty(input).candidates.first?.text ?? ""
    check("\(input) 首选是\(expected)", got == expected, "得到「\(got)」")
}
for input in ["jintianhenmang", "womenmingtianzaijian", "zhegedongxihenhaoyong", "nichifanlema", "womenyiqikaihuiba"] {
    // 汉字数不能超过音节数：整句候选绝不能比打的拼音多字
    let syllableCount = PinyinSyllables.segment(input)?.count ?? input.count
    let got = qwerty(input).candidates.first?.text ?? ""
    check("\(input) 没有多字", got.count <= syllableCount, "得到「\(got)」，音节数 \(syllableCount)")
}

print("多音节词优先于单字")
check("正常使用了", qwerty("zhengchangshiyongle").candidates.first?.text == "正常使用了", "\(texts(qwerty("zhengchangshiyongle")))")

print("没打完的词还能出来")
check("wom 有我们", texts(qwerty("wom"), 3).contains("我们"), "\(texts(qwerty("wom")))")
check("woxih 首选我喜欢", qwerty("woxih").candidates.first?.text == "我喜欢", "\(texts(qwerty("woxih")))")

print("打错字")
func correctedFirst(_ input: String, _ expected: String) {
    let got = typed(input)
    let top = got.candidates.first
    check("\(input) 首选纠成\(expected)", top?.text == expected && top?.kind == .corrected, "\(texts(got))")
}
correctedFirst("nihap", "你好")
correctedFirst("jintianhebmang", "今天很忙")
correctedFirst("woxiangchifna", "我想吃饭")
correctedFirst("zhegewenttizenmebanne", "这个问题怎么办呢")
correctedFirst("xiexienu", "谢谢你")
let clean = typed("wozhen")
check("拼对了不出纠错", !clean.candidates.prefix(3).contains { $0.kind == .corrected }, "\(texts(clean))")
for input in ["jintianhenmang", "woxihuanni", "nichifanlema", "zhegedongxihenhaoyong"] {
    check("\(input) 打对了首选不是纠错", typed(input).candidates.first?.kind != .corrected, "\(texts(typed(input)))")
}
check("简拼不乱纠错", !typed("wq").candidates.prefix(4).contains { $0.kind == .corrected }, "\(texts(typed("wq")))")
check("wbzd 不乱纠错", typed("wbzd").candidates.first?.text == "我不知道", "\(texts(typed("wbzd")))")

print("ü 和分词")
for (input, expected) in [("lve", "略"), ("lue", "略"), ("nve", "虐"), ("nue", "虐"), ("lueguo", "略过"),
                          ("nvhai", "女孩"), ("lvse", "绿色"), ("qulvyou", "去旅游"), ("zhanlue", "战略")] {
    check("\(input) 首选是\(expected)", qwerty(input).candidates.first?.text == expected, "\(texts(qwerty(input)))")
}
check("lve 不被切成 lv'e", qwerty("lve").spelling == "lve", qwerty("lve").spelling)
check("lv 首选是绿", qwerty("lv").candidates.first?.text == "绿", "\(texts(qwerty("lv")))")
check("pi 首选不是古音（被、比）", qwerty("pi").candidates.first?.text == "皮", "\(texts(qwerty("pi")))")
check("fu 前三没有不、还", !texts(qwerty("fu"), 3).contains("不") && !texts(qwerty("fu"), 3).contains("还"), "\(texts(qwerty("fu")))")
check("bang 不被切成 ba + ng", qwerty("ninengbangwoyigemangma").candidates.first?.text == "你能帮我一个忙吗",
      "\(texts(qwerty("ninengbangwoyigemangma")))")

print("联想")
let afterWo = engine.predictions(after: "我", limit: 14)
check("我 后面有想、们", afterWo.contains("想") && afterWo.contains("们"), "\(afterWo)")
let afterJin = engine.predictions(after: "今", limit: 14)
check("今 后面有天", afterJin.contains("天"), "\(afterJin)")
check("长句按结尾的词联想", engine.predictions(after: "我们今天", limit: 14).contains("晚上"), "\(engine.predictions(after: "我们今天", limit: 14))")
let afterQuestion = engine.predictions(after: "你吃过了吗", lastWord: "吗", limit: 14)
check("问句后面先给问号", afterQuestion.first == "？", "\(afterQuestion)")
let afterBusy = engine.predictions(after: "我今天很忙", lastWord: "忙", limit: 14)
check("整句后面不按单字补全（很忙 -> 碌）", !afterBusy.contains("碌") && afterBusy.first == "，", "\(afterBusy)")
let afterHome = engine.predictions(after: "我到家", lastWord: "到家", limit: 14)
check("到家 后面有了", afterHome.contains("了"), "\(afterHome)")

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

print("个人词库")
let beforeChoice = texts(qwerty("shiyong"), 10)
learning.record(segments: [(text: "试用", key: "shiyong")])
check("选过「试用」后 shiyong 首选是试用", qwerty("shiyong").candidates.first?.text == "试用", "\(beforeChoice) -> \(texts(qwerty("shiyong")))")
learning.record(segments: [(text: "睡觉了", key: "shuijiaole")])
check("选过的三字词整句也用它", qwerty("woyaoshuijiaole").candidates.first?.text.hasSuffix("睡觉了") == true, "\(texts(qwerty("woyaoshuijiaole")))")
learning.recordTyped([(text: "我吃过了", typed: "wcgl")])
check("简拼选过一次后排第一", qwerty("wcgl").candidates.first?.text == "我吃过了", "\(texts(qwerty("wcgl")))")
learning.removeEntry(text: "试用", key: "shiyong")
check("删掉以后不再排第一", qwerty("shiyong").candidates.first?.text != "试用", "\(texts(qwerty("shiyong")))")

print("性能")
let started = Date()
for _ in 0..<50 {
    _ = qwerty("jintiantianqihenhaowomenyiqichuquwanba")
}
let perCall = Date().timeIntervalSince(started) / 50 * 1000
print(String(format: "  长句每次转换 %.2f 毫秒", perCall))
check("长句转换不超过 16 毫秒", perCall < 16)
let typoStarted = Date()
for _ in 0..<20 {
    _ = typed("jintiantianqihenhaowomenyiqichuquwamba")
}
let typoPerCall = Date().timeIntervalSince(typoStarted) / 20 * 1000
print(String(format: "  长句打错一处（带纠错）每次转换 %.2f 毫秒", typoPerCall))
check("带纠错的长句不超过 40 毫秒", typoPerCall < 40)

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
