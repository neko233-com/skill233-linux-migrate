# skill233-linux-migrate · 本机 Compose 矩阵验证服务器迁移

**只搬软件、不换 OS**：在本机用 Kiri / Docker Compose 拉起 Debian、Ubuntu、CentOS(Stream)、Rocky、Alma、Alpine 容器矩阵，
**不碰生产**先把源机业务栈完整复刻方案跑一遍，找出包名 / 服务名 / 路径 / 二进制兼容差异；
全绿后经 `prod_deploy` 把**同一份计划**部署到真实目标机（自动备份 + 原地校验 + 一键回滚）。

完整复刻业务栈：**包、配置、业务目录（含属主/权限）、用户组、cron、systemd unit、常驻服务、防火墙规则**；
**数据库（dump→restore）为可选中间件**：核心业务优先跑通，中间件按需单独验证，不阻塞核心迁移发布。
技能**业务无关**——迁移你自己的任意业务到另一台 Linux；proxysss 只是可选示例二进制（`examples/business`），不是主线。

## 快速开始

```bash
# 主线：通用业务核心（python 应用 + 属主权限 + unit + 服务 + 防火墙，无中间件）
python scripts/matrix.py reset --only ubuntu-noble
python scripts/matrix.py apply --only ubuntu-noble --plan examples/full-business/plan.json \
    --stages pkgs,files,dirs,users,attrs,units,cron   # Agent 可先只跑核心文件/权限阶段
python scripts/matrix.py apply --only ubuntu-noble --plan examples/full-business/plan.json \
    --stages services,firewall                         # 再起服务、应用防火墙
python scripts/matrix.py verify --only ubuntu-noble --plan examples/full-business/plan.json
python scripts/matrix.py all --plan examples/full-business/plan.json   # 7 发行版全量验证
python scripts/prod_deploy.py --plan examples/full-business/plan.json \
    --transport docker --container lm-ubuntu-noble                     # 不碰真机预演生产路径
python scripts/prod_deploy.py --plan examples/full-business/plan.json \
    --transport ssh --target root@<目标机EIP>                          # 真实目标机部署
python scripts/prod_deploy.py --transport ssh --target root@<目标机EIP> --rollback  # 回滚
python scripts/matrix.py down                                          # 清理容器

# 可选中间件扩展：数据库 dump→restore（独立验证，不阻塞核心）
python scripts/matrix.py apply --only ubuntu-noble --plan examples/full-business/plan-with-db.json --stages databases
python scripts/matrix.py verify --only ubuntu-noble --plan examples/full-business/plan-with-db.json

# 可选示例：proxysss 网关（默认拉 latest，当前 v1.3.18 全静态）
python scripts/fetch_proxysss.py
python scripts/matrix.py all --plan examples/business/plan.json
```

源机有存量环境时：`scripts/snapshot.sh` 采基线 → `scripts/plan_from_snapshot.py` 直出计划
（包/用户/cron/`/server` 树**含属主权限**/unit 原文+派生服务/glibc 兼容检查/**数据库骨架（可选）**/**防火墙规则**自动带出）。
报告输出到 `report/migration-report.md`（矩阵）与 `report/target-report.md`（目标机）；有 FAIL 时退出码为 1。
切换计划前先 `python scripts/matrix.py reset`（down + up），避免上一轮服务残留占端口。

## Agent 分阶段协作

本工具不是一次性黑盒迁移，适合 Agent 逐步编排：

1. `apply --stages pkgs,files,dirs,users,attrs,units,cron` 先落文件/权限/unit/cron；
2. `apply --stages services,firewall` 再起服务、应用防火墙；
3. `verify` 输出 `out/<distro>.tsv`，`report` 输出 `report/results.json`（每项 `status/name/detail`）；Agent 读 FAIL 的 `detail` 改计划或脚本；
4. **只重跑相关阶段**，不要每次全量重来；核心绿后再跑全矩阵；
5. 中间件需要时再 `--stages databases` 单独验证，失败可作为后续增量任务，不阻塞核心迁移；
6. 生产前先 `prod_deploy --transport docker` 预演同一代码路径，再 SSH 真机部署，异常 `--rollback`。

## 矩阵（matrix.json，7 个发行版）

| 发行版 | 镜像 |
| --- | --- |
| Debian 12 bookworm | `debian:bookworm-slim` |
| Ubuntu 24.04 noble | `ubuntu:24.04` |
| Ubuntu 22.04 jammy | `ubuntu:22.04` |
| Rocky Linux 9 | `rockylinux:9` |
| CentOS Stream 9 | `quay.io/centos/centos:stream9` |
| AlmaLinux 9 | `almalinux:9` |
| Alpine 3.20 | `alpine:3.20` |

引擎优先 Kiri（`kiri compose`），未安装自动回退 `docker compose`。国内网络访问 archive/deb/dl-cdn 过慢时，给 `apply`/`all` 加 `--mirror cn`（容器内包源切到 `mirrors.aliyun.com`，仅显式开启）。

## 示例计划

| 目录 | 用途 |
| --- | --- |
| `examples/full-business/` | **生产主线（通用业务核心，无中间件）**：python http.server 应用 + appsvc 属主 + 0600 密钥 + unit + 真启动（8080 端口归属 + HTTP 回包）+ 防火墙放行 |
| `examples/full-business/plan-with-db.json` | **可选中间件扩展**：在主线之上加 PostgreSQL/Redis dump→restore，单独 `--stages databases` 验证 |
| `examples/business/` | 可选示例：proxysss 网关（`/server` 树 + unit + 真启动；端口归属、check-config、静态站、admin:7777），需先 `fetch_proxysss.py` |
| `examples/prod/` | 最小业务：proxysss 静态站 + deploy 用户 + 备份 cron |
| `examples/deep/` | nginx 三系路径差异参考（sites-enabled / conf.d / http.d）+ `nginx -T` 程序层校验，适用于仍跑 nginx 的旧机器 |
| `examples/negative/` | 负例：故意写错路径与缺失命令，验证 FAIL 与退出码 1 |

## 计划格式 `plan/migration.json`

```json
{
  "src_root": "out/real-server",
  "packages": ["curl", "python3"],
  "files": [{ "src": "files/app.conf", "dest": "/etc/app.conf", "contains": "migrated",
              "owner": "appsvc", "group": "appsvc", "mode": "0640" }],
  "dirs": [{ "src": "server", "dest": "/server", "owner": "appsvc", "group": "appsvc",
             "attrs": [{ "path": "secrets/db.key", "mode": "0600", "owner": "appsvc", "group": "appsvc" }] }],
  "units": [{ "src": "app.service", "name": "app.service", "dest": "/etc/systemd/system/app.service" }],
  "services": [{ "name": "app", "start": "cd /server/web && python3 -m http.server 8080 --bind 0.0.0.0",
                 "stop": "pkill -f 'http.server 8080'", "port": 8080, "wait": 6 }],
  "groups": ["appsvc"],
  "users": [{ "name": "appsvc", "group": "appsvc" }],
  "cron": [{ "expr": "*/10 * * * *", "cmd": "/server/bin/app.sh" }],
  "databases": [{ "type": "postgresql", "name": "appdb", "dump": "files/pg.sql",
                  "verify": "SELECT count(*) FROM users", "user": "app", "password": "apppass" }],
  "firewall": { "backend": "auto", "allow_tcp": [8080, 5432, 6379], "default_input": "deny" },
  "commands": ["curl"],
  "checks": [{ "name": "app-http", "cmd": "curl -s -m 3 -o /dev/null http://127.0.0.1:8080/" }],
  "per_distro": {}
}
```

- **属主/权限**：`files[]` 与 `dirs[]` 支持 `owner`/`group`/`mode`；`dirs[].attrs[]` 按相对路径逐文件还原（0600 密钥、0755 可执行等）。tar 保留源 mode/uid/gid，apply 阶段 chown/chmod，**不再统一 0755**。
- **数据库（可选）**：`databases[]` 支持 postgresql/mysql/mariadb/redis，`dump` 为源机导出文件，apply 自动装包→初始化→起守护→恢复→建账号，`verify` 恢复后校验查询。**核心迁移可先不填；中间件按需 `--stages databases` 单独验证，不阻塞核心发布**。mongodb 需人工 mongodump/mongorestore。
- **防火墙**：`firewall` 支持 ufw/firewalld/iptables/auto + 放行端口 + 原始规则；目标机真实应用，容器内结构级校验。

校验项：`pkg:` 包安装、`file:` 文件落盘含文本、`fattr:`/`dirattr:`/`attr:` 属主权限还原、`dir:` 目录树、
`unit:` unit 语法/结构、`svc:` 进程存活**且端口由该 pid 持有**、`db:` 数据库恢复后可连接且校验通过（仅计划声明 databases 时）、
`fw:` 防火墙状态/规则、`cmd:` 命令可发现、`user:`/`group:` 存在、
`cron:` 定义落在实际生效路径（Alpine `/etc/crontabs/root`，其余 `/etc/cron.d`）、
`check:` 自定义命令通过（验程序层，如配置是否真被加载、业务端口是否回 200）。

> 容器无 systemd / 无内核 / 无真实网卡：`units` 只验语法与结构，`svc` 只验进程与端口归属，`fw` 只验规则清单，
> 不验开机自启与 systemd 托管。详见 `references/workflow.md`。
> 业务服务器（`/server`、属主权限、可选数据库、二进制 glibc 兼容）见 `references/business-stack.md`；
> 阿里云 → 火山引擎迁移见 `references/aliyun-to-volcengine.md`。

## 生产部署（prod_deploy）

矩阵全绿后，同一份计划直接上目标机，验过的就是部署的：

1. 自动识别目标发行版（os-release），按 `per_distro` 合并计划；
2. 备份将被覆盖的文件/目录/cron/unit/**防火墙状态**到 `/var/backups/linuxmig-<ts>`（清单化）；
3. `USE_SYSTEMD=1` 执行：unit `enable --now`、服务由 systemd 托管（MainPID 校验端口归属）、cron reload、**防火墙真实应用**、数据库恢复；
4. 目标机原地跑同一套 `verify.sh`，出 `report/target-report.md`，FAIL 退出码 1；
5. `--rollback`：停服务（含数据库守护）→ 按清单还原（部署前不存在的删除，存在的恢复）→ 防火墙规则恢复 → daemon-reload。

不碰真机预演：`--transport docker --container lm-<distro>`，走与生产完全相同的代码路径。

## 实测状态（2026-11-23）

- 核心业务计划 `examples/full-business/plan.json`：**7 发行版 20/20 全 PASS**（Debian 12 / Ubuntu 24.04 / Ubuntu 22.04 / Rocky 9 / CentOS Stream 9 / Alma 9 / Alpine 3.20）。
- 覆盖：包安装、配置文件、`/server` 目录树、用户组、cron、unit、服务启动（8080 端口由 app 进程持有）、HTTP 回包、密钥 0600/可执行 0755 属主权限、防火墙规则清单。
- `prod_deploy --transport docker` 生产路径预演全 PASS；`--rollback` 恢复成功（服务停止、文件/权限/unit/cron 还原）。
- 中间件（PostgreSQL/Redis/MariaDB）代码已保留为**可选能力**，不作为核心迁移发布门槛；数据库 dump 需从源机导出后单独 `--stages databases` 验证。

## 作为 Agent Skill 使用

`SKILL.md` 即技能定义；把整个目录放入 `workspace/.user_skills/` 或技能加载目录即可被 Agent 触发。