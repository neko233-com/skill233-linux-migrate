#!/usr/bin/env python3
"""linux-migrate 矩阵编排：up / apply / verify / report / down / all / init。

无第三方依赖；compose 优先 kiri，回退 docker；容器操作直接用 docker CLI（引擎即 kiri）。
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "out"
PLAN_DIR = ROOT / "plan"
REPORT_DIR = ROOT / "report"


# ---------- 基础工具 ----------
def load_json(p: Path):
    return json.loads(p.read_text(encoding="utf-8"))


def shq(v: str) -> str:
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$") + '"'


def run(cmd, cwd=None, check=True, capture=False):
    kwargs = {"cwd": cwd or ROOT}
    if capture:
        kwargs["capture_output"] = True
        kwargs["text"] = True
    r = subprocess.run(cmd, **kwargs)
    if check and r.returncode != 0:
        raise SystemExit(f"命令失败 ({r.returncode}): {' '.join(cmd)}")
    return r


def detect_compose():
    if shutil.which("kiri"):
        return ["kiri", "compose"]
    if shutil.which("docker"):
        return ["docker", "compose"]
    raise SystemExit("未找到 kiri 或 docker，请先启动容器引擎")


def enabled_distros(matrix, only=None):
    out = []
    for d in matrix["distros"]:
        if not d.get("enabled", True):
            continue
        if only and d["name"] not in only:
            continue
        out.append(d)
    return out


def parse_only(args):
    return [x.strip() for x in (args.only or "").split(",") if x.strip()]


# ---------- init ----------
def cmd_init(_args):
    PLAN_DIR.mkdir(exist_ok=True)
    example = PLAN_DIR / "migration.json"
    if not example.exists():
        example.write_text(json.dumps({
            "packages": ["curl"],
            "files": [{"src": "files/hello.conf", "dest": "/etc/hello-migrate.conf", "contains": "migrated"}],
            "groups": ["appdemo"],
            "users": [{"name": "appdemo", "group": "appdemo"}],
            "cron": [{"expr": "*/10 * * * *", "cmd": "/opt/app/collect.sh"}],
            "commands": ["curl"],
            "per_distro": {}
        }, ensure_ascii=False, indent=2))
    files_dir = PLAN_DIR / "files"
    files_dir.mkdir(exist_ok=True)
    hello = files_dir / "hello.conf"
    if not hello.exists():
        hello.write_text("# migrated config\nkey=value\n", encoding="utf-8")
    print("init: plan/migration.json 与示例文件已就绪")


# ---------- 物化计划 ----------
def merge_plan(distro_name: str, plan: dict) -> dict:
    merged = {
        "packages": list(plan.get("packages", [])),
        "files": list(plan.get("files", [])),
        "groups": list(plan.get("groups", [])),
        "users": list(plan.get("users", [])),
        "cron": list(plan.get("cron", [])),
        "commands": list(plan.get("commands", [])),
    }
    ov = plan.get("per_distro", {}).get(distro_name, {})
    # packages：追加去重；其余列表：有覆盖则整体替换
    for p in ov.get("packages", []):
        if p not in merged["packages"]:
            merged["packages"].append(p)
    for k in ("files", "groups", "users", "cron", "commands"):
        if k in ov:
            merged[k] = ov[k]
    return merged


def materialize(distro_name: str, merged: dict, base_dir: Path = PLAN_DIR) -> Path:
    d = OUT / "plan" / distro_name
    shutil.rmtree(d, ignore_errors=True)
    files_d = d / "files"
    files_d.mkdir(parents=True)

    env_lines = []
    env_lines.append(f'PKGS="{" ".join(merged["packages"])}"')
    env_lines.append(f'GROUPLIST="{" ".join(merged["groups"])}"')
    users = [f'{u["name"]}:{u.get("group", "")}' for u in merged["users"]]
    env_lines.append(f'USERLIST="{" ".join(users)}"')
    env_lines.append(f'CMDS="{" ".join(merged["commands"])}"')

    for i, f in enumerate(merged["files"]):
        src = base_dir / f["src"]
        (files_d / str(i)).write_bytes(src.read_bytes())
        env_lines.append(f'FILE{i}_DEST={shq(f["dest"])}')
        env_lines.append(f'FILE{i}_CONTAINS={shq(f.get("contains", ""))}')

    for i, c in enumerate(merged["cron"]):
        env_lines.append(f'CRON{i}_EXPR={shq(c["expr"])}')
        env_lines.append(f'CRON{i}_CMD={shq(c["cmd"])}')

    # write_bytes 避免 Windows 下 \n 被翻译成 \r\n（容器内 sh 会吃到 \r）
    (d / "apply.env").write_bytes(("\n".join(env_lines) + "\n").encode("utf-8"))
    return d


# ---------- up ----------
def render_compose(matrix, distros):
    lines = ["services:"]
    for d in distros:
        name = d["name"]
        lines += [
            f"  {name}:",
            f"    image: {d['image']}",
            f"    container_name: lm-{name}",
            '    command: ["sleep", "infinity"]',
            "    volumes:",
            "      - ./guest:/guest:ro",
            "      - ./out:/guest-out",
            "    networks: [linuxmig-net]",
        ]
    lines += ["networks:", "  linuxmig-net:", "    driver: bridge"]
    (ROOT / "compose.generated.yml").write_text("\n".join(lines) + "\n", encoding="utf-8")


def cmd_up(args):
    matrix = load_json(ROOT / "matrix.json")
    distros = enabled_distros(matrix, set(parse_only(args)))
    if not distros:
        raise SystemExit("没有启用的发行版")
    if matrix.get("pull", True) and not args.skip_pull:
        for d in distros:
            print(f"[pull] {d['image']}")
            run(["docker", "pull", d["image"]], check=False)
    render_compose(matrix, distros)
    compose = detect_compose()
    proj = matrix.get("compose_project", "linuxmig")
    run(compose + ["-p", proj, "-f", "compose.generated.yml", "up", "-d"])
    print(f"up: {len(distros)} 个容器已启动")


# ---------- apply ----------
def container_name(d):
    return f"lm-{d['name']}"


def load_plan(args):
    if getattr(args, "plan", None):
        return load_json(ROOT / args.plan)
    return load_json(PLAN_DIR / "migration.json")


def cmd_apply(args):
    matrix = load_json(ROOT / "matrix.json")
    plan = load_plan(args)
    plan_base = (ROOT / args.plan).parent if getattr(args, "plan", None) else PLAN_DIR
    distros = enabled_distros(matrix, set(parse_only(args)))
    for d in distros:
        name = d["name"]
        merged = merge_plan(name, plan)
        mdir = materialize(name, merged, plan_base)
        cname = container_name(d)
        run(["docker", "exec", cname, "rm", "-rf", f"/tmp/plan-{name}"], check=False)
        # mdir/. 复制目录内容到目标，避免 docker cp 把源目录套成子目录
        run(["docker", "cp", f"{mdir}/.", f"{cname}:/tmp/plan-{name}"], check=False)
        r = run(["docker", "exec", cname, "sh", "/guest/apply.sh", f"/tmp/plan-{name}"], check=False, capture=True)
        print(f"[apply] {name}: {r.stdout.strip() or r.stderr.strip()}")


# ---------- verify ----------
def cmd_verify(args):
    matrix = load_json(ROOT / "matrix.json")
    distros = enabled_distros(matrix, set(parse_only(args)))
    OUT.mkdir(exist_ok=True)
    for d in distros:
        name = d["name"]
        cname = container_name(d)
        r = run(["docker", "exec", cname, "sh", "/guest/verify.sh",
                 f"/tmp/plan-{name}", f"/guest-out/{name}.tsv"], check=False, capture=True)
        print(f"[verify] {name}: {r.stdout.strip() or r.stderr.strip()}")


# ---------- report ----------
def parse_tsv(path: Path):
    checks = []
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.rstrip("\r")
            parts = line.split("|", 2)
            if len(parts) == 3:
                checks.append({"status": parts[0], "name": parts[1], "detail": parts[2]})
    return checks


def cmd_report(args):
    matrix = load_json(ROOT / "matrix.json")
    distros = enabled_distros(matrix, set(parse_only(args)))
    REPORT_DIR.mkdir(exist_ok=True)
    results = {}
    total_fail = 0
    for d in distros:
        name = d["name"]
        checks = parse_tsv(OUT / f"{name}.tsv")
        passed = sum(1 for c in checks if c["status"] == "PASS")
        failed = sum(1 for c in checks if c["status"] == "FAIL")
        total_fail += failed
        results[name] = {"image": d["image"], "pass": passed, "fail": failed,
                         "checks": checks}

    # Markdown
    md = ["# Linux 迁移验证报告\n"]
    md.append("| 发行版 | 镜像 | PASS | FAIL |")
    md.append("| --- | --- | --- | --- |")
    for name, r in results.items():
        md.append(f"| {name} | `{r['image']}` | {r['pass']} | {r['fail']} |")
    md.append("")
    for name, r in results.items():
        fails = [c for c in r["checks"] if c["status"] == "FAIL"]
        md.append(f"## {name}（{r['pass']} pass / {r['fail']} fail）")
        if not fails:
            md.append("- 全部通过\n")
            continue
        md.append("| 检查项 | 问题 |")
        md.append("| --- | --- |")
        for c in fails:
            md.append(f"| {c['name']} | {c['detail']} |")
        md.append("")
    (REPORT_DIR / "migration-report.md").write_text("\n".join(md), encoding="utf-8")
    (REPORT_DIR / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")

    # 控制台
    for name, r in results.items():
        icon = "OK " if r["fail"] == 0 else "FAIL"
        print(f"{icon} {name}: {r['pass']} pass / {r['fail']} fail")
    print(f"\n报告: {REPORT_DIR / 'migration-report.md'}")
    if total_fail:
        sys.exit(1)


# ---------- down / all ----------
def cmd_down(args):
    matrix = load_json(ROOT / "matrix.json")
    compose = detect_compose()
    proj = matrix.get("compose_project", "linuxmig")
    run(compose + ["-p", proj, "-f", "compose.generated.yml", "down", "-v"], check=False)
    print("down: 容器与网络已清理")


def cmd_all(args):
    cmd_up(args)
    cmd_apply(args)
    cmd_verify(args)
    cmd_report(args)


# ---------- main ----------
def main():
    ap = argparse.ArgumentParser(description="linux-migrate 发行版矩阵验证编排")
    ap.add_argument("--only", help="只跑指定发行版，逗号分隔")
    ap.add_argument("--skip-pull", action="store_true")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("init", "up", "apply", "verify", "report", "down", "all"):
        p = sub.add_parser(c)
        p.add_argument("--only", help="只跑指定发行版，逗号分隔")
        p.add_argument("--skip-pull", action="store_true")
        p.add_argument("--plan", help="使用指定计划文件（相对仓库根，默认 plan/migration.json）")
    args = ap.parse_args()
    {"init": cmd_init, "up": cmd_up, "apply": cmd_apply, "verify": cmd_verify,
     "report": cmd_report, "down": cmd_down, "all": cmd_all}[args.cmd](args)


if __name__ == "__main__":
    main()
