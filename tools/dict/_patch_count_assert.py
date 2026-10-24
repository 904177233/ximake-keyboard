"""一次性补丁：把 _simulate_engine.py 里的条数区间断言从 4000-7000 改为 30000-50000。

用途：词库扩展任务（v1.1.0，33,160 条）后，旧的规模区间断言必然失败；
这不是"删断言"，而是把区间同步到新的目标规模（详见 tools/dict/README.md 「词库扩展」小节）。
"""

import io
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TARGET = os.path.join(ROOT, "tools", "dict", "_simulate_engine.py")

OLD = 'run("\u603b\u6761\u6570\u5728 4000-7000", 4000 <= len(rows) <= 7000, True)'
NEW = 'run("\u603b\u6761\u6570\u5728 30000-50000", 30000 <= len(rows) <= 50000, True)'


def main() -> int:
    with io.open(TARGET, encoding="utf-8") as handle:
        text = handle.read()
    if NEW in text:
        print("[skip] 已经是新断言")
        return 0
    if OLD not in text:
        print("[fail] 找不到旧断言: %s" % OLD)
        return 1
    text = text.replace(OLD, NEW)
    with io.open(TARGET, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print("[ok] 条数断言已更新为 30000-50000")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
