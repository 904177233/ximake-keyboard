# -*- coding: utf-8 -*-
"""il_install.py —— 用 iloader 把未签名 IPA 签名并装到 iPhone 的一键脚本。

放在 `scripts/lead/` 下，与其它 Lead 只读检查器并列。它**不是构建的一部分**，
不进六闸门，只是一个「Windows 上装机」的自动化助手。

前置条件：
  1. iPhone 已用数据线接上、已信任本机、Apple Mobile Device Service 在跑
     （认不出设备时按 docs/04 §4.2 清幽灵设备）；
  2. iloader 已装好，并且**带 CDP 端口**启动（见下面用法）；
  3. iloader 里已登录 Apple ID（首次会弹 2FA 验证码，需人工填）。

用法：
  # 启动 iloader 并开 CDP（端口固定 9333，脚本里 CDP_PORT 可改）
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = '--remote-debugging-port=9333 --remote-allow-origins=*'
  Start-Process "$env:LOCALAPPDATA\\iloader\\iloader.exe"

  # 装机
  python scripts/lead/il_install.py --ipa dist\\AIKeyboard-unsigned.ipa

  # 插上手机后自动开跑
  python scripts/lead/il_install.py --wait-device 600

退出码：
  0 SUCCESS / 1 FAILED / 3 NO_DEVICE / 4 NOT_LOGGED_IN /
  5 NO_DIALOG / 6 NO_SIGN_BUTTON / 7 TIMEOUT

实现要点（踩过的坑都写在注释里，别删）：
  - iloader 是 Tauri + WebView2，UI Automation 读不到内容，只能走 CDP；
  - CDP 握手必须带 `--remote-allow-origins=*`，否则 WebSocket 403；
  - 「打开」文件对话框是原生 Win32（类名 #32770），不走 CDP：
    文件名输入框用 WM_SETTEXT(0x000C)，「打开」按钮用 BM_CLICK(0x00F5)；
  - 导入 IPA 后 iloader **会自动开始签名安装**，不需要也不应该再点按钮
    （旧版立刻找按钮会误判 NO_SIGN_BUTTON，见下方观察窗口）。
"""


import argparse
import asyncio
import ctypes
import ctypes.wintypes as wt
import json
import sys
import time
import warnings

import websocket

warnings.filterwarnings("ignore")

CDP_PORT = 9333
TARGET_IPA = r"dist\AIKeyboard-unsigned.ipa"

# WM_SETTEXT / WM_GETTEXT / BM_CLICK
WM_SETTEXT = 0x000C
WM_GETTEXT = 0x000D
BM_CLICK = 0x00F5


# --------------------------------------------------------------------------- #
# Win32 helpers (native "Open" file dialog)
# --------------------------------------------------------------------------- #

_user32 = ctypes.WinDLL("user32", use_last_error=True)

_user32.FindWindowW.restype = wt.HWND
_user32.FindWindowW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p]

_user32.GetDlgItem.restype = wt.HWND
_user32.GetDlgItem.argtypes = [wt.HWND, ctypes.c_int]

_user32.GetClassNameW.restype = ctypes.c_int
_user32.GetClassNameW.argtypes = [wt.HWND, ctypes.c_wchar_p, ctypes.c_int]

_user32.SendMessageW.restype = ctypes.c_ssize_t
# SendMessageW 的 wParam 是整数、lParam 才可能是字符串指针，
# 统一声明成 c_size_t / c_void_p，由调用点自己 ctypes.cast 出指针。
# （早前把 wParam 也声明成 c_wchar_p，导致 WM_SETTEXT 传 0 时抛
#   TypeError: int object cannot be interpreted as ctypes.c_wchar_p）
_user32.SendMessageW.argtypes = [wt.HWND, ctypes.c_uint, ctypes.c_size_t, ctypes.c_void_p]

_EnumWindowsProc = ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)
_user32.EnumWindows.argtypes = [_EnumWindowsProc, wt.LPARAM]


def _enum_windows():
    """枚举所有顶层窗口，返回 [(hwnd, class, title)]。"""
    found = []

    @_EnumWindowsProc
    def _cb(hwnd, _lparam):
        buf = ctypes.create_unicode_buffer(256)
        _user32.GetClassNameW(hwnd, buf, 256)
        cls = buf.value
        tbuf = ctypes.create_unicode_buffer(512)
        _user32.GetWindowTextW(hwnd, tbuf, 512)
        found.append((int(hwnd), cls, tbuf.value))
        return True

    _user32.EnumWindows(_cb, 0)
    return found


_user32.GetWindowTextW.restype = ctypes.c_int
_user32.GetWindowTextW.argtypes = [wt.HWND, ctypes.c_wchar_p, ctypes.c_int]


def find_dialog(timeout=25.0):
    """等待并定位 iloader 弹出的原生「打开」对话框（类名 #32770）。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for hwnd, cls, title in _enum_windows():
            if cls == "#32770" and ("打开" in title or "Open" in title):
                return hwnd
        time.sleep(0.4)
    return 0


def fill_dialog_and_open(hwnd, path):
    """把路径写进对话框的文件名输入框，再点「打开」。"""
    # 文件名输入框：优先 GetDlgItem(1148)，找不到就退回顶层第一个 Edit。
    edit = _user32.GetDlgItem(hwnd, 0x47C)  # 1148
    if not edit:
        for child_hwnd, cls, _title in _enum_windows():
            if cls == "Edit":
                edit = child_hwnd
                break
    if not edit:
        return "NO_EDIT"

    _user32.SendMessageW(edit, WM_SETTEXT, 0, ctypes.cast(ctypes.c_wchar_p(path), ctypes.c_void_p))

    # 回读确认
    buf = ctypes.create_unicode_buffer(1024)
    _user32.SendMessageW(edit, WM_GETTEXT, 1024, ctypes.cast(buf, ctypes.c_void_p))
    if buf.value.strip().lower() != path.strip().lower():
        return "SETTEXT_FAILED"

    # 点「打开」（IDOK）
    btn = _user32.GetDlgItem(hwnd, 1)
    if not btn:
        return "NO_OK_BUTTON"
    _user32.SendMessageW(btn, BM_CLICK, 0, 0)
    return "OK"


# --------------------------------------------------------------------------- #
# CDP (iloader is Tauri + WebView2; UI Automation cannot see its content)
# --------------------------------------------------------------------------- #


class Il:
    """iloader 的极简 CDP 客户端。"""

    def __init__(self, port=CDP_PORT):
        import urllib.request

        with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5) as r:
            targets = json.loads(r.read().decode("utf-8"))
        if not targets:
            raise RuntimeError("no CDP target")
        ws_url = targets[0]["webSocketDebuggerUrl"]
        # Tauri 页面在 tauri.localhost 源上，不带 origin 会被 DevTools 拒绝。
        self.ws = websocket.create_connection(ws_url, timeout=15, suppress_origin=True)
        self._id = 0
        self.send("Runtime.enable")

    def send(self, method, params=None):
        self._id += 1
        self.ws.send(json.dumps({"id": self._id, "method": method,
                                 "params": params or {}}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == self._id:
                return msg.get("result", {})

    def ev(self, expr):
        res = self.send("Runtime.evaluate",
                        {"expression": expr, "returnByValue": True, "awaitPromise": True})
        return res.get("result", {}).get("value")

    def body(self):
        return self.ev("document.body.innerText") or ""

    def click(self, predicate_js):
        """点击满足 `predicate_js` 的第一个 button。"""
        return self.ev(
            "(()=>{const bs=[...document.querySelectorAll('button')];"
            f"const b=bs.find({predicate_js});"
            "if(!b)return 'NOT_FOUND';b.click();return 'CLICKED';})()"
        )

    def click_text(self, text):
        return self.click(f"x=>(x.innerText||'').trim()==={json.dumps(text)}")

    def click_contains(self, needle):
        return self.click(
            f"x=>(x.innerText||'').toUpperCase().includes({json.dumps(needle.upper())})"
        )

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass


def device_count():
    try:
        from pymobiledevice3.usbmux import list_devices

        return len(asyncio.run(list_devices()))
    except Exception:
        return -1


def wait_for_device(seconds):
    if seconds <= 0:
        return device_count()
    deadline = time.time() + seconds
    while time.time() < deadline:
        n = device_count()
        if n > 0:
            return n
        time.sleep(5)
    return device_count()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", default=TARGET_IPA)
    ap.add_argument("--wait-device", type=int, default=0)
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--skip-import", action="store_true")
    args = ap.parse_args()

    n = wait_for_device(args.wait_device)
    print("USBMUX_COUNT:", n, flush=True)
    if n <= 0:
        print("RESULT: NO_DEVICE", flush=True)
        return 3

    d = Il()
    body = d.body()
    if "LOGGED IN AS" not in body.upper():
        print("RESULT: NOT_LOGGED_IN", flush=True)
        d.close()
        return 4

    print("click Refresh:", d.click_text("Refresh"), flush=True)
    time.sleep(4)

    if not args.skip_import:
        print("click Import IPA:", d.click_text("Import IPA"), flush=True)
        hwnd = find_dialog()
        if not hwnd:
            print("RESULT: NO_DIALOG", flush=True)
            print(d.body()[-600:].replace("\n", " | ")[:600], flush=True)
            d.close()
            return 5
        print("dialog hwnd:", hwnd, flush=True)
        print("fill dialog:", fill_dialog_and_open(hwnd, args.ipa), flush=True)
        time.sleep(6)

    # 导入 IPA 后 iloader 的行为分两种（2026-10-25 实测为第①种）：
    #   ① 自动开始签名安装 —— 此时**不该再点任何按钮**，直接等 "Operation completed"；
    #   ② 弹出确认框等用户点「Sign & Install App」。
    # 旧版在填完文件框后立刻找按钮，第①种情况下按钮还没出现，误判 NO_SIGN_BUTTON。
    # 所以先观察一段时间：出现进度/结果就直接进等待循环，没出现再去找按钮点。
    started = False
    observe_deadline = time.time() + 25
    while time.time() < observe_deadline:
        low = d.body().lower()
        if any(k in low for k in ("installing", "signing", "transferring",
                                  "operation completed", "operation failed")):
            started = True
            break
        time.sleep(2)

    if not started:
        for label in (
            "Sign & Install App",
            "Sign and Install App",
            "Sign & Install",
            "Install App",
        ):
            res = d.click_contains(label)
            if res == "CLICKED":
                print("clicked:", label, flush=True)
                started = True
                break

    if not started:
        print("RESULT: NO_SIGN_BUTTON", flush=True)
        print(d.body()[-800:].replace("\n", " | ")[:800], flush=True)
        d.close()
        return 6

    deadline = time.time() + args.timeout
    last = ""
    while time.time() < deadline:
        time.sleep(3)
        text = d.body()
        tail = " | ".join(x.strip() for x in text.splitlines() if x.strip())[-400:]
        if tail != last:
            print("[%ds] %s" % (int(time.time() % 10000), tail), flush=True)
            last = tail
        low = text.lower()
        if "operation completed" in low:
            print("RESULT: SUCCESS", flush=True)
            d.close()
            return 0
        if "operation failed" in low or ("error" in low and "failed" in low):
            print("RESULT: FAILED", flush=True)
            print(text[-1200:], flush=True)
            d.close()
            return 1

    print("RESULT: TIMEOUT", flush=True)
    print(d.body()[-1000:], flush=True)
    d.close()
    return 7


if __name__ == "__main__":
    sys.exit(main())
