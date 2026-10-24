# -*- coding: utf-8 -*-
"""向 Apple 的 usbmuxd（127.0.0.1:27015）查询设备列表，用于定位
「Windows 识别到 iPhone 但 Sideloadly 显示 <no devices detected>」的故障层。

背景：usbmuxd 用的是 Apple 私有二进制协议，不是 plist。协议头固定 16 字节：
    uint32 version = 1
    uint32 message   <- 消息类型
    uint32 tag       <- 任意，原样回传
    uint32 length    <- 负载长度

消息类型的编号在不同文档里说法不一，所以这里**不猜**：把候选值挨个试一遍，
看哪个返回 MessageResult(=1)，用实测确定 ListDevices 的真实编号，然后解析
设备数量与 UDID。

用法：python scripts/lead/usbmux_list.py
退出码：0 = 至少一台设备；2 = usbmuxd 活着但零设备；3 = 连不上 usbmuxd
"""

from __future__ import annotations

import socket
import struct
import sys

HOST = "127.0.0.1"
PORT = 27015

MESSAGE_RESULT = 1

# 候选的 ListDevices 消息号（不同版本/文档存在差异，实测确定）
CANDIDATE_MESSAGE_IDS = (11, 12, 8, 13, 5)

# UDID 形如 00008120-001C25860CB8C01E（40 字符，含一个连字符）
MIN_UDID_LEN = 24
MAX_UDID_LEN = 48


def recv_exact(sock: socket.socket, size: int) -> bytes:
    """收满 size 字节，或抛出 EOFError。"""
    chunks: list[bytes] = []
    remaining = size
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise EOFError(f"socket 提前关闭：还差 {remaining} 字节")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def ask(message_id: int, tag: int, payload: bytes = b"") -> tuple[int, bytes] | None:
    """发一条 usbmuxd 消息，返回 (resp_message, resp_payload)；失败返回 None。"""
    header = struct.pack("<IIII", 1, message_id, tag, len(payload))
    try:
        with socket.create_connection((HOST, PORT), timeout=5.0) as sock:
            sock.settimeout(5.0)
            sock.sendall(header + payload)
            resp_header = recv_exact(sock, 16)
            _version, resp_message, _resp_tag, resp_length = struct.unpack(
                "<IIII", resp_header
            )
            resp_payload = recv_exact(sock, resp_length) if resp_length else b""
            return resp_message, resp_payload
    except (OSError, EOFError) as exc:
        print(f"  message={message_id:2}: 失败 {type(exc).__name__}: {exc}")
        return None


def printable_runs(data: bytes) -> list[str]:
    """从二进制里提取可打印 ASCII 连续片段。"""
    runs: list[str] = []
    current: list[str] = []
    for byte in data:
        if 0x20 <= byte <= 0x7E:
            current.append(chr(byte))
        else:
            if current:
                runs.append("".join(current))
                current = []
    if current:
        runs.append("".join(current))
    return runs


def main() -> int:
    print(f"探测 usbmuxd {HOST}:{PORT} 的 ListDevices 消息号 ...")
    result_payload: bytes | None = None
    for message_id in CANDIDATE_MESSAGE_IDS:
        print(f"  message={message_id:2}: 发送中 ...")
        response = ask(message_id, tag=message_id)
        if response is None:
            continue
        resp_message, resp_payload = response
        print(
            f"  message={message_id:2}: 返回 resp_message={resp_message} "
            f"payload={len(resp_payload)} 字节"
        )
        if resp_message == MESSAGE_RESULT:
            result_payload = resp_payload
            print(f"  >>> 确认 ListDevices 消息号 = {message_id}")
            break

    if result_payload is None:
        print("\n没有任何候选消息号返回 MessageResult。")
        print("说明 AppleMobileDeviceService 虽然占着 27015，但没在正常应答 usbmuxd 协议。")
        print("大概率是 Apple Mobile Device Support 版本过旧（本机 16.5.0.12），")
        print("需要升级到与手机 iOS 版本匹配的新版本。")
        return 3

    print(f"\n负载十六进制（前 128 字节）: {result_payload[:128].hex(' ') or '(空)'}")
    if len(result_payload) < 4:
        print(f"负载只有 {len(result_payload)} 字节，读不出设备数量。")
        return 2

    count = struct.unpack("<I", result_payload[:4])[0]
    print(f"\n>>> usbmuxd 报告已连接设备数量: {count}")

    if count == 0:
        print("\n设备列表为空。按概率排查：")
        print("  1) 手机锁屏了 / 解锁后没点「信任此电脑」")
        print("  2) Apple Mobile Device Support 版本过旧（本机 16.5.0.12，2023 年）")
        print("  3) 数据线只充电不通数据，或接了 USB 集线器")
        return 2

    udids = [
        run
        for run in printable_runs(result_payload)
        if MIN_UDID_LEN <= len(run) <= MAX_UDID_LEN
    ]
    print(f"识别到的字符串片段: {udids or '(未解析出)'}")
    print("\n结论：usbmuxd 能看到设备 -> 手机与 Apple 驱动链路正常，")
    print("      问题在 Sideloadly 自身的设备枚举（重启 Sideloadly 即可）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
