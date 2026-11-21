#!/bin/sh
# verify.sh — 容器内校验（matrix.py 调用，$1=计划目录 $2=输出 TSV 路径）
# TSV 每行: STATUS|检查项|细节；STATUS ∈ PASS/FAIL/SKIP
set -u
PLAN_DIR="$1"; OUT="$2"
. "$PLAN_DIR/apply.env"
: > "$OUT"

pass() { echo "PASS|$1|$2" >> "$OUT"; }
fail() { echo "FAIL|$1|$2" >> "$OUT"; }
skip() { echo "SKIP|$1|$2" >> "$OUT"; }

# --- 探测（用于包检查）---
if command -v dpkg-query >/dev/null 2>&1; then PM=apt
elif command -v rpm >/dev/null 2>&1; then PM=rpm
elif command -v apk >/dev/null 2>&1; then PM=apk
else PM=none; fi

pkg_installed() {
  p="$1"
  case "$PM" in
    apt) dpkg -l "$p" 2>/dev/null | grep -q '^ii' ;;
    rpm) rpm -q "$p" >/dev/null 2>&1 || rpm -qa 2>/dev/null | grep -qw "$p" ;;
    apk) apk info -e "$p" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# --- 包 ---
for p in ${PACKAGES:-}; do
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
for c in ${COMMANDS:-}; do
  if command -v "$c" >/dev/null 2>&1; then pass "cmd:$c" "found"
  else fail "cmd:$c" "not found"; fi
done

# --- 用户 / 组 ---
for u in ${USERS:-}; do
  name=${u%%:*}
  if id "$name" >/dev/null 2>&1; then pass "user:$name" "exists"
  else fail "user:$name" "missing"; fi
done
for g in ${GROUPS:-}; do
  if getent group "$g" >/dev/null 2>&1; then pass "group:$g" "exists"
  else fail "group:$g" "missing"; fi
done

# --- cron（容器无 crontab 时 SKIP，不算失败）---
if command -v crontab >/dev/null 2>&1; then
  i=0
  while true; do
    eval "expr=\${CRON${i}_EXPR:-}"
    [ -z "$expr" ] && break
    eval "cmd=\${CRON${i}_CMD:-}"
    if crontab -l 2>/dev/null | grep -Fq "$cmd"; then pass "cron:$expr" "installed"
    else fail "cron:$expr" "not in crontab"; fi
    i=$((i + 1))
  done
else
  i=0
  while true; do
    eval "expr=\${CRON${i}_EXPR:-}"
    [ -z "$expr" ] && break
    skip "cron:$expr" "crontab unavailable in container"
    i=$((i + 1))
  done
fi

echo "verify done -> $OUT"
