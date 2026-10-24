# -*- coding: utf-8 -*-
"""用 usbmuxd 的 plist 协议查询已连接 iOS 设备（容忍连接重置，尽力读出负载）。

为什么单独一个脚本：
    Windows 版 AppleMobileDeviceService 的 usbmuxd 对协议版本很敏感。
    实测它接受「先长度后版本」的头（length, version=2, message=8, tag），
    并回一个 length=294 的响应，但随后会 RST 掉连接。
    大多数客户端（含 Sideloadly 内置的 libimobiledevice）在这种情况下会直接
    判定「没有设备」。所以这里把「响应到底说了什么」挖出来，用于区分：
      - 响应里是空 DeviceList   -> 手机确实没被 usbmuxd 枚举到
      - 响应里是完整设备列表     -> 枚举正常，问题在客户端

用法：python scripts/lead/usbmux_plist.py
"""

from __future__ import annotations

import plistlib
import socket
import struct
import sys

HOST = "127.0.0.1"
PORT = 27015

NEW_VERSION = 2
NEW_MESSAGE_PLIST = 8


def read_until_eof(sock: socket.socket, limit: int = 65536) -> bytes:
    """尽力读到 EOF 或超时；连接被对端 RST 时返回已读到的部分。"""
    chunks: list[bytes] = []
    total = 0
    while total < limit:
        try:
            chunk = sock.recv(min(4096, limit - total))
        except (ConnectionResetError, ConnectionAbortedError, socket.timeout) as exc:
            print(f"  （读取中止：{type(exc).__name__}）")
            break
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    return b"".join(chunks)


def main() -> int:
    request = {
        "MessageType": "ListDevices",
        "ClientVersionString": "usbmuxd_probe",
        "ProgName": "dsh-lead",
        "kLibUSBMuxVersion": 3,
    }
    payload = plistlib.dumps(request, fmt=plistlib.FMT_XML)
    # 新协议头：length 在前
    header = struct.pack("<IIII", len(payload), NEW_VERSION, NEW_MESSAGE_PLIST, 1)
    print(f"请求: header={len(header)}B payload={len(payload)}B")
    print(f"请求头十六进制: {header.hex(' ')}")

    try:
        with socket.create_connection((HOST, PORT), timeout=8.0) as sock:
            sock.settimeout(8.0)
            sock.sendall(header + payload)
            print("已发送，读取响应 ...")
            raw = read_until_eof(sock)
    except OSError as exc:
        print(f"连接失败：{type(exc).__name__}: {exc}")
        return 3

    print(f"\n共读到 {len(raw)} 字节")
    if len(raw) >= 16:
        # 先按「长度在前」解
        length, version, message, tag = struct.unpack("<IIII", raw[:16])
        print(
            f"响应头(按 length-first 解): length={length} version={version} "
            f"message={message} tag={tag}"
        )
        body = raw[16:]
        print(f"负载 {len(body)} 字节（头部声明 {length}）")
        print("负载前 240 字节:", body[:240])
        if body:
            for fmt_name, fmt in (("XML", plistlib.FMT_XML), ("binary", plistlib.FMT_BINARY)):
                try:
                    data = plistlib.loads(body, fmt=fmt)
                except Exception:  # noqa: BLE001 - 逐个格式试
                    continue
                print(f"\n>>> 负载按 {fmt_name} plist 解析成功：")
                print_plist(data)
                return 0
            print("\n负载不是可解析的 plist，原始十六进制：")
            print(body[:512].hex(" "))
    else:
        print("响应不足 16 字节，原始十六进制：")
        print(raw.hex(" ") or "(空)")
    return 3


def print_plist(data: object) -> None:
    """打印 plist 内容，重点展开设备列表。"""
    if not isinstance(data, dict):
        print("  （顶层不是 dict）", type(data).__name__, data)
        return
    print("  顶层键:", sorted(data))
    devices = data.get("DeviceList")
    if devices is None:
        for key, value in data.items():
            print(f"  {key} = {value!r}")
        return
    print(f"  设备数量: {len(devices)}")
    for index, device in enumerate(devices):
        print(f"  [{index}] {device}")
        properties = device.get("Properties", {}) if isinstance(device, dict) else {}
        for key in ("DeviceName", "ProductType", "ProductVersion", "BuildVersion",
                    "UniqueDeviceID", "SerialNumber", "ConnectionType", "Trusted"):
            if key in properties:
                print(f"        {key:16} = {properties[key]!r}")


if __name__ == "__main__":
    sys.exit(main())
