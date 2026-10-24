# -*- coding: utf-8 -*-
"""对 usbmuxd 的 ListDevices 请求做多组合探测，找出能被 AppleMobileDeviceService
正确应答的参数。Windows 上这条链路是 Sideloadly 能否看到手机的关键。

已确认的事实（由本脚本之前的探测得到）：
  - 端口 127.0.0.1:27015 由 AppleMobileDeviceService 监听，TCP 可连
  - 请求头必须是「length 在前」(length, version, message, tag)，否则连接被立即关闭
  - message=8 是 MESSAGE_TYPE_PLIST（把真正的请求放进 XML plist 负载）
  - 服务会用一份 plist 回复 <key>MessageType</key><string>Result</string>
    加 <key>Number</key><integer>N</integer>；N != 0 表示被拒绝

本脚本把 (header version, kLibUSBMuxVersion) 组合穷举一遍，打印每个组合下
usbmuxd 回什么。哪一个返回 DeviceList，就说明参数对了。

用法：python scripts/lead/usbmux_probe.py
"""

from __future__ import annotations

import plistlib
import socket
import struct
import sys

HOST = "127.0.0.1"
PORT = 27015
MESSAGE_TYPE_PLIST = 8


def read_response(sock: socket.socket) -> bytes:
    """读到 EOF / 超时为止，返回原始字节（包含 16 字节头）。"""
    chunks: list[bytes] = []
    total = 0
    while total < 65536:
        try:
            chunk = sock.recv(4096)
        except (ConnectionResetError, ConnectionAbortedError, socket.timeout):
            break
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    return b"".join(chunks)


def request(header_version: int, libusbmux_version: int, timeout: float = 6.0) -> dict | None:
    """发一次 ListDevices，返回解析后的响应 plist（失败返回 None）。"""
    payload = plistlib.dumps(
        {
            "MessageType": "ListDevices",
            "ClientVersionString": "dsh-probe/1.0",
            "ProgName": "dsh-probe",
            "kLibUSBMuxVersion": libusbmux_version,
        },
        fmt=plistlib.FMT_XML,
    )
    header = struct.pack("<IIII", len(payload), header_version, MESSAGE_TYPE_PLIST, 1)
    try:
        with socket.create_connection((HOST, PORT), timeout=timeout) as sock:
            sock.settimeout(timeout)
            sock.sendall(header + payload)
            raw = read_response(sock)
    except OSError as exc:
        print(f"    连接异常: {type(exc).__name__}: {exc}")
        return None

    if len(raw) < 16:
        print(f"    响应过短（{len(raw)} 字节）: {raw.hex(' ') or '(空)'}")
        return None
    body = raw[16:]
    try:
        data = plistlib.loads(body)
    except Exception as exc:  # noqa: BLE001 - 诊断脚本
        print(f"    负载不是 plist（{len(body)} 字节）: {type(exc).__name__}: {exc}")
        print(f"    原始前 120 字节: {body[:120]}")
        return None
    return data if isinstance(data, dict) else None


def describe(data: dict | None) -> None:
    if data is None:
        return
    message_type = data.get("MessageType")
    if message_type == "Result":
        number = data.get("Number")
        meaning = "OK（成功）" if number == 0 else f"被拒绝（错误码 {number}）"
        print(f"    -> Result: {meaning}")
        return
    devices = data.get("DeviceList")
    if devices is not None:
        print(f"    -> DeviceList: {len(devices)} 台设备")
        for device in devices:
            properties = device.get("Properties", {})
            print(
                f"       DeviceID={device.get('DeviceID')} "
                f"Name={properties.get('DeviceName')!r} "
                f"iOS={properties.get('ProductVersion')!r} "
                f"Model={properties.get('ProductType')!r} "
                f"Trusted={properties.get('Trusted')!r}"
            )
        return
    print(f"    -> 未知响应: {data}")


def main() -> int:
    found = False
    for header_version in (1, 2):
        for libusbmux_version in (3, 4, 2):
            print(
                f"[header_version={header_version}, kLibUSBMuxVersion={libusbmux_version}]"
            )
            data = request(header_version, libusbmux_version)
            describe(data)
            if data and data.get("DeviceList") is not None:
                found = True
    print()
    if found:
        print("结论：usbmuxd 能正常返回设备列表。")
        return 0
    print("结论：所有组合都没拿到 DeviceList。")
    print("这说明 AppleMobileDeviceService 拒绝服务，而不是手机没插好。")
    return 2


if __name__ == "__main__":
    sys.exit(main())
