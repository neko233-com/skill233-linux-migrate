---
name: linux-migrate
description: 在本机用 Kiri / Docker Compose 拉起 Debian、Ubuntu、CentOS(Stream)、Rocky、Alma、Alpine 发行版容器矩阵，不碰生产即可验证 Linux 服务器迁移方案与部署脚本：采集源服务器快照、按发行版差异适配安装与配置、逐项校验并生成兼容报告。当用户要迁移服务器、评估跨发行版兼容性、移植 apt/dnf 安装脚本、上生产前预检迁移步骤，或在本机模拟多发行版环境时使用。
---

# Linux Migrate · 本机 Compose 矩阵验证服务器迁移

目标：**只搬软件、不换 OS**，把源机软件栈（包、配置、用户、cron）原样复刻到目标机；先在本机容器矩阵里跑一遍，找出包名、服务名、路径、防火墙差异，再上生产。

本机引擎优先用 **Kiri**（`kiri compose`）；未安装 Kiri 时自动回退 `docker compose`。

## 前置检查

```powershell
kiri status 2>$null; docker info --format '{{.Name}}'   # 引擎在线即可
python --version                                        # 3.10+，无第三方依赖
```

引擎不在线时先 `kiri ui --start` 或启动 Docker Desktop。

## 标准工作流

1. **（可选）采集源快照**：在源服务器上跑 `scripts/snapshot.sh`，得到 `snapshot/source.txt`（系统、包清单、启用服务、监听端口、业务目录、cron、用户组、防火墙）。
2. **快照转计划**：`python scripts/plan_from_snapshot.py` 自动把包清单、业务用户、cron 写进 `plan/migration.json`；无快照则 `python scripts/matrix.py init` 手写。
3. **编辑计划**：补配置文件（`files`）、业务目录（`dirs`，如 `/server`）、systemd unit（`units`）、常驻服务（`services`）、命令（`commands`）；发行版专属差异用 `per_distro` 覆盖。
4. **跑矩阵**：`python scripts/matrix.py all`（= up → apply → verify → report）。
5. **读报告**：`report/migration-report.md`，逐发行版看 PASS/FAIL，按建议改计划或脚本。
6. **清理**：`python scripts/matrix.py down`。

> 换计划文件（例如先跑 examples/business 再跑真实业务树）**必须先 `down` 再 `up`（或 `reset`）**：
> 上一轮起的服务还占着端口，会造成「端口被占但不是本服务」的假通过。`verify` 已按「端口是否由该服务的 pid 持有」判定，但容器仍应干净。

## 命令（scripts/matrix.py）

| 命令 | 作用 |
| --- | --- |
| `init` | 无计划文件时脚手架生成示例 plan |
| `up` | 按 `matrix.json` 生成 `compose.generated.yml`，拉镜像并 `compose up -d` |
| `apply` | 把材料化后的计划拷入容器并执行 `guest/apply.sh`（装包/落配置/解包业务目录/落 unit/起服务/写 cron） |
| `verify` | 容器内跑 `guest/verify.sh`，产出每发行版 TSV 结果 |
| `report` | 汇总 TSV → `report/migration-report.md` + 控制台表格；有 FAIL 时退出码 1 |
| `down` | `compose down -v` 清理容器与网络 |
| `reset` | down + up，切换计划前重置干净环境 |
| `all` | up → apply → verify → report 一条龙 |

独立脚本：`python scripts/plan_from_snapshot.py` 把 `snapshot/source.txt` 转成 `plan/migration.json`（包/用户/cron 自动带出）。

指定发行版子集：`python scripts/matrix.py all --only rocky-9,ubuntu-noble`。
用自定义计划：`--plan examples/deep/plan.json`（`files/dirs/units` 的 `src` 相对计划目录解析；`src_root` 可整体改基准）。
示例场景：
- `examples/prod/` — 最小 nginx 站点；
- `examples/deep/` — 双用户组 + 双 cron + 三系 nginx 路径 + `nginx -T` 程序层校验（7 发行版全绿）；
- `examples/business/` — `/server` 业务目录树 + systemd unit + 常驻服务（起 nginx 并验证 8080 由该进程持有）；
- `examples/negative/` — 故意写错路径与缺失命令，用于验证 FAIL 与退出码。

## matrix.json（选哪些发行版）

```json
{
  "compose_project": "linuxmig",
  "compose_bin": "auto",
  "distros": [
    { "name": "debian-bookworm", "image": "debian:bookworm-slim", "enabled": true },
    { "name": "ubuntu-noble", "image": "ubuntu:24.04", "enabled": true },
    { "name": "rocky-9", "image": "rockylinux:9", "enabled": true },
    { "name": "centos-stream9", "image": "quay.io/centos/centos:stream9", "enabled": true },
    { "name": "alma-9", "image": "almalinux:9", "enabled": false },
    { "name": "alpine-320", "image": "alpine:3.20", "enabled": false }
  ]
}
```

`compose_bin: auto` → 有 kiri 用 `kiri compose`，否则 `docker compose`。

## plan/migration.json 格式

```json
{
  "src_root": "out/real-server",
  "packages": ["curl"],
  "files": [
    { "src": "files/hello.conf", "dest": "/etc/hello-migrate.conf", "contains": "migrated" }
  ],
  "dirs": [
    { "src": "server", "dest": "/server" }
  ],
  "units": [
    { "src": "proxysss.service", "name": "proxysss.service", "dest": "/etc/systemd/system/proxysss.service" }
  ],
  "services": [
    { "name": "proxysss", "start": "cd /server/proxysss && ./proxysss run -c proxysss.yaml",
      "stop": "pkill -f 'proxysss run'", "port": 8080, "wait": 6 }
  ],
  "users": [{ "name": "appdemo", "group": "appdemo" }],
  "groups": ["appdemo"],
  "cron": [{ "expr": "*/10 * * * *", "cmd": "/opt/app/collect.sh" }],
  "commands": ["curl"],
  "checks": [
    { "name": "nginx-conf-loaded", "cmd": "nginx -T 2>/dev/null | grep -q 'demo.example.com'" }
  ],
  "per_distro": {
    "rocky-9": { "packages": ["curl"] }
  }
}
```

- `packages`：通用包清单；`per_distro.<name>` 按发行版合并覆盖（追加/替换见下）。
- `files[].src` 相对计划目录；`dest` 为容器内目标路径；`contains` 为落盘后必须出现的文本（可省略）。
- `dirs`：**整棵业务目录树**（典型是源机 `/server`）。host 侧打成 tar，容器内解包到 `dest`，文件统一 0755。
- `units`：systemd unit 文件落盘；镜像内有 `systemd-analyze` 时做真实语法校验，否则做结构校验并标注。
- `services`：**真的把服务跑起来**。`start` 后台执行，`stop` 在下次 apply 前清理，`port` 用于校验该端口由本服务进程持有。
- `commands`：`command -v` 级别的可执行性校验。
- `checks`：容器内 `sh -c` 执行的任意校验命令，退出 0 记 PASS；用来验程序层（如 `nginx -T`、`curl` 打业务端口）。
- `per_distro` 支持键：`packages`（合并去重）、`files`、`dirs`、`units`、`services`、`users`、`groups`、`cron`、`commands`、`checks`。
- `src_root`：`files/dirs/units` 的统一基准目录（相对仓库根或绝对路径），用于把仓库外的真实业务树接进来。

## 校验项类型（guest/verify.sh 自动判定）

- `pkg:<name>`：包已安装（dpkg / rpm / apk 自动适配）
- `file:<dest>`：文件存在且含 `contains` 文本
- `dir:<dest>`：目录存在（附文件数）
- `unit:<name>`：unit 落盘 + 语法/结构校验（无 systemd 的发行版会明确标注 openrc 需转换）
- `svc:<name>`：进程存活，**且端口确实由该 pid 持有的 socket 监听**（不是「有人占着端口」）
- `cmd:<command>`：命令可执行
- `user:<name>` / `group:<name>`：存在（直接读 /etc/passwd、/etc/group，兼容 busybox）
- `cron:<expr>`：cron 定义落在实际生效路径（RHEL/Debian 为 `/etc/cron.d`，Alpine 为 `/etc/crontabs/root`）
- `check:<name>`：自定义命令通过

## 判读报告

- 全 PASS → 迁移方案在该矩阵上可重复，可进入真实服务器检查清单。
- FAIL 常见根因与修法见 `references/distro-matrix.md`（包名、服务名、路径、防火墙）与 `references/business-stack.md`（业务二进制/glibc/端口）。
- 报告同时输出 `report/results.json` 供脚本消费。

## 重要限制（不要过度解读）

- 容器**无 systemd、无内核、无真实网卡**：`units` 只验文件与语法（镜像内通常无 `systemd-analyze`，退化为结构校验）；`svc` 验证的是「进程起来了 + 端口 LISTEN 且归属该进程」，不验证 systemd 托管、开机自启、日志落盘策略。需要 systemd 行为时见 `references/workflow.md`。
- **业务二进制是最大的坑**：Rust/Go/C++ 产物常有 glibc 版本下限。实测 proxysss v1.3.9 linux-amd64 要求 `GLIBC_2.38/2.39`，在 Ubuntu 24.04 可跑，Debian 12(2.36)、Ubuntu 22.04(2.35)、Alma/Rocky 9(2.34) 全部 `GLIBC_x not found`，Alpine(musl) 直接 `not found`。详见 `references/business-stack.md`。
- 想验证「程序真的加载了配置」用 `checks`（如 `nginx -T | grep`）；只靠 `file:` 校验只能证明文件落盘，不能证明被加载。
- cron 在容器内只验证定义写入实际生效路径（Alpine 为 `/etc/crontabs/root`，其余为 `/etc/cron.d`）；真实服务器上由 cron 守护进程加载执行。
- 安装需要容器出网（apt/dnf/apk 更新源）；离线环境先在 `matrix.json` 里关闭安装类检查。
- RHEL 9 minimal 预装 `curl-minimal`，装 `curl` 需 `--allowerasing`（脚本已自动重试）。
- CentOS 7/8 已 EOL，官方仓库失效，矩阵用 CentOS Stream 9 代表 CentOS 系；迁移到老 CentOS 的注意事项见 `references/distro-matrix.md`。

## 参考文件

- `references/distro-matrix.md` — 各发行版包管理器/服务/路径/防火墙速查表与差异修法。
- `references/business-stack.md` — 业务服务器迁移：`/server` 目录、systemd unit、代理类服务、glibc 兼容实测与修法。
- `references/workflow.md` — 完整流程细节、systemd-in-docker、真实服务器收尾检查清单。
- `references/aliyun-to-volcengine.md` — 阿里云 → 火山引擎迁移专项清单（OS/数据/网络/切流回滚）。
