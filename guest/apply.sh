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

# 安装包（日志留 /tmp/linuxmig-pkg.log）。RHEL 9 minimal 预装 curl-minimal，
# 装 curl/nginx 会因包冲突整体失败，因此失败后用 --allowerasing 重试一次。
PKG_LOG=/tmp/linuxmig-pkg.log
install_pkgs() {
  case "$PM" in
    apt) apt-get update -y >>"$PKG_LOG" 2>&1
         DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS >>"$PKG_LOG" 2>&1 ;;
    dnf) dnf install -y $PKGS >>"$PKG_LOG" 2>&1 ;;
    yum) yum install -y $PKGS >>"$PKG_LOG" 2>&1 ;;
    apk) apk add --no-cache $PKGS >>"$PKG_LOG" 2>&1 ;;
  esac
}

if [ -n "${PKGS:-}" ] && [ "$PM" != "none" ]; then
  : > "$PKG_LOG"
  install_pkgs || {
    case "$PM" in
      dnf) echo "[apply] dnf 冲突重试 --allowerasing" | tee -a "$PKG_LOG"
           dnf install -y --allowerasing $PKGS >>"$PKG_LOG" 2>&1 ;;
      yum) echo "[apply] yum 冲突重试 --allowerasing" | tee -a "$PKG_LOG"
           yum install -y --allowerasing $PKGS >>"$PKG_LOG" 2>&1 ;;
    esac
  }
  # 二次校验：至少命令可执行层面不静默失败
  if [ -n "$(tail -5 "$PKG_LOG" 2>/dev/null | grep -i 'error\|conflict\|cannot' || true)" ]; then
    echo "[apply] 包安装可能有异常，日志尾部："
    tail -5 "$PKG_LOG"
  fi
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

# --- 组/用户存在性检查（awk 直接读文件，兼容 busybox 无 getent 的场景）---
has_group() { awk -F: -v g="$1" '$1==g{f=1} END{exit !f}' /etc/group 2>/dev/null; }
has_user()  { awk -F: -v u="$1" '$1==u{f=1} END{exit !f}' /etc/passwd 2>/dev/null; }

ensure_group() {
  g="$1"
  has_group "$g" && return 0
  if command -v groupadd >/dev/null 2>&1; then
    groupadd -r "$g" 2>/dev/null
  elif command -v addgroup >/dev/null 2>&1; then
    addgroup -S "$g" 2>/dev/null
  fi
  has_group "$g" && return 0
  gid=$(awk -F: 'BEGIN{m=99} $3 ~ /^[0-9]+$/ && $3 > m {m=$3} END{print m+1}' /etc/group)
  echo "$g:x:$gid:" >> /etc/group
}

ensure_user() {
  name="$1"; grp="$2"
  has_user "$name" && return 0
  if command -v useradd >/dev/null 2>&1; then
    useradd -r -g "$grp" "$name" 2>/dev/null
  elif command -v adduser >/dev/null 2>&1; then
    adduser -S -D -H -G "$grp" "$name" 2>/dev/null
  fi
  has_user "$name" && return 0
  gid=$(awk -F: -v g="$grp" '$1==g{print $3}' /etc/group); [ -z "$gid" ] && gid=100
  uid=$(awk -F: 'BEGIN{m=99} $3 ~ /^[0-9]+$/ && $3 > m {m=$3} END{print m+1}' /etc/passwd)
  echo "$name:x:$uid:${gid}::/home/$name:/usr/sbin/nologin" >> /etc/passwd
}

for g in ${GROUPLIST:-}; do ensure_group "$g"; done
for u in ${USERLIST:-}; do
  name=${u%%:*}; grp=${u#*:}
  [ -z "$grp" ] && grp="$name"
  ensure_user "$name" "$grp"
done

# --- cron：全量重建，保证重复 apply 幂等 ---
# busybox/Alpine 走 /etc/crontabs/root；其余发行版写 /etc/cron.d/linuxmig
CRON_FILE=/etc/cron.d/linuxmig
if [ "$PM" = "apk" ] || { [ -d /etc/crontabs ] && [ ! -d /etc/cron.d ]; }; then
  CRON_FILE=/etc/crontabs/root
fi
echo "$CRON_FILE" > "$PLAN_DIR/cron_path"

i=0
have_cron=0
while true; do
  eval "expr=\${CRON${i}_EXPR:-}"
  [ -z "$expr" ] && break
  have_cron=1
  i=$((i + 1))
done

if [ "$have_cron" = 1 ]; then
  mkdir -p "$(dirname "$CRON_FILE")"
  : > "$CRON_FILE" # 重建，避免重复追加
  i=0
  while true; do
    eval "expr=\${CRON${i}_EXPR:-}"
    [ -z "$expr" ] && break
    eval "cmd=\${CRON${i}_CMD:-}"
    # /etc/cron.d 需要 6 段（含用户）；crontabs 用户即文件名，写 5 段
    case "$CRON_FILE" in
      /etc/crontabs/*) echo "$expr $cmd" >> "$CRON_FILE" ;;
      *)               echo "$expr root $cmd" >> "$CRON_FILE" ;;
    esac
    i=$((i + 1))
  done
  chmod 644 "$CRON_FILE" 2>/dev/null || true
fi

echo "apply done (PM=$PM, cron=$CRON_FILE)"
