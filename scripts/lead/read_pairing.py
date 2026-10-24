# -*- coding: utf-8 -*-
"""递归展开 Windows 上的 iOS 配对记录（Lockdown plist），找设备型号与系统版本。

配对文件是 plain dict plist，设备信息键名随 iOS 版本变化，所以这里暴力递归
打印所有「看起来像版本/型号」的键值，便于人工判读。

用法：python scripts/lead/read_pairing.py [--all]
      不带 --all 只展开与当前插着的手机对应的那条；带 --all 展开全部。
"""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path

LOCKDOWN = Path(r"C:\ProgramData\Apple\Lockdown")

# 当前插在电脑上的手机（来自 USB 序列号 VID_05AC&PID_12A8\00008120001C25860CB8C01E）
CURRENT_DEVICE_PREFIX = "00008120-001C25860CB8C01E"

# 递归深度上限，防止某些设备写入超深结构
MAX_DEPTH = 6


def walk(node, path: str, depth: int, out: list[tuple[str, str]]) -> None:
    """把嵌套结构拍平成 (路径, 值) 列表。"""
    if depth > MAX_DEPTH:
        out.append((path, "<超过深度上限>"))
        return
    if isinstance(node, dict):
        for key in sorted(node):
            walk(node[key], f"{path}.{key}" if path else str(key), depth + 1, out)
    elif isinstance(node, (list, tuple)):
        out.append((path, f"<{len(node)} 项 {type(node).__name__}>"))
        for index, item in enumerate(node):
            walk(item, f"{path}[{index}]", depth + 1, out)
    elif isinstance(node, bytes):
        out.append((path, f"<{len(node)} 字节二进制>"))
    else:
        out.append((path, repr(node)))


def main() -> int:
    show_all = "--all" in sys.argv[1:]
    if not LOCKDOWN.is_dir():
        print("配对记录目录不存在——这台电脑从未与任何 iOS 设备配对成功。")
        return 1

    targets = []
    for path in sorted(LOCKDOWN.glob("*.plist")):
        if path.name == "SystemConfiguration.plist":
            continue
        if not show_all and CURRENT_DEVICE_PREFIX not in path.name:
            continue
        targets.append(path)

    if not targets:
        print(f"没有找到与当前手机（{CURRENT_DEVICE_PREFIX}）对应的配对记录。")
        print("说明这台电脑还没被这台手机信任过——手机上应该会弹「要信任此电脑吗」。")
        return 2

    for path in targets:
        print("=" * 72)
        print("配对文件:", path.name, f"({path.stat().st_size} 字节)")
        try:
            with path.open("rb") as fh:
                data = plistlib.load(fh)
        except Exception as exc:  # noqa: BLE001 - 诊断脚本
            print("  解析失败:", f"{type(exc).__name__}: {exc}")
            continue
        flat: list[tuple[str, str]] = []
        walk(data, "", 0, flat)
        print(f"  展开后 {len(flat)} 项，其中与型号/版本有关的：")
        hits = 0
        for key, value in flat:
            lowered = key.lower()
            if any(word in lowered for word in (
                "version", "producttype", "productname", "model",
                "buildversion", "deviceclass", "unique",
            )):
                print(f"    {key:46} = {value}")
                hits += 1
        if hits == 0:
            print("    （无型号/版本字段——这个配对记录只保存了可信主机信息，不含设备版本）")
            print("    顶层键:", ", ".join(sorted(data)) if isinstance(data, dict) else type(data).__name__)
    return 0


if __name__ == "__main__":
    sys.exit(main())
