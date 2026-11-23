#!/bin/sh
# snapshot.sh — 在源服务器上采集迁移基线（root 运行），结果写入 snapshot/ 目录。
# 用法: ssh root@源服务器 'bash -s' < scripts/snapshot.sh
set -u
OUT_DIR="snapshot"
mkdir -p "$OUT_DIR"

. /etc/os-release 2>/dev/null
echo "== OS ==" | tee "$OUT_DIR/source.txt"
echo "${PRETTY_NAME:-unknown}" | tee -a "$OUT_DIR/source.txt"

# --- 包管理器与已装包 ---
echo "" | tee -a "$OUT_DIR/source.txt"
echo "== PACKAGES ==" | tee -a "$OUT_DIR/source.txt"
if command -v dpkg >/dev/null 2>&1; then
  echo "package_manager: apt" | tee -a "$OUT_DIR/source.txt"
  dpkg-query -W -f='${Package}\n' 2>/dev/null | sort -u | tee -a "$OUT_DIR/source.txt"
elif command -v rpm >/dev/null 2>&1; then
  echo "package_manager: rpm" | tee -a "$OUT_DIR/source.txt"
  rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort -u | tee -a "$OUT_DIR/source.txt"
elif command -v apk >/dev/null 2>&1; then
  echo "package_manager: apk" | tee -a "$OUT_DIR/source.txt"
  apk info 2>/dev/null | sort -u | tee -a "$OUT_DIR/source.txt"
else
  echo "package_manager: unknown" | tee -a "$OUT_DIR/source.txt"
fi

# --- 监听端口 ---
echo "" | tee -a "$OUT_DIR/source.txt"
echo "== LISTEN PORTS ==" | tee -a "$OUT_DIR/source.txt"
ss -tlnp 2>/dev/null | awk 'NR>1{print $4}' | sort -u | tee -a "$OUT_DIR/source.txt"

# --- 启用的服务（systemd 主机）---
echo "" | tee -a "$OUT_DIR/source.txt"
echo "== ENABLED SERVICES ==" | tee -a "$OUT_DIR/source.txt"
systemctl list-unit-files --state=enabled --no-pager 2>/dev/null | awk 'NR>1{print $1}' | tee -a "$OUT_DIR/source.txt" || true

# --- cron ---
echo "" | tee -a "$OUT_DIR/source.txt"
echo "== CRONTAB (root) ==" | tee -a "$OUT_DIR/source.txt"
crontab -l 2>/dev/null | tee -a "$OUT_DIR/source.txt"
ls /etc/cron.d/ 2>/dev/null | tee -a "$OUT_DIR/source.txt"

# --- 用户 / 组 ---
echo "" | tee -a "$OUT_DIR/source.txt"
echo "== USERS (UID>=1000 or root) ==" | tee -a "$OUT_DIR/source.txt"
awk -F: '$3>=1000 || $1=="root"{print $1":"$3}' /etc/passwd | tee -a "$OUT_DIR/source.txt"
echo "== GROUPS ==" | tee -a "$OUT_DIR/source.txt"
getent group | awk -F: '$3>=1000{print $1}' | tee -a "$OUT_DIR/source.txt"

# --- 业务服务器目录（默认约定 /server）---
echo "" | tee -a "$OUT_DIR/source.txt"
echo "== BUSINESS TREE (/server) ==" | tee -a "$OUT_DIR/source.txt"
if [ -d /server ]; then
  du -sh /server 2>/dev/null | tee -a "$OUT_DIR/source.txt"
  find /server -maxdepth 3 \( -type f -o -type l \) 2>/dev/null | head -300 | tee -a "$OUT_DIR/source.txt"
else
  echo "no /server" | tee -a "$OUT_DIR/source.txt"
fi

# --- 业务目录属主/权限（迁移需原样还原，不再统一 0755）---
echo "" | tee -a "$OUT_DIR/source.txt"
echo "== BUSINESS ATTRS (/server) ==" | tee -a "$OUT_DIR/source.txt"
if [ -d /server ]; then
  printf '.|%s\n' "$(stat -c '%a|%U|%G' /server 2>/dev/null)" | tee -a "$OUT_DIR/source.txt"
  find /server -type f 2>/dev/null | head -500 | while read -r f; do
    rel=${f#/server/}
    printf '%s|%s\n' "$rel" "$(stat -c '%a|%U|%G' "$f" 2>/dev/null)"
  done | tee -a "$OUT_DIR/source.txt"
fi

# --- 业务二进制的 libc 下限（迁移最容易踩的坑）---
echo "" | tee -a "$OUT_DIR/source.txt"
echo "== BINARY LIBC REQUIREMENTS ==" | tee -a "$OUT_DIR/source.txt"
echo "host_glibc: $(ldd --version 2>/dev/null | head -1)" | tee -a "$OUT_DIR/source.txt"
for b in $(find /server -maxdepth 3 -type f -perm -u+x 2>/dev/null | head -20); do
  case "$b" in *.sh|*.yaml|*.yml|*.pem|*.env|*.conf|*.json) continue ;; esac
  echo "-- $b" | tee -a "$OUT_DIR/source.txt"
  ldd "$b" 2>/dev/null | grep -E 'not found|GLIBC' | tee -a "$OUT_DIR/source.txt"
  strings "$b" 2>/dev/null | grep -o 'GLIBC_2\.[0-9]*' | sort -u | tail -3 | tee -a "$OUT_DIR/source.txt"
done

# --- 业务 systemd unit 原文（ExecStart 引用 /server 的自定义 unit）---
echo "" | tee -a "$OUT_DIR/source.txt"
echo "== UNIT FILES ==" | tee -a "$OUT_DIR/source.txt"
for u in /etc/systemd/system/*.service; do
  [ -f "$u" ] || continue
  grep -q '/server' "$u" 2>/dev/null || continue
  echo "-- $u" | tee -a "$OUT_DIR/source.txt"
  cat "$u" | tee -a "$OUT_DIR/source.txt"
done

# --- 数据库引擎探测（迁移需 dump→restore，不能只拷数据文件）---
echo "" | tee -a "$OUT_DIR/source.txt"
echo "== DATABASES ==" | tee -a "$OUT_DIR/source.txt"
for eng in mysql mariadb psql redis-cli mongosh; do
  command -v "$eng" >/dev/null 2>&1 && echo "client: $eng" | tee -a "$OUT_DIR/source.txt"
done
ps -eo comm,args 2>/dev/null | grep -E 'mysqld|mariadbd|postgres|redis-server|mongod' | grep -v grep | tee -a "$OUT_DIR/source.txt"
mysql --version 2>/dev/null | tee -a "$OUT_DIR/source.txt"
psql --version 2>/dev/null | tee -a "$OUT_DIR/source.txt"
redis-server --version 2>/dev/null | tee -a "$OUT_DIR/source.txt"

# --- 防火墙 ---
echo "" | tee -a "$OUT_DIR/source.txt"
echo "== FIREWALL ==" | tee -a "$OUT_DIR/source.txt"
ufw status verbose 2>/dev/null | tee -a "$OUT_DIR/source.txt" || true
firewall-cmd --list-all 2>/dev/null | tee -a "$OUT_DIR/source.txt" || true
iptables -S 2>/dev/null | head -40 | tee -a "$OUT_DIR/source.txt" || true

echo ""
echo "快照完成: $OUT_DIR/source.txt（把该文件拷回本机，据此编写 plan/migration.json）"
