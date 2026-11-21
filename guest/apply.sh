#!/bin/sh
# apply.sh — 容器内执行迁移计划（matrix.py 调用，$1 = 已物化计划目录）
set -u
PLAN_DIR="$1"
. "$PLAN_DIR/apply.env"

# --- 探测包管理器 ---
if command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf >/dev/null 2>&1; then PM=dnf
elif command -v yum >/dev/null 2>&1; then PM=yum
elif command -v apk >/dev/null 2>&1; then PM=apk
else PM=none; fi

# --- 安装包 ---
if [ -n "${PKGS:-}" ] && [ "$PM" != "none" ]; then
  case "$PM" in
    apt) apt-get update -y >/dev/null 2>&1
         DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS >/dev/null 2>&1 ;;
    dnf) dnf install -y $PKGS >/dev/null 2>&1 ;;
    yum) yum install -y $PKGS >/dev/null 2>&1 ;;
    apk) apk add --no-cache $PKGS >/dev/null 2>&1 ;;
  esac
fi

# --- 落配置文件 ---
i=0
while true; do
  eval "dest=\${FILE${i}_DEST:-}"
  [ -z "$dest" ] && break
  mkdir -p "$(dirname "$dest")"
  cp "$PLAN_DIR/files/$i" "$dest" 2>/dev/null || true
  i=$((i + 1))
done

# --- 组：先试系统工具，失败则手动追加 /etc/group ---
ensure_group() {
  g="$1"
  getent group "$g" >/dev/null 2>&1 && return 0
  command -v groupadd >/dev/null 2>&1 && groupadd -r "$g" 2>/dev/null
  getent group "$g" >/dev/null 2>&1 && return 0
  gid=$(awk -F: 'BEGIN{m=99} $3 ~ /^[0-9]+$/ && $3 > m {m=$3} END{print m+1}' /etc/group)
  echo "$g:x:$gid:" >> /etc/group
}

# --- 用户：先试系统工具，失败则手动追加 /etc/passwd ---
ensure_user() {
  name="$1"; grp="$2"
  id "$name" >/dev/null 2>&1 && return 0
  command -v useradd >/dev/null 2>&1 && useradd -r -g "$grp" "$name" 2>/dev/null
  id "$name" >/dev/null 2>&1 && return 0
  gid=$(getent group "$grp" | cut -d: -f3); [ -z "$gid" ] && gid=100
  uid=$(awk -F: 'BEGIN{m=99} $3 ~ /^[0-9]+$/ && $3 > m {m=$3} END{print m+1}' /etc/passwd)
  echo "$name:x:$uid:${gid}::/home/$name:/usr/sbin/nologin" >> /etc/passwd
}

for g in ${GROUPLIST:-}; do ensure_group "$g"; done
for u in ${USERLIST:-}; do
  name=${u%%:*}; grp=${u#*:}
  [ -z "$grp" ] && grp="$name"
  ensure_user "$name" "$grp"
done

# --- cron：写入 /etc/cron.d/linuxmig（可移植，不依赖 crontab CLI / 守护进程）---
i=0
have_cron=0
while true; do
  eval "expr=\${CRON${i}_EXPR:-}"
  [ -z "$expr" ] && break
  have_cron=1
  eval "cmd=\${CRON${i}_CMD:-}"
  mkdir -p /etc/cron.d
  echo "$expr root $cmd" >> /etc/cron.d/linuxmig 2>/dev/null || true
  i=$((i + 1))
done
[ "$have_cron" = 1 ] && chmod 644 /etc/cron.d/linuxmig 2>/dev/null || true

echo "apply done (PM=$PM)"
