#!/bin/bash

# Dynamically scale the query path without restarting the stack.
# Scales triplets (RDB+HDB+QP) and REST_GW processes independently.
# Usage:
#   Triplets:
#   ./scale.sh up              # Add 1 triplet
#   ./scale.sh up 3            # Add 3 triplets
#   ./scale.sh down            # Remove the last triplet
#   ./scale.sh down 2          # Remove the last 2 triplets
#   ./scale.sh to 5            # Scale to exactly 5 triplets
#   ./scale.sh status          # Show current triplet and REST_GW counts
#   REST_GWs (share $REST_PORT via SO_REUSEPORT):
#   ./scale.sh rest-up         # Add 1 REST_GW
#   ./scale.sh rest-up 3       # Add 3 REST_GWs
#   ./scale.sh rest-down       # Remove the last REST_GW
#   ./scale.sh rest-to 5       # Scale to exactly 5 REST_GWs

e_flag=".env"
s_flag=0

# Parse trailing flags after the positional args
action=$1
count=${2:-1}
shift; shift 2>/dev/null

while getopts 'e:s:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    s) s_flag="${OPTARG}" ;;
    *) ;;
  esac
done

if [ -z "$action" ]; then
  printf "Usage: ./scale.sh <up|down|to|status> [count] [-e envFile] [-s secondaries]\n"
  exit 1
fi

# Source env vars
if [ ! -f "$e_flag" ]; then
  echo "Env file not found: $e_flag"
  exit 1
fi
source "$e_flag"

QUERY_TIMEOUT=${QUERY_TIMEOUT:-60}

# Detect current triplet count by finding the highest index across RDB_N, HDB_N, QP_N
# This handles partial triplets (e.g. QP crashed but RDB/HDB still running)
max_idx=-1
for proc in $(ps aux | grep -oP "(?<=-procName )(RDB|HDB|QP)_\d+"); do
  idx=${proc#*_}
  if [ "$idx" -gt "$max_idx" ] 2>/dev/null; then
    max_idx=$idx
  fi
done
current_count=$(( max_idx + 1 ))

# Detect current REST_GW count the same way
rest_max_idx=-1
for proc in $(ps aux | grep -oP "(?<=-procName )REST_GW_\d+"); do
  idx=${proc#REST_GW_}
  if [ "$idx" -gt "$rest_max_idx" ] 2>/dev/null; then
    rest_max_idx=$idx
  fi
done
rest_current_count=$(( rest_max_idx + 1 ))

# Port calculation for triplet i (interleaved scheme)
rdb_port_for()  { echo $(( PARALLEL_PORT_RANGE_START + 3*$1 )); }
hdb_port_for()  { echo $(( PARALLEL_PORT_RANGE_START + 3*$1 + 1 )); }
qp_port_for()   { echo $(( PARALLEL_PORT_RANGE_START + 3*$1 + 2 )); }

# Check if a process is running by procName
is_running() {
  ps aux | grep "q.*-procName ${1}\b" | grep -v grep > /dev/null 2>&1
}

# Launch a REST_GW at index i (skips if already running). All REST_GWs share
# $REST_PORT via SO_REUSEPORT (rp,PORT).
launch_rest_gw() {
  local i=$1
  if is_running "REST_GW_$i"; then
    echo "  REST_GW_$i already running, skipping"
  else
    q kdb-x-platform/rest-gw.q -p rp,$REST_PORT -s $s_flag \
      -gwPort $GW_PORT \
      -analyticsDir $ANALYTIC_DIR \
      -procName REST_GW_$i \
      < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started REST_GW_$i [rp,$REST_PORT] → GW:$GW_PORT"
  fi
}

# Kill a REST_GW at index i
kill_rest_gw() {
  local i=$1
  local pids=$(ps aux | grep "q.*-procName REST_GW_$i\b" | grep -v grep | awk '{print $2}')
  if [ -n "$pids" ]; then
    echo "$pids" | xargs kill -9 2>/dev/null
    echo "  Killed REST_GW_$i ($pids)"
  fi
}

# Launch a single triplet at index i (skips already-running components)
launch_triplet() {
  local i=$1
  local rdb_p=$(rdb_port_for $i)
  local hdb_p=$(hdb_port_for $i)
  local qp_p=$(qp_port_for $i)

  # RDB (chained read replica)
  if is_running "RDB_$i"; then
    echo "  RDB_$i already running, skipping"
  else
    q kdb-x-platform/r.q -p $rdb_p -T $QUERY_TIMEOUT -s $s_flag -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -tpPort $TICK_PORT -hdbPort $hdb_p -procName RDB_$i < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started RDB_$i [$rdb_p]"
  fi

  # HDB
  if is_running "HDB_$i"; then
    echo "  HDB_$i already running, skipping"
  else
    q kdb-x-platform/hdb.q -p $hdb_p -T $QUERY_TIMEOUT -s $s_flag -hdbDir $HDB_DIR -procName HDB_$i < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started HDB_$i [$hdb_p]"
  fi

  # QP (self-registers with QR on startup)
  if is_running "QP_$i"; then
    echo "  QP_$i already running, skipping"
  else
    q kdb-x-platform/qp.q -p $qp_p -T $QUERY_TIMEOUT -s $s_flag \
      -qrPort $QR_PORT -gwPort $GW_PORT \
      -rdbPort $rdb_p -hdbPort $hdb_p \
      -procName QP_$i \
      < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started QP_$i [$qp_p] -> RDB_$i:$rdb_p HDB_$i:$hdb_p"
  fi
}

# Kill a single triplet at index i
kill_triplet() {
  local i=$1
  for proc in "QP_$i" "RDB_$i" "HDB_$i"; do
    local pids=$(ps aux | grep "q.*-procName ${proc}\b" | grep -v grep | awk '{print $2}')
    if [ -n "$pids" ]; then
      echo "$pids" | xargs kill -9 2>/dev/null
      echo "  Killed $proc ($pids)"
    fi
  done
}

case "$action" in
  status)
    echo "Current triplet count: $current_count"
    if [ $current_count -gt 0 ]; then
      echo "  Port allocation:"
      for ((i=0; i<current_count; i++)); do
        echo "    Triplet $i: RDB_$i:$(rdb_port_for $i) HDB_$i:$(hdb_port_for $i) QP_$i:$(qp_port_for $i)"
      done
    fi
    echo "Current REST_GW count: $rest_current_count (shared port: ${REST_PORT:-unset})"
    ;;
  up)
    echo "Scaling up by $count (current: $current_count -> target: $(( current_count + count )))"
    for ((i=current_count; i<current_count+count; i++)); do
      launch_triplet $i
    done
    echo "Done. New triplet count: $(( current_count + count ))"
    ;;
  down)
    if [ $current_count -eq 0 ]; then
      echo "No triplets running, nothing to scale down."
      exit 0
    fi
    target=$(( current_count - count ))
    if [ $target -lt 0 ]; then target=0; fi
    echo "Scaling down by $count (current: $current_count -> target: $target)"
    for ((i=current_count-1; i>=target; i--)); do
      kill_triplet $i
    done
    echo "Done. New triplet count: $target"
    ;;
  to)
    target=$count
    if [ $target -eq $current_count ]; then
      echo "Already at $target triplets."
      exit 0
    elif [ $target -gt $current_count ]; then
      echo "Scaling up (current: $current_count -> target: $target)"
      for ((i=current_count; i<target; i++)); do
        launch_triplet $i
      done
    else
      echo "Scaling down (current: $current_count -> target: $target)"
      for ((i=current_count-1; i>=target; i--)); do
        kill_triplet $i
      done
    fi
    echo "Done. New triplet count: $target"
    ;;
  rest-up)
    echo "Scaling REST_GWs up by $count (current: $rest_current_count -> target: $(( rest_current_count + count )))"
    for ((i=rest_current_count; i<rest_current_count+count; i++)); do
      launch_rest_gw $i
    done
    echo "Done. New REST_GW count: $(( rest_current_count + count ))"
    ;;
  rest-down)
    if [ $rest_current_count -eq 0 ]; then
      echo "No REST_GWs running, nothing to scale down."
      exit 0
    fi
    target=$(( rest_current_count - count ))
    if [ $target -lt 0 ]; then target=0; fi
    echo "Scaling REST_GWs down by $count (current: $rest_current_count -> target: $target)"
    for ((i=rest_current_count-1; i>=target; i--)); do
      kill_rest_gw $i
    done
    echo "Done. New REST_GW count: $target"
    ;;
  rest-to)
    target=$count
    if [ $target -eq $rest_current_count ]; then
      echo "Already at $target REST_GWs."
      exit 0
    elif [ $target -gt $rest_current_count ]; then
      echo "Scaling REST_GWs up (current: $rest_current_count -> target: $target)"
      for ((i=rest_current_count; i<target; i++)); do
        launch_rest_gw $i
      done
    else
      echo "Scaling REST_GWs down (current: $rest_current_count -> target: $target)"
      for ((i=rest_current_count-1; i>=target; i--)); do
        kill_rest_gw $i
      done
    fi
    echo "Done. New REST_GW count: $target"
    ;;
  *)
    echo "Unknown action: $action"
    echo "Valid: up [N] | down [N] | to N | rest-up [N] | rest-down [N] | rest-to N | status"
    exit 1
    ;;
esac
