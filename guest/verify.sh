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
