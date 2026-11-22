# 业务服务器迁移（/server + unit + 代理类服务）

裸软件栈（包 / 配置 / 用户 / cron）全绿，**不代表业务能跑起来**。业务服务器多出来的坑集中在三处：
目录树、进程托管（systemd unit）、以及**二进制对目标机 libc 的硬要求**。

本文件记录用真实 `proxysss` release 产物在 7 发行版矩阵上实测的结果与处置办法。

## 1. 目录约定：/server 是业务根

源机约定：`/server` 下是业务服务器（每个子目录一个服务，例如 `/server/proxysss`）。
计划里用 `dirs` 整棵树搬，不要用 `files` 逐个文件写——目录结构、证书、脚本、插件目录都要保留：

```json
{
  "src_root": "out/real-proxysss",
  "dirs": [{ "src": "server", "dest": "/server" }]
}
```

- host 侧打 tar（文件统一 0755，属主 root），容器内 `tar -xf` 到 `dest`。
- 二进制、`*.pem` 证书、`plugins/`、`logs/` 结构一并保留；`logs/` 空目录由业务自己创建。
- 单目录几十 MB 二进制也没问题（实测 21.8MB × 7 容器）。

采集源机目录清单：

```sh
find /server -maxdepth 3 \( -type f -o -type l \) | head -300
du -sh /server/*
```

## 2. systemd unit

`units` 落盘到 `/etc/systemd/system/`，校验分两档：

| 情况 | 校验方式 | 结果 |
| --- | --- | --- |
| 镜像内有 `systemd-analyze` | 真实语法校验（含 ExecStart 可执行性） | PASS/FAIL |
| 镜像内无 systemd（slim / alpine） | 结构校验：`[Unit]` + `[Service]` + `ExecStart=` | PASS，detail 标注 |
| Alpine（openrc） | 同上，detail 明确提示需要 openrc 脚本 | PASS + 警告 |

容器无 systemd，**不要**把「unit 校验通过」理解成「开机自启已配置」。
真实目标机要另做：`systemctl daemon-reload && systemctl enable --now <svc>`。

proxysss 自带 `service install`（会生成并安装 unit），迁移时两种方式二选一：

```sh
/server/proxysss/proxysss service install -c /server/proxysss/proxysss.yaml
# 或直接落我们准备好的 unit
```

unit 关键项（代理类服务绑 80/443 必须注意）：

```ini
[Service]
WorkingDirectory=/server/proxysss
ExecStart=/server/proxysss/proxysss run -c /server/proxysss/proxysss.yaml
Restart=always
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
```

## 3. 服务验证：端口必须由该进程持有

`services` 不只是「文件放好了」，而是真的启动并检查监听：

```json
"services": [
  { "name": "proxysss", "start": "cd /server/proxysss && ./proxysss run -c proxysss.yaml",
    "stop": "pkill -f 'proxysss run'", "port": 8080, "wait": 6 }
]
```

校验逻辑（`guest/verify.sh`）：

1. pid 存活；
2. 该端口的 LISTEN socket inode ∈ 该 pid 的 `/proc/<pid>/fd` 里的 `socket:[inode]`；
3. 若端口有人监听但不是本进程 → FAIL（`stale/another process`），专门防「上一轮容器残留的 nginx 占着 8080 造成假通过」。

配套：`matrix.py reset`（down + up）。换 plan 前必须重置，否则残留服务会污染端口。

## 4. 二进制兼容：v1.3.15 已解决，老版本是 glibc 地狱（历史实测）

**现状：proxysss v1.3.15+ 的 linux-amd64 产物是全静态 ELF（无 PT_INTERP），7 发行版含 Alpine/musl 实测全绿。**
用 `python scripts/fetch_proxysss.py` 直接从 `neko233-com/proxysss` 的 Release 拉取组装，不要再用老动态产物。

以下为 v1.3.9 的历史实测，说明为什么迁移必须验「服务真能起来」：

样本：`proxysss-linux-amd64`，21.8MB，动态链接，interp `/lib64/ld-linux-x86-64.so.2`。

| 发行版 | glibc | 结果 |
| --- | --- | --- |
| ubuntu-noble (24.04) | 2.39 | **PASS**：8080 LISTEN、`:7777` admin、HTTP 可达、`--version` 正常 |
| debian-bookworm (12) | 2.36 | FAIL：`version 'GLIBC_2.38' not found`、`GLIBC_2.39 not found` |
| ubuntu-jammy (22.04) | 2.35 | FAIL：同上 |
| rocky-9 / alma-9 / centos-stream9 | 2.34 | FAIL：同上 |
| alpine-320 | musl 1.2 | FAIL：`./proxysss: not found`（musl 无 glibc ld.so） |

结论：**这个二进制是在 glibc 2.39 环境（Ubuntu 24.04）编译的**，只有 Ubuntu 24.04 能原地跑。
「只搬软件不换 OS」在这个案例上直接撞墙——目标机 glibc 比构建机旧，二进制必然起不来。

处置优先级：

1. **升级到 v1.3.15+ 静态产物**（`fetch_proxysss.py` 一键拉取）——已验证 7 发行版全绿，首选。
2. 必须用老动态产物时：目标机选 Ubuntu 24.04（与构建环境 glibc 一致）。
3. 自行编译静态 musl：`cargo build --release --target x86_64-unknown-linux-musl`。
4. 容器化部署：把 proxysss 打进镜像，宿主 glibc 版本与业务无关。
5. 兼容层（Alpine `gcompat`、老系统升 glibc）不推荐：升级 glibc 会连带炸系统包。

自检一行（迁移前在目标机跑）：

```sh
ldd /server/proxysss/proxysss | grep -E 'not found|GLIBC' || echo ok
strings /server/proxysss/proxysss | grep -o 'GLIBC_2\.[0-9]*' | sort -u | tail -3
```

## 5. 代理类服务的迁移清单

以 proxysss 为例（反代/网关类通用）：

- [ ] 二进制 + `proxysss.yaml` + `certs/`（cert 与 key 权限 600，属主 root）
- [ ] `plugins/`（TS/JS 插件，`script.command` 依赖的运行时如 deno 也要在目标机）
- [ ] 端口：`plain_bind 80`、`tls_bind 443`、`h3_bind 443(UDP)`、`admin 127.0.0.1:7777`
- [ ] 安全组/防火墙放行 80/443（**UDP 443 常被漏**，HTTP/3 会静默降级）
- [ ] `admin` 只绑 127.0.0.1，不要跟着安全组一起放开
- [ ] 日志目录 `logs/` 与轮转；`access_log_path`/`error_log_path` 用绝对路径更稳
- [ ] 上游地址、DNS 解析在目标机 VPC 内可达
- [ ] unit 的 `AmbientCapabilities=CAP_NET_BIND_SERVICE`（非 root 跑时必需）

## 6. 接入真实业务树的最小流程

```powershell
# 1) 把源机 /server 拉到本地（rsync / scp 皆可）
rsync -av root@src:/server ./out/real-server/server

# 2) 写计划：dirs + units + services + checks（src_root 指向 out/real-server）
# 3) 干净环境跑矩阵
python scripts/matrix.py reset
python scripts/matrix.py apply --plan out/real-server/plan.json
python scripts/matrix.py verify
python scripts/matrix.py report
```

计划里务必带上这三类 `checks`，否则「文件在、包也装了」会骗过你：

```json
"checks": [
  { "name": "binary-exec", "cmd": "/server/proxysss/proxysss --version" },
  { "name": "http-reachable", "cmd": "curl -s -m 3 -o /dev/null http://127.0.0.1:8080/" },
  { "name": "admin-port-7777", "cmd": "awk -v pat='1E61' 'FNR>1{split($2,a,\":\"); if(toupper(a[2])==pat && $4==\"0A\") f=1} END{exit !f}' /proc/net/tcp" }
]
```

## 7. 生产部署与回滚（prod_deploy）

矩阵全绿后，`scripts/prod_deploy.py` 把**同一份物化计划**送到目标机执行，验过的就是部署的：

```powershell
# 真实目标机（火山引擎 ECS）
python scripts/prod_deploy.py --plan examples/business/plan.json --transport ssh --target root@<EIP>
# 失败回滚（停服务 → 按备份清单还原 → daemon-reload）
python scripts/prod_deploy.py --transport ssh --target root@<EIP> --rollback
# 不碰真机预演（与生产同一代码路径，已在 noble/alpine 实测）
python scripts/prod_deploy.py --plan examples/business/plan.json --transport docker --container lm-ubuntu-noble
```

目标机侧行为（`guest/target_apply.sh`）：

1. 备份将被覆盖的 file/dir/cron/unit 到 `/var/backups/linuxmig-<ts>`，清单 `manifest.tsv`（不存在记 MISSING）；
2. `USE_SYSTEMD=1` 调 `apply.sh`：unit `systemctl enable --now`，服务由 systemd 托管（`MainPID` 写入 pid 文件供端口归属校验），cron `reload crond/cron`（Alpine 走 `rc-service crond restart`）；
3. Alpine 的 `/etc/crontabs/root` 只重建 `# BEGIN/END linuxmig` 标记块，**用户既有 cron 保留**；
4. 原地跑 `verify.sh` → `report/target-report.md`，FAIL 退出码 1。

回滚（`guest/target_rollback.sh`）：先停本次部署的服务（systemctl stop / stop 命令 / pid kill），
再按清单还原：MISSING 的删除（unit 先 `disable --now`），存在的恢复；目录整树 tar 还原。

注意：目标机部署需要 root（或等效权限）；SSH 密钥/安全组 22 端口自行保证。
`--distro` 可显式指定 per_distro 合并键，缺省按 os-release 自动识别。
