"""L1 本地联想质量评测（仅本机诊断用，不参与构建）。

用途：把 `ContextualSeedTemplates.swift` 里的触发词表当成**唯一真相源**解析出来，
在 Python 里复刻 `LocalSuggestionIndex.suggestions(context:composing:limit:)` 的
匹配规则（末句截取 → 按「触发词长度降序、置信度降序」找第一个后缀命中 → 取短句），
然后对 30 个典型上文逐条打印「上文 → 产出」，用来做人工质量评审。

为什么要用 Python 复刻：
- Swift 只能跑在 macOS/Xcode，评审时拿不到现成输出；
- 直接读 Swift 源码解析，改模板后结果立刻可见，不会出现「代码改了、评测还是旧表」。

运行：
    python tools/dict/_eval_suggestion.py            # 打印 30 条评审表
    python tools/dict/_eval_suggestion.py --strict   # 额外跑模板规范校验（违规退出码 1）

退出码：0 正常；1 `--strict` 下发现违规。
"""

import argparse
import os
import re
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEMPLATES_PATH = os.path.join(ROOT, "ios", "Shared", "IMECore", "ContextualSeedTemplates.swift")

# 与 ContextualSuggestion.swift 保持一致的常量（改那边必须同步改这里）
MINIMUM_CONTEXT_KEY_LENGTH = 2
MAXIMUM_SENTENCE_CHARACTERS = 32
MAXIMUM_LOCAL_RESULTS = 2

# 句子终止符（ContextualSuggestion.isSentenceTerminator）
TERMINATORS = set("。．.！!？?；;…\n\r")

# 句末语气词（ContextualSuggestion.sentenceFinalParticles）
SENTENCE_FINAL_PARTICLES = set("啊呀呢吧嘛哦啦咯呐哈")

# 30 个典型上文：覆盖问候、吃饭、时间、感谢、道歉、工作、情绪等场景。
CONTEXTS = [
    "在吗",
    "在干嘛",
    "我到家了",
    "你吃饭了吗",
    "明天几点",
    "谢谢你",
    "晚安",
    "这个多少钱",
    "我明天有事",
    "在忙吗",
    "好的我看看",
    "早点休息",
    "周末有空吗",
    "今天好累",
    "生日快乐",
    "新年快乐",
    "我刚到公司",
    "下班了吗",
    "在开会",
    "我发你了",
    "怎么办啊",
    "哈哈哈",
    "真的吗",
    "睡了吗",
    "你在哪",
    "好久不见",
    "我感冒了",
    "考试加油",
    "到家了吗",
    "今天下雨了",
]

RULE_PATTERN = re.compile(
    r'Rule\(trigger:\s*"([^"]*)",\s*texts:\s*\[(.*?)\],\s*confidence:\s*([0-9.]+)\)',
    re.S,
)
TEXT_PATTERN = re.compile(r'"([^"]*)"')


def _is_ignorable(character):
    """空白、标点、符号都算可忽略（对齐 Swift 的 isWhitespace/isPunctuation/isSymbol）。"""
    category = unicodedata.category(character)
    return character.isspace() or category.startswith("P") or category.startswith("S")


def last_sentence(context):
    """复刻 ContextualSuggestion.lastSentence：取末句、去尾标点、最长 32 字。"""
    text = context
    while text and _is_ignorable(text[-1]):
        text = text[:-1]
    if not text:
        return ""

    buffer = []
    for character in reversed(text):
        if character in TERMINATORS:
            if not buffer:
                continue
            break
        buffer.append(character)
        if len(buffer) >= MAXIMUM_SENTENCE_CHARACTERS:
            break
    sentence = "".join(reversed(buffer))
    while sentence and _is_ignorable(sentence[-1]):
        sentence = sentence[:-1]
    return sentence


def load_rules(path=TEMPLATES_PATH):
    """从 Swift 源码解析出规则表，返回 [{trigger, texts, confidence}]。"""
    with open(path, "r", encoding="utf-8") as handle:
        source = handle.read()
    rules = []
    for trigger, texts_blob, confidence in RULE_PATTERN.findall(source):
        texts = TEXT_PATTERN.findall(texts_blob)
        rules.append({"trigger": trigger, "texts": texts, "confidence": float(confidence)})
    return rules


def sorted_rules(rules):
    """与 LocalSuggestionIndex.init 的排序一致：触发词长度降序 → 置信度降序。"""
    return sorted(rules, key=lambda rule: (-len(rule["trigger"]), -rule["confidence"]))


def trigger_matches(sentence, trigger):
    """复刻 ContextualSuggestion.triggerMatches：允许句尾带语气词。"""
    if not trigger:
        return False
    if sentence.endswith(trigger):
        return True
    trimmed = sentence
    while trimmed and trimmed[-1] in SENTENCE_FINAL_PARTICLES and len(trimmed) > len(trigger):
        trimmed = trimmed[:-1]
        if trimmed.endswith(trigger):
            return True
    return False


def suggest(sentence, rules, limit=MAXIMUM_LOCAL_RESULTS, composing=""):
    """复刻 L1 的无学习态分支（评测只关心内置模板）。"""
    budget = min(limit, MAXIMUM_LOCAL_RESULTS)
    if composing:
        budget = min(budget, 1)
    if budget <= 0 or len(sentence) < MINIMUM_CONTEXT_KEY_LENGTH:
        return []
    results = []
    for rule in sorted_rules(rules):
        if not trigger_matches(sentence, rule["trigger"]):
            continue
        for raw in rule["texts"]:
            if len(results) >= budget:
                break
            text = raw.strip()
            if not text or text == sentence:
                continue
            results.append({"text": text, "trigger": rule["trigger"], "confidence": rule["confidence"]})
        break
    return results


def review(contexts, rules):
    """打印「上文 → 产出」评审表，并给每条产出打质量标记。"""
    rows = []
    for index, context in enumerate(contexts, 1):
        sentence = last_sentence(context)
        produced = suggest(sentence, rules)
        flags = []
        if not produced:
            flags.append("无产出")
        for item in produced:
            text = item["text"]
            if text in sentence or sentence in text:
                flags.append("复述")
            if len(text) <= 1:
                flags.append("单词")
            if len(text) > MAXIMUM_SENTENCE_CHARACTERS:
                flags.append("过长")
        rows.append((index, context, sentence, produced, flags))

        print("[%02d] 上文：%s" % (index, context))
        print("     末句：%s" % (sentence or "（空）"))
        if produced:
            joined = " ｜ ".join(
                "%s（%s %.2f）" % (item["text"], item["trigger"], item["confidence"] * 0.92)
                for item in produced
            )
            print("     产出：%s" % joined)
        else:
            print("     产出：（静默不显示）")
        if flags:
            print("     标记：%s" % "、".join(sorted(set(flags))))
        print("")

    hit = sum(1 for row in rows if row[3])
    print("=" * 78)
    print("共 %d 条上文：有产出 %d 条（%.0f%%），无产出 %d 条"
          % (len(rows), hit, hit * 100.0 / max(1, len(rows)), len(rows) - hit))
    repeated = sum(1 for row in rows if "复述" in row[4])
    print("产出里出现「复述上文」的：%d 条；出现单词候选的：%d 条"
          % (repeated, sum(1 for row in rows if "单词" in row[4])))
    print("模板：%d 组 / %d 条短句" % (len(rules), sum(len(rule["texts"]) for rule in rules)))
    print("=" * 78)
    return rows


def strict_check(rules):
    """模板规范校验：宁缺毋滥的机械化底线。返回违规列表。"""
    problems = []
    seen_triggers = {}
    for rule in rules:
        trigger = rule["trigger"]
        if len(trigger) < MINIMUM_CONTEXT_KEY_LENGTH:
            problems.append("触发词过短（<2 字）：%r" % trigger)
        if trigger in seen_triggers:
            problems.append("触发词重复：%r" % trigger)
        seen_triggers[trigger] = True
        if not rule["texts"]:
            problems.append("规则没有候选：%r" % trigger)
        if not 0.4 <= rule["confidence"] <= 0.95:
            problems.append("置信度越界（0.4-0.95）：%r %.2f" % (trigger, rule["confidence"]))
        seen_texts = set()
        for text in rule["texts"]:
            if text in seen_texts:
                problems.append("候选重复：%r -> %r" % (trigger, text))
            seen_texts.add(text)
            if len(text) <= 1:
                problems.append("候选过短（单词）：%r -> %r" % (trigger, text))
            if text == trigger:
                problems.append("候选等于触发词：%r" % trigger)
            if len(text) > MAXIMUM_SENTENCE_CHARACTERS:
                problems.append("候选过长（>32 字）：%r -> %r" % (trigger, text))
    if len(rules) > 120:
        problems.append("规则过多（%d 组，上限 120）：触发词越多，撞上无关后缀的概率越大" % len(rules))
    return problems


def main():
    parser = argparse.ArgumentParser(description="L1 本地联想质量评测")
    parser.add_argument("--strict", action="store_true", help="额外跑模板规范校验")
    args = parser.parse_args()

    if not os.path.exists(TEMPLATES_PATH):
        print("模板文件不存在：%s" % TEMPLATES_PATH)
        return 1
    rules = load_rules()
    if not rules:
        print("没解析到任何规则，检查 ContextualSeedTemplates.swift 的写法：%s" % TEMPLATES_PATH)
        return 1

    review(CONTEXTS, rules)

    if args.strict:
        problems = strict_check(rules)
        if problems:
            print("模板规范校验：%d 项违规" % len(problems))
            for problem in problems:
                print("  - %s" % problem)
            return 1
        print("模板规范校验：通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
