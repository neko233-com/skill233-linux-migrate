#!/bin/sh
# target_rollback.sh — 停掉本次部署的服务并按备份清单恢复到部署前状态。
# 用法: sh target_rollback.sh [backup_dir] [plan_dir]
#   backup_dir 缺省读 /tmp/linuxmig-last-backup；plan_dir 缺省 /tmp/linuxmig-deploy/plan
set -u
BK="${1:-}"
[ -z "$BK" ] && BK=$(cat /tmp/linuxmig-last-backup 2>/dev/null)
[ -n "$BK" ] && [ -d "$BK" ] || { echo "无可用备份: ${BK:-<empty>}"; exit 1; }
MAN="$BK/manifest.tsv"
[ -f "$MAN" ] || { echo "备份缺少 manifest: $MAN"; exit 1; }
PLAN_DIR="${2:-/tmp/linuxmig-deploy/plan}"

# 先停服务，再还原文件（避免进程握着已删除的二进制/配置）
if [ -f "$PLAN_DIR/apply.env" ]; then
  . "$PLAN_DIR/apply.env"
  i=0
  while true; do
    eval "sname=\${SVC${i}_NAME:-}"
    [ -z "$sname" ] && break
    eval "sstop=\${SVC${i}_STOP:-}"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] \
       && systemctl cat "$sname.service" >/dev/null 2>&1; then
      systemctl stop "$sname.service" >/dev/null 2>&1 || true
    elif [ -n "$sstop" ]; then
      sh -c "$sstop" >/dev/null 2>&1 || true
    fi
    [ -f "/tmp/svc-$sname.pid" ] && kill "$(cat "/tmp/svc-$sname.pid")" 2>/dev/null
    i=$((i + 1))
  done
fi

TAB=$(printf '\t')
while IFS="$TAB" read -r t d rel; do
  [ -z "$t" ] && continue
  case "$t" in
    dir)
      if [ "$rel" = "MISSING" ]; then
        rm -rf "$d"
      else
        rm -rf "$d"
        mkdir -p "$d"
        tar -xf "$BK/$rel" -C "$d" 2>/dev/null
      fi ;;
    *)
      if [ "$rel" = "MISSING" ]; then
        # 部署前不存在的 unit：先解除 enable 再删文件
        if [ "$t" = "unit" ] && command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
          systemctl disable --now "$(basename "$d")" >/dev/null 2>&1 || true
        fi
        rm -f "$d"
      else
        mkdir -p "$(dirname "$d")"
        cp "$BK/$rel" "$d" 2>/dev/null
      fi ;;
  esac
done < "$MAN"

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
echo "rollback done from $BK"
