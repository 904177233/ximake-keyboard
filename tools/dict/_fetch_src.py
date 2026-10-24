# -*- coding: utf-8 -*-
"""一次性下载脚本：抓取 jieba 词频表到 tools/dict/.cache/（不参与构建，仅作数据获取）。
构建脚本 build_dict.py 在找不到缓存时会自动调用本逻辑。
"""
import os
import sys
import urllib.request

CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache")

SOURCES = {
    "jieba_dict.txt": "https://raw.githubusercontent.com/fxsjy/jieba/master/jieba/dict.txt",
    "jieba_dict_big.txt": "https://raw.githubusercontent.com/fxsjy/jieba/master/extra_dict/dict.txt.big",
}


def fetch(name, url, force=False):
    os.makedirs(CACHE_DIR, exist_ok=True)
    dst = os.path.join(CACHE_DIR, name)
    if os.path.exists(dst) and os.path.getsize(dst) > 1024 and not force:
        print("[cache] %s 已存在 %d 字节" % (name, os.path.getsize(dst)))
        return dst
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Moyu dict builder)"})
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = resp.read()
    except Exception as exc:  # noqa: BLE001 - 下载失败要能降级
        print("[warn] 下载失败 %s: %s" % (url, exc))
        return None
    with open(dst, "wb") as fh:
        fh.write(data)
    print("[ok] %s -> %s (%d 字节)" % (url, dst, len(data)))
    return dst


def main():
    force = "--force" in sys.argv
    ok = 0
    for name, url in SOURCES.items():
        if fetch(name, url, force=force):
            ok += 1
    print("完成：%d 个源可用" % ok)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
