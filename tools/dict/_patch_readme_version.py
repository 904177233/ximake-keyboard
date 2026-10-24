"""一次性补丁：把 IMECore/README.md 里 `1.0.0` 版本号更新为 `1.1.0`（词库扩展后）。"""

from __future__ import annotations

import io
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PATH = os.path.join(ROOT, "ios", "Shared", "IMECore", "README.md")

REPLACEMENTS = [
    ('| 2 | `dict.version == "1.0.0"` | `true` |',
     '| 2 | `dict.version == "1.1.0"` | `true` |'),
    ('        assert(dict.version == "1.0.0",                       "版本号应为 1.0.0，实际 \\(dict.version)")',
     '        assert(dict.version == "1.1.0",                       "版本号应为 1.1.0，实际 \\(dict.version)")'),
    ('        assert(kit.dictionaryVersion == "1.0.0")',
     '        assert(kit.dictionaryVersion == "1.1.0")'),
    ('| `dictionaryVersion` | `String` | `"1.0.0"` | 来自 `dict_meta.json` 的 `version`；兜底时为 `"0.0.0-builtin"` |',
     '| `dictionaryVersion` | `String` | `"1.1.0"` | 来自 `dict_meta.json` 的 `version`；兜底时为 `"0.0.0-builtin"` |'),
]


def main() -> int:
    text = io.open(PATH, encoding="utf-8").read()
    missing = 0
    for old, new in REPLACEMENTS:
        count = text.count(old)
        if count == 0:
            missing += 1
            print("[miss] %s" % old.strip()[:70])
            continue
        text = text.replace(old, new)
        print("[ok %d] %s" % (count, old.strip()[:60]))
    io.open(PATH, "w", encoding="utf-8", newline="\n").write(text)
    print("[done] 未命中 %d 处" % missing)
    return 0 if missing == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
