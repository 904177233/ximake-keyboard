#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_workflow_bash.py —— 在 Windows 上校验 GitHub Actions workflow 里的 shell 脚本语法。

背景
----
CI 上的 workflow 跑在 Ubuntu/macOS 的 /bin/bash 上；Windows 本地没有 bash，
只有 Git for Windows 自带的 bash。YAML 层 `yaml.safe_load` 能过，不代表里面的
shell 能跑 —— 少一个 fi、多一个 done，只有 bash 自己知道。

本脚本做三件事：
  1) 用 yaml.safe_load 解析 workflow；
  2) 把每个 step 的 run 脚本落成临时 .sh；
  3) 用 Git 自带的 bash 执行 `bash -n`（只做语法检查，不执行）。

退出码：0 = 全部通过；1 = 有语法错误；3 = 脚本自身/环境问题。
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("需要 PyYAML：python -m pip install pyyaml", file=sys.stderr)
    raise SystemExit(3)

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "build.yml"

BASH_CANDIDATES = [
    r"C:\Program Files\Git\bin\bash.exe",
    r"C:\Program Files\Git\usr\bin\bash.exe",
    r"C:\Program Files (x86)\Git\bin\bash.exe",
    "bash",
]


def find_bash() -> str:
    for candidate in BASH_CANDIDATES:
        found = shutil.which(candidate) if "\\" not in candidate else (
            candidate if Path(candidate).is_file() else None
        )
        if found:
            return found
    print("找不到 bash（需要 Git for Windows）", file=sys.stderr)
    raise SystemExit(3)


def main() -> int:
    if not WORKFLOW.is_file():
        print(f"找不到 workflow：{WORKFLOW}", file=sys.stderr)
        return 3

    data = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    bash = find_bash()
    print(f"bash    : {bash}")
    print(f"workflow: {WORKFLOW.relative_to(REPO_ROOT)}")

    total = 0
    failed = 0
    tmpdir = Path(tempfile.mkdtemp(prefix="wf_bash_"))
    try:
        for job_name, job in (data.get("jobs") or {}).items():
            for index, step in enumerate(job.get("steps") or [], start=1):
                script = step.get("run")
                if not script:
                    continue
                total += 1
                name = step.get("name", f"<step {index}>")
                target = tmpdir / f"{job_name}_{index:02d}.sh"
                # CRLF 会让 bash 报 "$'\r': command not found"，统一成 LF。
                target.write_bytes(script.replace("\r\n", "\n").encode("utf-8"))
                proc = subprocess.run(
                    [bash, "-n", str(target)],
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                )
                if proc.returncode == 0:
                    print(f"  [OK]   {index:02d}. {name}")
                else:
                    failed += 1
                    print(f"  [FAIL] {index:02d}. {name}")
                    for line in (proc.stderr or "").splitlines():
                        print(f"         {line}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    print()
    if failed:
        print(f"bash 语法检查：{total} 个脚本，失败 {failed} 个")
        return 1
    print(f"bash 语法检查：{total} 个脚本全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
