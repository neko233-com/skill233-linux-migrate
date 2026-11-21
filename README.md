# skill233-linux-migrate · 本机 Compose 矩阵验证服务器迁移

**只搬软件、不换 OS**：在本机用 Kiri / Docker Compose 拉起 Debian、Ubuntu、CentOS(Stream)、Rocky、Alma、Alpine 容器矩阵，
**不碰生产**先把源机软件栈（包、配置、用户、cron）复刻方案跑一遍，找出包名 / 服务名 / 路径 / 防火墙差异，再上真实服务器。

## 快速开始

```bash
python scripts/snapshot.sh  # (可选) 在源服务器采集基线，拷回 snapshot/source.txt
python scripts/plan_from_snapshot.py   # 快照 → plan/migration.json（或 matrix.py init 手写）
python scripts/matrix.py all       # up → apply → verify → report
python scripts/matrix.py down      # 清理容器
```

报告输出到 `report/migration-report.md`；有 FAIL 时命令退出码为 1。
自定义计划：`python scripts/matrix.py all --plan examples/prod/plan.json`；`examples/prod/` 是 nginx 站点 + deploy 用户 + 备份 cron 的生产风格示例。

## 矩阵（matrix.json 里启用/注释）

| 发行版 | 镜像 | 默认 |
| --- | --- | --- |
| Debian 12 bookworm | `debian:bookworm-slim` | on |
| Ubuntu 24.04 noble | `ubuntu:24.04` | on |
| Rocky Linux 9 | `rockylinux:9` | on |
| CentOS Stream 9 | `quay.io/centos/centos:stream9` | on |
| AlmaLinux 9 | `almalinux:9` | off |
| Alpine 3.20 | `alpine:3.20` | off |

引擎优先 Kiri（`kiri compose`），未安装自动回退 `docker compose`。

## 计划格式 `plan/migration.json`

```json
{
  "packages": ["curl"],
  "files": [{ "src": "files/hello.conf", "dest": "/etc/hello-migrate.conf", "contains": "migrated" }],
  "groups": ["appdemo"],
  "users": [{ "name": "appdemo", "group": "appdemo" }],
  "cron": [{ "expr": "*/10 * * * *", "cmd": "/opt/app/collect.sh" }],
  "commands": ["curl"],
  "per_distro": {}
}
```

校验项：`pkg:` 包安装、`file:` 文件落盘含文本、`cmd:` 命令可发现、`user:`/`group:` 存在、`cron:` 任务定义写入 `/etc/cron.d/linuxmig`。

> 容器无 systemd / 无内核 / 无真实网卡：本工具只验证包、配置、命令、用户、cron 定义这一层；
> 服务启停、端口连通、防火墙策略需在真实目标机验证。详见 `references/workflow.md`。
> 阿里云 → 火山引擎迁移见 `references/aliyun-to-volcengine.md`。

## 作为 Agent Skill 使用

`SKILL.md` 即技能定义；把整个目录放入 `workspace/.user_skills/` 或技能加载目录即可被 Agent 触发。
