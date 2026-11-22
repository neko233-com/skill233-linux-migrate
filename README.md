# skill233-linux-migrate · 本机 Compose 矩阵验证服务器迁移

**只搬软件、不换 OS**：在本机用 Kiri / Docker Compose 拉起 Debian、Ubuntu、CentOS(Stream)、Rocky、Alma、Alpine 容器矩阵，
**不碰生产**先把源机软件栈（包、配置、用户、cron、`/server` 业务树、systemd unit、常驻服务）复刻方案跑一遍，
找出包名 / 服务名 / 路径 / 二进制兼容差异；全绿后经 `prod_deploy` 把**同一份计划**部署到真实目标机（自动备份 + 原地校验 + 一键回滚）。

业务主线用 **proxysss 替代 nginx**（`neko233-com/proxysss`，v1.3.15+ 全静态 ELF，7 发行版通用）。

## 快速开始

```bash
python scripts/fetch_proxysss.py         # 从你的 GitHub Release 拉 proxysss，组装 /server 业务树
python scripts/matrix.py all --plan examples/business/plan.json   # 7 发行版验证
python scripts/prod_deploy.py --plan examples/business/plan.json \
    --transport docker --container lm-ubuntu-noble                # 不碰真机预演生产路径
python scripts/prod_deploy.py --plan examples/business/plan.json \
    --transport ssh --target root@<火山EIP>                        # 真实目标机部署
python scripts/prod_deploy.py --transport ssh --target root@<火山EIP> --rollback  # 回滚
python scripts/matrix.py down            # 清理容器
```

源机有存量环境时：`scripts/snapshot.sh` 采基线 → `scripts/plan_from_snapshot.py` 直出计划
（包/用户/cron/`/server` 树/unit 原文+派生服务/glibc 兼容检查自动带出）。
报告输出到 `report/migration-report.md`（矩阵）与 `report/target-report.md`（目标机）；有 FAIL 时退出码为 1。
切换计划前先 `python scripts/matrix.py reset`（down + up），避免上一轮服务残留占端口。

## 矩阵（matrix.json 全部默认启用，7 个发行版）

| 发行版 | 镜像 |
| --- | --- |
| Debian 12 bookworm | `debian:bookworm-slim` |
| Ubuntu 24.04 noble | `ubuntu:24.04` |
| Ubuntu 22.04 jammy | `ubuntu:22.04` |
| Rocky Linux 9 | `rockylinux:9` |
| CentOS Stream 9 | `quay.io/centos/centos:stream9` |
| AlmaLinux 9 | `almalinux:9` |
| Alpine 3.20 | `alpine:3.20` |

引擎优先 Kiri（`kiri compose`），未安装自动回退 `docker compose`。

## 示例计划

| 目录 | 用途 |
| --- | --- |
| `examples/business/` | **生产主线**：proxysss 网关（`/server` 树 + unit + 真启动；校验端口归属、check-config、静态站、admin:7777），7 发行版 × 8 项全绿 |
| `examples/prod/` | 最小业务：proxysss 静态站 + deploy 用户 + 备份 cron，7 发行版全绿 |
| `examples/deep/` | nginx 三系路径差异参考（sites-enabled / conf.d / http.d）+ `nginx -T` 程序层校验，适用于仍跑 nginx 的旧机器 |
| `examples/negative/` | 负例：故意写错路径与缺失命令，验证 FAIL 与退出码 1 |

## 计划格式 `plan/migration.json`

```json
{
  "src_root": "out/real-server",
  "packages": ["curl"],
  "files": [{ "src": "files/hello.conf", "dest": "/etc/hello-migrate.conf", "contains": "migrated" }],
  "dirs": [{ "src": "server", "dest": "/server" }],
  "units": [{ "src": "proxysss.service", "name": "proxysss.service", "dest": "/etc/systemd/system/proxysss.service" }],
  "services": [{ "name": "proxysss", "start": "cd /server/proxysss && ./proxysss run -c proxysss.yaml",
                 "stop": "pkill -f 'proxysss run'", "port": 8080, "wait": 6 }],
  "groups": ["appdemo"],
  "users": [{ "name": "appdemo", "group": "appdemo" }],
  "cron": [{ "expr": "*/10 * * * *", "cmd": "/opt/app/collect.sh" }],
  "commands": ["curl"],
  "checks": [{ "name": "http-reachable", "cmd": "curl -s -m 3 -o /dev/null http://127.0.0.1:8080/" }],
  "per_distro": {}
}
```

校验项：`pkg:` 包安装、`file:` 文件落盘含文本、`dir:` 目录树、`unit:` unit 语法/结构、
`svc:` 进程存活**且端口由该 pid 持有**、`cmd:` 命令可发现、`user:`/`group:` 存在、
`cron:` 定义落在实际生效路径（Alpine `/etc/crontabs/root`，其余 `/etc/cron.d`）、
`check:` 自定义命令通过（验程序层，如配置是否真被加载、业务端口是否回 200）。

> 容器无 systemd / 无内核 / 无真实网卡：`units` 只验语法与结构，`svc` 只验进程与端口归属，
> 不验开机自启与 systemd 托管。详见 `references/workflow.md`。
> 业务服务器（`/server`、代理类服务、二进制 glibc 兼容）见 `references/business-stack.md`；
> 阿里云 → 火山引擎迁移见 `references/aliyun-to-volcengine.md`。

## 实测结论（真实业务二进制）

**proxysss v1.3.15（全静态 ELF，22.9MB）：7 发行版 × 8 项全绿**，含 Alpine/musl——
`--version`、`check-config`、静态站回包、admin:7777 监听、8080 端口归属进程全部通过。

历史对照：v1.3.9 linux-amd64 为动态 glibc 产物（要求 GLIBC_2.38/2.39），仅 Ubuntu 24.04 可跑，
Debian 12 / Ubuntu 22.04 / Rocky / Alma / Stream 9 全部 `GLIBC_x not found`，Alpine `not found`。
**包全装上、文件全落对，业务照样起不来**——这就是必须做「服务启动 + 端口归属」验证的原因。
详见 `references/business-stack.md`。

## 生产部署（prod_deploy）

矩阵全绿后，同一份计划直接上目标机，验过的就是部署的：

1. 自动识别目标发行版（os-release），按 `per_distro` 合并计划；
2. 备份将被覆盖的文件/目录/cron/unit 到 `/var/backups/linuxmig-<ts>`（清单化）；
3. `USE_SYSTEMD=1` 执行：unit `enable --now`、服务由 systemd 托管（MainPID 校验端口归属）、cron reload；
4. 目标机原地跑同一套 `verify.sh`，出 `report/target-report.md`，FAIL 退出码 1；
5. `--rollback`：停服务 → 按清单还原（部署前不存在的删除，存在的恢复）→ daemon-reload。

不碰真机预演：`--transport docker --container lm-<distro>`，走与生产完全相同的代码路径
（已在 ubuntu-noble 与 alpine-320 实测部署 8/8 + 回滚还原）。

## 作为 Agent Skill 使用

`SKILL.md` 即技能定义；把整个目录放入 `workspace/.user_skills/` 或技能加载目录即可被 Agent 触发。
