# Changelog

## v0.5.0

**完整业务迁移 + Agent 分阶段编排**

### 新增
- **业务目录属主/权限还原**：`dirs[].owner/group` 递归属主，`dirs[].attrs[]` 按相对路径逐文件还原 mode/owner/group；tar 保留源属性，不再统一 0755/root。校验 `fattr`/`dirattr`/`attr`。
- **数据库迁移（可选）**：`databases[]` 支持 PostgreSQL/MariaDB/Redis，dump→restore + 业务账号 + 校验查询。容器内直控守护（pg_ctl / mariadbd-safe / redis-server），不依赖 systemd。**中间件可后置，不阻塞核心迁移**。
- **防火墙纳入计划与还原**：`firewall` 段支持 ufw/firewalld/iptables/auto；目标机真实应用，容器内结构级校验；`prod_deploy` 部署前备份防火墙状态，回滚时 `iptables-restore` 还原。
- **Agent 分阶段执行**：`apply --stages pkgs,files,dirs,units,users,attrs,databases,services,cron,firewall` 可按阶段跑；`verify` 输出 TSV、`report` 输出 `results.json`，Agent 按 FAIL detail 增量修复。
- **国内镜像加速（可选）**：`--mirror cn` 把容器内包源切到 `mirrors.aliyun.com`（apt/apk/yum 系），仅显式开启。
- **通用业务主线示例** `examples/full-business/`（无中间件核心）+ `plan-with-db.json`（可选 DB 扩展），7 发行版验证。
- **MariaDB 容器启动修复**：创建 `/run/mysqld`、`--pid-file` 覆盖、`setsid -f` 脱离会话，解决无 systemd 容器中 `can't create PID file` 崩溃。

### 变更
- 去 proxysss 主线化：proxysss 降为可选示例（`examples/business`），默认拉 latest（v1.3.18 全静态），配置适配 v1.3.18 `admin.monitor.password` schema。
- `snapshot.sh` 新增 BUSINESS ATTRS（`/server` 属主/权限）与 DATABASES 探测；`plan_from_snapshot.py` 自动生成 `dirs.attrs`、`databases` 骨架、`firewall`。
- `prod_deploy.py` 支持 `--stages`，目标机 `target_apply.sh` 透传阶段，生产侧同样可分步执行。

### 验证
- **7 发行版核心业务矩阵 20/20 全 PASS**（Debian 12 / Ubuntu 24.04 / Ubuntu 22.04 / Rocky 9 / CentOS Stream 9 / Alma 9 / Alpine 3.20）。
- ubuntu-noble 核心链 19 项全 PASS（包/文件/目录/用户组/cron/unit/服务端口归属/自定义 check/属主权限/防火墙清单）。
- `prod_deploy --transport docker` 预演全 PASS；`--rollback` 恢复成功。
- 中间件（PostgreSQL/Redis/MariaDB）为可选能力，不阻塞核心迁移发布；dump 需从源机导出后单独验证。

### 限制
- 容器无 systemd/内核/真实网卡：`units` 只验语法或结构，`svc` 验进程与端口归属，`fw` 容器内为结构级；真实目标机由 `prod_deploy` 启用 systemd 托管与真实防火墙。
- 数据库 dump 需先从源机导出（快照只探测引擎，不自动导出）。
