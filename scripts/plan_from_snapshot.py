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

    # --- 业务目录树：源机有 /server 就按整树迁移 ---
    dirs = []
    tree = [l.strip() for l in sections.get("BUSINESS TREE (/server)", []) if l.strip()]
    if tree and not any("no /server" in l for l in tree):
        dirs.append({"src": "server", "dest": "/server"})

    # --- 业务目录属主/权限：原样还原（不再统一 0755）---
    attrs_section = sections.get("BUSINESS ATTRS (/server)", [])
    if dirs and attrs_section:
        owner = group = ""
        attrs = []
        for line in attrs_section:
            parts = line.strip().split("|")
            if len(parts) != 4:
                continue
            path, mode, u, g = parts
            if path == ".":
                owner, group = u, g
                continue
            attrs.append({"path": path, "mode": mode, "owner": u, "group": g})
        if owner:
            dirs[0]["owner"] = owner
        if group:
            dirs[0]["group"] = group
        if attrs:
            dirs[0]["attrs"] = attrs

    # --- 业务二进制的 glibc 下限：每个二进制生成一条兼容性 check ---
    checks = []
    libc_floor = ""
    bin_section = sections.get("BINARY LIBC REQUIREMENTS", [])
    cur_bin, cur_vers = None, []

    def flush_bin():
        nonlocal libc_floor
        if not cur_bin or not cur_vers:
            return
        need = max(cur_vers, key=lambda v: tuple(int(x) for x in v.split(".")))
        libc_floor = max(libc_floor, need, key=lambda v: tuple(int(x) for x in v.split("."))) if libc_floor else need
        # 目标机 libc 版本必须 >= 产物要求；musl 主机会因版本号较低/解析不到而 FAIL（符合事实）
        cmd = (f"need={need}; "
               "have=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\\.[0-9]+' | head -1); "
               "[ -n \"$have\" ] && [ \"$(printf '%s\\n%s\\n' \"$have\" \"$need\" | sort -V | tail -1)\" = \"$have\" ]")
        checks.append({"name": f"glibc>={need}:{Path(cur_bin).name}", "cmd": cmd})

    for line in bin_section:
        s = line.strip()
        if s.startswith("-- "):
            flush_bin()
            cur_bin, cur_vers = s[3:].strip(), []
            continue
        for v in re.findall(r"GLIBC_2\.[0-9]+", s):
            cur_vers.append(v.replace("GLIBC_", ""))
    flush_bin()

    # --- 业务 unit：原文落盘 + 派生 units/services（ExecStart/WorkingDirectory）---
    units = []
    services = []
    out_dir = (ROOT / args.out).parent
    cur_name, cur_lines = None, []

    def flush_unit():
        if not cur_name or not cur_lines:
            return
        content = "\n".join(cur_lines).strip() + "\n"
        ud = out_dir / "units"
        ud.mkdir(parents=True, exist_ok=True)
        (ud / cur_name).write_bytes(content.encode())
        units.append({"src": f"units/{cur_name}", "name": cur_name,
                      "dest": f"/etc/systemd/system/{cur_name}"})
        exec_start = wd = ""
        for ln in cur_lines:
            if ln.startswith("ExecStart="):
                exec_start = ln[len("ExecStart="):].strip()
            elif ln.startswith("WorkingDirectory="):
                wd = ln[len("WorkingDirectory="):].strip()
        if exec_start:
            svc_name = cur_name[:-8] if cur_name.endswith(".service") else cur_name
            start = f"cd {wd} && {exec_start}" if wd else exec_start
            services.append({"name": svc_name, "start": start, "stop": "", "port": "", "wait": 5})

    for line in sections.get("UNIT FILES", []):
        s = line.rstrip()
        if s.startswith("-- "):
            flush_unit()
            cur_name = Path(s[3:].strip()).name
            cur_lines = []
            continue
        if cur_name:
            cur_lines.append(s)
    flush_unit()

    # --- 数据库：探测到的引擎生成 databases 骨架（dump 需人工从源机导出补入）---
    databases = []
    db_text = "\n".join(sections.get("DATABASES", [])).lower()
    if "mariadb" in db_text or "mysql" in db_text:
        databases.append({"type": "mariadb", "name": "appdb", "dump": "", "verify": "SELECT 1"})
    if "psql" in db_text or "postgres" in db_text:
        databases.append({"type": "postgresql", "name": "appdb", "dump": "", "verify": "SELECT 1"})
    if "redis" in db_text:
        databases.append({"type": "redis", "name": "cache", "dump": "", "verify": "PING"})

    # --- 防火墙：解析 ufw / firewalld / iptables 放行规则 ---
    fw_section = sections.get("FIREWALL", [])
    fw_text = "\n".join(fw_section)
    allow_tcp, allow_udp, rules = [], [], []
    for m in re.finditer(r"(\d+)/(tcp|udp)", fw_text):
        port = int(m.group(1))
        (allow_tcp if m.group(2) == "tcp" else allow_udp).append(port)
    for line in fw_section:
        s = line.strip()
        if s.startswith("-A INPUT"):
            rules.append(s)
    backend = ""
    if re.search(r"Status:\s*active", fw_text) or "ufw" in fw_text.lower():
        backend = "ufw"
    elif "ports:" in fw_text or "firewall-cmd" in fw_text:
        backend = "firewalld"
    elif rules:
        backend = "iptables"
    firewall = {}
    if allow_tcp or allow_udp or rules or backend:
        firewall = {
            "backend": backend or "auto",
            "allow_tcp": sorted(set(allow_tcp)),
            "allow_udp": sorted(set(allow_udp)),
            "rules": rules,
            "default_input": "deny" if "deny" in fw_text.lower() else "",
        }

    plan = {
        "packages": packages,
        "files": [],
        "dirs": dirs,
        "units": units,
        "services": services,
        "groups": groups,
        "users": users,
        "cron": cron,
        "commands": [],
        "checks": checks,
        "databases": databases,
        "firewall": firewall,
        "per_distro": {},
        "_note": ("由 plan_from_snapshot.py 生成；请人工补 files（配置文件）、commands，"
                  "给 services 补 port（监听端口）与 stop；dirs 的 src 需把源机 /server 拷到计划目录下"
                  "（或设置 src_root 指向本地副本）；databases 需补 dump 文件路径（源机 mysqldump/pg_dump/redis 导出），"
                  "mongodb 需人工 mongodump/mongorestore；firewall 规则请人工复核"),
    }
    if libc_floor:
        plan["_libc_floor"] = libc_floor

    out = ROOT / args.out
    out.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    n_attrs = len(dirs[0].get("attrs", [])) if dirs else 0
    print(f"已写入 {out}：{len(packages)} 包 / {len(users)} 用户 / {len(cron)} cron / "
          f"{len(dirs)} 目录树({n_attrs} 属主权限项) / {len(units)} unit / {len(services)} 服务 / "
          f"{len(checks)} 二进制兼容检查 / {len(databases)} 数据库 / 防火墙{'有' if firewall else '无'}")
    if libc_floor:
        print(f"业务二进制最高要求 glibc {libc_floor}——目标机必须 >= 该版本，否则换静态产物（proxysss v1.3.15+ 已静态）或容器化。")
    print("提醒：配置文件、services 的 port/stop、防火墙规则需人工补充；packages 可按需要裁剪。")


if __name__ == "__main__":
    main()
