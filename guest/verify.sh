#!/bin/sh
# verify.sh — 容器内校验（matrix.py 调用，$1=计划目录 $2=输出 TSV 路径）
# TSV 每行: STATUS|检查项|细节；STATUS ∈ PASS/FAIL
set -u
PLAN_DIR="$1"; OUT="$2"
. "$PLAN_DIR/apply.env"
: > "$OUT"

pass() { echo "PASS|$1|$2" >> "$OUT"; }
fail() { echo "FAIL|$1|$2" >> "$OUT"; }

# --- 探测（用于包检查）---
if command -v dpkg-query >/dev/null 2>&1; then PM=apt
elif command -v rpm >/dev/null 2>&1; then PM=rpm
elif command -v apk >/dev/null 2>&1; then PM=apk
else PM=none; fi

pkg_installed() {
  p="$1"
  case "$PM" in
    apt) dpkg -l "$p" 2>/dev/null | grep -q '^ii' ;;
    rpm) rpm -q "$p" >/dev/null 2>&1 || rpm -qa 2>/dev/null | grep -q "^${p}-" ;;
    apk) apk info -e "$p" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# --- 包 ---
for p in ${PKGS:-}; do
  if pkg_installed "$p"; then pass "pkg:$p" "installed"
  else fail "pkg:$p" "not installed"; fi
done

# --- 文件 ---
i=0
while true; do
  eval "dest=\${FILE${i}_DEST:-}"
  [ -z "$dest" ] && break
  eval "want=\${FILE${i}_CONTAINS:-}"
  if [ ! -f "$dest" ]; then
    fail "file:$dest" "missing"
  elif [ -n "$want" ] && ! grep -qF "$want" "$dest" 2>/dev/null; then
    fail "file:$dest" "missing text: $want"
  else
    pass "file:$dest" "ok"
  fi
  i=$((i + 1))
done

# --- 命令 ---
for c in ${CMDS:-}; do
  if command -v "$c" >/dev/null 2>&1; then pass "cmd:$c" "found"
  else fail "cmd:$c" "not found"; fi
done

# --- 用户 / 组（直接读文件，兼容 busybox）---
for u in ${USERLIST:-}; do
  name=${u%%:*}
  if awk -F: -v n="$name" '$1==n{f=1} END{exit !f}' /etc/passwd 2>/dev/null; then
    pass "user:$name" "exists"
  else
    fail "user:$name" "missing"
  fi
done
for g in ${GROUPLIST:-}; do
  if awk -F: -v n="$g" '$1==n{f=1} END{exit !f}' /etc/group 2>/dev/null; then
    pass "group:$g" "exists"
  else
    fail "group:$g" "missing"
  fi
done

# --- cron：路径由 apply 阶段决定（cron_path），校验表达式与命令均在 ---
CRON_FILE=/etc/cron.d/linuxmig
[ -f "$PLAN_DIR/cron_path" ] && CRON_FILE=$(cat "$PLAN_DIR/cron_path")

i=0
while true; do
  eval "expr=\${CRON${i}_EXPR:-}"
  [ -z "$expr" ] && break
  eval "cmd=\${CRON${i}_CMD:-}"
  if [ -f "$CRON_FILE" ] \
    && grep -Fq "$cmd" "$CRON_FILE" \
    && grep -Fq "$expr" "$CRON_FILE"; then
    pass "cron:$expr" "installed in $CRON_FILE"
  else
    fail "cron:$expr" "missing in $CRON_FILE"
  fi
  i=$((i + 1))
done

# --- 业务目录树 ---
i=0
while true; do
  eval "dest=\${DIR${i}_DEST:-}"
  [ -z "$dest" ] && break
  if [ -d "$dest" ]; then
    n=$(find "$dest" -type f 2>/dev/null | wc -l | tr -d ' ')
    pass "dir:$dest" "exists, $n files"
  else
    fail "dir:$dest" "missing"
  fi
  i=$((i + 1))
done

# --- systemd unit：有 systemd-analyze 才做真正语法校验 ---
i=0
while true; do
  eval "uname_=\${UNIT${i}_NAME:-}"
  [ -z "$uname_" ] && break
  eval "udest=\${UNIT${i}_DEST:-}"
  if [ ! -f "$udest" ]; then
    fail "unit:$uname_" "missing at $udest"
  elif command -v systemd-analyze >/dev/null 2>&1; then
    if systemd-analyze verify "$udest" >/tmp/unit-verify.log 2>&1; then
      pass "unit:$uname_" "systemd-analyze verify ok"
    else
      fail "unit:$uname_" "systemd-analyze verify failed: $(tail -1 /tmp/unit-verify.log)"
    fi
  elif grep -q '^\[Service\]' "$udest" 2>/dev/null \
       && grep -q '^ExecStart=' "$udest" 2>/dev/null \
       && grep -q '^\[Unit\]' "$udest" 2>/dev/null; then
    # 镜像无 systemd-analyze：退化为结构校验，并明确标注（Alpine 用 openrc，需转换）
    if [ -f /sbin/openrc-run ] || command -v rc-service >/dev/null 2>&1; then
      pass "unit:$uname_" "structural ok; WARNING: openrc host, needs openrc script instead of unit"
    else
      pass "unit:$uname_" "structural ok (no systemd-analyze in image)"
    fi
  else
    fail "unit:$uname_" "not a valid unit (missing [Unit]/[Service]/ExecStart=)"
  fi
  i=$((i + 1))
done

# --- 业务服务：进程存活 + 端口由该进程自己持有（避免被旧进程占端口造成假通过）---
listening_inodes() {
  p="$1"
  ph=$(printf "%04X" "$p" 2>/dev/null) || return 1
  awk -v pat="$ph" 'FNR>1 { split($2,a,":"); if (toupper(a[2])==pat && $4=="0A") print $10 }' \
    /proc/net/tcp /proc/net/tcp6 2>/dev/null | sort -u
}

pid_owns_port() {
  pid="$1"; p="$2"
  inodes=$(listening_inodes "$p")
  [ -z "$inodes" ] && return 1
  for fd in /proc/"$pid"/fd/*; do
    l=$(readlink "$fd" 2>/dev/null) || continue
    case "$l" in
      "socket:["*"]")
        ino=${l#socket:[}; ino=${ino%]}
        echo "$inodes" | grep -qx "$ino" && return 0 ;;
    esac
  done
  return 1
}

i=0
while true; do
  eval "sname=\${SVC${i}_NAME:-}"
  [ -z "$sname" ] && break
  eval "sport=\${SVC${i}_PORT:-}"
  pid=""
  [ -f "/tmp/svc-$sname.pid" ] && pid=$(cat "/tmp/svc-$sname.pid")
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    fail "svc:$sname" "process dead | $(tail -2 "/tmp/svc-$sname.log" 2>/dev/null | tr '\n' ' ')"
  elif [ -n "$sport" ] && ! pid_owns_port "$pid" "$sport"; then
    if [ -n "$(listening_inodes "$sport")" ]; then
      fail "svc:$sname" "tcp/$sport is LISTEN but not owned by pid $pid (stale/another process)"
    else
      fail "svc:$sname" "process alive but tcp/$sport not LISTEN | $(tail -2 "/tmp/svc-$sname.log" 2>/dev/null | tr '\n' ' ')"
    fi
  else
    pass "svc:$sname" "pid $pid owns tcp/${sport:-n/a}"
  fi
  i=$((i + 1))
done

# --- 自定义命令校验：程序层（如 nginx -T 是否真的加载了配置）---
i=0
while true; do
  eval "cname=\${CHECK${i}_NAME:-}"
  [ -z "$cname" ] && break
  eval "ccmd=\${CHECK${i}_CMD:-}"
  if sh -c "$ccmd" >/dev/null 2>&1; then
    pass "check:$cname" "ok"
  else
    fail "check:$cname" "command failed"
  fi
  i=$((i + 1))
done

echo "verify done -> $OUT"
