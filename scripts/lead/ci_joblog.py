# -*- coding: utf-8 -*-
"""下载一次 GitHub Actions 运行的 job 日志并抓错误行（只读工具，开发期用）。

用法：
    python scripts/lead/ci_joblog.py --run-id 40149646081 [--grep "error:"] [--tail 60]

为什么要单独一个脚本：`/actions/jobs/{id}/logs` 会 302 到 Azure Blob，
必须**去掉 Authorization 头**（否则 401）、并且接受 `*/*`（否则 415）。
"""

import argparse
import io
import json
import os
import re
import sys
import urllib.error
import urllib.request

REPO = "904177233/ximake-keyboard"
TOKEN_FILE = os.path.join(os.environ.get("TEMP", "."), "dsh_gh_token.txt")
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")


class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            for key in list(new.headers):
                if key.lower() == "authorization":
                    del new.headers[key]
            new.unredirected_hdrs.pop("Authorization", None)
            new.unredirected_hdrs.pop("authorization", None)
        return new


def token():
    with io.open(TOKEN_FILE, "r", encoding="utf-8") as handle:
        return handle.read().strip()


def api(path):
    request = urllib.request.Request(
        "https://api.github.com" + path,
        headers={
            "Authorization": "Bearer " + token(),
            "Accept": "application/vnd.github+json",
            "User-Agent": "dsh-lead",
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def job_logs(job_id):
    opener = urllib.request.build_opener(NoAuthRedirect)
    request = urllib.request.Request(
        "https://api.github.com/repos/%s/actions/jobs/%s/logs" % (REPO, job_id),
        headers={"Authorization": "Bearer " + token(), "Accept": "*/*", "User-Agent": "dsh-lead"},
    )
    with opener.open(request, timeout=120) as response:
        return response.read().decode("utf-8-sig", "replace")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--grep", default="error:|ARCHIVE FAILED|The following build commands failed")
    parser.add_argument("--tail", type=int, default=40)
    parser.add_argument("--context", type=int, default=2)
    args = parser.parse_args()

    jobs = api("/repos/%s/actions/runs/%s/jobs" % (REPO, args.run_id)).get("jobs", [])
    pattern = re.compile(args.grep)
    for job in jobs:
        if job.get("conclusion") != "failure":
            continue
        print("## job %s %s (%s)" % (job["id"], job["name"], job["conclusion"]))
        try:
            text = job_logs(job["id"])
        except urllib.error.HTTPError as error:
            print("!! 取日志失败 %s" % error)
            continue
        lines = [STAMP.sub("", line) for line in text.split("\n")]
        hits = [index for index, line in enumerate(lines) if pattern.search(line)]
        print("匹配行数: %d" % len(hits))
        shown = set()
        for index in hits[: args.tail]:
            for offset in range(-args.context, args.context + 1):
                position = index + offset
                if 0 <= position < len(lines) and position not in shown:
                    shown.add(position)
                    print("  %5d | %s" % (position + 1, lines[position].rstrip()))
        if hits:
            print("--- 末尾 15 行 ---")
            for position, line in list(enumerate(lines))[-15:]:
                print("  %5d | %s" % (position + 1, line.rstrip()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
