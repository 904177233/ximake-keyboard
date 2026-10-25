# -*- coding: utf-8 -*-
"""墨语输入法 · 聊天高频词权重表（唯一真相源）。

为什么需要这张表
----------------
`base_dict.tsv` 的词频来自 jieba 的新闻/百科语料。语料词频和「聊天里真正会打的词」
是错配的：
- 书面词被高估：`望去`(1082) / `顽强`(1619) / `无穷`(2775) 在语料里常见，聊天里几乎不打；
- 口语词被低估：`我去`(5200) / `好的`(原来不在词库) / `行吧`(6500) 在语料里偏低甚至缺失。

简拼（首字母，如 `wq`）是按词频排序的，于是 `wq` 的第一页成了「望去 顽强 无穷」，
而用户想要的是「我去」。这张表就是给「仅首字母命中」这条路径补一个聊天先验。

字段语义
--------
两列 TSV：`词 <TAB> 权重`，权重 1.0–3.0（越大越优先）。落盘到
`ios/Shared/dict/chat_priority.tsv`，Swift 端由 `ChatPriorityTable` 加载，
引擎按 `最终分 × (1 + 权重)` 放大「仅首字母命中」的候选（全拼/精确命中不受影响）。

权重怎么给
----------
- 3.0 聊天骨架：秒回型应答词，简拼必须第一屏（我去 / 你好 / 好的 / 嗯 / 哈哈 / 谢谢 / 收到）
- 2.5 强口语：生活时间词、当面沟通高频词（现在 / 今天 / 下班 / 到家 / 辛苦了）
- 2.0 常用表达：连接词与疑问短语（为什么 / 怎么办 / 可以吗 / 没事吧）
- 1.5 通用高频：语料里本来就靠前，只做轻微前移（什么 / 怎么 / 这个 / 我们）
- 1.0 保守：名词类聊天高频词，仅避免被同字母串的书面词挤掉（电话 / 快递 / 外卖）

新增或改权重时只改这个文件，然后跑：
    python tools/dict/chat_priority.py            # 校验 + 生成 chat_priority.tsv
    python tools/dict/_apply_chat_priority.py     # 补齐 base_dict.tsv 缺失词并重排
"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT_PATH = os.path.join(ROOT, "ios", "Shared", "dict", "chat_priority.tsv")

MIN_WEIGHT = 1.0
MAX_WEIGHT = 3.0

# ---- 3.0 聊天骨架：一屏必须能选到的应答词 ----
_W3_0 = """
我去 你好 您好 在吗 在的 在呢 在干嘛 怎么回事 好的 好的呀 好哒 好嘞 好的呢 好的吧
行吧 好吧 嗯 嗯嗯 嗯呢 嗯好 哈哈 哈哈哈 哈哈哈哈 谢谢 谢谢啦 谢啦 收到 收到啦 可以
没问题 麻烦了 辛苦了 不好意思 对不起 没关系 吃了吗 吃了没 睡了吗 等我 稍等 等一下
我看看 我知道 我不知道 我知道了 你说 你说呢 我到了 我在路上 有空 晚安 早安 拜拜 再见
加油 厉害 太棒了 不客气 明白了 懂了 有道理 笑死 无语 服了 绝了 救命 离谱 麻了
优秀 可爱 好看 别客气 放心 到家了 先忙 晚点聊 我去洗澡 我请客 早点睡 多喝热水 我来了
我马上到 是的呀 对呀 好呀 行呀 在忙吗
"""

# ---- 2.5 强口语：生活 / 时间 / 当面沟通 ----
_W2_5 = """
现在 今天 明天 昨天 刚才 马上 最近 晚上 早上 下午 中午 周末 上班 下班 加班 公司
到家 路上 堵车 出门 回家 睡觉 起床 吃饭 洗澡 有空吗 没时间 有时间 想你 麻烦你 麻烦你了
感谢 感谢你 抱歉 对不起啊 真不好意思 好的谢谢 太好了 真的呀 无语了 牛啊 厉害了 可以的
好嘛 对了 那我 那好 那行 晚点 一会 一会儿 待会 待会儿 马上来 这就来 在忙 忙完 忙完了
先挂了 挂了 我睡了 我去忙 我去吃饭 我在开会 我在上班 我在家 我刚到 我快到了 快到了
马上到 你到了吗 你在哪 你在干嘛 你在吗 辛苦了呀
"""

# ---- 2.0 常用表达：疑问 / 连接 / 委婉 ----
_W2_0 = """
可以吗 行吗 好吗 怎么样 什么意思 为啥 干什么 干嘛 干啥 多少钱 多久 多少 为什么 因为 所以
但是 不过 而且 然后 还有 反正 大概 差不多 好像 可能 也许 应该 肯定 必须 一定 真的 确实
当然 其实 至少 那就 怎么办 怎么说 怎么弄 什么时候 在哪里 在哪儿 行不行 好不好 对不对
是不是 有没有 要不要 能不能 会不会 可不可以 没事吧 没事儿 不行 不用 不用了 别急 别担心
慢慢来 注意安全 早点休息 好好休息 辛苦啦 麻烦啦 谢谢啊 谢谢您 知道了 明白 好的好的
行行行 好好好
"""

# ---- 1.5 通用高频：语料里已经靠前，只做轻微前移 ----
_W1_5 = """
什么 怎么 这个 那个 哪个 这样 那样 这些 那些 哪些 我们 你们 他们 咱们 大家 自己
知道 觉得 认为 希望 需要 喜欢 想要 看看 试试 想想 说说 问问 找找 上面 下面 里面
外面 前面 后面 时候 没有 是的 不是 算了 随便 都行 再说 再说吧 回头说 晚点说 看情况
"""

# ---- 1.0 保守：聊天里常出现，但语料词频已经不低 ----
_W1_0 = """
中国 问题 事情 东西 地方 时间 朋友 老师 学生 工作 生活 手机 微信 消息 图片 视频
会议 项目 方案 确认 回复 文件 邮件 电话 地址 快递 外卖 天气 电影 音乐 游戏 旅行
照片 电脑 充电 电量 网络 信号 导航 地图 付款 转账 红包 订单
"""

_GROUPS = [
    (3.0, _W3_0),
    (2.5, _W2_5),
    (2.0, _W2_0),
    (1.5, _W1_5),
    (1.0, _W1_0),
]

# 单词覆盖：权重按「简拼场景下更该排在前面」给，不按语料词频。
# `中国` 的语料词频(33177) 低于 `这个`(61310)，但简拼 `zg` 的第一屏必须是「中国」，
# 否则会退化成「这个 咱们 著名」——这是简拼排序先验，不是「口语词白名单」。
_OVERRIDES = {
    "中国": 3.0,
}

# 词库补词时给的词频：权重越高给得越足，但远低于「的/是/在」这类功能词（30 万+）。
_FREQ_BASE = 3000.0


def table() -> dict:
    """返回 `{词: 权重}`（已去重、已校验）。"""
    result = {}
    for weight, block in _GROUPS:
        for word in block.split():
            result[word] = max(result.get(word, 0.0), weight)
    for word, weight in _OVERRIDES.items():
        result[word] = weight
    return result


def ordered() -> list:
    """按（权重降序, 词升序）排好的 `[(词, 权重)]`，保证落盘可重跑幂等。"""
    return sorted(table().items(), key=lambda item: (-item[1], item[0]))


def missing_frequency(weight: float) -> int:
    """表里的词若原本不在 base_dict.tsv，补进去时用的词频（取整到 10）。"""
    return int(round(_FREQ_BASE * weight / 10.0) * 10)


def pinyin_of(word: str) -> str:
    """词 -> 连写全拼（与词库同一套 pypinyin 规则，ü 写作 v）。"""
    from pypinyin import Style, lazy_pinyin

    return "".join(lazy_pinyin(word, style=Style.NORMAL))


def iter_rows() -> list:
    """`[(词, 权重文本)]`，权重固定一位小数（1.0/1.5/2.0/2.5/3.0）。"""
    return [(word, "%.1f" % weight) for word, weight in ordered()]


def write_tsv(path: str = OUT_PATH) -> int:
    """写两列 TSV：UTF-8 无 BOM、纯 LF、无表头无注释行。返回条数。"""
    rows = iter_rows()
    text = "\n".join("%s\t%s" % (word, weight) for word, weight in rows) + "\n"
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    return len(rows)


def validate() -> list:
    """自查：权重区间 / 纯汉字 / 拼音可切分 / 无重复。返回问题列表。"""
    from syllable_table import is_splittable

    problems = []
    if not (200 <= len(table()) <= 400):
        problems.append("条数 %d 不在 200-400 区间" % len(table()))
    for word, weight in ordered():
        if not (MIN_WEIGHT <= weight <= MAX_WEIGHT):
            problems.append("%s 权重 %s 越界" % (word, weight))
        if not word:
            problems.append("空词")
            continue
        if not all("\u4e00" <= ch <= "\u9fff" for ch in word):
            problems.append("%s 含非汉字字符" % word)
        if not (1 <= len(word) <= 6):
            problems.append("%s 长度 %d 超出 1-6" % (word, len(word)))
        pinyin = pinyin_of(word)
        if not is_splittable(pinyin):
            problems.append("%s 拼音 %s 无法切分" % (word, pinyin))
    return problems


def main() -> int:
    problems = validate()
    print("聊天权重表：%d 条（权重 %.1f-%.1f）" % (len(table()), MIN_WEIGHT, MAX_WEIGHT))
    distribution = {}
    for _, weight in ordered():
        distribution[weight] = distribution.get(weight, 0) + 1
    for weight in sorted(distribution, reverse=True):
        print("  权重 %.1f：%d 条" % (weight, distribution[weight]))
    if problems:
        print("校验失败：")
        for item in problems:
            print("  -", item)
        return 1
    count = write_tsv()
    print("已写入 %s（%d 条）" % (os.path.relpath(OUT_PATH, ROOT), count))
    return 0


if __name__ == "__main__":
    sys.exit(main())
