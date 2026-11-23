#!/bin/sh
# target_apply.sh — 真实目标机执行器（root 运行）。
# 与容器验证共用同一份物化计划与 apply.sh/verify.sh，保证「验过的就是部署的」。
# 流程：备份将被覆盖的文件/目录/cron/unit → USE_SYSTEMD=1 apply → 记录备份点。
# 用法: sh target_apply.sh <plan_dir>   （plan_dir 内含 apply.env、files/、dirs/）
set -u
PLAN_DIR="$1"
HERE=$(cd "$(dirname "$0")" && pwd)
. "$PLAN_DIR/apply.env"
STAGES="${STAGES:-all}"

TS=$(date +%Y%m%d-%H%M%S)
BK="/var/backups/linuxmig-$TS"
mkdir -p "$BK" || { echo "无法创建备份目录 $BK"; exit 1; }
MAN="$BK/manifest.tsv"
: > "$MAN"

# backup_path <type> <dest>：存在则备份（目录打 tar），不存在记 MISSING（回滚时删除）
backup_path() {
  t="$1"; d="$2"
  rel="$t/$(echo "$d" | tr '/' '_')"
  if [ -d "$d" ]; then
    mkdir -p "$BK/$t"
    tar -cf "$BK/$rel.tar" -C "$d" . 2>/dev/null
    printf '%s\t%s\t%s.tar\n' "$t" "$d" "$rel" >> "$MAN"
  elif [ -e "$d" ]; then
    mkdir -p "$BK/$t"
    cp "$d" "$BK/$rel" 2>/dev/null
    printf '%s\t%s\t%s\n' "$t" "$d" "$rel" >> "$MAN"
  else
    printf '%s\t%s\tMISSING\n' "$t" "$d" >> "$MAN"
  fi
}

i=0
while true; do
  eval "dest=\${FILE${i}_DEST:-}"
  [ -z "$dest" ] && break
  backup_path file "$dest"
  i=$((i + 1))
done

i=0
while true; do
  eval "dest=\${DIR${i}_DEST:-}"
  [ -z "$dest" ] && break
  backup_path dir "$dest"
  i=$((i + 1))
done

i=0
while true; do
  eval "udest=\${UNIT${i}_DEST:-}"
  [ -z "$udest" ] && break
  backup_path unit "$udest"
  i=$((i + 1))
done

# cron 目标路径（与 apply.sh 同逻辑）
if command -v apk >/dev/null 2>&1; then CRON_FILE=/etc/crontabs/root
elif [ -d /etc/crontabs ] && [ ! -d /etc/cron.d ]; then CRON_FILE=/etc/crontabs/root
else CRON_FILE=/etc/cron.d/linuxmig; fi
backup_path cron "$CRON_FILE"

# 防火墙状态备份（回滚用）
if command -v ufw >/dev/null 2>&1; then
  ufw status verbose > "$BK/firewall-ufw.txt" 2>/dev/null
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --list-all > "$BK/firewall-firewalld.txt" 2>/dev/null
fi
command -v iptables-save >/dev/null 2>&1 && iptables-save > "$BK/firewall-iptables.rules" 2>/dev/null

USE_SYSTEMD=1 STAGES="$STAGES" sh "$HERE/apply.sh" "$PLAN_DIR"
rc=$?
echo "$BK" > /tmp/linuxmig-last-backup
echo "target apply done (rc=$rc); backup=$BK"
exit $rc
