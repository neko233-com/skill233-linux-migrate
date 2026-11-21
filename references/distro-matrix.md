# 发行版差异速查表（Debian / Ubuntu / CentOS 系 / Alpine）

## 包管理器对照

| 发行版 | 包管理器 | 更新索引 | 安装 | 卸载 | 查已装 |
| --- | --- | --- | --- | --- | --- |
| Debian 12 (bookworm) | apt | `apt-get update` | `apt-get install -y pkg` | `apt-get remove -y pkg` | `dpkg -l` |
| Ubuntu 24.04 (noble) | apt | 同上 | 同上 | 同上 | 同上 |
| Rocky / Alma 9 | dnf | `dnf check-update`（无需先 update） | `dnf install -y pkg` | `dnf remove -y pkg` | `rpm -qa` |
| CentOS Stream 9 | dnf | 同上 | 同上 | 同上 | `rpm -qa` |
| CentOS 7（EOL，仅存量） | yum | 官方仓库已失效，需换 vault 源 | — | — | `rpm -qa` |
| Alpine 3.20 | apk | `apk update` | `apk add --no-cache pkg` | `apk del pkg` | `apk info` |

注意：apt 系镜像首次安装前必须 `apt-get update`；dnf/yum/apk 不需要。

## 服务管理差异

- Debian/Ubuntu：SSH 服务名 `ssh`；`service ssh restart` / `systemctl`。
- RHEL 系（Rocky/Alma/CentOS Stream）：SSH 服务名 `sshd`；Web 服务器默认是 `httpd`（Apache），不是 nginx。
- 容器内无 systemd，本技能不验证服务启停；真实服务器上 `systemctl enable` 名称以目标发行版为准。

## 常见路径差异

| 内容 | Debian/Ubuntu | RHEL 系 |
| --- | --- | --- |
| nginx 配置主目录 | `/etc/nginx/` | `/etc/nginx/` |
| nginx 站点片段 | `/etc/nginx/sites-enabled/`（conf.d 默认不读） | `/etc/nginx/conf.d/` |
| Apache 配置 | `/etc/apache2/` | `/etc/httpd/` |
| 站点目录 | `/var/www/html` | `/var/www/html` |
| 日志 | `/var/log/nginx/` | `/var/log/nginx/` |
| 时区数据 | `/usr/share/zoneinfo` | 同左（`tzdata` 包） |

> 注意：`/etc/nginx/conf.d/` 在 Debian/Ubuntu 的 nginx 默认配置里不被加载（那里是 RHEL 系约定）。把站点配置写到 conf.d 在 RHEL 系成立，在 Debian/Ubuntu 应写到 `sites-enabled` 并用 `per_distro` 区分目标路径。

## 防火墙差异

- Debian/Ubuntu 常用 `ufw`（`ufw allow 80/tcp`）或裸 iptables。
- RHEL 系默认 `firewalld`（`firewall-cmd --add-service=http --permanent`）。
- 迁移时不要把 ufw 规则照搬到 RHEL 系，反之亦然。

## 高频迁移坑

1. **包名不同**：同一软件在不同仓库名字不同（如 `nginx` 通用；`python3-pip` vs `python3-pip`，RHEL 系为 `python3-pip` 也可，但 `epel-release` 常需先装）。矩阵 FAIL 在 `pkg:` 时先查目标仓库是否有同名包。
2. **服务名不同**：`ssh` vs `sshd`；`nginx` 两系一致。
3. **配置路径不同**：Apache `/etc/apache2` vs `/etc/httpd`。
4. **用户创建**：Debian/Ubuntu 有 `useradd`/`groupadd`；Alpine 用 `adduser`/`addgroup`，脚本需兼容。
5. **CentOS 7/8 EOL**：官方镜像仓库 404，存量迁移先换 vault.centos.org 或内部镜像；新机器直接选 Rocky/Alma/Stream 9。
6. **glibc / 编译产物**：预编译二进制在不同 glibc 版本间不通用，矩阵只验证包与配置，不验证二进制运行。

## 实测踩到的坑（本技能已在容器内复现并处理）

### RHEL 9 系 `curl-minimal` 冲突

Rocky/Alma/CentOS Stream 9 的 minimal 镜像预装 `curl-minimal`。执行 `dnf install curl nginx`
会报执行计划冲突，**整个事务失败**（连 nginx 一起装不上）：

```
package curl-minimal-... from @System conflicts with curl provided by curl-...
```

处理：`dnf install -y --allowerasing`（替换冲突包）。本技能 `guest/apply.sh` 在 dnf 失败后
自动用 `--allowerasing` 重试一次，并把日志留在容器 `/tmp/linuxmig-pkg.log`。

### Alpine 的 nginx 配置位置是 `http.d`，不是 `conf.d`

Alpine 3.20 的 nginx 默认配置：

- `include /etc/nginx/conf.d/*.conf;` —— 在 **main context**，只能放 `upstream`/`map` 这类，
  放 `server { }` 会直接报 `"server" directive is not allowed here`，并让 `nginx -t` 整体失败。
- `include /etc/nginx/http.d/*.conf;` —— 在 **http context**，`server` 块必须放这里。

对照表：

| 系 | server 块放置位置 | server 块之外 |
| --- | --- | --- |
| Debian / Ubuntu | `/etc/nginx/sites-enabled/*` | — |
| RHEL 系（Rocky/Alma/Stream） | `/etc/nginx/conf.d/*.conf`（http 上下文） | — |
| Alpine | `/etc/nginx/http.d/*.conf` | `/etc/nginx/conf.d` 仅 main 上下文 |

用 `per_distro.files` 分别指定 `dest` 即可一份计划覆盖三系。

### Alpine cron 目录不同

Alpine 走 busybox crond，读 `/etc/crontabs/<user>`（**5 段，无用户字段**）；
RHEL/Debian/Ubuntu 走 `/etc/cron.d/<name>`（**6 段，含用户字段**）。
`guest/apply.sh` 按包管理器自动选路径，并把实际路径写入 `cron_path` 供 `verify.sh` 复用。

## 程序层校验（checks）

只校验"文件落盘"无法证明目标程序真的加载了配置。用 `checks` 补这一层：

```json
"checks": [
  { "name": "nginx-conf-loaded", "cmd": "nginx -T 2>/dev/null | grep -q 'demo.example.com'" }
]
```

容器内以 `sh -c` 执行，退出码 0 记 PASS。`nginx -T`（转储全部实际加载的配置）比 `nginx -t`
（仅语法检查）更能证明路径正确——`nginx -t` 对未被 include 的文件不会报错。

## per_distro 覆盖写法

`plan/migration.json` 中按发行版名（与 matrix.json 的 `name` 一致）覆盖：

```json
"per_distro": {
  "rocky-9": { "packages": ["curl", "epel-release"] },
  "alpine-320": { "commands": ["curl"] }
}
```

`packages` 为追加去重；`files/users/groups/cron/commands` 为整体替换。
