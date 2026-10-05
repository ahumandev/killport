#!/usr/bin/env bash

set -euo pipefail

if (( $# == 0 )) || [[ -z "$1" ]]; then
  echo "Usage: killport <port>"
  exit 1
fi

if (( $# > 1 )); then
  echo "Error: expected exactly one port, got $# arguments." >&2
  echo "Usage: killport <port>" >&2
  exit 1
fi

RAW_PORT="$1"
# Strip leading zeros so "0080" is decimal 80, never octal.
PORT="${RAW_PORT#"${RAW_PORT%%[!0]*}"}"
if [[ ! "$RAW_PORT" =~ ^[0-9]+$ ]] || [[ -z "$PORT" ]] || (( ${#PORT} > 5 )) || (( PORT > 65535 )); then
  echo "Error: invalid port '$RAW_PORT' (expected an integer from 1 to 65535)." >&2
  exit 1
fi

case "$(uname -s 2>/dev/null || true)" in
  MINGW*|MSYS*|CYGWIN*) BACKEND="windows" ;;
  *) BACKEND="posix" ;;
esac

backend() {
  local fn="$1"
  shift
  "${BACKEND}_${fn}" "$@"
}

is_permission_error() {
  [[ "$1" == *"Operation not permitted"* || "$1" == *"Permission denied"* || "$1" == *"Access is denied"* ]]
}

# Usage: report_stop_error <action> <pid> <name> <error>
report_stop_error() {
  if is_permission_error "$4"; then
    echo "Error: cannot $1 PID $2 ($3): permission denied. Run as its owner or with sufficient privileges." >&2
  else
    echo "Error: cannot $1 PID $2 ($3): ${4:-process may have exited or is protected}." >&2
  fi
}

# Bounded poll: 10 checks, 0.1s apart.
wait_for_exit() {
  local _
  for _ in {1..10}; do
    if ! backend is_alive "$1"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# ---------------------------------------------------------------------------
# posix backend (Linux and other Unix): lsof, ps, kill.
# ---------------------------------------------------------------------------

posix_init() {
  # Find only TCP listener PIDs; fuser can include client connections.
  if ! command -v lsof &>/dev/null; then
    echo "Error: 'lsof' is required." >&2
    exit 1
  fi
  SOFT_REQUEST="graceful stop"
  SOFT_DONE="stopped gracefully"
  SOFT_FAILURE_FORCES=0
}

posix_find_pids() {
  lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk '/^[0-9]+$/ && !seen[$0]++ { print }' || true
}

posix_name() {
  ps -p "$1" -o comm= 2>/dev/null || echo "unknown"
}

posix_is_alive() {
  local err
  if err=$(kill -0 "$1" 2>&1); then
    return 0
  fi
  # EPERM means the process exists but belongs to someone else.
  is_permission_error "$err"
}

posix_soft_stop() {
  kill -TERM "$1"
}

posix_force_stop() {
  kill -KILL "$1"
}

# ---------------------------------------------------------------------------
# windows backend (MINGW/MSYS/Cygwin): native netstat.exe, tasklist.exe, taskkill.exe.
# MSYS kill only reaches MSYS PIDs, so native Windows PIDs must use native tools.
# ---------------------------------------------------------------------------

# Resolve a native Windows tool, preferring System32 over MSYS/Cygwin lookalikes on PATH.
windows_tool() {
  local name="$1" root candidate
  if [[ -n "${KILLPORT_WINDOWS_BIN_DIR:-}" ]]; then
    candidate="$KILLPORT_WINDOWS_BIN_DIR/$name.exe"
    [[ -x "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
    return 0
  fi
  root="${SYSTEMROOT:-${SystemRoot:-}}"
  if [[ -n "$root" ]] && command -v cygpath &>/dev/null; then
    candidate="$(cygpath -u "$root")/System32/$name.exe"
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  command -v "$name.exe"
}

windows_init() {
  local tool
  for tool in netstat tasklist taskkill; do
    if ! windows_tool "$tool" &>/dev/null; then
      echo "Error: '$tool.exe' is required but was not found in Windows System32 or PATH." >&2
      exit 1
    fi
  done
  NETSTAT=$(windows_tool netstat)
  TASKLIST=$(windows_tool tasklist)
  TASKKILL=$(windows_tool taskkill)

  # Keep "/PID", "/FI" etc. from being rewritten as POSIX paths.
  export MSYS_NO_PATHCONV=1
  export MSYS2_ARG_CONV_EXCL="*"

  # taskkill without /F only asks windows to close; it is not a POSIX TERM.
  SOFT_REQUEST="normal stop (taskkill without /F)"
  SOFT_DONE="stopped after normal stop request"
  SOFT_FAILURE_FORCES=1
}

# Listener rows have a foreign port of 0, which stays valid on localized Windows
# where the LISTENING state text is translated. UDP rows have no state/PID column
# layout match (NF < 5) and are skipped.
windows_find_pids() {
  local out
  if ! out=$("$NETSTAT" -ano 2>&1); then
    echo "Error: netstat failed: ${out:-no output}" >&2
    return 1
  fi
  printf '%s\n' "$out" | tr -d '\r' | awk -v port="$1" '
    $1 == "TCP" && NF >= 5 {
      local_port = $2
      sub(/^.*:/, "", local_port)
      pid = $NF
      if (local_port == port && $3 ~ /:0$/ && pid ~ /^[0-9]+$/ && pid !~ /^0+$/ && !seen[pid]++) {
        print pid
      }
    }
  ' || { echo "Error: failed to parse netstat output." >&2; return 1; }
}

# Prints image name. Returns 0 found, 1 not found, 2 tasklist failed.
windows_task_name() {
  local out name
  if ! out=$("$TASKLIST" /FI "PID eq $1" /FO CSV /NH 2>&1); then
    return 2
  fi
  name=$(printf '%s\n' "$out" | tr -d '\r' | awk -F'","' -v pid="$1" '
    $2 == pid { sub(/^"/, "", $1); print $1; exit }
  ')
  [[ -n "$name" ]] || return 1
  printf '%s\n' "$name"
}

windows_name() {
  windows_task_name "$1" || echo "unknown"
}

windows_is_alive() {
  local rc=0
  windows_task_name "$1" >/dev/null || rc=$?
  if (( rc == 1 )); then
    return 1
  fi
  if (( rc == 2 )); then
    echo "Warning: cannot verify PID $1 with tasklist; assuming it is still running." >&2
  fi
  return 0
}

# Prints taskkill output on one line; keeps taskkill's exit status.
windows_run_taskkill() {
  local out rc=0
  out=$("$TASKKILL" "$@" 2>&1) || rc=$?
  printf '%s' "$out" | tr -d '\r' | tr '\n' ' '
  return "$rc"
}

# Single PID only: never /T, so child processes are not touched.
windows_soft_stop() {
  windows_run_taskkill /PID "$1"
}

windows_force_stop() {
  windows_run_taskkill /F /PID "$1"
}

# ---------------------------------------------------------------------------

backend init

if ! PID_OUTPUT=$(backend find_pids "$PORT"); then
  exit 1
fi

PIDS=()
if [[ -n "$PID_OUTPUT" ]]; then
  mapfile -t PIDS <<<"$PID_OUTPUT"
fi

if (( ${#PIDS[@]} == 0 )); then
  echo "No process found on port $PORT"
  exit 0
fi

FAILURES=0

for PID in "${PIDS[@]}"; do
  PNAME=$(backend name "$PID")

  echo "Requesting $SOFT_REQUEST for process $PID ($PNAME) on port $PORT..."
  if ! STOP_ERROR=$(backend soft_stop "$PID" 2>&1); then
    if is_permission_error "$STOP_ERROR"; then
      report_stop_error stop "$PID" "$PNAME" "$STOP_ERROR"
      FAILURES=$((FAILURES + 1))
      continue
    fi
    if ! backend is_alive "$PID"; then
      echo "Process $PID ($PNAME) already exited."
      continue
    fi
    if (( ! SOFT_FAILURE_FORCES )); then
      report_stop_error stop "$PID" "$PNAME" "$STOP_ERROR"
      FAILURES=$((FAILURES + 1))
      continue
    fi
    echo "Normal stop request not accepted for process $PID ($PNAME): ${STOP_ERROR:-no details}"
  elif wait_for_exit "$PID"; then
    echo "Process $PID ($PNAME) $SOFT_DONE."
    continue
  fi

  echo "Process $PID ($PNAME) still running; forcing termination..."
  if ! KILL_ERROR=$(backend force_stop "$PID" 2>&1); then
    if ! is_permission_error "$KILL_ERROR" && ! backend is_alive "$PID"; then
      echo "Process $PID ($PNAME) already exited."
      continue
    fi
    report_stop_error force-stop "$PID" "$PNAME" "$KILL_ERROR"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  echo "Process $PID ($PNAME) received forced termination."
  if ! wait_for_exit "$PID"; then
    echo "Error: PID $PID ($PNAME) is still running after forced termination." >&2
    FAILURES=$((FAILURES + 1))
  fi
done

if (( FAILURES > 0 )); then
  exit 1
fi

echo "Done."
