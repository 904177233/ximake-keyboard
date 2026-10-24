#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""watch_gen.py —— 源码变化时自动重跑 gen_xcodeproj.py 的守护脚本。

背景
----
`ios/AIKeyboard.xcodeproj/project.pbxproj` 是 `scripts/gen_xcodeproj.py` 按磁盘上
真实存在的 `.swift` 文件列表生成的。并行开发阶段，其他智能体/同事会随时往
`ios/Shared/`、`ios/AIKeyboard/`、`ios/AIKeyboardExtension/` 里增删文件，
一旦忘了重跑生成器，`scripts/qa/project_check.py` 就会报
`PBX-UNTRACKED-SOURCE` / `PBX-SHARED-NOT-IN-APP` / `PBX-SHARED-NOT-IN-EXT`。

这个脚本用最朴素的「轮询 mtime」方式盯着那三个源码目录（以及 `ios/Shared/dict` 词库目录），
发现变化就自动跑一次生成器 + 结构校验。没有第三方依赖，只用标准库，
所以在 Windows / macOS / CI 上都能直接跑。

用法
----
    # 前台跑，Ctrl+C 停止（推荐：开发时挂在旁边一个窗口）
    python scripts/watch_gen.py

    # 后台跑（Windows PowerShell）
    Start-Process -WindowStyle Hidden python -ArgumentList "scripts/watch_gen.py"

    # 只监控不自动生成（先看看谁在动文件）
    python scripts/watch_gen.py --dry-run

    # 自定义轮询间隔（秒，默认 3）
    python scripts/watch_gen.py --interval 5

参数
----
--interval N    轮询间隔秒数，默认 3，最小 1。
--dry-run       只打印检测到的变化，不实际执行生成器。
--once          扫一轮就退出（用于脚本里的一次性检查）。
--quiet         只打印「真的重跑了生成器」的行，忽略「无变化」。

退出码
------
0 正常结束（--once 模式下始终 0）；2 参数错误或仓库结构不对。

注意
----
- 这个脚本**不是**构建流程的一部分，纯开发期辅助工具，不参与 CI 的硬门禁。
- 它只是把「手动跑 gen」变成「自动跑 gen」，**不替代** `scripts/finalize.ps1` /
  `scripts/finalize.sh` 的完整 5 闸门；冻结前仍然要跑一次 finalize。
- 生成器本身是幂等的（同样的磁盘内容 -> 同样的 pbxproj 字节），所以多跑几次
  不会产生垃圾提交；`gen_xcodeproj.py --check` 就是用来验证这一点的。
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
GEN_SCRIPT = SCRIPTS_DIR / "gen_xcodeproj.py"
VALIDATE_SCRIPT = SCRIPTS_DIR / "validate_project.py"

#: 需要监控的目录（相对仓库根）。只有这些目录里的文件变化才可能影响 pbxproj。
WATCH_DIRS = (
    "ios/Shared",
    "ios/AIKeyboard",
    "ios/AIKeyboardExtension",
)

#: 影响工程文件的扩展名。`.xcassets` 是目录，单独处理。
WATCH_SUFFIXES = {".swift", ".plist", ".xcconfig", ".tsv", ".json", ".txt"}

#: 生成器/校验器自身的修改也要触发重跑（改脚本 = 改生成结果）。
WATCH_SCRIPTS = ("gen_xcodeproj.py",)

#: 需要跳过扫描的目录名（构建产物 / 缓存 / IDE 元数据）。
SKIP_DIR_NAMES = {
    ".git", ".build", "build", "DerivedData", "xcuserdata",
    ".swiftpm", "__pycache__", "node_modules", ".venv", "venv",
}

# ---------------------------------------------------------------------------
# 快照
# ---------------------------------------------------------------------------


class Entry:
    """一个被监控文件的轻量快照。"""

    __slots__ = ("mtime", "size")

    def __init__(self, mtime: float, size: int) -> None:
        self.mtime = mtime
        self.size = size

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Entry):
            return NotImplemented
        return self.mtime == other.mtime and self.size == other.size

    def __repr__(self) -> str:  # pragma: no cover - 仅调试用
        return f"Entry(mtime={self.mtime!r}, size={self.size})"


def _iter_files(root: Path):
    """递归产出 root 下所有「可能是工程输入」的文件（跳过 SKIP_DIR_NAMES）。"""
    if not root.exists():
        return
    stack = [root]
    while stack:
        current = stack.pop()
        try:
            children = sorted(current.iterdir())
        except (OSError, PermissionError):
            continue
        for child in children:
            name = child.name
            if name in SKIP_DIR_NAMES or name.startswith("."):
                # `.gitkeep` 之类不影响工程，跳过（但 .xcodeproj 不在监控范围内）
                if child.is_dir():
                    continue
                if name.startswith("."):
                    continue
                continue
            try:
                if child.is_dir():
                    stack.append(child)
                    continue
                if child.suffix.lower() not in WATCH_SUFFIXES:
                    continue
                stat = child.stat()
            except (OSError, PermissionError):
                continue
            yield child, stat


def take_snapshot() -> dict[str, Entry]:
    """对全部监控目标拍一次快照，返回 {相对仓库根的 posix 路径: Entry}。"""
    snapshot: dict[str, Entry] = {}
    for rel_dir in WATCH_DIRS:
        for path, stat in _iter_files(REPO_ROOT / rel_dir):
            try:
                rel = path.relative_to(REPO_ROOT).as_posix()
            except ValueError:  # pragma: no cover - 理论上不会发生
                continue
            snapshot[rel] = Entry(stat.st_mtime, stat.st_size)
    for name in WATCH_SCRIPTS:
        path = SCRIPTS_DIR / name
        if path.is_file():
            stat = path.stat()
            snapshot[f"scripts/{name}"] = Entry(stat.st_mtime, stat.st_size)
    return snapshot


def diff_snapshots(old: dict[str, Entry], new: dict[str, Entry]):
    """对比两次快照，返回 (新增列表, 删除列表, 修改列表)。"""
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    changed = sorted(k for k in (set(old) & set(new)) if old[k] != new[k])
    return added, removed, changed


# ---------------------------------------------------------------------------
# 执行
# ---------------------------------------------------------------------------


def run_python(script: Path, extra_args: list[str] | None = None) -> int:
    """用当前解释器跑一个脚本，输出直通到终端。返回退出码。"""
    cmd = [sys.executable, str(script)]
    if extra_args:
        cmd.extend(extra_args)
    print(f"    $ {Path(sys.executable).name} {' '.join(p.name if p.parent == SCRIPTS_DIR else str(p) for p in [script, *(extra_args or [])])}")
    try:
        # 不捕获输出：让子进程直接写终端，保留颜色/中文/进度
        return subprocess.call(cmd, cwd=str(REPO_ROOT))
    except OSError as exc:
        print(f"    [错误] 无法执行 {script.name}: {exc}", file=sys.stderr)
        return 2


def regenerate(verbose: bool = True) -> bool:
    """跑一次生成器 + 结构校验。全绿返回 True。"""
    if verbose:
        print("[gen] 检测到变化，重新生成 Xcode 工程 …")
    code = run_python(GEN_SCRIPT)
    if code != 0:
        print(f"[失败] gen_xcodeproj.py 退出码 {code}（工程文件可能暂时不一致）", file=sys.stderr)
        return False
    if verbose:
        print("[gen] 生成完毕，跑结构校验 …")
    code = run_python(VALIDATE_SCRIPT)
    if code != 0:
        print(f"[失败] validate_project.py 退出码 {code}", file=sys.stderr)
        return False
    print("[gen] 生成 + 校验通过\n")
    return True


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def preflight() -> bool:
    """检查仓库结构与基础脚本存在。"""
    problems: list[str] = []
    if not GEN_SCRIPT.is_file():
        problems.append(f"缺少 {GEN_SCRIPT.relative_to(REPO_ROOT).as_posix()}")
    if not VALIDATE_SCRIPT.is_file():
        problems.append(f"缺少 {VALIDATE_SCRIPT.relative_to(REPO_ROOT).as_posix()}")
    for rel_dir in WATCH_DIRS:
        if not (REPO_ROOT / rel_dir).is_dir():
            problems.append(f"监控目录不存在：{rel_dir}")
    if problems:
        print("[错误] 仓库结构不完整：", file=sys.stderr)
        for item in problems:
            print(f"  - {item}", file=sys.stderr)
        return False
    return True


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="监控 ios/ 源码变化并自动重跑 gen_xcodeproj.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--interval", type=float, default=3.0, metavar="N",
                        help="轮询间隔秒数（默认 3，最小 1）")
    parser.add_argument("--dry-run", action="store_true",
                        help="只打印变化，不实际执行生成器")
    parser.add_argument("--once", action="store_true",
                        help="扫一轮就退出（用于一次性检查）")
    parser.add_argument("--quiet", action="store_true",
                        help="安静模式：不打印「无变化」之类的心跳行")
    args = parser.parse_args(argv)

    interval = max(float(args.interval), 1.0)

    if not preflight():
        return 2

    print("=" * 78)
    print(" 墨语（Moyu）· 源码变化自动重跑工程生成器（watch_gen.py）")
    print("=" * 78)
    print(f" 仓库根   : {REPO_ROOT}")
    print(f" 生成器   : scripts/gen_xcodeproj.py")
    print(f" 监控目录 : {', '.join(WATCH_DIRS)}")
    print(f" 轮询间隔 : {interval:g} 秒")
    if args.dry_run:
        print(" 模式     : DRY-RUN（只看变化，不生成）")
    print(" 停止方式 : Ctrl+C")
    print("=" * 78)
    print()

    # 启动时先同步一次：并行开发期磁盘上很可能已经有未纳入工程的新文件
    if not args.dry_run and not args.once:
        regenerate(verbose=True)
    elif args.once and not args.dry_run:
        regenerate(verbose=True)

    snapshot = take_snapshot()
    print(f"[watch] 已记录 {len(snapshot)} 个文件的初始状态，开始监控 …\n")

    if args.once:
        return 0

    if args.dry_run:
        # dry-run 不做生成，但仍然持续报告变化
        pass

    rounds = 0
    try:
        while True:
            time.sleep(interval)
            rounds += 1
            current = take_snapshot()
            added, removed, changed = diff_snapshots(snapshot, current)
            if not (added or removed or changed):
                if not args.quiet and rounds % 20 == 0:
                    print(f"[watch] {time.strftime('%H:%M:%S')} 无变化（已轮询 {rounds} 次）")
                continue

            stamp = time.strftime("%H:%M:%S")
            total = len(added) + len(removed) + len(changed)
            print(f"[watch] {stamp} 检测到 {total} 处变化：")
            for label, items in (("新增", added), ("删除", removed), ("修改", changed)):
                # 一次最多列 12 条，避免刷屏
                for item in items[:12]:
                    print(f"    {label}: {item}")
                if len(items) > 12:
                    print(f"    {label}: … 另有 {len(items) - 12} 个")

            # 先更新快照再生成：生成期间的新变化会在下一轮被捕获
            snapshot = current

            if args.dry_run:
                print("    （dry-run：跳过生成）\n")
                continue

            regenerate(verbose=True)
    except KeyboardInterrupt:
        print("\n[watch] 收到 Ctrl+C，退出。")
        print("[watch] 提醒：退出前建议手动跑一次 "
              "`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/finalize.ps1`")
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
