#!/bin/bash

# Restart a specific process without taking down the whole stack
# Run from the project root directory
#
# Usage: ./tick/scripts/restart.sh <procName> [-s secondaries] [-e envfile]
#
# procName: TP | RDB | HDB | FH | RTE | GW
#
# Examples:
#   ./tick/scripts/restart.sh GW
#   ./tick/scripts/restart.sh RTE
#
# Config comes from the shared env file (sourced below), same as
# tick/scripts/startup.sh — edit one place and both stay in sync.

#################
# Configuration #
#################
ENV_FILE="samples/sample_env"

###############
# CLI-parsing #
###############
proc_name=$1
shift

if [ -z "$proc_name" ]; then
  printf "Usage: ./tick/scripts/restart.sh <procName> [-s secondaries] [-e envfile]\n"
  exit 1
fi

s_flag=0

while getopts 's:e:' flag; do
  case "${flag}" in
    s) s_flag="${OPTARG}" ;;
    e) ENV_FILE="${OPTARG}" ;;
    *) exit 1 ;;
  esac
done

# Load shared configuration (defines + exports ports, paths, intervals)
if [ ! -f "$ENV_FILE" ]; then
  echo "Config file not found: $ENV_FILE (run from the project root, or pass -e <file>)" >&2
  exit 1
fi
. "$ENV_FILE"

kill_proc() {
  local pattern=$1
  local pids=""
  # `pgrep -f` is portable (BSD + GNU); -af is not — on macOS BSD `-a` means
  # "include ancestors" and the output is just PIDs, so the awk that followed
  # was a no-op. We then resolve each PID's args via `ps` and require an exact
  # -procName match (followed by space or end of line) so e.g. "RDB" does not
  # also match "RDB_CHAIN_0".
  for pid in $(pgrep -f "q.*-procName $pattern"); do
    local cmd
    cmd=$(ps -p "$pid" -o args= 2>/dev/null)
    echo "$cmd" | grep -qE -- "-procName $pattern( |\$)" && pids="$pids $pid"
  done
  if [ -n "$pids" ]; then
    echo "  Killing $pattern:$pids"
    kill -9 $pids 2>/dev/null
    sleep 0.3
  else
    echo "  No running process found for $pattern"
  fi
}

echo "Restarting [$proc_name]..."

case "$proc_name" in
  TP)
    kill_proc "TP"
    q tick/src/tick.q -p $TICK_PORT -s $s_flag \
      -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR \
      -procName TP < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started TP [$TICK_PORT]"
    ;;

  RDB)
    kill_proc "RDB"
    q tick/src/rdb.q -p $RDB_PORT -s $s_flag \
      -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR \
      -tpPort $TICK_PORT -hdbPort $HDB_PORT \
      -procName RDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started RDB [$RDB_PORT]"
    ;;

  HDB)
    kill_proc "HDB"
    q tick/src/hdb.q -p $HDB_PORT -s $s_flag \
      -hdbDir $HDB_DIR \
      -procName HDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started HDB [$HDB_PORT]"
    ;;

  FH)
    kill_proc "FH"
    q tick/src/fh.q -p $FH_PORT -s $s_flag \
      -fhTimer $FH_TIMER \
      -tpPort $TICK_PORT \
      -procName FH < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started FH [$FH_PORT]"
    ;;

  RTE)
    kill_proc "RTE"
    q tick/src/rte.q -p $RTE_PORT -s $s_flag \
      -tpPort $TICK_PORT \
      -procName RTE < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started RTE [$RTE_PORT]"
    ;;

  GW)
    kill_proc "GW"
    q tick/src/gw.q -p $GW_PORT -s $s_flag \
      -rdbPort $RDB_PORT \
      -hdbPort $HDB_PORT \
      -analyticsDir $ANALYTIC_DIR \
      -procName GW < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started GW [$GW_PORT]"
    ;;

  *)
    echo "Unknown procName: $proc_name"
    echo "Valid: TP | RDB | HDB | FH | RTE | GW"
    exit 1
    ;;
esac

echo "Done."
