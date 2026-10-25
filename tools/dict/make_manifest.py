# -*- coding: utf-8 -*-
"""生成在线词库包清单 `ios/Shared/dict/dict_manifest.json`。

词库改过之后跑一次：

    python tools/dict/make_manifest.py

清单结构对应 Swift 的 `DictionaryPackManifest`：

    {
      "manifestVersion": 1,
      "packVersion": "1.2.0",
      "generatedAt": "2026-10-25T01:00:00Z",
      "entryCount": 33239,
      "files": [
        {"name": "base_dict.tsv", "url": "base_dict.tsv", "sha256": "...", "bytes": 827895},
        {"name": "chat_priority.tsv", "url": "chat_priority.tsv", "sha256": "...", "bytes": 4043}
      ]
    }

`url` 写相对文件名（下载时会拼到清单所在目录），也可以改成 https 绝对地址指向自建服务器。
"""

import hashlib
import io
import json
import os
import sys

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DICT_DIR = os.path.join(BASE, "ios", "Shared", "dict")
MANIFEST = os.path.join(DICT_DIR, "dict_manifest.json")
META = os.path.join(DICT_DIR, "dict_meta.json")

# 随包分发的文件（顺序即安装顺序；dict_meta.json 只是元信息，也一起带上便于安装后读版本）
FILES = ["base_dict.tsv", "chat_priority.tsv", "dict_meta.json"]


def sha256_of(path):
    digest = hashlib.sha256()
    with io.open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def count_entries(path):
    total = 0
    with io.open(path, "r", encoding="utf-8", newline="\n") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            total += 1
    return total


def main():
    missing = [name for name in FILES if not os.path.exists(os.path.join(DICT_DIR, name))]
    if missing:
        print("缺少文件: %s" % ", ".join(missing), file=sys.stderr)
        return 2

    pack_version = "1.0.0"
    if os.path.exists(META):
        with io.open(META, "r", encoding="utf-8") as handle:
            pack_version = json.load(handle).get("version", pack_version)

    files = []
    for name in FILES:
        path = os.path.join(DICT_DIR, name)
        files.append({
            "name": name,
            "url": name,
            "sha256": sha256_of(path),
            "bytes": os.path.getsize(path),
        })

    entry_count = count_entries(os.path.join(DICT_DIR, "base_dict.tsv"))
    manifest = {
        "manifestVersion": 1,
        "packVersion": pack_version,
        "generatedAt": "2026-10-25T01:00:00Z",
        "entryCount": entry_count,
        "files": files,
    }

    with io.open(MANIFEST, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    print("写出 %s" % os.path.relpath(MANIFEST, BASE))
    print("  packVersion = %s" % pack_version)
    print("  entryCount  = %d" % entry_count)
    for item in files:
        print("  %-18s %9d B  %s" % (item["name"], item["bytes"], item["sha256"][:16]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
