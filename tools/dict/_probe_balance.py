# -*- coding: utf-8 -*-
"""临时核查脚本（不入库）：检查 IMEKit 等 Swift 文件的括号配平与编码。"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIR = os.path.join(ROOT, "ios", "Shared", "IMECore")


def strip_code(text):
    """粗剥注释与字符串，便于数括号。"""
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            i = n if end < 0 else end + 3
            continue
        ch = text[i]
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            end = text.find("\n", i)
            i = n if end < 0 else end
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        if ch == '"':
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def main():
    bad = 0
    for name in sorted(os.listdir(DIR)):
        if not name.endswith(".swift"):
            continue
        path = os.path.join(DIR, name)
        raw = open(path, "rb").read()
        text = raw.decode("utf-8")
        code = strip_code(text)
        pairs = [("{", "}"), ("(", ")"), ("[", "]")]
        detail = []
        for left, right in pairs:
            a, b = code.count(left), code.count(right)
            detail.append("%s%s=%d/%d" % (left, right, a, b))
            if a != b:
                bad += 1
        flags = []
        if raw[:3] == b"\xef\xbb\xbf":
            flags.append("BOM")
        if b"\r" in raw:
            flags.append("CR")
        if b"\t" in raw:
            flags.append("TAB")
        lines = text.count("\n")
        print("%-32s %4d 行 %6dB  %s  %s" % (name, lines, len(raw), " ".join(detail), ",".join(flags) or "OK"))
    print("\n括号失衡文件数：", bad)
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
