#!/usr/bin/env python
"""轮询等待 iPhone 接入，接上后立即调用 il_install.py 装机。

用法：
    python scripts/lead/wait_and_install.py --ipa dist/AIKeyboard-unsigned.ipa --wait 1800

退出码：
    0  装机成功
    1  iloader 安装失败
    2  等待超时（设备一直没接上）
    3  iloader 未运行 / CDP 不可达
"""
from __future__ import annotations

import argparse
import asyncio
import os
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def device_count() -> int:
    try:
        from pymobiledevice3.usbmux import list_devices

        return len(asyncio.run(list_devices()))
    except Exception as exc:  # noqa: BLE001 - 探针失败一律当 0 处理
        print(f"  [usbmux 探针异常] {exc}")
        return 0


def iloader_ready() -> bool:
    import urllib.request

    try:
        with urllib.request.urlopen("http://127.0.0.1:9333/json/list", timeout=3) as resp:
            return resp.status == 200
    except Exception:  # noqa: BLE001 - 连不上就是不就绪
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", default="dist/AIKeyboard-unsigned.ipa")
    ap.add_argument("--wait", type=int, default=1800, help="最长等待设备接入的秒数")
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--timeout", type=int, default=900, help="传给 il_install.py 的安装超时")
    args = ap.parse_args()

    ipa = Path(args.ipa)
    if not ipa.is_absolute():
        ipa = REPO / ipa
    if not ipa.exists():
        print(f"IPA 不存在：{ipa}")
        return 1

    print(f"=" * 70)
    print(f"等待 iPhone 接入（最长 {args.wait} 秒，每 {args.interval} 秒轮询一次）")
    print(f"IPA：{ipa}（{ipa.stat().st_size:,} 字节）")
    print(f"=" * 70)

    deadline = time.time() + args.wait
    announced = False
    while time.time() < deadline:
        count = device_count()
        stamp = time.strftime("%H:%M:%S")
        if count > 0:
            print(f"[{stamp}] DEVICES={count} —— 已检测到设备，开始装机")
            break
        if not announced:
            print(f"[{stamp}] DEVICES=0 —— 等待中（请插上数据线并解锁手机）")
            announced = True
        time.sleep(args.interval)
    else:
        print("RESULT: TIMEOUT —— 等待超时，设备始终没有接上")
        return 2

    if not iloader_ready():
        print("RESULT: ILOADER_NOT_RUNNING —— CDP 9333 不可达")
        print("  请先启动 iloader：")
        print("    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS='--remote-debugging-port=9333 --remote-allow-origins=*'")
        print(r"    Start-Process 'C:\Users\z9041\AppData\Local\iloader\iloader.exe'")
        return 3

    print("-" * 70)
    print("调用 il_install.py …")
    print("-" * 70)
    env = dict(os.environ)
    env.setdefault("PYTHONIOENCODING", "utf-8")
    env.setdefault("PYTHONUTF8", "1")
    proc = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "lead" / "il_install.py"),
         "--ipa", str(ipa), "--timeout", str(args.timeout)],
        cwd=str(REPO), env=env,
    )
    return 0 if proc.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
