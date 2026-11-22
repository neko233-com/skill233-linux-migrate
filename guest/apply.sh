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

# --- 业务目录树（tar 解包，保留结构）---
i=0
while true; do
  eval "dest=\${DIR${i}_DEST:-}"
  [ -z "$dest" ] && break
  mkdir -p "$dest"
  tar -xf "$PLAN_DIR/dirs/$i.tar" -C "$dest" 2>/dev/null || \
    echo "[apply] 解包失败: $PLAN_DIR/dirs/$i.tar -> $dest"
  i=$((i + 1))
done

# --- systemd unit 文件落盘 ---
i=0
while true; do
  eval "uname_=\${UNIT${i}_NAME:-}"
  [ -z "$uname_" ] && break
  eval "udest=\${UNIT${i}_DEST:-}"
  if [ -n "$udest" ]; then
    mkdir -p "$(dirname "$udest")"
    cp "$PLAN_DIR/files/unit$i" "$udest" 2>/dev/null || true
  fi
  i=$((i + 1))
done

# --- 组/用户（awk 读文件，兼容 busybox 无 getent）---
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

# --- systemd 集成（仅真实目标机：USE_SYSTEMD=1 且 systemd 在跑；容器内不启用）---
SYSTEMD_ACTIVE=0
if [ "${USE_SYSTEMD:-0}" = 1 ] && command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  SYSTEMD_ACTIVE=1
  systemctl daemon-reload >/dev/null 2>&1 || true
  i=0
  while true; do
    eval "un=\${UNIT${i}_NAME:-}"
    [ -z "$un" ] && break
    systemctl enable --now "$un" >/dev/null 2>&1 || echo "[apply] enable $un 失败"
    i=$((i + 1))
  done
fi

# --- 业务服务启动（后台常驻，日志/pid 落 /tmp）---
listening_inodes() {
  p="$1"
  ph=$(printf "%04X" "$p" 2>/dev/null) || return 1
  awk -v pat="$ph" 'FNR>1 { split($2,a,":"); if (toupper(a[2])==pat && $4=="0A") print $10 }' \
    /proc/net/tcp /proc/net/tcp6 2>/dev/null | sort -u
}

# 反查真正持有监听端口的 pid（启动脚本会 fork/exec，记录的 $! 未必是 listener）
find_port_owner() {
  port="$1"
  inodes=$(listening_inodes "$port")
  [ -z "$inodes" ] && return 1
  for pd in /proc/[0-9]*; do
    for fd in "$pd"/fd/*; do
      l=$(readlink "$fd" 2>/dev/null) || continue
      case "$l" in
        "socket:["*"]")
          ino=${l#socket:[}; ino=${ino%]}
          if echo "$inodes" | grep -qx "$ino"; then
            echo "${pd#/proc/}"; return 0
          fi ;;
      esac
    done
  done
  return 1
}

i=0
while true; do
  eval "sname=\${SVC${i}_NAME:-}"
  [ -z "$sname" ] && break
  eval "sstart=\${SVC${i}_START:-}"
  eval "sstop=\${SVC${i}_STOP:-}"
  eval "sport=\${SVC${i}_PORT:-}"
  eval "swait=\${SVC${i}_WAIT:-5}"

  rm -f "/tmp/svc-$sname.pid"
  managed=0
  [ "$SYSTEMD_ACTIVE" = 1 ] && systemctl cat "$sname.service" >/dev/null 2>&1 && managed=1

  if [ "$managed" = 1 ]; then
    # 目标机由 systemd unit 托管：restart 并取 MainPID，不走后台脚本
    systemctl restart "$sname.service" >/dev/null 2>&1 || true
    mp=$(systemctl show -p MainPID --value "$sname.service" 2>/dev/null)
    [ -n "$mp" ] && [ "$mp" != 0 ] && echo "$mp" > "/tmp/svc-$sname.pid"
  else
    [ -n "$sstop" ] && sh -c "$sstop" >/dev/null 2>&1

    # 生成启动脚本（避免引号地狱；脚本自行记录 pid，随后 exec 保持同一 pid）
    script="/tmp/svc-$sname.sh"
    {
      echo '#!/bin/sh'
      echo "echo \$\$ > /tmp/svc-$sname.pid"
      echo "$sstart"
    } > "$script"
    chmod +x "$script"

    # setsid -f 优先（脱离会话），busybox 无 setsid 时退回 nohup
    if setsid -f true >/dev/null 2>&1; then
      setsid -f "$script" >"/tmp/svc-$sname.log" 2>&1
    elif command -v setsid >/dev/null 2>&1; then
      setsid "$script" >"/tmp/svc-$sname.log" 2>&1 &
    else
      nohup "$script" >"/tmp/svc-$sname.log" 2>&1 &
    fi
  fi

  # 等端口就绪，并把 pid 校正为真正的 listener
  n=0
  while [ "$n" -lt "$swait" ]; do
    sleep 1
    n=$((n + 1))
    if [ -n "$sport" ] && [ -n "$(listening_inodes "$sport")" ]; then
      owner=$(find_port_owner "$sport")
      [ -n "$owner" ] && echo "$owner" > "/tmp/svc-$sname.pid"
      break
    fi
  done
  i=$((i + 1))
done

# --- cron：全量重建，保证重复 apply 幂等 ---
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
  case "$CRON_FILE" in
    /etc/crontabs/*)
      # Alpine：/etc/crontabs/root 可能有用户既有任务，只重建 linuxmig 标记块，其余保留
      tmp="$CRON_FILE.tmp"
      awk '/^# BEGIN linuxmig$/{skip=1;next} /^# END linuxmig$/{skip=0;next} !skip' \
        "$CRON_FILE" > "$tmp" 2>/dev/null || : > "$tmp"
      mv "$tmp" "$CRON_FILE"
      echo "# BEGIN linuxmig" >> "$CRON_FILE"
      ;;
    *) : > "$CRON_FILE" ;; # /etc/cron.d/linuxmig 是本工具专属文件，全量重建
  esac
  i=0
  while true; do
    eval "expr=\${CRON${i}_EXPR:-}"
    [ -z "$expr" ] && break
    eval "cmd=\${CRON${i}_CMD:-}"
    case "$CRON_FILE" in
      /etc/crontabs/*) echo "$expr $cmd" >> "$CRON_FILE" ;;
      *)               echo "$expr root $cmd" >> "$CRON_FILE" ;;
    esac
    i=$((i + 1))
  done
  case "$CRON_FILE" in
    /etc/crontabs/*) echo "# END linuxmig" >> "$CRON_FILE" ;;
  esac
  chmod 644 "$CRON_FILE" 2>/dev/null || true
fi

# 目标机：让 cron 守护进程加载新定义（容器内无守护进程，跳过）
if [ "${USE_SYSTEMD:-0}" = 1 ]; then
  if [ "$SYSTEMD_ACTIVE" = 1 ]; then
    systemctl reload crond >/dev/null 2>&1 || systemctl reload cron >/dev/null 2>&1 || true
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service crond restart >/dev/null 2>&1 || true
  fi
fi

echo "apply done (PM=$PM, cron=$CRON_FILE)"
