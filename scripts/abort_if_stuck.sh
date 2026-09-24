#!/usr/bin/env bash
# Watchdog: if the OMLibraryTesting full coverage run is still on the same
# model as the previous invocation, the worker has been stuck >= the loop
# interval. Send SIGINT to the Distributed worker child so the driver
# records a timeout and moves on.
#
# State files (all under /tmp):
#   /tmp/omjl_current_log.txt      - absolute path to the tee'd coverage log
#   /tmp/omjl_driver_pid.txt       - PID of the driver Julia process
#   /tmp/omjl_loop_last_model.txt  - "MODEL|TIMESTAMP" seen on previous tick
#
# Stdout: one short human-readable status line.

set -u

LOG_PATH_FILE=/tmp/omjl_current_log.txt
DRIVER_PID_FILE=/tmp/omjl_driver_pid.txt
STATE_FILE=/tmp/omjl_loop_last_model.txt
NOW=$(date '+%Y-%m-%d %H:%M:%S')

if [[ ! -s "$LOG_PATH_FILE" ]]; then
    echo "[$NOW] no coverage log path recorded at $LOG_PATH_FILE — nothing to watch"
    exit 0
fi
LOG=$(cat "$LOG_PATH_FILE")
if [[ ! -s "$LOG" ]]; then
    echo "[$NOW] coverage log $LOG missing or empty — nothing to watch"
    exit 0
fi

# Driver PID: re-resolve if the stored one is stale.
DRIVER_PID=""
if [[ -s "$DRIVER_PID_FILE" ]]; then
    DRIVER_PID=$(cat "$DRIVER_PID_FILE")
fi
if [[ -z "$DRIVER_PID" ]] || ! kill -0 "$DRIVER_PID" 2>/dev/null; then
    DRIVER_PID=$(pgrep -f 'run_full_coverage.jl|resume_missing_models.jl' | head -1 || true)
    if [[ -n "$DRIVER_PID" ]]; then
        echo "$DRIVER_PID" > "$DRIVER_PID_FILE"
    fi
fi
if [[ -z "$DRIVER_PID" ]]; then
    echo "[$NOW] driver Julia (run_full_coverage.jl) not running — coverage likely finished or crashed"
    exit 0
fi

# Find the latest "[N/TOTAL] Modelica.Foo.Bar" or "[resume N/TOTAL] ..." line.
LINE=$(grep -E '^\[ Info: \[(resume )?[0-9]+/[0-9]+\] ' "$LOG" | tail -1 || true)
if [[ -z "$LINE" ]]; then
    echo "[$NOW] no model-start line seen in $LOG yet"
    exit 0
fi
# Extract the "N/TOTAL" and the model name, stripping an optional "resume " prefix.
IDX=$(echo "$LINE" | sed -E 's/^\[ Info: \[(resume )?([0-9]+\/[0-9]+)\] .*/\2/')
MODEL=$(echo "$LINE" | sed -E 's/^\[ Info: \[(resume )?[0-9]+\/[0-9]+\] (.*)$/\2/')

PREV_MODEL=""
PREV_TS=""
if [[ -s "$STATE_FILE" ]]; then
    PREV_MODEL=$(cut -d'|' -f1 "$STATE_FILE")
    PREV_TS=$(cut -d'|' -f2 "$STATE_FILE")
fi

action="record"
if [[ -n "$PREV_MODEL" && "$PREV_MODEL" == "$MODEL" ]]; then
    # Same model as last tick → send SIGINT to the worker child.
    WORKER_PIDS=$(pgrep -P "$DRIVER_PID" julia 2>/dev/null || true)
    if [[ -z "$WORKER_PIDS" ]]; then
        action="no_worker_child_found"
    else
        # Send SIGINT twice with a short pause — matches Distributed.interrupt(pid)
        for pid in $WORKER_PIDS; do
            kill -INT "$pid" 2>/dev/null || true
        done
        sleep 1
        for pid in $WORKER_PIDS; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -INT "$pid" 2>/dev/null || true
            fi
        done
        action="SIGINT sent to worker PID(s): $WORKER_PIDS"
    fi
fi

echo "${MODEL}|${NOW}" > "$STATE_FILE"

echo "[$NOW] idx=$IDX model=$MODEL driver_pid=$DRIVER_PID prev_model=\"$PREV_MODEL\" prev_ts=\"$PREV_TS\" action=$action"
