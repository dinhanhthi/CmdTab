#!/bin/bash
#
# measure.sh — Check CmdTab against the plan's performance budgets.
#
#   idle    [seconds=30] [maxMB=40]   samples the running CmdTab with `top` once per
#                                     second: average %CPU, idle wakeups, memory footprint.
#   latency [minutes=5]               reads the `perf <name> <ms>` lines CmdTab logged in
#                                     the last <minutes> (`log show`, no sudo) and prints
#                                     count, p50 and max per metric.
#
# BUDGET_SCALE (default 1) multiplies every latency budget (VM runs use BUDGET_SCALE=3).
# A latency metric without samples prints n/a and does not fail.
#
# Usage:
#   scripts/measure.sh idle               # 30 s, memory budget 40 MB
#   scripts/measure.sh idle 30 65         # after 20 hold sessions
#   BUDGET_SCALE=3 scripts/measure.sh latency 10
#
# Last line PASS or FAIL. Exit: 0 PASS, 1 FAIL, 2 usage error, CmdTab not running
# or no samples.
#
set -euo pipefail
export LC_ALL=C

# Latency budgets, in milliseconds on the host: p50 and max per Perf metric ("-" = none).
PRESS_P50_MS=6;      PRESS_MAX_MS=16
SHOWPANEL_P50_MS=12; SHOWPANEL_MAX_MS=25
STEP_P50_MS=2;       STEP_MAX_MS=8
FOCUS_P50_MS=50;     FOCUS_MAX_MS=300
CAPTURE_P50_MS=40;   CAPTURE_MAX_MS=-
# Idle budgets.
IDLE_CPU_MAX_PCT=0.1        # average %CPU over the run
IDLE_WAKEUPS_PER_30S=30     # idle wakeups in 30 s (scaled linearly to the run's length)
IDLE_MEM_MAX_MB=40          # memory footprint in MB (default of the second argument)

BUDGET_SCALE="${BUDGET_SCALE:-1}"
SUBSYSTEM="com.math2it.cmdtab"

usage() {
  echo "usage: $0 idle [seconds=30] [maxMB=$IDLE_MEM_MAX_MB]" >&2
  echo "       $0 latency [minutes=5]          (env BUDGET_SCALE=<n> scales latency budgets)" >&2
  exit 2
}

is_int() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 )); }
is_num() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

measure_idle() {
  local secs="${1:-30}" max_mb="${2:-$IDLE_MEM_MAX_MB}"
  is_int "$secs" && is_num "$max_mb" || usage

  local pid
  pid="$(pgrep -x CmdTab | head -1 || true)"
  if [[ -z "$pid" ]]; then
    echo "CmdTab is not running." >&2
    exit 2
  fi

  echo "==> Sampling CmdTab (pid $pid) for $secs s (top, 1 s interval, first CPU sample ignored)…"
  # -c e: absolute event counters, so IDLEW is cumulative (last - first = wakeups during
  # the run) while %CPU stays per interval. (-c a also accumulates IDLEW, but its %CPU is
  # "since the launch of top", a running mean that must not be averaged again.)
  local top_out
  top_out="$(top -l "$((secs + 1))" -s 1 -c e -stats pid,command,mem,cpu,idlew -pid "$pid" || true)"

  PID="$pid" SECS="$secs" MAX_MB="$max_mb" CPU_MAX="$IDLE_CPU_MAX_PCT" \
  WAKE_30="$IDLE_WAKEUPS_PER_30S" awk '
    function num(v) { gsub(/[+-]$/, "", v); return v + 0 }
    function mb(v,   n, u) {
      gsub(/[+-]$/, "", v)
      u = substr(v, length(v), 1)
      n = substr(v, 1, length(v) - 1) + 0
      if (u == "K") return n / 1024
      if (u == "M") return n
      if (u == "G") return n * 1024
      if (u == "B") return n / 1048576
      return v / 1048576                      # plain bytes
    }
    # Columns: PID COMMAND MEM %CPU IDLEW; read from the right (widths shift).
    $1 == ENVIRON["PID"] && NF >= 5 {
      n++
      if (n == 1) firstw = num($NF)
      else { cpu += $(NF - 1); ncpu++ }
      lastw = num($NF); lastmem = $(NF - 2)
    }
    END {
      if (n < 2) { print "No top samples for CmdTab (did it quit?)." > "/dev/stderr"; exit 2 }
      c = cpu / ncpu; w = lastw - firstw; m = mb(lastmem)
      cmax = ENVIRON["CPU_MAX"] + 0; mmax = ENVIRON["MAX_MB"] + 0
      wmax = ENVIRON["WAKE_30"] * ENVIRON["SECS"] / 30
      okc = (c <= cmax); okw = (w <= wmax); okm = (m <= mmax)
      printf "\n%-22s %10s %10s  %s\n", "METRIC", "VALUE", "BUDGET", "RESULT"
      printf "%-22s %10.2f %10.2f  %s\n", "avg %CPU", c, cmax, (okc ? "ok" : "FAIL")
      printf "%-22s %10d %10.1f  %s\n", "idle wakeups (" ENVIRON["SECS"] " s)", w, wmax, (okw ? "ok" : "FAIL")
      printf "%-22s %10.1f %10.1f  %s\n", "memory MB (last)", m, mmax, (okm ? "ok" : "FAIL")
      pass = okc && okw && okm
      print ""
      print (pass ? "PASS" : "FAIL")
      exit (pass ? 0 : 1)
    }
  ' <<<"$top_out"
}

measure_latency() {
  local mins="${1:-5}"
  is_int "$mins" && is_num "$BUDGET_SCALE" || usage

  # MEASURE_LOG_FILE (test hook): read saved `log show` text instead of the live log.
  local log_out
  if [[ -n "${MEASURE_LOG_FILE:-}" ]]; then log_out="$(cat "$MEASURE_LOG_FILE")"
  elif ! log_out="$(/usr/bin/log show --last "${mins}m" \
      --predicate "subsystem == \"$SUBSYSTEM\" AND category == \"Perf\"" 2>&1)"; then
    echo "log show failed: $log_out" >&2
    exit 2
  fi

  # Lines look like `… [com.math2it.cmdtab:Perf] perf <name> <ms>`; other names (spike) are ignored.
  local pairs
  pairs="$(awk -v tag="[$SUBSYSTEM:Perf]" '
    index($0, tag) && $(NF - 2) == "perf" &&
    $(NF - 1) ~ /^(press|showPanel|step|focus|capture)$/ && $NF ~ /^[0-9]+(\.[0-9]+)?$/ {
      print $(NF - 1), $NF
    }
  ' <<<"$log_out" | sort -k1,1 -k2,2n)"
  if [[ -z "$pairs" ]]; then
    echo "No CmdTab perf lines in the last $mins min." >&2
    exit 2
  fi

  echo "==> CmdTab latency, last $mins min (BUDGET_SCALE=$BUDGET_SCALE)"
  BUDGETS="press $PRESS_P50_MS $PRESS_MAX_MS
showPanel $SHOWPANEL_P50_MS $SHOWPANEL_MAX_MS
step $STEP_P50_MS $STEP_MAX_MS
focus $FOCUS_P50_MS $FOCUS_MAX_MS
capture $CAPTURE_P50_MS $CAPTURE_MAX_MS" SCALE="$BUDGET_SCALE" awk '
    { cnt[$1]++; v[$1, cnt[$1]] = $2 + 0 }
    END {
      scale = ENVIRON["SCALE"] + 0; pass = 1
      printf "\n%-10s %6s %9s %9s %9s %9s  %s\n", "METRIC", "COUNT", "P50 ms", "BUDGET", "MAX ms", "BUDGET", "RESULT"
      nb = split(ENVIRON["BUDGETS"], rows, "\n")
      for (i = 1; i <= nb; i++) {
        split(rows[i], b, " "); name = b[1]; c = cnt[name] + 0
        bp = b[2] * scale; bm = (b[3] == "-" ? -1 : b[3] * scale)
        if (!c) { printf "%-10s %6d %9s %9.2f %9s %9s  %s\n", name, 0, "n/a", bp, "n/a", (bm < 0 ? "-" : sprintf("%.2f", bm)), "n/a"; continue }
        # p50 = median (mean of the two middle values for an even count); values are sorted.
        p50 = (c % 2) ? v[name, (c + 1) / 2] : (v[name, c / 2] + v[name, c / 2 + 1]) / 2
        mx = v[name, c]
        ok = (p50 <= bp) && (bm < 0 || mx <= bm)
        if (!ok) pass = 0
        printf "%-10s %6d %9.2f %9.2f %9.2f %9s  %s\n", name, c, p50, bp, mx, (bm < 0 ? "-" : sprintf("%.2f", bm)), (ok ? "ok" : "FAIL")
      }
      print ""
      print (pass ? "PASS" : "FAIL")
      exit (pass ? 0 : 1)
    }
  ' <<<"$pairs"
}

case "${1:-}" in
  idle)    shift; measure_idle "$@" ;;
  latency) shift; measure_latency "$@" ;;
  *)       usage ;;
esac
