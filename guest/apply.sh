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
if [ -n "${PACKAGES:-}" ] && [ "$PM" != "none" ]; then
  case "$PM" in
    apt) apt-get update -y >/dev/null 2>&1
         DEBIAN_FRONTEND=noninteractive apt-get install -y $PACKAGES >/dev/null 2>&1 ;;
    dnf) dnf install -y $PACKAGES >/dev/null 2>&1 ;;
    yum) yum install -y $PACKAGES >/dev/null 2>&1 ;;
    apk) apk add --no-cache $PACKAGES >/dev/null 2>&1 ;;
  esac
fi

# --- 落配置文件（先于用户创建，保证配置可见）---
i=0
while true; do
  eval "dest=\${FILE${i}_DEST:-}"
  [ -z "$dest" ] && break
  eval "want=\${FILE${i}_CONTAINS:-}"
  mkdir -p "$(dirname "$dest")"
  cp "$PLAN_DIR/files/$i" "$dest" 2>/dev/null || true
  i=$((i + 1))
done

# --- 组（优先系统工具，缺失时手动追加 /etc/group）---
ensure_group() {
  g="$1"
  getent group "$g" >/dev/null 2>&1 && return 0
  if command -v groupadd >/dev/null 2>&1; then groupadd -r "$g" && return 0; fi
  gid=$(awk -F: '{if ($3 > m) m=$3} END {print m+1}' /etc/group)
  echo "$g:x:$gid:" >> /etc/group
}

# --- 用户（同上兜底）---
ensure_user() {
  name="$1"; grp="$2"
  id "$name" >/dev/null 2>&1 && return 0
  if command -v useradd >/dev/null 2>&1; then useradd -r -m -g "$grp" "$name" && return 0; fi
  gid=$(getent group "$grp" | cut -d: -f3)
  uid=$(awk -F: '{if ($3 > m) m=$3} END {print m+1}' /etc/passwd)
  echo "$name:x:$uid:${gid:-100}::/home/$name:/usr/sbin/nologin" >> /etc/passwd
}

for g in ${GROUPS:-}; do ensure_group "$g"; done
for u in ${USERS:-}; do
  name=${u%%:*}; grp=${u#*:}
  [ -z "$grp" ] && grp="$name"
  ensure_user "$name" "$grp"
done

# --- cron（仅当 crontab 可用）---
if command -v crontab >/dev/null 2>&1; then
  i=0
  while true; do
    eval "expr=\${CRON${i}_EXPR:-}"
    [ -z "$expr" ] && break
    eval "cmd=\${CRON${i}_CMD:-}"
    ( crontab -l 2>/dev/null; echo "$expr $cmd" ) | crontab - 2>/dev/null || true
    i=$((i + 1))
  done
fi

echo "apply done (PM=$PM)"
