# 完整工作流与边界说明

## 1. 采集源基线（可选）

```bash
ssh root@源服务器 'bash -s' < scripts/snapshot.sh
# 或在源服务器上: bash scripts/snapshot.sh
```

把 `snapshot/source.txt` 拷回本机，重点看：OS、package_manager、已装包清单、监听端口、enabled services、crontab、用户、防火墙。据此把需要保留/重建的项写进 `plan/migration.json`。

没有真实源服务器时跳过本步，直接手写计划。

## 2. 编写迁移计划

有快照时先跑 `python scripts/plan_from_snapshot.py`，自动把包清单、业务用户、cron、`/server` 目录树、业务二进制 glibc 下限写进 `plan/migration.json`，再人工补 `files`、`units`、`services`（启动命令与端口）；无快照用 `python scripts/matrix.py init` 手写。

`plan/migration.json`：

- `packages`：目标机器要确保存在的包（原样复刻时可直接放全量清单，再裁剪）。RHEL 9 minimal 装 `curl` 需 `--allowerasing`（脚本会自动重试）。
- `files`：要落盘的配置（`src` 相对 plan/，`dest` 容器内路径，`contains` 必含文本）。
- `dirs`：整棵业务目录树（如 `/server`），host 打 tar、容器解包，保结构保权限；`src_root` 可指向仓库外的真实副本。
- `units`：systemd unit 落盘；镜像有 `systemd-analyze` 做真实校验，否则结构校验。
- `services`：真正启动业务进程并校验端口归属（`port` 必填才能验监听）。
- `groups` / `users`：`users[].group` 为所属组。
- `cron`：`expr` 五段表达式 + `cmd`；apply 按系写入 `/etc/cron.d` 或 `/etc/crontabs/root`。
- `commands`：`command -v` 可发现的二进制名。
- `checks`：容器内执行的校验命令，用于验证程序层（如 `nginx -T` 里能否看到你的 server 块、业务端口能否回包、glibc 版本是否够）。
- `per_distro`：发行版专属覆盖，键名同 matrix.json（支持 `files/dirs/units/services/...` 全部列表键）。

## 3. 跑矩阵

```bash
python scripts/matrix.py all                 # 全部启用发行版
python scripts/matrix.py all --only rocky-9,ubuntu-noble
python scripts/matrix.py up                  # 只起容器
python scripts/matrix.py reset               # 换 plan 前重置（down + up）
python scripts/matrix.py down                # 清理
```

> 换计划文件必须 `reset`：上一轮起的业务进程会占着端口，虽然 `svc:` 校验会识别「端口不是本进程持有」，
> 但残留进程仍可能让后续服务起不来，干扰结论。

## 4. 读报告并迭代

`report/migration-report.md`：总表 + 每个发行版的 FAIL 明细。常见处置：

- `pkg:xxx not installed` → 该发行版仓库无此包，换包名或加 `epel-release` 类前置包，用 `per_distro` 区分。
- `file:... missing` → 目标路径不同，改 `dest` 或在 `per_distro` 替换。
- `cmd:xxx not found` → 可执行文件路径不在 PATH，或包未装。
- `dir:xxx missing` → 业务目录树没解开，检查 `dirs[].src`/`src_root` 与 tar 包内容。
- `unit:xxx` FAIL → unit 缺 `[Unit]/[Service]/ExecStart=`，或 `ExecStart` 指向的二进制不存在/不可执行。
- `svc:xxx` FAIL →看 detail：`process dead` 查 `/tmp/svc-<name>.log`（多为二进制跑不起来，如 glibc/musl 不兼容）；
  `not owned by pid` 说明端口被别的进程占着，先 `reset`；`not LISTEN` 说明进程活着但没绑上端口（配置/端口冲突）。
- `check:glibc>=x:yyy` FAIL → 目标机 libc 低于产物要求，见 `business-stack.md`（换 OS / 编 musl / 容器化）。
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
**推荐路径**：直接用 `prod_deploy` 在真实目标机执行（自动走 systemd 托管），无需 systemd-in-docker。

## 6. 生产部署（prod_deploy）

矩阵全绿后，把同一份计划部署到目标机并原地校验：

```bash
python scripts/prod_deploy.py --plan examples/business/plan.json --transport ssh --target root@<EIP>
python scripts/prod_deploy.py --transport ssh --target root@<EIP> --rollback   # 失败回滚
python scripts/prod_deploy.py --plan examples/business/plan.json --transport docker --container lm-ubuntu-noble  # 本机预演
```

- 自动备份到 `/var/backups/linuxmig-<ts>`（file/dir/cron/unit 清单化），回滚按清单还原；
- 目标机有 systemd 时 unit `enable --now`、服务由 systemd 托管、cron reload；
- 目标机原地跑同一套 verify，报告 `report/target-report.md`，FAIL 退出码 1；
- 发行版自动识别（os-release），`--distro` 可强制指定 per_distro 合并键。

## 7. 上生产前收尾清单

1. 目标机 OS 版本已确认（不要把 EOL 的 CentOS 7 当新机器）。
2. 包清单在矩阵全绿；配置文件内容已逐文件核对。
3. cron、计划任务、备份任务已迁移。
4. 用户/组权限、sudo 规则已建。
5. 防火墙策略按目标发行版重写（ufw ≠ firewalld）。
6. 回滚方案：保留旧机镜像/快照，数据先同步验证再切流。
