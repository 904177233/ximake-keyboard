#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gh_artifact.py —— 从 GitHub Actions 下载构建产物到 dist/（只读 API + 下载）。

用法：
    python scripts/lead/gh_artifact.py --list
    python scripts/lead/gh_artifact.py --download            # 最近一次成功的 run
    python scripts/lead/gh_artifact.py --download --run-id 40084131236
    python scripts/lead/gh_artifact.py --logs --run-id 40084131236 --grep "情形"

设计要点：
  * artifact 下载接口会 302 到 Azure Blob，**必须去掉 Authorization 头**，否则 401。
  * token 从 %TEMP%\\dsh_gh_token.txt 读（GitHub Desktop 的 credential manager 缓存）。
  * 解出来的 .ipa 放到 dist/，并打印大小与 sha256，方便和 README 里记的数值对照。
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

REPO = "904177233/ximake-keyboard"
API = f"https://api.github.com/repos/{REPO}"
REPO_ROOT = Path(__file__).resolve().parents[2]
DIST = REPO_ROOT / "dist"

TIMESTAMP_RE = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?(.*)$")


class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    """跟随 302 到 Azure Blob 时必须丢掉 Authorization，否则 401。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            for mapping in (new.headers, new.unredirected_hdrs):
                for key in [k for k in mapping if k.lower() == "authorization"]:
                    del mapping[key]
        return new


OPENER = urllib.request.build_opener(NoAuthRedirect)


def token() -> str:
    path = Path(tempfile.gettempdir()) / "dsh_gh_token.txt"
    if not path.is_file():
        print(f"找不到 token 文件：{path}", file=sys.stderr)
        raise SystemExit(2)
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        print(f"token 文件是空的：{path}", file=sys.stderr)
        raise SystemExit(2)
    return value


def api_get(url: str, tok: str, accept: str = "application/vnd.github+json"):
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {tok}",
            "Accept": accept,
            "User-Agent": "dsh-lead",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    return OPENER.open(req, timeout=120)


def latest_run(tok: str, want_success: bool = True) -> dict:
    url = f"{API}/actions/runs?per_page=20"
    runs = json.load(api_get(url, tok))["workflow_runs"]
    if want_success:
        for run in runs:
            if run.get("conclusion") == "success":
                return run
    if not runs:
        raise SystemExit("这个仓库还没有任何 workflow run")
    return runs[0]


def list_artifacts(tok: str, run_id: int) -> list[dict]:
    data = json.load(api_get(f"{API}/actions/runs/{run_id}/artifacts", tok))
    return data.get("artifacts", [])


def download_artifact(tok: str, artifact_id: int, out: Path) -> Path:
    url = f"{API}/actions/artifacts/{artifact_id}/zip"
    with api_get(url, tok, accept="application/vnd.github+json") as resp:
        blob = resp.read()
    print(f"下载完成：{len(blob)} 字节")

    DIST.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(blob)) as zf:
        names = zf.namelist()
        print(f"artifact 内文件：{names}")
        ipas = [n for n in names if n.lower().endswith(".ipa")]
        if not ipas:
            raise SystemExit(f"artifact 里没有 .ipa：{names}")
        data = zf.read(ipas[0])
        out.write_bytes(data)
        print(f"已写出：{out}")
        print(f"大小  ：{len(data)} 字节（{len(data) / 1024 / 1024:.2f} MB）")
        print(f"sha256：{hashlib.sha256(data).hexdigest()}")
        with zipfile.ZipFile(io.BytesIO(data)) as ipa:
            entries = ipa.namelist()
            print(f"IPA 内条目数：{len(entries)}")
            for key in (
                "Payload/AIKeyboard.app/AIKeyboard",
                "Payload/AIKeyboard.app/Info.plist",
                "Payload/AIKeyboard.app/PlugIns/AIKeyboardExtension.appex/Info.plist",
            ):
                print(f"  {'OK ' if key in entries else 'MISS'}  {key}")
            appex_exec = [
                n for n in entries
                if n.startswith("Payload/AIKeyboard.app/PlugIns/AIKeyboardExtension.appex/")
            ]
            print(f"  appex 内条目数：{len(appex_exec)}")
        return out


def dump_logs(tok: str, run_id: int, pattern: str | None, head: int, tail: int) -> None:
    jobs = json.load(api_get(f"{API}/actions/runs/{run_id}/jobs", tok))["jobs"]
    lines: list[str] = []
    for job in jobs:
        try:
            with api_get(f"{API}/actions/jobs/{job['id']}/logs", tok, accept="text/plain") as resp:
                raw = resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            lines.append(f"!! 取日志失败 job={job['id']} {exc}")
            continue
        for line in raw.splitlines():
            match = TIMESTAMP_RE.match(line)
            lines.append(match.group(1) if match else line)

    if pattern:
        rx = re.compile(pattern)
        lines = [ln for ln in lines if rx.search(ln)]
        print(f"匹配 '{pattern}' 的行数：{len(lines)}")
    total = len(lines)
    if head:
        lines = lines[:head] + (["…… 省略 ……"] if total > head + tail else []) + lines[-tail:]
    print("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true", help="列出最近一次成功 run 的 artifact")
    parser.add_argument("--download", action="store_true", help="下载 .ipa 到 dist/")
    parser.add_argument("--logs", action="store_true", help="打印 job 日志")
    parser.add_argument("--run-id", type=int, default=None)
    parser.add_argument("--grep", default=None, help="日志过滤正则")
    parser.add_argument("--head", type=int, default=0)
    parser.add_argument("--tail", type=int, default=60)
    args = parser.parse_args()

    tok = token()
    run_id = args.run_id
    if run_id is None:
        run = latest_run(tok)
        run_id = run["id"]
        print(f"run_id : {run_id}")
        print(f"commit : {run['head_sha'][:8]}")
        print(f"结论   : {run.get('conclusion')}")
        print(f"链接   : {run['html_url']}")

    if args.logs:
        dump_logs(tok, run_id, args.grep, args.head, args.tail)
        return 0

    artifacts = list_artifacts(tok, run_id)
    if not artifacts:
        print("这个 run 没有 artifact")
        return 1
    for item in artifacts:
        print(f"artifact id={item['id']} name={item['name']} size={item['size_in_bytes']} expired={item['expired']}")

    if args.download:
        target = next((a for a in artifacts if a["name"] == "AIKeyboard-unsigned-ipa"), None)
        if target is None:
            print("没找到名为 AIKeyboard-unsigned-ipa 的 artifact", file=sys.stderr)
            return 1
        download_artifact(tok, target["id"], DIST / "AIKeyboard-unsigned.ipa")
    return 0


if __name__ == "__main__":
    sys.exit(main())
