# 完整工作流与边界说明

## 1. 采集源基线（可选）

```bash
ssh root@源服务器 'bash -s' < scripts/snapshot.sh
# 或在源服务器上: bash scripts/snapshot.sh
```

把 `snapshot/source.txt` 拷回本机，重点看：OS、package_manager、已装包清单、监听端口、enabled services、crontab、用户、防火墙。据此把需要保留/重建的项写进 `plan/migration.json`。

没有真实源服务器时跳过本步，直接手写计划。

## 2. 编写迁移计划

有快照时先跑 `python scripts/plan_from_snapshot.py`，自动把包清单、业务用户、cron 写进 `plan/migration.json`，再人工补 `files` 与 `commands`；无快照用 `python scripts/matrix.py init` 手写。

`plan/migration.json`：

- `packages`：目标机器要确保存在的包（原样复刻时可直接放全量清单，再裁剪）。
- `files`：要落盘的配置（`src` 相对 plan/，`dest` 容器内路径，`contains` 必含文本）。
- `groups` / `users`：`users[].group` 为所属组。
- `cron`：`expr` 五段表达式 + `cmd`；apply 阶段写入 `/etc/cron.d/linuxmig`。
- `commands`：`command -v` 可发现的二进制名。
- `per_distro`：发行版专属覆盖，键名同 matrix.json。

## 3. 跑矩阵

```bash
python scripts/matrix.py all                 # 全部启用发行版
python scripts/matrix.py all --only rocky-9,ubuntu-noble
python scripts/matrix.py up                  # 只起容器
python scripts/matrix.py down                # 清理
```

## 4. 读报告并迭代

`report/migration-report.md`：总表 + 每个发行版的 FAIL 明细。常见处置：

- `pkg:xxx not installed` → 该发行版仓库无此包，换包名或加 `epel-release` 类前置包，用 `per_distro` 区分。
- `file:... missing` → 目标路径不同，改 `dest` 或在 `per_distro` 替换。
- `cmd:xxx not found` → 可执行文件路径不在 PATH，或包未装。
- `user/group` FAIL → 脚本未创建成功，检查 apply 阶段日志。
- `cron` FAIL → `/etc/cron.d/linuxmig` 未写入或表达式/命令缺失，检查 plan 中 cron 条目。

报告全绿后，再把同一计划对照真实服务器检查清单过一遍。

## 5. 本技能验证不到的层（容器边界）

容器无 systemd、无内核、无真实网卡，以下事项矩阵不覆盖，需在真实目标机或额外环境验证：

- 服务能否真正启动、监听端口（无 systemd 也无法 `systemctl enable`）。
- 内核参数、sysctl、文件描述符限制、磁盘挂载。
- 防火墙端口连通性、TLS 证书、域名与 DNS。
- 预编译二进制的 glibc 兼容性。

### 需要 systemd 行为时的做法（可选）

用带 systemd 的基础镜像（如 `jrei/systemd-debian-12`、`centos/systemd`），compose 加：

```yaml
init: true
cgroup: host
volumes:
  - /sys/fs/cgroup:/sys/fs/cgroup:ro
```

本技能默认矩阵不启用该模式，仅在需要验证 `systemctl enable` 类步骤时手工切换。

## 6. 上生产前收尾清单

1. 目标机 OS 版本已确认（不要把 EOL 的 CentOS 7 当新机器）。
2. 包清单在矩阵全绿；配置文件内容已逐文件核对。
3. cron、计划任务、备份任务已迁移。
4. 用户/组权限、sudo 规则已建。
5. 防火墙策略按目标发行版重写（ufw ≠ firewalld）。
6. 回滚方案：保留旧机镜像/快照，数据先同步验证再切流。
