# -*- coding: utf-8 -*-
"""把 `chat_priority.py` 的聊天权重表落到实际产物上。

做三件事：
1. 生成 `ios/Shared/dict/chat_priority.tsv`（两列，UTF-8 无 BOM、纯 LF）；
2. 把表里**原本不在**词库的词补进 `base_dict.tsv`（flags 含 `chat`，词频按权重给）；
3. 同步 `dict_meta.json` 的条数 / 字节 / SHA256 / flags 分布。

硬约束（`PinyinDictionary.parse` 依赖）：
- `base_dict.tsv` 恒为 4 列 `拼音 <TAB> 词 <TAB> 词频 <TAB> flags`；
- 无空行、无注释行（首行表头除外）、无 BOM、纯 LF；
- **已有条目的词频一个都不改**（只追加缺失词），否则等于重新洗了一遍排序。

用法：
    python tools/dict/_apply_chat_priority.py           # 应用
    python tools/dict/_apply_chat_priority.py --check   # 只报告差异，不写文件
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import chat_priority  # noqa: E402

DICT_DIR = os.path.join(ROOT, "ios", "Shared", "dict")
BASE_PATH = os.path.join(DICT_DIR, "base_dict.tsv")
META_PATH = os.path.join(DICT_DIR, "dict_meta.json")
CHAT_PATH = os.path.join(DICT_DIR, "chat_priority.tsv")

# 表头里的版本号/分隔说明沿用原样，只替换条数
HEADER_PREFIX = "# 墨语输入法基础词库"


def read_rows(path):
    """读 base_dict.tsv -> (header, [(pinyin, word, freq, flags)])。"""
    with open(path, "r", encoding="utf-8", newline="") as handle:
        lines = handle.read().split("\n")
    header = ""
    rows = []
    for index, line in enumerate(lines):
        if not line:
            continue
        if line.startswith("#"):
            if index == 0:
                header = line
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            raise SystemExit("列数异常（%d 列）：%r" % (len(fields), line))
        rows.append((fields[0], fields[1], int(fields[2]), fields[3]))
    return header, rows


def render(header, rows):
    """4 列 TSV，词频降序 + 拼音 + 词 稳定排序；末尾单个 LF。"""
    rows = sorted(rows, key=lambda row: (-row[2], row[0], row[1]))
    body = "\n".join("%s\t%s\t%d\t%s" % row for row in rows)
    return "%s\n%s\n" % (header, body), rows


def flag_counts(rows):
    counts = {}
    for _, _, _, flags in rows:
        for flag in flags.split(","):
            flag = flag.strip()
            if flag:
                counts[flag] = counts.get(flag, 0) + 1
    return dict(sorted(counts.items()))


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="只报告差异，不写文件")
    args = parser.parse_args(argv)

    table = chat_priority.table()
    header, rows = read_rows(BASE_PATH)
    present = {row[1] for row in rows}

    added = []
    for word, weight in chat_priority.ordered():
        if word in present:
            continue
        pinyin = chat_priority.pinyin_of(word)
        added.append((pinyin, word, chat_priority.missing_frequency(weight), "chat"))

    print("权重表 %d 条；词库已有 %d 条；本次新增 %d 条" % (len(table), len(rows), len(added)))

    chat_tsv = "\n".join("%s\t%s" % pair for pair in chat_priority.iter_rows()) + "\n"
    old_chat = ""
    if os.path.exists(CHAT_PATH):
        with open(CHAT_PATH, "r", encoding="utf-8", newline="") as handle:
            old_chat = handle.read()
    if old_chat != chat_tsv:
        print("chat_priority.tsv：内容有更新（%d 条）" % len(chat_priority.iter_rows()))
        if not args.check:
            with open(CHAT_PATH, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(chat_tsv)
    else:
        print("chat_priority.tsv：已是最新")

    if not added:
        print("base_dict.tsv：无需补词")
    else:
        print("新增词：%s" % " ".join(row[1] for row in added))
        if args.check:
            print("（--check 模式，不写文件）")
            return 0

    # 表头：只更新条数，版本号沿用原值（默认 v1.1.0）
    match = re.search(r"v(\d+\.\d+\.\d+)", header or "")
    version = match.group(1) if match else "1.1.0"
    header = "%s v%s | 拼音\t词\t词频\tflags | 共 %d 条" % (
        HEADER_PREFIX,
        version,
        len(rows) + len(added),
    )

    merged = rows + added
    text, merged = render(header, merged)
    data = text.encode("utf-8")

    meta = {}
    if os.path.exists(META_PATH):
        with open(META_PATH, "r", encoding="utf-8") as handle:
            meta = json.load(handle)
    meta["count"] = len(merged)
    meta.setdefault("files", {})["base_dict.tsv"] = {
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }
    meta["flags"] = flag_counts(merged)
    sources = meta.get("sources", [])
    if not any(item.get("name") == "chat_priority.py" for item in sources):
        sources.append(
            {
                "license": "项目内使用",
                "name": "chat_priority.py",
                "url": "本项目原创",
            }
        )
    meta["sources"] = sources

    if not args.check:
        with open(BASE_PATH, "wb") as handle:
            handle.write(data)
        with open(META_PATH, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(meta, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        print(
            "已写入 base_dict.tsv：%d 条 / %d 字节 / sha256 %s"
            % (len(merged), len(data), meta["files"]["base_dict.tsv"]["sha256"])
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
