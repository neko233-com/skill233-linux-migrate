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

# --- 防火墙 ---
echo "" | tee -a "$OUT_DIR/source.txt"
echo "== FIREWALL ==" | tee -a "$OUT_DIR/source.txt"
ufw status verbose 2>/dev/null | tee -a "$OUT_DIR/source.txt" || true
firewall-cmd --list-all 2>/dev/null | tee -a "$OUT_DIR/source.txt" || true
iptables -S 2>/dev/null | head -40 | tee -a "$OUT_DIR/source.txt" || true

echo ""
echo "快照完成: $OUT_DIR/source.txt（把该文件拷回本机，据此编写 plan/migration.json）"
