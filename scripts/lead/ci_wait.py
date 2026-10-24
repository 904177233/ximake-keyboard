#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""等待并汇报 GitHub Actions 最近一次运行的状态（只读，不修改仓库）。

用法：
    python scripts/lead/ci_wait.py [--timeout 900] [--run-id N] [--logs]

说明：token 从 %TEMP%\\dsh_gh_token.txt 读取（由 GitHub Desktop 的 credential manager 导出），
不打印 token 本身。下载日志时 302 跳到 Azure Blob，必须去掉 Authorization 头。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

REPO = "904177233/ximake-keyboard"
API = "https://api.github.com"
UA = "dsh-lead"


def token() -> str:
    path = os.path.join(os.environ.get("TEMP", "."), "dsh_gh_token.txt")
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read().strip()


class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    """跟随重定向时丢弃 Authorization 头（Azure Blob 会拒绝带认证的请求）。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is None:
            return None
        # urllib 把显式设置的头存在 unredirected_hdrs 里，headers 里没有，两处都要清。
        new.unredirected_hdrs.pop("Authorization", None)
        for key in list(new.headers):
            if key.lower() == "authorization":
                del new.headers[key]
        return new


def api(path: str) -> dict:
    req = urllib.request.Request(
        API + path,
        headers={
            "Authorization": "Bearer " + token(),
            "Accept": "application/vnd.github+json",
            "User-Agent": UA,
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def latest_run() -> dict:
    data = api("/repos/%s/actions/runs?branch=main&per_page=1" % REPO)
    runs = data.get("workflow_runs") or []
    return runs[0] if runs else {}


def fetch_log(job_id: int) -> str:
    req = urllib.request.Request(
        API + "/repos/%s/actions/jobs/%d/logs" % (REPO, job_id),
        headers={
            "Authorization": "Bearer " + token(),
            "Accept": "application/vnd.github+json",
            "User-Agent": UA,
        },
    )
    opener = urllib.request.build_opener(NoAuthRedirect)
    with opener.open(req, timeout=120) as resp:
        return resp.read().decode("utf-8-sig", errors="replace")


STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")


def strip_stamps(text: str) -> str:
    out = []
    for line in text.splitlines():
        match = STAMP.match(line)
        out.append(line[match.end():] if match else line)
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--run-id", type=int, default=0)
    parser.add_argument("--logs", action="store_true")
    parser.add_argument("--steps", action="store_true")
    args = parser.parse_args()

    deadline = time.time() + args.timeout
    run = {}
    while True:
        run = latest_run() if not args.run_id else api("/repos/%s/actions/runs/%d" % (REPO, args.run_id))
        status = run.get("status")
        if status == "completed":
            break
        if time.time() > deadline:
            print("[超时] 运行仍在进行：id=%s status=%s" % (run.get("id"), status))
            return 3
        time.sleep(15)

    print("run_id    : %s" % run.get("id"))
    print("commit    : %s" % (run.get("head_sha") or "")[:8])
    print("title     : %s" % (run.get("display_title") or ""))
    print("结论      : %s / %s" % (run.get("status"), run.get("conclusion")))
    print("链接      : %s" % run.get("html_url"))

    jobs = api("/repos/%s/actions/runs/%s/jobs" % (REPO, run.get("id"))).get("jobs") or []
    for job in jobs:
        print("\nJOB %s  id=%s  %s/%s" % (job.get("name"), job.get("id"), job.get("status"), job.get("conclusion")))
        if args.steps:
            for step in job.get("steps") or []:
                print("  %-2s %-46s %s" % (step.get("number"), step.get("name"), step.get("conclusion")))
        if args.logs and job.get("conclusion") != "success":
            logs = strip_stamps(fetch_log(job["id"]))
            print("\n--- 日志尾部 160 行 ---")
            print("\n".join(logs.splitlines()[-160:]))

    return 0 if run.get("conclusion") == "success" else 1


if __name__ == "__main__":
    sys.exit(main())
