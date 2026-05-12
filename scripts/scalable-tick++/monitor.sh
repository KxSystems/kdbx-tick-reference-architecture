#!/bin/bash

# Watchdog script - checks critical processes are alive and restarts dead ones.
# Designed to run via cron (e.g. */1 * * * *) or manually.
#
# Usage:
#   ./monitor.sh -m 2                              # Check all modules, 2 triplets
#   ./monitor.sh -p realtime -m 0                   # Realtime only
#   ./monitor.sh -p query -m 2                      # Query path only
#   ./monitor.sh -p realtime,query -m 2 -e .env     # Explicit both, custom env

e_flag=".env"
s_flag=0
m_flag=0
p_flag="realtime,query"

while getopts 'e:s:m:p:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    s) s_flag="${OPTARG}" ;;
    m) m_flag="${OPTARG}" ;;
    p) p_flag="${OPTARG}" ;;
    *) exit 1 ;;
  esac
done

# Module check helper
has_module() { [[ ",$p_flag," == *",$1,"* ]]; }

# Source env vars
if [ ! -f "$e_flag" ]; then
  echo "Env file not found: $e_flag"
  exit 1
fi
source "$e_flag"

QUERY_TIMEOUT=${QUERY_TIMEOUT:-60}
REST_GW_COUNT=${REST_GW_COUNT:-1}

# Build port arrays (mirror startup.sh interleaved triplet logic)
RDB_PORTS=()
HDB_PORTS=()
QP_PORTS=()
for ((i=0; i<m_flag; i++)); do
  RDB_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 3*i )) )
  HDB_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 3*i + 1 )) )
  QP_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 3*i + 2 )) )
done

# Check if a process is running by procName
is_alive() {
  ps aux | grep "q.*-procName ${1}\b" | grep -v grep > /dev/null 2>&1
}

restarts=0
ts=$(date '+%Y-%m-%dT%H:%M:%S')

check_proc() {
  local name=$1
  if is_alive "$name"; then
    echo "[$ts] [OK]   $name"
  else
    echo "[$ts] [DEAD] $name — restarting..."
    restarts=$((restarts + 1))
    return 1
  fi
}

# ── Realtime module ───────────────────────────────────────────────────────

if has_module "realtime"; then

check_proc "TP" || {
  q kdb-x-platform/tick.q -p $TICK_PORT -s $s_flag -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR -procName TP < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started TP [$TICK_PORT]"
}

if has_module "query"; then
  ALL_HDB_PORTS=($HDB_PORT ${HDB_PORTS[*]})
else
  ALL_HDB_PORTS=($HDB_PORT)
fi
check_proc "RDB" || {
  q kdb-x-platform/r.q -p $RDB_PORT -T $QUERY_TIMEOUT -s $s_flag -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -tpPort $TICK_PORT -hdbPort ${ALL_HDB_PORTS[*]} -procName RDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started RDB [$RDB_PORT]"
}

check_proc "HDB" || {
  q kdb-x-platform/hdb.q -p $HDB_PORT -T $QUERY_TIMEOUT -s $s_flag -hdbDir $HDB_DIR -procName HDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started HDB [$HDB_PORT]"
}

check_proc "FH" || {
  q kdb-x-platform/fh.q -p $FH_PORT -fhDir $FH_ANALYTIC_DIR -fhTimer $FH_TIMER -s $s_flag -tpPort $TICK_PORT -procName FH < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started FH [$FH_PORT]"
}

check_proc "RTE" || {
  q kdb-x-platform/rte.q -p $RTE_PORT -s $s_flag -schemaDir $SCHEMA_DIR -tpPort $TICK_PORT -procName RTE < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started RTE [$RTE_PORT]"
}

fi  # end realtime

# ── Query module ──────────────────────────────────────────────────────────

if has_module "query"; then

check_proc "QR" || {
  q kdb-x-platform/qr.q -p $QR_PORT -s $s_flag -procName QR < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started QR [$QR_PORT]"
  sleep 0.5  # Give QR a moment before starting GW/QPs that depend on it
}

check_proc "GW" || {
  q kdb-x-platform/gw.q -p $GW_PORT -s $s_flag -qrPort $QR_PORT -procName GW < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
  echo "[$ts]         Started GW [$GW_PORT]"
  sleep 0.5  # Give GW a moment before QPs/REST_GWs try to connect
}

for ((i=0; i<m_flag; i++)); do
  check_proc "RDB_$i" || {
    q kdb-x-platform/r.q -p ${RDB_PORTS[$i]} -T $QUERY_TIMEOUT -s $s_flag -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -tpPort $TICK_PORT -hdbPort ${HDB_PORTS[$i]} -procName RDB_$i < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "[$ts]         Started RDB_$i [${RDB_PORTS[$i]}]"
  }

  check_proc "HDB_$i" || {
    q kdb-x-platform/hdb.q -p ${HDB_PORTS[$i]} -T $QUERY_TIMEOUT -s $s_flag -hdbDir $HDB_DIR -procName HDB_$i < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "[$ts]         Started HDB_$i [${HDB_PORTS[$i]}]"
  }

  check_proc "QP_$i" || {
    q kdb-x-platform/qp.q -p ${QP_PORTS[$i]} -T $QUERY_TIMEOUT -s $s_flag \
      -qrPort $QR_PORT -gwPort $GW_PORT \
      -rdbPort ${RDB_PORTS[$i]} -hdbPort ${HDB_PORTS[$i]} \
      -procName QP_$i \
      < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "[$ts]         Started QP_$i [${QP_PORTS[$i]}]"
  }
done

# REST_GWs — all share $REST_PORT via SO_REUSEPORT
for ((i=0; i<REST_GW_COUNT; i++)); do
  check_proc "REST_GW_$i" || {
    q kdb-x-platform/rest-gw.q -p rp,$REST_PORT -s $s_flag \
      -gwPort $GW_PORT -analyticsDir $ANALYTIC_DIR \
      -procName REST_GW_$i \
      < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "[$ts]         Started REST_GW_$i [rp,$REST_PORT]"
  }
done

fi  # end query

# ── Summary ───────────────────────────────────────────────────────────────

if [ $restarts -eq 0 ]; then
  echo "[$ts] All processes healthy."
else
  echo "[$ts] Restarted $restarts process(es)."
fi
