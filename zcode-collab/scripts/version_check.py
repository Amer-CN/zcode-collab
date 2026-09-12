#!/usr/bin/env python3
"""version_check.py — zcode-collab Skill 版本自检

用法：
    python scripts/version_check.py            # 输出 JSON 状态
    python scripts/version_check.py --quiet    # 只 exit code

输出 JSON：
    {"status": "current",  "local": "1.1.0", "remote": "1.1.0"}
    {"status": "behind",   "local": "1.0.0", "remote": "1.1.0"}  # 有新版本
    {"status": "unknown",  "local": "1.0.0", "remote": null}     # 离线/无git

设计铁律（与 super-official-writer 同口径）：
- **永不阻塞协作任务**：任何异常（断网、无 git、非仓库目录）都归为 unknown，exit 0
- behind 时提示更新但不强制；由用户裁决
- 本脚本只读（urlopen 读 raw + git ls-remote 不改本地任何东西），无凭据传输
"""
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

REPO_URL = "https://github.com/Amer-CN/collab-mode.git"
SKILL_DIR = Path(__file__).resolve().parent.parent
RAW_URL = "https://raw.githubusercontent.com/Amer-CN/collab-mode/main/zcode-collab/VERSION"


def _local_version() -> str | None:
    """本地版本：读 VERSION 文件；取不到时退化为 git HEAD 短哈希。"""
    try:
        v = (SKILL_DIR / "VERSION").read_text(encoding="utf-8").strip()
        if v:
            return v
    except Exception:
        pass
    try:
        r = subprocess.run(
            ["git", "-C", str(SKILL_DIR), "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0:
            return r.stdout.strip()
    except Exception:
        pass
    return None


def _remote_version() -> str | None:
    """远端版本：优先 raw VERSION 文件；失败退化 ls-remote HEAD 短哈希。"""
    try:
        req = urllib.request.Request(
            RAW_URL, headers={"User-Agent": "skill-version-check/1.0"}
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            v = resp.read().decode("utf-8", errors="ignore").strip()
            if v:
                return v
    except Exception:
        pass
    try:
        r = subprocess.run(
            ["git", "ls-remote", REPO_URL, "HEAD"],
            capture_output=True, text=True, timeout=15,
        )
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.split()[0][:7]
    except Exception:
        pass
    return None


def main() -> int:
    quiet = "--quiet" in sys.argv
    local, remote = _local_version(), _remote_version()

    if remote is None:
        status = "unknown"          # 离线/无 git：静默放行
    elif local == remote:
        status = "current"
    elif local and remote and re.match(r"^[\d.]+$", local) and re.match(r"^[\d.]+$", remote):
        lv = [int(x) for x in local.split(".")]
        rv = [int(x) for x in remote.split(".")]
        status = "behind" if lv < rv else "current"  # 本地更新（含未推送）也算 current
    elif local and remote and local != remote:
        status = "behind"
    else:
        status = "current"

    result = {"status": status, "local": local, "remote": remote}
    if not quiet:
        print(json.dumps(result, ensure_ascii=False))
        if status == "behind":
            print(f"[skill 更新] 发现新版本（本地 {local} → 远端 {remote}）。", file=sys.stderr)
            print("建议：git pull 本仓库，或重新下载覆盖。也可先继续当前任务。", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
