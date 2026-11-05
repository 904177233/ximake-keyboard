#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""取 GitHub token，给看 CI 日志和下载安装包的脚本用。

先读旧脚本约定的临时文件；没有就问 git 的凭据管理器（和 git push 用的是同一份凭据）。
token 只留在内存里，不打印，也不写盘。
"""

from __future__ import annotations

import os
import subprocess
import tempfile

GIT = r"C:\Program Files\Git\cmd\git.exe"


def github_token() -> str:
    path = os.path.join(tempfile.gettempdir(), "dsh_gh_token.txt")
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as handle:
            value = handle.read().strip()
        if value:
            return value
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    result = subprocess.run(
        [GIT if os.path.exists(GIT) else "git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
        check=False,
    )
    for line in result.stdout.splitlines():
        if line.startswith("password="):
            return line[len("password="):]
    raise SystemExit("拿不到 GitHub 凭据：先用 GitHub Desktop 或 git push 登录一次")
