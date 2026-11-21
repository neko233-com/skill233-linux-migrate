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

1. **（可选）采集源快照**：在源服务器上跑 `scripts/snapshot.sh`，得到 `snapshot/source.txt`（系统、包清单、启用服务、监听端口、cron、用户组、防火墙）。
2. **快照转计划**：`python scripts/plan_from_snapshot.py` 自动把包清单、业务用户、cron 写进 `plan/migration.json`；无快照则 `python scripts/matrix.py init` 手写。
3. **编辑计划**：补配置文件（`files`）、命令（`commands`）；发行版专属差异用 `per_distro` 覆盖。
4. **跑矩阵**：`python scripts/matrix.py all`（= up → apply → verify → report）。
5. **读报告**：`report/migration-report.md`，逐发行版看 PASS/FAIL，按建议改计划或脚本。
6. **清理**：`python scripts/matrix.py down`。

## 命令（scripts/matrix.py）

| 命令 | 作用 |
| --- | --- |
| `init` | 无计划文件时脚手架生成示例 plan |
| `up` | 按 `matrix.json` 生成 `compose.generated.yml`，拉镜像并 `compose up -d` |
| `apply` | 把材料化后的计划拷入容器并执行 `guest/apply.sh`（包安装/落配置/建用户/cron 写入 /etc/cron.d） |
| `verify` | 容器内跑 `guest/verify.sh`，产出每发行版 TSV 结果 |
| `report` | 汇总 TSV → `report/migration-report.md` + 控制台表格；有 FAIL 时退出码 1 |
| `down` | `compose down -v` 清理容器与网络 |
| `all` | up → apply → verify → report 一条龙 |

独立脚本：`python scripts/plan_from_snapshot.py` 把 `snapshot/source.txt` 转成 `plan/migration.json`（包/用户/cron 自动带出）。

指定发行版子集：`python scripts/matrix.py all --only rocky-9,ubuntu-noble`。

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
  "packages": ["curl"],
  "files": [
    { "src": "files/hello.conf", "dest": "/etc/hello-migrate.conf", "contains": "migrated" }
  ],
  "users": [{ "name": "appdemo", "group": "appdemo" }],
  "groups": ["appdemo"],
  "cron": [{ "expr": "*/10 * * * *", "cmd": "/opt/app/collect.sh" }],
  "commands": ["curl"],
  "per_distro": {
    "rocky-9": { "packages": ["curl"] }
  }
}
```

- `packages`：通用包清单；`per_distro.<name>` 按发行版合并覆盖（追加/替换见下）。
- `files[].src` 相对 `plan/` 目录；`dest` 为容器内目标路径；`contains` 为落盘后必须出现的文本（可省略）。
- `commands`：`command -v` 级别的可执行性校验。
- `per_distro` 支持键：`packages`（合并去重）、`files`、`users`、`groups`、`cron`、`commands`。

## 校验项类型（guest/verify.sh 自动判定）

- `pkg:<name>`：包已安装（dpkg -l / rpm -qa / apk info 自动适配）
- `file:<dest>`：文件存在且含 `contains` 文本
- `cmd:<command>`：命令可执行
- `user:<name>` / `group:<name>`：存在
- `cron:<expr>`：`/etc/cron.d/linuxmig` 中表达式与命令均在

## 判读报告

- 全 PASS → 迁移方案在该矩阵上可重复，可进入真实服务器检查清单。
- FAIL 常见根因与修法见 `references/distro-matrix.md`（包名、服务名、路径、防火墙）。
- 报告同时输出 `report/results.json` 供脚本消费。

## 重要限制（不要过度解读）

- 容器**无 systemd、无内核、无真实网卡**：本技能只验证「包能装上、配置能落对、命令能找到、用户/cron 定义落盘」这一层；服务真起不起得来、端口通不通，不在此验证范围。需要 systemd 行为时见 `references/workflow.md` 的 systemd-in-docker 方案。
- cron 在容器内只验证任务定义写入 `/etc/cron.d/linuxmig`；真实服务器上由 cron 守护进程加载执行。
- 安装需要容器出网（apt/dnf/apk 更新源）；离线环境先在 `matrix.json` 里关闭安装类检查。
- CentOS 7/8 已 EOL，官方仓库失效，矩阵用 CentOS Stream 9 代表 CentOS 系；迁移到老 CentOS 的注意事项见 `references/distro-matrix.md`。

## 参考文件

- `references/distro-matrix.md` — 各发行版包管理器/服务/路径/防火墙速查表与差异修法。
- `references/workflow.md` — 完整流程细节、systemd-in-docker、真实服务器收尾检查清单。
