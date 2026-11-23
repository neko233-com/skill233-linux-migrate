---
name: linux-migrate
description: 在本机用 Kiri / Docker Compose 拉起 Debian、Ubuntu、CentOS(Stream)、Rocky、Alma、Alpine 发行版容器矩阵，不碰生产即可验证 Linux 服务器迁移方案与部署脚本：采集源服务器快照、按发行版差异适配安装与配置、逐项校验并生成兼容报告。完整复刻业务栈——包、配置、业务目录（含属主/权限）、用户组、cron、systemd unit、数据库（dump→restore）、防火墙规则；支持把验过的同一份计划经 prod_deploy 部署到真实目标机（自动备份、原地校验、一键回滚）。当用户要迁移服务器、把业务整体搬到另一台 Linux、评估跨发行版兼容性、移植 apt/dnf 安装脚本、上生产前预检迁移步骤，或在本机模拟多发行版环境时使用。
---

# Linux Migrate · 本机 Compose 矩阵验证服务器迁移

目标：**只搬软件、不换 OS**，把源机业务栈复刻到目标机。**核心业务优先**（包、配置、用户、cron、业务目录属主/权限、unit、服务、防火墙），中间件（数据库）按需延后、独立验证；先在本机容器矩阵跑通核心，再上生产。

**本技能按 Agent 协作设计，不是一次性黑盒迁移**：采集 → 计划 → 分阶段 apply → 逐项 verify → 按结果修复 → 再增量执行；Agent 可只跑需要的阶段、只验关心的项、跳过暂不处理的中间件。

本机引擎优先用 **Kiri**（`kiri compose`）；未安装 Kiri 时自动回退 `docker compose`。

## 前置检查

```powershell
kiri status 2>$null; docker info --format '{{.Name}}'   # 引擎在线即可
python --version                                        # 3.10+，无第三方依赖
```

引擎不在线时先 `kiri ui --start` 或启动 Docker Desktop。

## 标准工作流（Agent 分阶段协作）

0. **（可选示例）拉取 proxysss**：`python scripts/fetch_proxysss.py` 从 `neko233-com/proxysss` 的 GitHub Release 拉二进制（默认 latest，当前 v1.3.18 全静态）组装 `/server` 业务树，仅供 `examples/business` 示例使用。**技能主线是任意业务栈迁移，不绑定 proxysss**；通用业务示例见 `examples/full-business`。
1. **采集源快照**：在源服务器上跑 `scripts/snapshot.sh`，得到 `snapshot/source.txt`（系统、包清单、启用服务、监听端口、业务目录、**属主/权限**、unit 原文、二进制 glibc 下限、cron、用户组、**数据库引擎**、防火墙）。
2. **快照转计划**：`python scripts/plan_from_snapshot.py` 自动把包清单、业务用户、cron、`/server` 目录树（**含 owner/group/attrs 属主权限**）、unit（落盘+派生 services）、业务二进制 glibc 兼容检查、**数据库骨架（可选）**、**防火墙规则**写进 `plan/migration.json`；无快照则 `python scripts/matrix.py init` 手写。
3. **Agent 审阅计划（关键）**：不照单全收。按源机实际裁剪：只迁还在用的目录；中间件不确定就先留空 `databases`（核心业务可先跑通）；补 `files`/`services` 的 `stop` 与 `port`；`attrs` 至少覆盖密钥/可执行/配置。**计划是 Agent 的工作稿，不是一次性配置文件**。
4. **分阶段 apply（核心优先）**：
   ```powershell
   python scripts/matrix.py reset --only ubuntu-noble
   python scripts/matrix.py apply --only ubuntu-noble --plan <plan> --stages pkgs,files,dirs,users,attrs,units,cron
   python scripts/matrix.py verify --only ubuntu-noble --plan <plan>
   ```
   读 `out/<distro>.tsv`（或 `report/results.json`）逐项看 FAIL 的 `detail`，改计划/脚本后**只重跑相关阶段**，不要每次全量重来。
5. **起服务 + 防火墙**：`--stages services,firewall` 后再 verify；`svc` 必须「端口由该进程持有」，`fw` 容器内为结构级、目标机为真实状态。
6. **中间件（可选、不阻塞核心）**：需要时在计划补 `databases`（dump 从源机导出），单独 `--stages databases` 验证；**数据库未绿不影响核心业务迁移的发布判定**，可作为后续增量任务交给 Agent 继续。
7. **全矩阵 + 报告**：核心绿后 `python scripts/matrix.py all`（或仅跑启用发行版）→ `report/migration-report.md`；有 FAIL 退出码 1，`results.json` 供 Agent 消费。
8. **生产部署**：`python scripts/prod_deploy.py --plan <plan> --transport ssh --target root@<目标机>`——同一份计划在目标机执行（自动备份 → systemd 托管 → 原地 verify → 报告）；失败 `--rollback` 一键恢复。不碰真机预演用 `--transport docker --container lm-<distro>`。
9. **清理**：`python scripts/matrix.py down`。

> 换计划文件或换发行版前**必须先 `down` 再 `up`（或 `reset`）**：
> 上一轮起的服务还占着端口，会造成「端口被占但不是本服务」的假通过。`verify` 已按「端口是否由该服务的 pid 持有」判定，但容器仍应干净。

## 命令（scripts/matrix.py）

| 命令 | 作用 |
| --- | --- |
| `init` | 无计划文件时脚手架生成示例 plan |
| `up` | 按 `matrix.json` 生成 `compose.generated.yml`，拉镜像并 `compose up -d` |
| `apply` | 把材料化后的计划拷入容器并执行 `guest/apply.sh`（装包/落配置/解包业务目录/落 unit/起服务/写 cron）；`--stages pkgs,files,dirs,units,users,attrs,databases,services,cron,firewall` 只跑指定阶段，默认 all |
| `verify` | 容器内跑 `guest/verify.sh`，产出每发行版 TSV 结果 |
| `report` | 汇总 TSV → `report/migration-report.md` + 控制台表格；有 FAIL 时退出码 1 |
| `down` | `compose down -v` 清理容器与网络 |
| `reset` | down + up，切换计划前重置干净环境 |
| `all` | up → apply → verify → report 一条龙 |

独立脚本：
- `python scripts/fetch_proxysss.py` — （可选示例）从 `neko233-com/proxysss` Release 拉二进制组装 `/server` 业务树，仅供 examples/business 使用；默认 latest（v1.3.18 全静态）。
- `python scripts/plan_from_snapshot.py` — 快照 → 计划（包/用户/cron/目录树**含属主权限**/unit/服务/glibc 检查/**数据库骨架**/**防火墙规则**自动带出）。
- `python scripts/prod_deploy.py` — 目标机生产执行器：`--transport ssh --target root@<EIP>` 真实部署；`--transport docker --container lm-<distro>` 本机预演；`--rollback` 恢复最近一次部署前状态。自动备份到 `/var/backups/linuxmig-<ts>`，目标机原地 verify 出 `report/target-report.md`，有 FAIL 退出码 1。

指定发行版子集：`python scripts/matrix.py all --only rocky-9,ubuntu-noble`。
国内网络访问 archive/deb/dl-cdn 过慢时加 `--mirror cn`：容器内包源切到 `mirrors.aliyun.com`（仅显式开启，不改默认）。
用自定义计划：`--plan examples/deep/plan.json`（`files/units` 的 `src` 相对计划目录；`dirs` 受 `src_root` 控制）。
示例场景：
- `examples/full-business/` — **生产主线（通用业务核心，无中间件）**：python http.server 应用（`/server` 树 + appsvc 属主 + 0600 密钥 + unit + 真启动校验 8080 归属与 HTTP）+ 防火墙，7 发行版验证；`plan-with-db.json` 为**可选中间件扩展**（PostgreSQL/Redis dump→restore），按需单独验证；
- `examples/business/` — 可选示例：proxysss 网关（`/server` 树 + unit + 真启动，校验 8080 归属、check-config、静态站、admin:7777），需先 `fetch_proxysss.py`；
- `examples/prod/` — 最小业务：proxysss 静态站 + deploy 用户 + 备份 cron；
- `examples/deep/` — nginx 三系路径差异参考（sites-enabled / conf.d / http.d）+ `nginx -T` 程序层校验，适用于仍跑 nginx 的旧机器；
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
  "packages": ["curl", "python3"],
  "files": [
    { "src": "files/hello.conf", "dest": "/etc/hello-migrate.conf", "contains": "migrated",
      "owner": "appsvc", "group": "appsvc", "mode": "0640" }
  ],
  "dirs": [
    { "src": "server", "dest": "/server", "owner": "appsvc", "group": "appsvc",
      "attrs": [ { "path": "secrets/db.key", "mode": "0600", "owner": "appsvc", "group": "appsvc" } ] }
  ],
  "units": [
    { "src": "app.service", "name": "app.service", "dest": "/etc/systemd/system/app.service" }
  ],
  "services": [
    { "name": "app", "start": "cd /server/web && python3 -m http.server 8080 --bind 0.0.0.0",
      "stop": "pkill -f 'http.server 8080'", "port": 8080, "wait": 6 }
  ],
  "users": [{ "name": "appsvc", "group": "appsvc" }],
  "groups": ["appsvc"],
  "cron": [{ "expr": "*/10 * * * *", "cmd": "/server/bin/app.sh" }],
  "databases": [
    { "type": "postgresql", "name": "appdb", "dump": "files/pg.sql",
      "verify": "SELECT count(*) FROM users", "user": "app", "password": "apppass" },
    { "type": "redis", "name": "cache", "dump": "files/redis.txt", "verify": "GET session:1" }
  ],
  "firewall": { "backend": "auto", "allow_tcp": [8080, 5432, 6379], "allow_udp": [], "default_input": "deny" },
  "commands": ["curl"],
  "checks": [
    { "name": "app-http", "cmd": "curl -s -m 3 -o /dev/null http://127.0.0.1:8080/" }
  ],
  "per_distro": {
    "rocky-9": { "packages": ["curl"] }
  }
}
```

- `packages`：通用包清单；`per_distro.<name>` 按发行版合并覆盖（追加/替换见下）。
- `files[].src` 相对计划目录；`dest` 为容器内目标路径；`contains` 为落盘后必须出现的文本（可省略）；`owner`/`group`/`mode` 还原属主与权限（可省略，省略则不强制）。
- `dirs`：**整棵业务目录树**（典型是源机 `/server`）。host 侧打成 tar（保留源 mode/uid/gid），容器内解包到 `dest`；`owner`/`group` 递归 chown，`attrs[]` 按相对路径逐文件还原 `mode`/`owner`/`group`（如 0600 密钥、0755 可执行）。**不再统一 0755**。
- `units`：systemd unit 文件落盘；镜像内有 `systemd-analyze` 时做真实语法校验，否则做结构校验并标注。
- `services`：**真的把服务跑起来**。`start` 后台执行，`stop` 在下次 apply 前清理，`port` 用于校验该端口由本服务进程持有。
- `databases`（**可选**）：数据库迁移。`type` ∈ postgresql/mysql/mariadb/redis；`dump` 为源机导出的 SQL/命令文件（相对计划目录）；apply 自动装包→初始化→起守护→恢复→建账号；`verify` 为恢复后校验查询（pg/mysql 用 SQL，redis 用命令如 `GET key`/`PING`）。`user`/`password` 建业务账号，`port`/`packages` 可覆盖默认。**核心迁移可先不填；中间件单独 `--stages databases` 验证，不阻塞核心发布**。mongodb 需人工 mongodump/mongorestore。
- `firewall`：`backend` ∈ ufw/firewalld/iptables/auto；`allow_tcp`/`allow_udp` 放行端口；`rules` 原始 iptables 规则；`default_input` 入站默认策略。**目标机真实应用；容器内无 netfilter 权限，落规则清单做结构级校验**。
- `commands`：`command -v` 级别的可执行性校验。
- `checks`：容器内 `sh -c` 执行的任意校验命令，退出 0 记 PASS；用来验程序层（如 `nginx -T`、`curl` 打业务端口）。
- `per_distro` 支持键：`packages`（合并去重）、`files`、`dirs`、`units`、`services`、`users`、`groups`、`cron`、`commands`、`checks`、`databases`、`firewall`。
- `src_root`：`dirs` 的基准目录（相对仓库根或绝对路径），用于把仓库外的真实 `/server` 副本接进来；`files/units` 仍相对计划目录，保证计划可移植。

## 校验项类型（guest/verify.sh 自动判定）

- `pkg:<name>`：包已安装（dpkg / rpm / apk 自动适配）
- `file:<dest>`：文件存在且含 `contains` 文本
- `fattr:<dest>` / `dirattr:<dest>` / `attr:<dest>/<path>`：属主/属组/权限按源机还原（stat %U/%G/%a，兼容 busybox）
- `dir:<dest>`：目录存在（附文件数）
- `unit:<name>`：unit 落盘 + 语法/结构校验（无 systemd 的发行版会明确标注 openrc 需转换）
- `svc:<name>`：进程存活，**且端口确实由该 pid 持有的 socket 监听**（不是「有人占着端口」）
- `db:<name>`：数据库恢复后实例可连接且校验查询通过（postgresql/mysql/mariadb/redis）
- `fw:<backend>`：防火墙——目标机查真实 active 状态；容器内查规则清单（结构级，无 netfilter）
- `cmd:<command>`：命令可执行
- `user:<name>` / `group:<name>`：存在（直接读 /etc/passwd、/etc/group，兼容 busybox）
- `cron:<expr>`：cron 定义落在实际生效路径（RHEL/Debian 为 `/etc/cron.d`，Alpine 为 `/etc/crontabs/root`）
- `check:<name>`：自定义命令通过

## 判读报告

- 全 PASS → 迁移方案在该矩阵上可重复，可进入真实服务器检查清单。
- FAIL 常见根因与修法见 `references/distro-matrix.md`（包名、服务名、路径、防火墙）与 `references/business-stack.md`（业务二进制/glibc/端口）。
- 报告同时输出 `report/results.json` 供脚本消费。

## 重要限制（不要过度解读）

- 容器**无 systemd、无内核、无真实网卡**：矩阵里 `units` 只验文件与语法/结构，`svc` 验「进程起来 + 端口 LISTEN 且归属该进程」，`fw` 只验规则清单（结构级）。**真实目标机经 `prod_deploy` 部署时启用 systemd 托管**（`enable --now` + `MainPID` 取 pid + cron reload）、**真实应用防火墙**，并自动备份、可回滚；开机自启在目标机由 unit 的 `[Install]` 生效。
- **数据库**：容器内用直控守护进程（pg_ctl / mariadbd-safe / redis-server）初始化并恢复 dump，验证「恢复后实例可连接 + 校验查询通过」；目标机同样适用。dump 文件需先从源机导出（mysqldump / pg_dump / redis 命令），快照只探测引擎不自动导出（需凭据）。mongodb 需人工 mongodump/mongorestore。
- **业务二进制 glibc**：动态链接产物要求目标机 glibc >= 产物下限（快照自动检查）；全静态产物（如 proxysss v1.3.18）7 发行版含 Alpine/musl 通用。历史实测与修法见 `references/business-stack.md`。
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
