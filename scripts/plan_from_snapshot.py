#!/usr/bin/env python3
"""plan_from_snapshot.py — 把 snapshot/source.txt 转成 plan/migration.json。

目标：原样复刻源机软件栈（只搬软件，不换 OS）。包清单/用户/cron 自动带出；
配置文件、监听端口、防火墙需人工补进 migration.json。

用法: python scripts/plan_from_snapshot.py [--snapshot snapshot/source.txt] [--out plan/migration.json]
"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def parse_sections(text: str) -> dict:
    sections = {}
    current = None
    for line in text.splitlines():
        m = re.match(r"==\s*(.+?)\s*==", line.strip())
        if m:
            current = m.group(1).strip()
            sections[current] = []
            continue
        if current is not None:
            sections[current].append(line.rstrip())
    return sections


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", default="snapshot/source.txt")
    ap.add_argument("--out", default="plan/migration.json")
    args = ap.parse_args()

    src = ROOT / args.snapshot
    if not src.exists():
        raise SystemExit(f"找不到 {src}，先在源服务器跑 scripts/snapshot.sh")
    sections = parse_sections(src.read_text(encoding="utf-8", errors="replace"))

    # --- 包清单：去掉 package_manager: 行与空行 ---
    packages = []
    for line in sections.get("PACKAGES", []):
        s = line.strip()
        if not s or s.startswith("package_manager:"):
            continue
        packages.append(s)

    # --- 用户：UID>=1000 的业务用户（跳过 root 与系统账号）---
    users = []
    for line in sections.get("USERS (UID>=1000 or root)", []):
        name, _, uid = line.partition(":")
        name = name.strip()
        if not name or name == "root":
            continue
        if uid.isdigit() and int(uid) >= 1000:
            users.append({"name": name, "group": name})

    # --- 组 ---
    groups = [l.strip() for l in sections.get("GROUPS", []) if l.strip()]

    # --- cron：解析 root crontab（前五段为表达式，其余为命令）---
    cron = []
    for line in sections.get("CRONTAB (root)", []):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        parts = s.split(None, 5)
        if len(parts) >= 6 and all(re.fullmatch(r"[\d\*/,\-]+", t) for t in parts[:5]):
            cron.append({"expr": " ".join(parts[:5]), "cmd": parts[5]})

    plan = {
        "packages": packages,
        "files": [],
        "groups": groups,
        "users": users,
        "cron": cron,
        "commands": [],
        "per_distro": {},
        "_note": "由 plan_from_snapshot.py 生成；请人工补 files（配置文件）、commands，并按目标发行版调整 per_distro",
    }

    out = ROOT / args.out
    out.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"已写入 {out}：{len(packages)} 包 / {len(users)} 用户 / {len(cron)} cron")
    print("提醒：配置文件、监听端口、防火墙规则需人工补充；packages 可按需要裁剪。")


if __name__ == "__main__":
    main()
