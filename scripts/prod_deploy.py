#!/usr/bin/env python3
"""prod_deploy.py — 把「容器里验过的同一份计划」部署到真实目标机并原地校验。

生产闭环：snapshot → plan → matrix 容器验证 → prod_deploy 目标机执行 → 目标机 verify → 报告。
执行前自动备份（/var/backups/linuxmig-<ts>），失败可 --rollback 一键恢复。

用法:
  # 真实目标机（SSH，root 或可 sudo 的账号需自行保证权限）
  python scripts/prod_deploy.py --plan examples/business/plan.json --transport ssh --target root@<火山EIP>
  # 本机容器预演（不碰真机，走与生产完全相同的 target_apply/verify 代码路径）
  python scripts/prod_deploy.py --plan examples/business/plan.json --transport docker --container lm-ubuntu-noble
  # 回滚最近一次部署
  python scripts/prod_deploy.py --transport ssh --target root@<EIP> --rollback

--distro 可显式指定 per_distro 合并键（缺省按目标机 os-release 自动识别）。
"""
import argparse
import json
import subprocess
import sys
import tarfile
from pathlib import Path

import matrix

ROOT = matrix.ROOT
REMOTE_DIR = "/tmp/linuxmig-deploy"
REMOTE_TAR = "/tmp/linuxmig-deploy.tar"
REMOTE_TSV = "/tmp/linuxmig-verify.tsv"

DISTRO_MAP = {
    "ubuntu-24.04": "ubuntu-noble",
    "ubuntu-22.04": "ubuntu-jammy",
    "debian-12": "debian-bookworm",
    "rocky-9": "rocky-9",
    "almalinux-9": "alma-9",
    "centos-9": "centos-stream9",
    "alpine-3.20": "alpine-320",
}


class DockerTransport:
    def __init__(self, container):
        self.c = container

    def exec(self, cmd, check=True):
        r = subprocess.run(["docker", "exec", self.c, "sh", "-c", cmd],
                           capture_output=True, text=True)
        if check and r.returncode != 0:
            raise SystemExit(f"远端命令失败(rc={r.returncode}): {cmd}\n{r.stdout}\n{r.stderr}")
        return r

    def upload(self, local: Path, remote: str):
        r = subprocess.run(["docker", "cp", str(local), f"{self.c}:{remote}"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit(f"docker cp 失败: {r.stderr.strip()}")

    def download_text(self, remote: str) -> str:
        r = subprocess.run(["docker", "exec", self.c, "cat", remote],
                           capture_output=True, text=True, check=True)
        return r.stdout


class SshTransport:
    def __init__(self, target):
        self.t = target

    def exec(self, cmd, check=True):
        r = subprocess.run(["ssh", self.t, cmd], capture_output=True, text=True)
        if check and r.returncode != 0:
            raise SystemExit(f"远端命令失败(rc={r.returncode}): {cmd}\n{r.stdout}\n{r.stderr}")
        return r

    def upload(self, local: Path, remote: str):
        r = subprocess.run(["scp", str(local), f"{self.t}:{remote}"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit(f"scp 失败: {r.stderr.strip()}")

    def download_text(self, remote: str) -> str:
        r = subprocess.run(["ssh", self.t, f"cat {remote}"],
                           capture_output=True, text=True, check=True)
        return r.stdout


def detect_distro(tr) -> str:
    r = tr.exec('. /etc/os-release 2>/dev/null; echo $ID-$VERSION_ID', check=False)
    key = r.stdout.strip().strip('"')
    if key in DISTRO_MAP:
        return DISTRO_MAP[key]
    for k, v in DISTRO_MAP.items():
        if key.startswith(k.rsplit("-", 1)[0] + "-"):
            return v
    return ""


def build_tar(mdir: Path) -> Path:
    d = matrix.OUT / "deploy"
    d.mkdir(parents=True, exist_ok=True)
    tmp = d / "linuxmig-deploy.tar"
    with tarfile.open(tmp, "w") as tf:
        for f in sorted(mdir.rglob("*")):
            if f.is_file():
                tf.add(f, arcname="plan/" + f.relative_to(mdir).as_posix())
        for f in sorted((ROOT / "guest").glob("*.sh")):
            tf.add(f, arcname="guest/" + f.name)
    return tmp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", default="plan/migration.json")
    ap.add_argument("--transport", choices=["ssh", "docker"], required=True)
    ap.add_argument("--target", help="ssh 目标，如 root@1.2.3.4")
    ap.add_argument("--container", help="docker 容器名，如 lm-ubuntu-noble")
    ap.add_argument("--distro", help="per_distro 合并键（缺省自动识别目标机）")
    ap.add_argument("--rollback", action="store_true", help="恢复最近一次部署前的状态")
    args = ap.parse_args()

    if args.transport == "ssh":
        if not args.target:
            raise SystemExit("--transport ssh 需要 --target")
        tr = SshTransport(args.target)
    else:
        if not args.container:
            raise SystemExit("--transport docker 需要 --container")
        tr = DockerTransport(args.container)

    if args.rollback:
        r = tr.exec(f"sh {REMOTE_DIR}/guest/target_rollback.sh")
        print(r.stdout.strip())
        return

    plan_path = ROOT / args.plan
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    plan_base = plan_path.parent
    dirs_base = plan_base
    if plan.get("src_root"):
        dirs_base = Path(plan["src_root"])
        if not dirs_base.is_absolute():
            dirs_base = ROOT / dirs_base

    name = args.distro or detect_distro(tr)
    if not name:
        print("警告：无法识别目标发行版，按基础计划执行（不做 per_distro 覆盖）")
        name = "target"
    else:
        print(f"目标发行版: {name}")

    merged = matrix.merge_plan(name, plan)
    mdir = matrix.materialize(name, merged, plan_base, dirs_base)
    tar = build_tar(mdir)
    tr.upload(tar, REMOTE_TAR)
    tr.exec(f"rm -rf {REMOTE_DIR} && mkdir -p {REMOTE_DIR} && tar -xf {REMOTE_TAR} -C {REMOTE_DIR}")

    r = tr.exec(f"sh {REMOTE_DIR}/guest/target_apply.sh {REMOTE_DIR}/plan")
    print(r.stdout.strip())

    tr.exec(f"sh {REMOTE_DIR}/guest/verify.sh {REMOTE_DIR}/plan {REMOTE_TSV}")
    tsv = tr.download_text(REMOTE_TSV)
    matrix.OUT.mkdir(exist_ok=True)
    (matrix.OUT / "target-verify.tsv").write_bytes(tsv.encode())
    checks = matrix.parse_tsv(matrix.OUT / "target-verify.tsv")
    passed = sum(1 for c in checks if c["status"] == "PASS")
    failed = sum(1 for c in checks if c["status"] == "FAIL")

    matrix.REPORT_DIR.mkdir(exist_ok=True)
    md = [f"# 目标机部署校验报告（{args.target or args.container} / {name}）\n",
          f"PASS {passed} / FAIL {failed}\n", "| 状态 | 检查项 | 细节 |", "| --- | --- | --- |"]
    for c in checks:
        md.append(f"| {c['status']} | {c['name']} | {c['detail']} |")
    md.append("\n回滚: `python scripts/prod_deploy.py --transport %s %s --rollback`"
              % (args.transport, f"--target {args.target}" if args.target else f"--container {args.container}"))
    (matrix.REPORT_DIR / "target-report.md").write_text("\n".join(md), encoding="utf-8")
    (matrix.REPORT_DIR / "target-results.json").write_text(
        json.dumps({"target": args.target or args.container, "distro": name,
                    "pass": passed, "fail": failed, "checks": checks}, ensure_ascii=False, indent=2),
        encoding="utf-8")

    for c in checks:
        print(f"{c['status']} {c['name']}: {c['detail']}")
    print(f"\n报告: {matrix.REPORT_DIR / 'target-report.md'}")
    if failed:
        print("存在 FAIL：可 --rollback 恢复部署前状态")
        sys.exit(1)


if __name__ == "__main__":
    main()
