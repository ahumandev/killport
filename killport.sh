#!/usr/bin/env bash

set -euo pipefail

PORT="${1:-}"

if [[ -z "$PORT" ]]; then
  echo "Usage: killport <port>"
  exit 1
fi

# Find only TCP listener PIDs; fuser can include client connections.
if ! command -v lsof &>/dev/null; then
  echo "Error: 'lsof' is required." >&2
  exit 1
fi

mapfile -t PIDS < <(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk '/^[0-9]+$/ && !seen[$0]++ { print }' || true)

if (( ${#PIDS[@]} == 0 )); then
  echo "No process found on port $PORT"
  exit 0
fi

FAILURES=0

for PID in "${PIDS[@]}"; do
  PNAME=$(ps -p "$PID" -o comm= 2>/dev/null || echo "unknown")

  echo "Requesting graceful stop for process $PID ($PNAME) on port $PORT..."
  if ! TERM_ERROR=$(kill -TERM "$PID" 2>&1); then
    if [[ "$TERM_ERROR" == *"Operation not permitted"* || "$TERM_ERROR" == *"Permission denied"* ]]; then
      echo "Error: cannot stop PID $PID ($PNAME): permission denied. Run as its owner or with sufficient privileges." >&2
    else
      echo "Error: cannot stop PID $PID ($PNAME): ${TERM_ERROR:-process may have exited or is protected}." >&2
    fi
    FAILURES=$((FAILURES + 1))
    continue
  fi

  STOPPED_GRACEFULLY=0
  for _ in {1..10}; do
    if ! kill -0 "$PID" 2>/dev/null; then
      STOPPED_GRACEFULLY=1
      break
    fi
    sleep 0.1
  done

  if (( STOPPED_GRACEFULLY )); then
    echo "Process $PID ($PNAME) stopped gracefully."
    continue
  fi

  echo "Process $PID ($PNAME) still running; forcing termination..."
  if ! KILL_ERROR=$(kill -KILL "$PID" 2>&1); then
    if [[ "$KILL_ERROR" == *"Operation not permitted"* || "$KILL_ERROR" == *"Permission denied"* ]]; then
      echo "Error: cannot force-stop PID $PID ($PNAME): permission denied. Run as its owner or with sufficient privileges." >&2
    else
      echo "Error: cannot force-stop PID $PID ($PNAME): ${KILL_ERROR:-process may have exited or is protected}." >&2
    fi
    FAILURES=$((FAILURES + 1))
  else
    echo "Process $PID ($PNAME) received forced termination."
  fi
done

if (( FAILURES > 0 )); then
  exit 1
fi

echo "Done."
