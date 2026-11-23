# 完整业务迁移（目录树 / 属主权限 / 数据库 / 防火墙 / unit / 服务）

裸软件栈（包 / 配置 / 用户 / cron）全绿，**不代表业务能跑起来**。完整业务迁移多出来的坑集中在：
目录树与**属主/权限**、**数据库数据**、**防火墙放行**、进程托管（systemd unit）、以及二进制对目标机 libc 的硬要求。

本文件记录这些能力的用法与实测处置办法。主线示例是 `examples/full-business`（通用业务，零外部二进制）；
代理类服务（proxysss）仅作为「二进制兼容」一节的可选案例。

## 1. 目录树 + 属主 / 权限 / attrs

源机约定：`/server` 下是业务根（每个子目录一个服务）。用 `dirs` 整棵树搬，保留结构、证书、脚本、插件目录：

```json
{
  "src_root": "out/real-server",
  "dirs": [{
    "src": "server", "dest": "/server", "owner": "appsvc", "group": "appsvc",
    "attrs": [{ "path": "secrets/db.key", "mode": "0600", "owner": "appsvc", "group": "appsvc" }]
  }]
}
```

- host 侧打 tar **保留源属性**（不再统一 0755/root）；容器内 `tar -xpf` 还原 mode/owner/group（数字 UID/GID）。
- `dirs[].owner/group` 设整树属主；`attrs[]` 按相对路径逐文件覆盖 mode/owner/group——**密钥 0600、可执行 0755、配置 0644** 这类关键权限必须显式声明，否则业务以非 root 运行时读不到密钥 / 跑不起脚本。
- 属主用名字时，plan 的 `users`/`groups` 要先建好（apply 先建用户组再 set_attrs）。
- 校验：`fattr`/`dirattr`/`attr` 用 `stat -c '%U %G %a'` 比对（busybox 兼容）。

采集源机目录与权限：

```sh
find /server -maxdepth 3 \( -type f -o -type l \) | head -300
find /server -type f -exec stat -c '%a|%U|%G|%n' {} + | head -300   # 权限清单 → attrs
du -sh /server/*
```

`scripts/snapshot.sh` 的 `BUSINESS ATTRS` 段已自动采集 `/server` 权限，`plan_from_snapshot.py` 转成 `dirs[].attrs`。

## 2. systemd unit

`units` 落盘到 `/etc/systemd/system/`，校验分两档：

| 情况 | 校验方式 | 结果 |
| --- | --- | --- |
| 镜像内有 `systemd-analyze` | 真实语法校验（含 ExecStart 可执行性） | PASS/FAIL |
| 镜像内无 systemd（slim / alpine） | 结构校验：`[Unit]` + `[Service]` + `ExecStart=` | PASS，detail 标注 |
| Alpine（openrc） | 同上，detail 提示需要 openrc 脚本 | PASS + 警告 |

容器无 systemd，**不要**把「unit 校验通过」理解成「开机自启已配置」。
真实目标机要另做：`systemctl daemon-reload && systemctl enable --now <svc>`（prod_deploy 的 `USE_SYSTEMD=1` 已自动做）。

unit 关键项（绑 80/443 等特权端口、非 root 运行时）：

```ini
[Service]
User=appsvc
WorkingDirectory=/server/app
ExecStart=/server/app/bin/app.sh
Restart=always
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
```

## 3. 服务验证：端口必须由该进程持有

`services` 不只是「文件放好了」，而是真的启动并检查监听：

```json
"services": [
  { "name": "web", "start": "cd /server/web && setsid -f python3 -m http.server 8080",
    "stop": "pkill -f 'http.server 8080'", "port": 8080, "wait": 4 }
]
```

校验逻辑（`guest/verify.sh`）：

1. pid 存活；
2. 该端口的 LISTEN socket inode ∈ 该 pid 的 `/proc/<pid>/fd` 里的 `socket:[inode]`；
3. 端口有人监听但不是本进程 → FAIL（`stale/another process`），防「上一轮残留进程占端口造成假通过」。

配套：`matrix.py reset`（down + up）。换 plan 前必须重置，否则残留服务污染端口。
容器内后台服务用 `setsid -f` 脱离会话（`nohup &` 会随 docker exec 结束被杀）。

## 4. 数据库迁移（PostgreSQL / MariaDB / Redis）

`databases[]` 描述要迁的库，apply 在目标机装包 → 初始化 → 起守护 → 建库建用户 → 导入 dump → 校验查询：

```json
"databases": [
  { "type": "postgres", "name": "appdb", "dump": "files/pg.sql",
    "verify": "SELECT count(*) FROM users", "user": "app", "password": "secret" },
  { "type": "redis", "name": "cache", "dump": "files/redis.txt", "verify": "DBSIZE" }
]
```

- `type`：`postgres` / `mariadb` / `redis`。`dump` 相对 `src_root`；`verify` 是迁移后跑的校验查询（返回非空/非错即 PASS）。
- 容器无 systemd，apply **直控守护**（pg 用 `pg_ctl`、mariadb 用 `mariadbd-safe`、redis 用 `--daemonize`），目标机同样适用。
- 连接信息落 `/tmp/linuxmig-{pgbin,pgport,mysql-client,mysql-sock,redis-port}` 供 verify 复用。
- **MariaDB 容器坑（已修）**：默认 pid 目录 `/run/mysqld` 在无 systemd-tmpfiles 的容器里不存在 → `can't create PID file` 崩溃。
  apply 已 `mkdir -p /run/mysqld` + `--pid-file=/tmp/linuxmig-mysql.pid` + `setsid -f` 脱离会话。io_uring EPERM 只是无害警告。
- 校验类型 `db`：跑 `verify` 查询，detail 带结果。

源机导出 dump：

```sh
sudo -u postgres pg_dump appdb > pg.sql                 # PostgreSQL
mariadb-dump appdb > mysql.sql                          # MariaDB
redis-cli --rdb /tmp/dump.rdb                           # Redis（RDB；或 BGSAVE 后拷 dump.rdb）
```

`snapshot.sh` 的 `DATABASES` 段探测已装客户端与运行守护，`plan_from_snapshot.py` 生成 `databases` 骨架（`dump:""` 待补真实导出）。
**生产单次 apply 导入一次**；矩阵换 plan 前 `reset`，避免重复导入叠加数据。

## 5. 防火墙规则

`firewall` 段把源机放行规则纳入计划，目标机真实应用：

```json
"firewall": { "backend": "iptables", "allow_tcp": [80, 443, 8080], "allow_udp": [443], "default_input": "DROP" }
```

- `backend`：`ufw` / `firewalld` / `iptables`（按目标机实际选择；缺省自动探测）。
- 目标机（`USE_SYSTEMD=1`）真实应用：`ufw allow` / `firewall-cmd --add-port` / `iptables -A INPUT`。
- 容器内无真实防火墙栈 → 落 `/tmp/linuxmig-firewall.manifest` 做**结构级校验**（`fw` 类型 PASS，detail 标注 structural）。
- **UDP 常被漏**（HTTP/3、QUIC、DNS），`allow_udp` 显式声明。
- 云主机还要在**安全组**放行（OS 防火墙之外），技能不代改云安全组。

`target_apply.sh` 部署前备份防火墙状态（`iptables-save` / `ufw status` / `firewall-cmd --list-all`）到备份目录；
`target_rollback.sh` 用 `iptables-restore` 等还原。`snapshot.sh` 采集 ufw/firewalld/iptables 现状供计划参考。

## 6. 二进制兼容（可选案例：proxysss）

迁代理/网关类二进制时，目标机 libc 必须兼容。**proxysss v1.3.15+ 的 linux-amd64 是全静态 ELF（无 PT_INTERP），7 发行版含 Alpine/musl 全绿**；
用 `python scripts/fetch_proxysss.py` 从 `neko233-com/proxysss` Release 拉取组装（默认 latest，当前 v1.3.18）。

历史教训（v1.3.9 动态产物）：在 glibc 2.39（Ubuntu 24.04）编译的动态二进制，只有 noble 能跑，
debian/rocky/alma/centos（glibc 2.34~2.36）报 `GLIBC_2.38 not found`，Alpine musl 直接 `not found`。
「只搬软件不换 OS」会撞墙——目标机 glibc 比构建机旧，二进制必然起不来。

处置优先级：① 用静态产物（首选）② 目标机选与构建环境一致 glibc ③ 自编译 musl 静态
`cargo build --release --target x86_64-unknown-linux-musl` ④ 容器化 ⑤ 兼容层（gcompat/升 glibc）不推荐。

迁移前自检：

```sh
ldd /server/app/bin/app | grep -E 'not found|GLIBC' || echo ok
file /server/app/bin/app   # statically linked 最佳
```

proxysss 迁移清单（反代/网关类通用）：二进制 + yaml + certs（key 0600）+ plugins（依赖运行时如 deno）；
端口 80/443/UDP443/admin 127.0.0.1:7777；admin 只绑回环不要随安全组放开；unit `AmbientCapabilities=CAP_NET_BIND_SERVICE`。
v1.3.18 配置用 `admin.monitor.password`（替代旧 `admin.enabled/username/password`），OTel 默认关闭、迁移零影响。

## 7. 接入真实业务树的最小流程

```powershell
# 1) 把源机 /server 拉到本地（rsync / scp 皆可），并导出数据库 dump
rsync -av root@src:/server ./out/real-server/server
# 2) 写计划：dirs(含 attrs) + databases + firewall + units + services + checks
# 3) 干净环境跑矩阵
python scripts/matrix.py reset
python scripts/matrix.py apply --plan out/real-server/plan.json
python scripts/matrix.py verify --plan out/real-server/plan.json
python scripts/matrix.py report
```

计划务必带 `checks`，否则「文件在、包也装了」会骗过你：

```json
"checks": [
  { "name": "http-reachable", "cmd": "curl -s -m 3 -o /dev/null http://127.0.0.1:8080/" },
  { "name": "key-perm", "cmd": "test \"$(stat -c '%a' /server/app/secrets/db.key)\" = 600" }
]
```

## 8. 生产部署与回滚（prod_deploy）

矩阵全绿后，`scripts/prod_deploy.py` 把**同一份物化计划**送到目标机执行，验过的就是部署的：

```powershell
python scripts/prod_deploy.py --plan examples/full-business/plan.json --transport ssh --target root@<EIP>
python scripts/prod_deploy.py --transport ssh --target root@<EIP> --rollback
python scripts/prod_deploy.py --plan examples/full-business/plan.json --transport docker --container lm-ubuntu-noble
```

目标机侧（`guest/target_apply.sh`）：

1. 备份将被覆盖的 file/dir/cron/unit + **防火墙状态**到 `/var/backups/linuxmig-<ts>`，清单 `manifest.tsv`（不存在记 MISSING）；
2. `USE_SYSTEMD=1` 调 `apply.sh`：unit `enable --now`、服务由 systemd 托管、cron reload、**防火墙真实应用**、数据库直控守护；
3. Alpine `/etc/crontabs/root` 只重建 `# BEGIN/END linuxmig` 标记块，用户既有 cron 保留；
4. 原地 `verify.sh` → `report/target-report.md`，FAIL 退出码 1。

回滚（`guest/target_rollback.sh`）：停本次服务（systemctl stop / stop 命令 / pid kill）+ **停数据库守护**，
按清单还原（MISSING 删除、存在恢复、目录整树 tar 还原）+ **iptables-restore 还原防火墙**。

目标机部署需 root（或等效权限）；SSH 密钥/安全组 22 端口自行保证。`--distro` 可显式指定 per_distro 合并键，缺省按 os-release 识别。