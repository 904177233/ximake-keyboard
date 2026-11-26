//
//  main.swift
//  内核回归测试：不依赖界面，直接跑拼音引擎。云编译时会先跑这个，失败就不往下编了。
//
//  用法：imecheck ios/Shared/dict/moyu.dict ios/Shared/dict/next.tsv
//

import Foundation
#if canImport(notify)
import notify
#endif

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
// 打成了另一句也通顺的话（你好好嘛），纠成常用短语的那句排在前两个里
let haiHao = typed("nihaohaoma")
check("nihaohaoma 前两个里有纠错的你还好吗",
      haiHao.candidates.prefix(2).contains { $0.text == "你还好吗" && $0.kind == .corrected }, "\(texts(haiHao))")
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
if CommandLine.arguments.count >= 6 {
    let phraseIndex = PhraseSuggestionIndex(url: URL(fileURLWithPath: CommandLine.arguments[5]))
    let longest = phraseIndex.suggestions(after: "最近忙吗", limit: 1).first?.text
    check("短语联想优先最长后缀", longest == "还行", "得到「\(longest ?? "nil")」")
}
let afterWo = engine.predictions(after: "我", limit: 14)
check("我 后面有想、们", afterWo.contains("想") && afterWo.contains("们"), "\(afterWo)")
let afterJin = engine.predictions(after: "今", limit: 14)
check("今 后面有天", afterJin.contains("天"), "\(afterJin)")
check("长句按结尾的词联想", engine.predictions(after: "我们今天", limit: 14).contains("晚上"), "\(engine.predictions(after: "我们今天", limit: 14))")
let afterQuestion = engine.predictions(after: "你吃过了吗", lastWord: "吗", limit: 14)
check("问句后面先给问号", afterQuestion.first == "？", "\(afterQuestion)")
let afterBusy = engine.predictions(after: "我今天很忙", lastWord: "忙", limit: 14)
check("整句后面不按单字补全（很忙 -> 碌）", !afterBusy.contains("碌") && afterBusy.first == "，", "\(afterBusy)")
let weatherEvidence = nextWords.followingEvidence(after: "天气预报")
check("天气预报后面的说带真实次数和来源",
      weatherEvidence.first?.text == "说" && weatherEvidence.first?.count == 9
        && weatherEvidence.first?.source == "tatoeba", "\(weatherEvidence)")
let afterHome = engine.predictions(after: "我到家", lastWord: "到家", limit: 14)
check("到家 后面有了", afterHome.contains("了"), "\(afterHome)")

print("新词和英文")
check("视频号是一个词", qwerty("shipinhao").candidates.first?.text == "视频号", "\(texts(qwerty("shipinhao")))")
check("拼多多是一个词", qwerty("pinduoduo").candidates.first?.text == "拼多多", "\(texts(qwerty("pinduoduo")))")
if CommandLine.arguments.count >= 5 {
    let fileStore = HotWordStore(url: URL(fileURLWithPath: CommandLine.arguments[4]))
    check("仓库里的新词表能读", (fileStore?.count ?? 0) > 200, "\(fileStore?.count ?? 0)")
}
engine.hotWords = HotWordStore(text: "# 墨语新词表 v1\n墨语键盘\tmo'yu'jian'pan\t20000\n坏行\n")
check("拉到的新词能打出来", qwerty("moyujianpan").candidates.first?.text == "墨语键盘", "\(texts(qwerty("moyujianpan")))")
check("拉到的新词简拼也有", texts(qwerty("myjp"), 6).contains("墨语键盘"), "\(texts(qwerty("myjp")))")
engine.hotWords = nil
if CommandLine.arguments.count >= 4 {
    let english = EnglishLexicon(url: URL(fileURLWithPath: CommandLine.arguments[3]))
    check("英文词表能读", english.count > 30000, "\(english.count)")
    check("hel 补全有 hello", english.completions(for: "hel").contains("hello"), "\(english.completions(for: "hel"))")
    check("Hel 补全首字母大写", english.completions(for: "Hel").first?.first?.isUppercase == true, "\(english.completions(for: "Hel"))")
    check("一个字母不补全", english.completions(for: "h").isEmpty)
}
let afterTogether = engine.predictions(after: "我们一起", lastWord: "一起", limit: 14)
check("一起 后面有去", afterTogether.contains("去"), "\(afterTogether)")
check("我妈不被打成我吗", qwerty("womarangwohuijiachifan").candidates.first?.text == "我妈让我回家吃饭",
      "\(texts(qwerty("womarangwohuijiachifan")))")

print("标点")
check("数字后面的句号是小数点", SmartPunctuation.adjusted("。", before: "3") == ".")
check("汉字后面的句号不变", SmartPunctuation.adjusted("。", before: "好") == "。")
check("数字后面的冒号是半角（12:30）", SmartPunctuation.adjusted("：", before: "12") == ":")
check("第一个引号是前引号", SmartPunctuation.adjusted("“", before: "他说") == "“")
check("前面有没配上的引号就给后引号", SmartPunctuation.adjusted("“", before: "他说“你好") == "”")
check("配上以后又是前引号", SmartPunctuation.adjusted("“", before: "他说“你好”然后") == "“")
check("换了段不管上一段没配上的", SmartPunctuation.adjusted("“", before: "他说“你好\n") == "“")
check("英文补全后的空格遇到句号要去掉", SmartPunctuation.closesUpSpace(".") && !SmartPunctuation.closesUpSpace("("))

print("App 和键盘同步")
let outOfRangePrefs = Data("{\"contextTurns\":\(Int.max),\"voiceKeepAliveMinutes\":0}".utf8)
let clampedPrefs = try? JSONDecoder().decode(AIPrefs.self, from: outOfRangePrefs)
check("旧偏好的轮数和语音时长落在设置范围内", clampedPrefs?.contextTurns == 20 && clampedPrefs?.voiceKeepAliveMinutes == 1)
let envelope = SharedSync.wrap(Data("abc".utf8), revision: 42)
let opened = SharedSync.unwrap(envelope)
check("带时间的数据能拆回来", opened.revision == 42 && opened.payload == Data("abc".utf8))
check("旧版没带时间的数据当作时间 0", SharedSync.unwrap(Data("old".utf8)).revision == 0)
let prefsJSON = Data("{\"theme\":\"coral\",\"layout\":\"qwerty\"}".utf8)
SharedSync.writeNotify(prefsJSON, key: SharedStoreKey.keyboardPrefs, revision: 7)
let notified = SharedSync.readNotify(key: SharedStoreKey.keyboardPrefs)
check("键盘偏好走系统通知能读回来", notified?.payload == prefsJSON && notified?.revision == 7, "\(String(describing: notified))")
let notifyTailName = "com.moyu.imecheck.tail"
NotifyChannel.write(Data(repeating: 0x41, count: 17), name: notifyTailName)
NotifyChannel.write(Data("ok".utf8), name: notifyTailName)
check("通知改短后不会读到旧尾块", NotifyChannel.read(name: notifyTailName) == Data("ok".utf8))
#if canImport(notify)
var tailToken: Int32 = 0
if notify_register_check(notifyTailName + ".2", &tailToken) == 0 {
    var tail = UInt64.max
    let status = notify_get_state(tailToken, &tail)
    check("通知改短后擦除旧尾块", status == 0 && tail == 0)
    _ = notify_cancel(tailToken)
}
#endif
NotifyChannel.write(nil, name: notifyTailName)
for key in [SharedStoreKey.configSnapshot, "moyu.ai.prefs.v1", SharedStoreKey.phrases] {
    let name = SharedSync.notifyName(key)
    NotifyChannel.write(nil, name: name)
    SharedSync.writeNotify(prefsJSON, key: key, revision: 8)
    check("私有设置不会发布到通知 " + key, NotifyChannel.read(name: name) == nil)
    if let packed = SharedSync.compress(prefsJSON) {
        NotifyChannel.write(SharedSync.wrap(packed, revision: 7), name: name)
        check("忽略旧通知里的私有设置 " + key, SharedSync.readNotify(key: key) == nil)
        NotifyChannel.write(nil, name: name)
    }
}

#if canImport(notify)
let invalidLengthName = "com.moyu.imecheck.invalid-length"
var invalidLengthToken: Int32 = 0
if notify_register_check(invalidLengthName + ".len", &invalidLengthToken) == 0 {
    _ = notify_set_state(invalidLengthToken, UInt64.max)
    check("通知中的超大长度不会导致整数溢出", NotifyChannel.read(name: invalidLengthName) == nil)
    NotifyChannel.write(nil, name: invalidLengthName)
    _ = notify_cancel(invalidLengthToken)
}
#endif

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
let kn = qwerty("kn")
check("kn 的首选是可能", kn.candidates.first?.text == "可能", "\(texts(kn, 8))")
let dg = qwerty("dg")
check("dg 的蛋糕进入前五", dg.candidates.firstIndex { $0.text == "蛋糕" }.map { $0 < 5 } == true, "\(texts(dg, 8))")
let xiAn = engine.convert(IMEQuery(mode: .qwerty, input: Array("xian".utf8), breaks: [2]),
                          rawText: "xian", fuzzy: .off, typoCorrection: false)
check("xi'an 的首选是西安", xiAn.candidates.first?.text == "西安", "\(texts(xiAn, 8))")
let fanGan = engine.convert(IMEQuery(mode: .qwerty, input: Array("fangan".utf8), breaks: [3]),
                           rawText: "fangan", fuzzy: .off, typoCorrection: false)
check("fan'gan 的首选是反感", fanGan.candidates.first?.text == "反感", "\(texts(fanGan, 8))")

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
let nineInitials = t9("94")
let likedRank = nineInitials.candidates.firstIndex { $0.text == "喜欢" }
check("简拼 94 的喜欢有真实名次", likedRank.map { $0 < 24 } == true, "名次 \(likedRank.map { $0 + 1 } ?? -1)，\(texts(nineInitials, 40))")
let remainder = engine.convert(IMEQuery(mode: .qwerty, input: Array("yaoshi".utf8), leftContext: "把"),
                              rawText: "yaoshi", fuzzy: .off, typoCorrection: false)
check("把之后的余串首选钥匙", remainder.candidates.first?.text == "钥匙", "\(texts(remainder, 8))")

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
learning.record(segments: [(text: "弱强度词", key: "ruoqiangdu")], strength: 0.2)
let weakLearningCount = learning.userWords(forKey: "ruoqiangdu").first?.count ?? 0
learning.record(segments: [(text: "弱强度词", key: "ruoqiangdu")], strength: 1.0)
let strongLearningCount = learning.userWords(forKey: "ruoqiangdu").first?.count ?? 0
check("显式选择强度高于自动接受", strongLearningCount > weakLearningCount,
      "\(weakLearningCount) -> \(strongLearningCount)")
learning.addEntry(text: "固定词", key: "gudingci")
check("手动添加词保持强优先",
      learning.isPinnedUserWord(text: "固定词", key: "gudingci")
        && qwerty("gudingci").candidates.first?.text == "固定词",
      "\(texts(qwerty("gudingci")))")
learning.removeEntry(text: "试用", key: "shiyong")
check("删掉以后不再排第一", qwerty("shiyong").candidates.first?.text != "试用", "\(texts(qwerty("shiyong")))")

let persistenceStore = SharedStore(forceMemory: true)
let persistenceLearning = UserLearningStore(store: persistenceStore)
persistenceLearning.record(segments: [(text: "持久化词", key: "chijiuhuaci")])
persistenceLearning.flush()
let restoredLearning = UserLearningStore(store: persistenceStore)
check("等待写盘后个人词库能恢复",
      restoredLearning.userWords(forKey: "chijiuhuaci").contains { $0.text == "持久化词" })
for _ in 0..<6 {
    persistenceLearning.record(segments: [(text: "旧词", key: "jiuci")])
}
persistenceLearning.reset()
persistenceLearning.flush()
let clearedLearning = UserLearningStore(store: persistenceStore)
check("清空后个人词库不会复活", clearedLearning.allEntries().isEmpty && clearedLearning.count(of: "旧词") == 0)

print("性能")
let started = Date()
for _ in 0..<50 {
    _ = qwerty("jintiantianqihenhaowomenyiqichuquwanba")
}
let perCall = Date().timeIntervalSince(started) / 50 * 1000
print(String(format: "  长句每次转换 %.2f 毫秒", perCall))
check("长句转换不超过 16 毫秒", perCall < 16)
let longerStarted = Date()
for _ in 0..<20 {
    _ = qwerty("nixianbashoujiandizhifageiwowojintianxiabanqianjichuqu")
}
let longerPerCall = Date().timeIntervalSince(longerStarted) / 20 * 1000
print(String(format: "  54 个字母的长句每次转换 %.2f 毫秒", longerPerCall))
check("54 个字母的长句不超过 30 毫秒", longerPerCall < 30)
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
