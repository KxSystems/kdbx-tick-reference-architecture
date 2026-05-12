#!/bin/bash

# Watchdog — checks all stack processes are alive and restarts dead ones.
# Designed to run via cron (e.g. */1 * * * *) or manually.
#
# Usage:
#   ./scripts/tick/monitor.sh [-e envFile] [-s secondaries] [-m chainedRdbs]

e_flag=".env"
s_flag=0
m_flag=0

while getopts 'e:s:m:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    s) s_flag="${OPTARG}" ;;
    m) m_flag="${OPTARG}" ;;
    *) exit 1 ;;
  esac
done

if [ ! -f "$e_flag" ]; then
  echo "Env file not found: $e_flag"
  exit 1
fi
source "$e_flag"

# Paired port scheme (mirrors startup.sh)
RDB_CHAIN_PORTS=()
HDB_EXTRA_PORTS=()
for ((i=0; i<m_flag; i++)); do
  RDB_CHAIN_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 2*i )) )
  HDB_EXTRA_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 2*i + 1 )) )
done
ALL_HDB_PORTS=($HDB_PORT ${HDB_EXTRA_PORTS[*]})

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
  q kdb-x-platform/tick.q -p $TICK_PORT -s $s_flag \
    -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR \
    -procName TP < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started TP [$TICK_PORT]"
}

check_proc "RDB" || {
  q kdb-x-platform/r.q -p $RDB_PORT -s $s_flag \
    -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR \
    -tpPort $TICK_PORT -hdbPort ${ALL_HDB_PORTS[*]} \
    -procName RDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started RDB [$RDB_PORT]"
}

for ((i=0; i<m_flag; i++)); do
  check_proc "RDB_CHAIN_$i" || {
    q kdb-x-platform/r.q -p ${RDB_CHAIN_PORTS[$i]} -s $s_flag \
      -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR \
      -tpPort $TICK_PORT -hdbPort ${ALL_HDB_PORTS[*]} \
      -procName RDB_CHAIN_$i < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "[$ts]         Started RDB_CHAIN_$i [${RDB_CHAIN_PORTS[$i]}]"
  }
done

check_proc "HDB" || {
  q kdb-x-platform/hdb.q -p $HDB_PORT -s $s_flag \
    -hdbDir $HDB_DIR \
    -procName HDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started HDB [$HDB_PORT]"
}

for ((i=0; i<m_flag; i++)); do
  check_proc "HDB_EXTRA_$i" || {
    q kdb-x-platform/hdb.q -p ${HDB_EXTRA_PORTS[$i]} -s $s_flag \
      -hdbDir $HDB_DIR \
      -procName HDB_EXTRA_$i < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "[$ts]         Started HDB_EXTRA_$i [${HDB_EXTRA_PORTS[$i]}]"
  }
done

check_proc "FH" || {
  q kdb-x-platform/fh.q -p $FH_PORT -s $s_flag \
    -fhDir $FH_ANALYTIC_DIR -fhTimer $FH_TIMER \
    -tpPort $TICK_PORT \
    -procName FH < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started FH [$FH_PORT]"
}

check_proc "RTE" || {
  q kdb-x-platform/rte.q -p $RTE_PORT -s $s_flag \
    -enrichFile $RTE_ENRICH_FILE \
    -tpPort $TICK_PORT \
    -procName RTE < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started RTE [$RTE_PORT]"
}

check_proc "GW" || {
  q kdb-x-platform/gw.q -p $GW_PORT -s $s_flag \
    -rdbPort $RDB_PORT \
    -crdbPort ${RDB_CHAIN_PORTS[*]} \
    -hdbPort ${ALL_HDB_PORTS[*]} \
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
