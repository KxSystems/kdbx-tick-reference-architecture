#!/bin/bash

# Watchdog — checks all stack processes are alive and restarts dead ones.
# Designed to run via cron (e.g. */1 * * * *) or manually.
#
# Usage:
#   ./tick/scripts/monitor.sh [-e envFile] [-s secondaries]

e_flag=".env"
s_flag=0

while getopts 'e:s:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    s) s_flag="${OPTARG}" ;;
    *) exit 1 ;;
  esac
done

if [ ! -f "$e_flag" ]; then
  echo "Env file not found: $e_flag"
  exit 1
fi
source "$e_flag"

is_alive() {
  pgrep -af "q.*-procName ${1}\b" > /dev/null 2>&1
}

restarts=0
ts=$(date '+%Y-%m-%dT%H:%M:%S')

check_proc() {
  local name=$1
  if is_alive "$name"; then
    echo "[$ts] [OK]   $name"
  else
    echo "[$ts] [DEAD] $name — restarting..."
    restarts=$(( restarts + 1 ))
    return 1
  fi
}

# ── Core processes ────────────────────────────────────────────────────────

check_proc "TP" || {
  q tick/tick/tick.q -p $TICK_PORT -s $s_flag \
    -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR \
    -procName TP < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started TP [$TICK_PORT]"
}

check_proc "RDB" || {
  q tick/tick/rdb.q -p $RDB_PORT -s $s_flag \
    -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR \
    -tpPort $TICK_PORT -hdbPort $HDB_PORT \
    -procName RDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started RDB [$RDB_PORT]"
}

check_proc "HDB" || {
  q tick/tick/hdb.q -p $HDB_PORT -s $s_flag \
    -hdbDir $HDB_DIR \
    -procName HDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started HDB [$HDB_PORT]"
}

check_proc "FH" || {
  q tick/tick/fh.q -p $FH_PORT -s $s_flag \
    -fhDir $FH_ANALYTIC_DIR -fhTimer $FH_TIMER \
    -tpPort $TICK_PORT \
    -procName FH < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started FH [$FH_PORT]"
}

check_proc "RTE" || {
  q tick/tick/rte.q -p $RTE_PORT -s $s_flag \
    -enrichFile $RTE_ENRICH_FILE \
    -tpPort $TICK_PORT \
    -procName RTE < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started RTE [$RTE_PORT]"
}

check_proc "GW" || {
  q tick/tick/gw.q -p $GW_PORT -s $s_flag \
    -rdbPort $RDB_PORT \
    -hdbPort $HDB_PORT \
    -analyticsDir $ANALYTIC_DIR \
    -procName GW < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started GW [$GW_PORT]"
}

# ── Summary ───────────────────────────────────────────────────────────────

if [ $restarts -eq 0 ]; then
  echo "[$ts] All processes healthy."
else
  echo "[$ts] Restarted $restarts process(es)."
fi
