#!/usr/bin/env python3
"""fetch_proxysss.py — 从 neko233-com/proxysss 的 GitHub Release 拉取二进制，
组装 /server 业务树（默认 out/proxysss-stack），供 examples/business、examples/prod 使用。

proxysss 替代 nginx 作为业务网关。v1.3.15+ 为全静态 ELF，7 发行版（含 Alpine/musl）通用。

用法: python scripts/fetch_proxysss.py [--tag v1.3.15|latest] [--arch amd64|arm64] [--out out/proxysss-stack]
"""
import argparse
import re
import struct
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CONFIG = """\
config_version: 1
http:
  plain_bind: 0.0.0.0:8080
  tls_bind: 0.0.0.0:8443
  h3_bind: 0.0.0.0:8443
  tls:
    mode: self_signed
    cert_path: certs/proxysss-cert.pem
    key_path: certs/proxysss-key.pem
    generate_self_signed_if_missing: true
    server_name: gateway.local
admin:
  enabled: true
  bind: 127.0.0.1:7777
  username: root
  password: root
monitoring:
  enabled: true
  path: /metrics
services:
  static_sites:
    - name: business
      hosts: []
      path_prefix: /
      root: /server/web
      index_files: [index.html]
"""


def elf_info(p: Path):
    d = p.read_bytes()
    if d[:4] != b"\x7fELF":
        return "not-elf", ""
    phoff = struct.unpack_from("<Q", d, 32)[0]
    phsz = struct.unpack_from("<H", d, 54)[0]
    phn = struct.unpack_from("<H", d, 56)[0]
    interp = any(struct.unpack_from("<I", d, phoff + i * phsz)[0] == 3 for i in range(phn))
    vs = sorted(set(re.findall(rb"GLIBC_2\.(\d+)", d)), key=int)
    floor = f"2.{vs[-1]}" if vs else ""
    return ("dynamic" if interp else "static"), floor


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="latest")
    ap.add_argument("--arch", default="amd64", choices=["amd64", "arm64"])
    ap.add_argument("--out", default="out/proxysss-stack")
    args = ap.parse_args()

    out = ROOT / args.out
    stack = out / "server" / "proxysss"
    web = out / "server" / "web"
    for d in (stack / "certs", stack / "logs", web):
        d.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as td:
        cmd = ["gh", "release", "download"]
        if args.tag != "latest":
            cmd.append(args.tag)
        cmd += ["-R", "neko233-com/proxysss", "-p", f"proxysss-linux-{args.arch}.tar.gz",
                "-D", td, "--clobber"]
        subprocess.run(cmd, check=True)
        tgz = next(Path(td).glob("*.tar.gz"))
        with tarfile.open(tgz) as tf:
            member = next(m for m in tf.getmembers()
                          if m.name in ("proxysss", "./proxysss") or m.name.endswith("/proxysss"))
            with tf.extractfile(member) as src, open(stack / "proxysss", "wb") as dst:
                dst.write(src.read())
    (stack / "proxysss").chmod(0o755)

    (stack / "proxysss.yaml").write_bytes(CONFIG.encode())
    (web / "index.html").write_bytes(b"proxysss business ok\n")

    kind, floor = elf_info(stack / "proxysss")
    size_mb = (stack / "proxysss").stat().st_size / 1048576
    print(f"已组装 {out}（{size_mb:.1f}MB, {kind}" + (f", glibc>={floor}" if floor else "") + "）")
    if kind == "dynamic" and floor:
        print(f"警告：动态产物要求 glibc>={floor}，老发行版会起不来；建议用 v1.3.15+ 静态版。")
    print("下一步: python scripts/matrix.py reset && python scripts/matrix.py all --plan examples/business/plan.json")


if __name__ == "__main__":
    main()
