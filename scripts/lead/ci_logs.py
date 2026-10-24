"""Fetch a GitHub Actions job log (text/plain) and print selected lines.

GitHub redirects the job-logs endpoint to an Azure Blob URL; the Authorization
header must be dropped on the redirect or the blob returns 401/415.  The body is
plain text with a per-line ISO timestamp prefix that we strip before matching.

Usage:
    python scripts/lead/ci_logs.py --run-id 40119343120 [--grep REGEX]
                                   [--head N] [--tail N] [--raw]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

REPO = "904177233/ximake-keyboard"
TOKEN_FILE = os.path.join(os.environ.get("TEMP", "."), "dsh_gh_token.txt")
API = "https://api.github.com"

STRIP_TS = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")


def load_token() -> str:
    with open(TOKEN_FILE, "r", encoding="utf-8") as handle:
        return handle.read().strip()


class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    """Follow redirects while removing the Authorization header."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is None:
            return None
        for mapping in (new.headers, new.unredirected_hdrs):
            for key in list(mapping):
                if key.lower() == "authorization":
                    del mapping[key]
        new.add_unredirected_header("User-Agent", "dsh-lead")
        return new


def api_get(path: str, token: str) -> bytes:
    request = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "dsh-lead",
        },
    )
    opener = urllib.request.build_opener(NoAuthRedirect)
    with opener.open(request, timeout=120) as response:
        return response.read()


def latest_run_id(token: str) -> int:
    payload = json.loads(api_get(f"/repos/{REPO}/actions/runs?per_page=1", token))
    runs = payload.get("workflow_runs") or []
    if not runs:
        raise SystemExit("no workflow runs found")
    return int(runs[0]["id"])


def job_ids(run_id: int, token: str) -> list[tuple[int, str]]:
    payload = json.loads(api_get(f"/repos/{REPO}/actions/runs/{run_id}/jobs", token))
    return [(int(job["id"]), job["name"]) for job in payload.get("jobs") or []]


def fetch_log(job_id: int, token: str) -> str:
    blob = api_get(f"/repos/{REPO}/actions/jobs/{job_id}/logs", token)
    return blob.decode("utf-8-sig", errors="replace")


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch and filter an Actions job log")
    parser.add_argument("--run-id", type=int, default=0)
    parser.add_argument("--job-id", type=int, default=0)
    parser.add_argument("--grep", default="")
    parser.add_argument("--head", type=int, default=0)
    parser.add_argument("--tail", type=int, default=0)
    parser.add_argument("--raw", action="store_true")
    args = parser.parse_args()

    token = load_token()
    run_id = args.run_id or latest_run_id(token)
    jobs = job_ids(run_id, token)
    if not jobs:
        raise SystemExit(f"no jobs for run {run_id}")

    targets = [jid for jid, _ in jobs if not args.job_id or jid == args.job_id]
    if not targets:
        raise SystemExit("job id not found in this run")

    pattern = re.compile(args.grep) if args.grep else None
    for job_id in targets:
        try:
            text = fetch_log(job_id, token)
        except urllib.error.HTTPError as error:
            print(f"!! job {job_id} log HTTP {error.code}: {error.reason}", file=sys.stderr)
            continue

        lines = []
        for raw in text.splitlines():
            line = STRIP_TS.sub("", raw).rstrip()
            if pattern is None or pattern.search(line):
                lines.append(line)
        if args.head:
            lines = lines[: args.head]
        if args.tail:
            lines = lines[-args.tail :]
        print(f"===== job {job_id} ({len(lines)} lines) =====")
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
